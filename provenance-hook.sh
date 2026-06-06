#!/usr/bin/env bash
#
# provenance-hook.sh — shell-enforced entry points for provenance-kit.
# Source this from a launcher (start-prd.sh, start-techstack.sh,
# start-feature.sh); it exposes two functions:
#
#   provenance_gate <manifest>
#       Enforces the project's declared provenance policy at launch time.
#       If prompt_provenance.enabled is true AND attestation.required is true
#       but no usable GPG signing key is configured, it FAILS LOUDLY (exit 1).
#       This is the gate that turns "the protocol says sign" into "the launcher
#       refuses to start an unsignable build." No-op when the manifest does not
#       opt in (missing block or enabled: false).
#
#   provenance_open_session <manifest> <project_dir> <prompt_lib> <start_prompt_rel> <launcher>
#       Opens a provenance session: writes the immutable
#       .build-provenance/session_<uuid>/manifest.yaml per
#       prompts/Provenance_Init.md (harness, session id,
#       invocation cwd, starting prompt + sha256, library/project commits,
#       genesis_hash anchor), initializes an empty append-only audit.yaml and
#       an in-progress summary.json, and back-references the session in the
#       project manifest. Echoes the session directory path on stdout.
#
# What is and isn't enforced here (be honest about it):
#   - ENFORCED at the shell boundary: the GPG-policy gate and the creation of an
#     immutable, genesis-anchored session manifest before the agent runs.
#   - STILL INSTRUCTED (inside the agent session): per-agent-step audit entries
#     and the final signed attestation. A launcher shell cannot observe the
#     agent's in-session tool calls; that capture needs harness cooperation
#     (Claude Code / opencode hooks) and is tracked separately.
#
# Dependencies: coreutils, git, gpg (only when attestation.required), and one of
# {sha256sum, shasum}. Manifest reads prefer yq, then python3+PyYAML, then a
# grep fallback for the two fields the gate needs.
#
# Safe to source under `set -euo pipefail`. Honors PROV_DRY_RUN=1 (validate the
# gate but write nothing) and PROVENANCE_DISABLE=1 (skip entirely).

# Resolve the provenance-kit tool root from this script's own location and export
# it so the harness hooks can locate lib/provenance_chain.py under the TOOL,
# independent of the prompt library being hashed (PROMPT_LIBRARY_PATH).
PROVENANCE_KIT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"; export PROVENANCE_KIT_PATH

# ────────────────────────────── small helpers ────────────────────────────
_prov_have() { command -v "$1" >/dev/null 2>&1; }

_prov_sha256() {
  if _prov_have sha256sum; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

_prov_uuid() {
  if _prov_have uuidgen; then uuidgen | tr 'A-Z' 'a-z'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  else python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# _prov_yaml_get <file> <dotted.path> — echo a scalar value, or empty if absent.
# Tiers: yq → python3+PyYAML → grep fallback (only for the two gate fields).
_prov_yaml_get() {
  local file="$1" path="$2"
  [[ -f "$file" ]] || return 0
  if _prov_have yq; then
    local v; v="$(yq -r ".${path} // \"\"" "$file" 2>/dev/null || true)"
    [[ "$v" == "null" ]] && v=""
    printf '%s' "$v"; return 0
  fi
  if _prov_have python3; then
    python3 - "$file" "$path" <<'PY' 2>/dev/null || true
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        d = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
cur = d
for k in sys.argv[2].split('.'):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
print(cur if not isinstance(cur, bool) else str(cur).lower())
PY
    return 0
  fi
  # grep fallback — only reliable for the gate's two fields.
  case "$path" in
    prompt_provenance.enabled)
      awk '/^prompt_provenance:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]+enabled:/{print;exit}' \
        "$file" | sed -E 's/.*enabled:[[:space:]]*//; s/[[:space:]]*#.*//' ;;
    prompt_provenance.attestation.required)
      awk '/^prompt_provenance:/{f=1} f&&/^[[:space:]]+required:/{print;exit}' \
        "$file" | sed -E 's/.*required:[[:space:]]*//; s/[[:space:]]*#.*//' ;;
  esac
}

_prov_truthy() { [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]; }

# ────────────────────────────── harness detection ────────────────────────
# Sets PROV_HARNESS_NAME and PROV_HARNESS_SESSION. Matches Provenance_Init.md.
_prov_harness_detect() {
  if [[ -n "${CLAUDE_SESSION_ID:-}" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDECODE:-}" ]]; then
    PROV_HARNESS_NAME="claude-code"
    PROV_HARNESS_SESSION="${CLAUDE_SESSION_ID:-unknown}"
  elif [[ -n "${OPENCODE_SESSION_ID:-}" || -n "${OPENCODE:-}" ]] || _prov_have opencode; then
    PROV_HARNESS_NAME="opencode"
    PROV_HARNESS_SESSION="${OPENCODE_SESSION_ID:-unknown}"
  else
    PROV_HARNESS_NAME="unknown"
    PROV_HARNESS_SESSION="unknown"
  fi
}

# ────────────────────────────── the gate ─────────────────────────────────
# provenance_gate <manifest>
# Returns 0 (proceed) when provenance is disabled or its policy is satisfiable.
# Exits 1 when the project requires signed attestation but no key is usable.
provenance_gate() {
  local manifest="$1"
  [[ "${PROVENANCE_DISABLE:-0}" == "1" ]] && { echo "ℹ provenance: disabled via PROVENANCE_DISABLE=1" >&2; return 0; }

  local enabled; enabled="$(_prov_yaml_get "$manifest" prompt_provenance.enabled)"
  if ! _prov_truthy "${enabled:-false}"; then
    return 0   # project hasn't opted in — silent no-op, old manifests keep working
  fi

  local required; required="$(_prov_yaml_get "$manifest" prompt_provenance.attestation.required)"
  if _prov_truthy "${required:-false}"; then
    if [[ -z "${GPG_SIGNING_KEY_ID:-}" ]]; then
      echo "✗ provenance gate: prompt_provenance.attestation.required is true but" >&2
      echo "  GPG_SIGNING_KEY_ID is not set in .env. This build could not be signed" >&2
      echo "  at completion. Set a signing key or set attestation.required: false." >&2
      echo "    1. gpg --full-generate-key" >&2
      echo "    2. gpg --list-secret-keys --keyid-format LONG" >&2
      echo "    3. add GPG_SIGNING_KEY_ID=<id> to .env" >&2
      exit 1
    fi
    if ! _prov_have gpg; then
      echo "✗ provenance gate: gpg not found in PATH but attestation is required." >&2
      exit 1
    fi
    if ! gpg --list-secret-keys "$GPG_SIGNING_KEY_ID" >/dev/null 2>&1; then
      echo "✗ provenance gate: GPG secret key '$GPG_SIGNING_KEY_ID' not found." >&2
      echo "  Run: gpg --list-secret-keys --keyid-format LONG" >&2
      exit 1
    fi
    echo "✓ provenance gate: signing key $GPG_SIGNING_KEY_ID present"
  fi
  return 0
}

# ────────────────────────────── open a session ───────────────────────────
# provenance_open_session <manifest> <project_dir> <prompt_lib> <start_prompt_rel> <launcher>
# Optional env: PROV_CLI_ARGS, PROV_INITIAL_MESSAGE.
# Echoes the session directory path. On PROV_DRY_RUN=1, echoes a placeholder
# and writes nothing.
provenance_open_session() {
  local manifest="$1" project_dir="$2" prompt_lib="$3" start_prompt_rel="$4" launcher="$5"

  local enabled; enabled="$(_prov_yaml_get "$manifest" prompt_provenance.enabled)"
  if [[ "${PROVENANCE_DISABLE:-0}" == "1" ]] || ! _prov_truthy "${enabled:-false}"; then
    printf '%s' ""    # provenance off — caller treats empty as "no session"
    return 0
  fi

  if [[ "${PROV_DRY_RUN:-0}" == "1" ]]; then
    printf '%s' ".build-provenance/session_<uuid>  (dry-run: not created)"
    return 0
  fi

  _prov_harness_detect
  local session_id
  if [[ "$PROV_HARNESS_SESSION" != "unknown" ]]; then session_id="$PROV_HARNESS_SESSION"
  else session_id="$(_prov_uuid)"; fi

  local storage_root; storage_root="$(_prov_yaml_get "$manifest" prompt_provenance.storage_root)"
  storage_root="${storage_root:-.build-provenance}"
  local session_dir="$storage_root/session_${session_id}"
  mkdir -p "$project_dir/$session_dir"
  local abs="$project_dir/$session_dir"

  # Commits that define this build.
  local project_commit project_remote lib_commit lib_remote
  project_commit="$(git -C "$project_dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  project_remote="$(git -C "$project_dir" config --get remote.origin.url 2>/dev/null || echo none)"
  lib_commit="$(git -C "$prompt_lib" rev-parse HEAD 2>/dev/null || echo unknown)"
  lib_remote="$(git -C "$prompt_lib" config --get remote.origin.url 2>/dev/null || echo none)"

  local started_at; started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  local env_fp; env_fp="$(env | cut -d= -f1 | sort | _prov_sha256)"

  # Starting prompt hash (the agent prompt this launcher is about to invoke).
  local start_sha="unknown"
  if [[ -f "$prompt_lib/$start_prompt_rel" ]]; then
    start_sha="$(_prov_sha256 < "$prompt_lib/$start_prompt_rel")"
  fi

  local initial_msg="${PROV_INITIAL_MESSAGE:-Launched via $launcher (no interactive user message; primer is launcher-generated).}"
  local cli_args="${PROV_CLI_ARGS:-}"

  # Write manifest.yaml WITHOUT the genesis_hash line first.
  {
    printf '# %s/manifest.yaml  — IMMUTABLE (written by provenance-hook.sh)\n' "$session_dir"
    printf 'schema: provenance/manifest@1\n'
    printf 'session_id: "%s"\n' "$session_id"
    printf 'started_at: "%s"\n' "$started_at"
    printf 'invocation_cwd: "%s"\n' "$project_dir"
    printf 'launcher: "%s"\n' "$launcher"
    printf '\nharness:\n'
    printf '  name: "%s"\n' "$PROV_HARNESS_NAME"
    printf '  version: null\n'
    printf '  session_id: "%s"\n' "$PROV_HARNESS_SESSION"
    printf '\nuser_inputs:\n'
    printf '  starting_prompt:\n'
    printf '    path: "%s"\n' "$start_prompt_rel"
    printf '    sha256: "%s"\n' "$start_sha"
    printf '  cli_args: "%s"\n' "$cli_args"
    printf '  initial_user_message: |\n'
    # block scalar — indent each line by 4 spaces; recorded, never executed
    printf '%s\n' "$initial_msg" | sed 's/^/    /'
    printf '  registered_inputs: []\n'
    printf '  env_fingerprint: "%s"\n' "$env_fp"
    printf '\nlibrary:\n'
    printf '  commit: "%s"\n' "$lib_commit"
    printf '  remote: "%s"\n' "$lib_remote"
    printf '  path: "%s"\n' "$prompt_lib"
    printf '\nproject:\n'
    printf '  commit_at_init: "%s"\n' "$project_commit"
    printf '  remote: "%s"\n' "$project_remote"
  } > "$abs/manifest.yaml"

  # Compute genesis_hash over the canonical body (file minus the genesis line),
  # exactly as Provenance_Init.md / Provenance_Verify.md specify, then append.
  local genesis
  genesis="$(grep -v '^genesis_hash:' "$abs/manifest.yaml" | _prov_sha256)"
  printf 'genesis_hash: "%s"\n' "$genesis" >> "$abs/manifest.yaml"

  # Initialize the append-only audit log and the rolled-up summary.
  printf 'schema: provenance/audit@1\nentries: []\n' > "$abs/audit.yaml"
  printf '{"schema":"provenance/summary@1","session_id":"%s","status":"in_progress","genesis_hash":"%s"}\n' \
    "$session_id" "$genesis" > "$abs/summary.json"

  # Back-reference the session in the project manifest (best-effort; non-fatal).
  # Prefer yq; fall back to targeted sed so the keys are set even without yq,
  # without reserializing the file (which would drop comments). The two keys
  # are unique to the prompt_provenance block, so line-matching is safe.
  if _prov_have yq; then
    yq -i ".prompt_provenance.current_session = \"$session_dir/\" | .prompt_provenance.library_commit_at_init = \"$lib_commit\"" \
      "$manifest" 2>/dev/null || true
  else
    sed -i.provbak -E \
      -e "s|^([[:space:]]*current_session:).*|\1 \"$session_dir/\"|" \
      -e "s|^([[:space:]]*library_commit_at_init:).*|\1 \"$lib_commit\"|" \
      "$manifest" 2>/dev/null && rm -f "${manifest}.provbak" || true
  fi

  printf '%s' "$session_dir"
}
