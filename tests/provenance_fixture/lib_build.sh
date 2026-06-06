#!/usr/bin/env bash
#
# lib_build.sh — shared helper that builds a known-good provenance session for
# the fixture tests. Sourced by run_parity_test.sh and tamper_test.sh so the
# canonical "good build" lives in exactly one place.
#
# Exposes:
#   prov_require_deps
#   prov_setup_gpg <build_dir>         # sets GNUPGHOME, GPG_SIGNING_KEY_ID, PROV_GPG_OK
#   prov_build_known_good <build_dir> [variant]  # full pipeline; sets PROV_SESSION_DIR, PROV_BUILD_COMMIT
#                                                 # variant 'b' diverges (skips an agent, phones home, more tokens)
#
# All progress goes to stdout; the functions communicate results via globals
# (not stdout capture), so callers can print freely.

_LB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROV_FIXTURE_DIR="$_LB_DIR"
KIT="$(cd "$_LB_DIR/../.." && pwd)"           # repo root = the provenance-kit TOOL
PROV_REF="$_LB_DIR/provenance_ref.py"
PROV_HOOK="$KIT/provenance-hook.sh"
export PROVENANCE_KIT_PATH="$KIT"             # so the harness hooks find lib/ under the TOOL

# PROV_LIB is the throwaway prompt LIBRARY being hashed. It is built on demand
# (a temp git repo seeded from sample-library/) by prov_make_library; the build
# functions call that, so the fixture never reaches into any real library.
PROV_LIB=""

prov_require_deps() {
  local dep
  for dep in git python3; do
    command -v "$dep" >/dev/null || { echo "✗ missing dependency: $dep" >&2; return 2; }
  done
  python3 -c 'import yaml' 2>/dev/null || { echo "✗ PyYAML not installed (python3 -m pip install pyyaml)" >&2; return 2; }
  [[ -f "$PROV_HOOK" ]] || { echo "✗ provenance-hook.sh not found at $PROV_HOOK" >&2; return 2; }
  [[ -d "$_LB_DIR/sample-library" ]] || { echo "✗ sample-library not found at $_LB_DIR/sample-library" >&2; return 2; }
}

# Build a hermetic throwaway prompt library: copy sample-library into a temp
# dir, make it a git repo with one commit, and set PROV_LIB to it so that
# `git -C "$PROV_LIB" rev-parse HEAD` works.
prov_make_library() {
  PROV_LIB="$(mktemp -d)"
  cp -r "$_LB_DIR/sample-library/." "$PROV_LIB/"
  git -C "$PROV_LIB" init -q
  git -C "$PROV_LIB" config user.email "library@test"
  git -C "$PROV_LIB" config user.name "library"
  git -C "$PROV_LIB" config commit.gpgsign false
  git -C "$PROV_LIB" config tag.gpgsign false
  git -C "$PROV_LIB" add -A
  git -C "$PROV_LIB" commit -q -m "sample library: initial state"
}

# Generate an ephemeral throwaway signing key in a temp GNUPGHOME. If gpg is
# unavailable, relax the fixture manifest's attestation.required and set
# PROV_GPG_OK=0 so callers can SKIP signature checks. Assumes cwd == build dir.
prov_setup_gpg() {
  PROV_GPG_OK=0
  if command -v gpg >/dev/null; then
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
    chmod 700 "$GNUPGHOME"
    cat > "$GNUPGHOME/keyparams" <<'PARAMS'
%no-protection
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Provenance Fixture
Name-Email: fixture@test
Expire-Date: 0
%commit
PARAMS
    if gpg --batch --gen-key "$GNUPGHOME/keyparams" >/dev/null 2>&1; then
      GPG_SIGNING_KEY_ID="$(gpg --list-secret-keys --keyid-format LONG --with-colons \
                            | awk -F: '/^sec/{print $5; exit}')"
      export GPG_SIGNING_KEY_ID
      echo "✓ ephemeral signing key: $GPG_SIGNING_KEY_ID"
      PROV_GPG_OK=1
    fi
  fi
  if [[ "$PROV_GPG_OK" -eq 0 ]]; then
    echo "⚠ gpg unavailable — relaxing attestation.required and skipping signature checks"
    sed -i 's/required: true/required: false/' project.manifest.yaml
    unset GPG_SIGNING_KEY_ID || true
  fi
}

# Build a complete, valid session in <build_dir>. Real hook for Init; simulated
# (provenance_ref.py) for the agent audit chain + attestation.
prov_build_known_good() {
  local build="$1" variant="${2:-a}"
  prov_make_library
  cp -r "$PROV_FIXTURE_DIR/fixture/." "$build/"
  cd "$build"
  git init -q
  git config user.email "fixture@test"
  git config user.name "fixture"
  git config commit.gpgsign false
  git config tag.gpgsign false

  local phash; phash="$(sha256sum docs/inputs/product_proposal.md | cut -d' ' -f1)"
  sed -i "s/PLACEHOLDER_SET_BY_RUNNER/$phash/" project.manifest.yaml
  printf 'PROMPT_LIBRARY_PATH=%s\n' "$PROV_LIB" > .env

  prov_setup_gpg "$build"
  git add -A && git commit -q -m "fixture: initial state"

  # shellcheck source=/dev/null
  source "$PROV_HOOK"
  provenance_gate "$build/project.manifest.yaml"
  PROV_SESSION_DIR="$(PROV_INITIAL_MESSAGE="Build the provenance fixture web app." PROV_CLI_ARGS="shape=proposal-driven" \
    provenance_open_session "$build/project.manifest.yaml" "$build" "$PROV_LIB" \
      "agents/prd.md" "start-prd.sh")"
  [[ -n "$PROV_SESSION_DIR" ]] || { echo "✗ session was not opened" >&2; return 1; }
  echo "✓ session: $PROV_SESSION_DIR"
  printf '%s start-prd.sh shape=proposal-driven proposal=%s sha256=%s\n' \
    "2026-06-01T00:00:00Z" "docs/inputs/product_proposal.md" "$phash" \
    >> "$build/.build-provenance/launcher.log"

  mkdir -p docs
  echo "# PRD (fixture)" > docs/prd.md
  echo "# TechStack decision (fixture)" > docs/techstack_decision.md
  python3 "$PROV_REF" seed-audit "$build/$PROV_SESSION_DIR" "$PROV_LIB" "$variant"
  git add -A && git commit -q -m "[fixture] build artifacts + audit log"
  PROV_BUILD_COMMIT="$(git rev-parse HEAD)"

  python3 "$PROV_REF" attest "$build/$PROV_SESSION_DIR" "$PROV_BUILD_COMMIT" "${GPG_SIGNING_KEY_ID:-unsigned}"
  if [[ "$PROV_GPG_OK" -eq 1 ]]; then
    gpg --armor --detach-sign --local-user "$GPG_SIGNING_KEY_ID" \
        --output "$build/$PROV_SESSION_DIR/attestation.asc" \
        "$build/$PROV_SESSION_DIR/attestation.yaml"
    echo "✓ signed attestation.asc"
  fi
  python3 "$PROV_REF" finalize "$build/$PROV_SESSION_DIR"

  local prompt_sha att_hash session_id
  prompt_sha="$(sha256sum "$PROV_LIB/agents/validation.md" | cut -d' ' -f1)"
  att_hash="$(python3 -c "import yaml;print(yaml.safe_load(open('$build/$PROV_SESSION_DIR/attestation.yaml'))['attestation_hash'])")"
  session_id="$(python3 -c "import yaml;print(yaml.safe_load(open('$build/$PROV_SESSION_DIR/manifest.yaml'))['session_id'])")"
  git add -A
  git commit -q -m "[validation-agent-v1.0] Pipeline complete

Agent-ID: validation-agent-v1.0
Prompt: agents/validation.md @ sha256:$prompt_sha
Attestation: $att_hash (session $session_id)"
}
