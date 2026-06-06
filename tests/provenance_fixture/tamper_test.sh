#!/usr/bin/env bash
#
# tamper_test.sh — proves the provenance verification mechanism actually catches
# forgery (use case C from provenance-kit's README.md).
#
# Builds one known-good session, asserts `provenance_ref.py verify` PASSES, then
# applies a matrix of tampers to independent COPIES of that session and asserts
# verify FAILS each time, naming the right broken check. Exit 0 only if the
# known-good passes AND every tamper is caught.
#
# Usage: tests/provenance_fixture/tamper_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_build.sh
source "$SCRIPT_DIR/lib_build.sh"
prov_require_deps

BUILD="$(mktemp -d)"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$BUILD" "$WORK" "${GNUPGHOME:-}" "${PROV_LIB:-}"; }
trap cleanup EXIT

echo "══ build known-good session ══════════════════════════════════════════"
prov_build_known_good "$BUILD"
GOOD="$BUILD/$PROV_SESSION_DIR"

GPG_FLAG=()
[[ "$PROV_GPG_OK" -eq 1 ]] && GPG_FLAG=(--gpg)

PASS=0; FAIL=0

# assert_good: known-good must verify clean (exit 0)
echo
echo "══ case 0: known-good must PASS ══════════════════════════════════════"
if python3 "$PROV_REF" verify "$GOOD" "${GPG_FLAG[@]}"; then
  echo "  ✓ known-good verified"; PASS=$((PASS+1))
else
  echo "  ✗ known-good FAILED to verify (should not happen)"; FAIL=$((FAIL+1))
fi

# tamper <name> <expected-signal-regex> <mutator-fn>
# Each runs on a fresh copy of GOOD; verify must exit non-zero and the output
# must match the expected signal.
run_tamper() {
  local name="$1" expect="$2" fn="$3"
  local dir="$WORK/$name"
  rm -rf "$dir"; mkdir -p "$dir"
  cp -r "$GOOD/." "$dir/"
  "$fn" "$dir"
  echo
  echo "══ case: $name ═══════════════════════════════════════════════════════"
  local out rc
  set +e
  out="$(python3 "$PROV_REF" verify "$dir" "${GPG_FLAG[@]}" 2>&1)"; rc=$?
  set -e
  echo "$out" | sed 's/^/  /'
  if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qE "$expect"; then
    echo "  ✓ tamper caught (expected: /$expect/)"; PASS=$((PASS+1))
  else
    echo "  ✗ tamper NOT caught (rc=$rc, expected match /$expect/)"; FAIL=$((FAIL+1))
  fi
}

# ── mutators ──
t_counter() {  # alter an audit counter but leave its stale entry_hash
  python3 - "$1/audit.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p))
d['entries'][1]['counters']['shell_commands']['self_report']=999999
yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
}
t_prompt_sha() {  # forge a recorded prompt hash
  python3 - "$1/audit.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p))
d['entries'][0]['prompt_sha256']='0'*64
yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
}
t_delete_entry() {  # drop a middle entry (breaks seq + prev_hash chain)
  python3 - "$1/audit.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p))
del d['entries'][1]
yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
}
t_manifest() {  # edit the recorded initial user message after genesis
  python3 - "$1/manifest.yaml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("Build the provenance fixture web app.","Build something else entirely.")
open(p,'w').write(s)
PY
}
t_attestation_hash() {  # tamper the recorded attestation hash
  python3 - "$1/attestation.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p))
d['attestation_hash']='f'*64
yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
}
t_signed_payload() {  # change the signed payload after signing -> bad signature
  python3 - "$1/attestation.yaml" <<'PY'
import sys,yaml
p=sys.argv[1]; d=yaml.safe_load(open(p))
d['project_final_commit']='deadbeef'*5
yaml.safe_dump(d,open(p,'w'),sort_keys=False)
PY
}

run_tamper "audit-counter-altered"  "chain break at seq 2: entry_hash mismatch" t_counter
run_tamper "prompt-sha-forged"      "chain break at seq 1: entry_hash mismatch" t_prompt_sha
run_tamper "audit-entry-deleted"    "chain break"                                t_delete_entry
run_tamper "manifest-tampered"      "genesis_hash mismatch"                      t_manifest
run_tamper "attestation-hash-bad"   "attestation: FAIL"                          t_attestation_hash
if [[ "$PROV_GPG_OK" -eq 1 ]]; then
  # With a real signature, mutating the payload must fail either the chain-head
  # cross-check or the GPG signature; both are acceptable "caught" signals.
  run_tamper "signed-payload-altered" "attestation: FAIL|gpg signature: FAIL"    t_signed_payload
else
  echo; echo "══ case: signed-payload-altered ══ SKIP (gpg unavailable)"
fi

echo
echo "══════════════════════════════════════════════════════════════════════"
echo "RESULT: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || { echo "TAMPER TEST FAILED"; exit 1; }
echo "TAMPER TEST PASSED — verification catches every tamper in the matrix"
