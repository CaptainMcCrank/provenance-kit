#!/usr/bin/env bash
#
# harness_capture_test.sh — proves the Claude Code hooks capture an audit entry
# automatically.
#
# Drives the REAL hook scripts (post_tool_use.sh, stop.sh) with synthetic
# PostToolUse JSON — exactly what Claude Code feeds them on stdin — then attests
# and verifies the resulting session. Asserts the harness-captured counters
# match the simulated tool calls and that the chain + signature verify clean.
#
# Usage: tests/provenance_fixture/harness_capture_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_build.sh
source "$SCRIPT_DIR/lib_build.sh"
prov_require_deps

HOOK_DIR="$KIT/harness/claude-code"
POST="$HOOK_DIR/post_tool_use.sh"
STOP="$HOOK_DIR/stop.sh"
CHAIN="$KIT/lib/provenance_chain.py"
for f in "$POST" "$STOP" "$CHAIN"; do
  [[ -f "$f" ]] || { echo "✗ missing: $f" >&2; exit 2; }
done

BUILD="$(mktemp -d)"
cleanup() { rm -rf "$BUILD" "${GNUPGHOME:-}" "${PROV_LIB:-}"; }
trap cleanup EXIT
FAIL=0

echo "── stage fixture + open session via REAL hook (Init only, no seed) ────"
prov_make_library          # hermetic throwaway prompt library being hashed
cp -r "$SCRIPT_DIR/fixture/." "$BUILD/"
cd "$BUILD"
git init -q
git config user.email "fixture@test"; git config user.name "fixture"
git config commit.gpgsign false; git config tag.gpgsign false
PHASH="$(sha256sum docs/inputs/product_proposal.md | cut -d' ' -f1)"
sed -i "s/PLACEHOLDER_SET_BY_RUNNER/$PHASH/" project.manifest.yaml
printf 'PROMPT_LIBRARY_PATH=%s\n' "$PROV_LIB" > .env
prov_setup_gpg "$BUILD"
git add -A && git commit -q -m "fixture: initial state"

# shellcheck source=/dev/null
source "$PROV_HOOK"
provenance_gate "$BUILD/project.manifest.yaml"
SD="$(provenance_open_session "$BUILD/project.manifest.yaml" "$BUILD" "$PROV_LIB" \
        "agents/prd.md" "start-prd.sh")"
export PROVENANCE_SESSION_DIR="$BUILD/$SD"
echo "✓ session: $SD"

echo "── simulate Claude Code tool calls through the PostToolUse hook ───────"
# 3 Bash, 2 Read, 1 Write, 1 WebFetch  → shell=3 reads=2 written=1
#                                          accessed=2+1=3 network=1
emit() { printf '{"hook_event_name":"PostToolUse","session_id":"s","cwd":"%s","tool_name":"%s","tool_input":{}}' "$BUILD" "$1" | bash "$POST"; }
for t in Bash Bash Bash Read Read Write WebFetch; do emit "$t"; done
echo "  events recorded: $(wc -l < "$PROVENANCE_SESSION_DIR/.hook_events.jsonl") lines"

echo "── fire the Stop hook → should append ONE hash-chained audit entry ────"
printf '{"hook_event_name":"Stop","session_id":"s","cwd":"%s"}' "$BUILD" | bash "$STOP"
[[ -f "$PROVENANCE_SESSION_DIR/.hook_events.jsonl" ]] && { echo "  ✗ events file not cleared"; FAIL=$((FAIL+1)); } || echo "  ✓ events cleared after finalize"

echo "── assert the captured entry's counters ──────────────────────────────"
python3 - "$PROVENANCE_SESSION_DIR/audit.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert len(d["entries"]) == 1, f"expected 1 entry, got {len(d['entries'])}"
c = d["entries"][0]["counters"]
def h(k): return c[k]["harness"]
exp = {"shell_commands":3,"files_read":2,"files_written":1,"files_accessed":3,"network_calls":1}
for k,v in exp.items():
    assert h(k)==v, f"{k}: expected {v}, got {h(k)}"
assert c["tokens_in"]["harness"] is None, "tokens should be null (not hook-exposed)"
assert d["entries"][0]["source"]=="claude-code"
print("  ✓ counters:", {k:h(k) for k in exp})
print("  ✓ source=claude-code, tokens harness=null (honest)")
PY

echo "── attest + sign, then verify the harness-captured chain ──────────────"
git add -A && git commit -q -m "[harness] build + captured audit"
BUILD_COMMIT="$(git rev-parse HEAD)"
python3 "$PROV_REF" attest "$PROVENANCE_SESSION_DIR" "$BUILD_COMMIT" "${GPG_SIGNING_KEY_ID:-unsigned}"
if [[ "$PROV_GPG_OK" -eq 1 ]]; then
  gpg --armor --detach-sign --local-user "$GPG_SIGNING_KEY_ID" \
      --output "$PROVENANCE_SESSION_DIR/attestation.asc" \
      "$PROVENANCE_SESSION_DIR/attestation.yaml"
fi
python3 "$PROV_REF" finalize "$PROVENANCE_SESSION_DIR"

VARGS=("$PROVENANCE_SESSION_DIR"); [[ "$PROV_GPG_OK" -eq 1 ]] && VARGS+=(--gpg)
if python3 "$PROV_REF" verify "${VARGS[@]}"; then
  echo "  ✓ harness-captured session verifies clean"
else
  echo "  ✗ verify failed on harness-captured session"; FAIL=$((FAIL+1))
fi

echo
echo "══════════════════════════════════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || { echo "HARNESS CAPTURE TEST FAILED ($FAIL)"; exit 1; }
echo "HARNESS CAPTURE TEST PASSED — hooks produce a valid, verifiable audit entry"
