#!/usr/bin/env bash
#
# run_parity_test.sh — end-to-end parity test for provenance-kit.
#
# Validates that the provenance machinery (provenance-hook.sh + the
# provenance-kit prompts, codified by provenance_ref.py) produces every
# observable in the expected observable set. Exit 0 = parity satisfied;
# exit 1 = a regression.
#
# What runs for real vs. simulated:
#   - REAL: provenance_gate + provenance_open_session from provenance-hook.sh
#     (the immutable, genesis-anchored session manifest).
#   - SIMULATED: the per-agent audit entries and the attestation that a live
#     agent pipeline would produce. provenance_ref.py seeds a valid hash chain
#     and attestation so the parity/verify checks have a complete session to
#     inspect without needing live LLM calls.
#
# The known-good build is produced by lib_build.sh (shared with tamper_test.sh).
#
# Usage: tests/provenance_fixture/run_parity_test.sh [--keep]
#   --keep   leave the temp build dir in place for inspection

set -euo pipefail

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_build.sh
source "$SCRIPT_DIR/lib_build.sh"
prov_require_deps

BUILD="$(mktemp -d)"
cleanup() { [[ "$KEEP" -eq 1 ]] || rm -rf "$BUILD" "${GNUPGHOME:-}" "${PROV_LIB:-}"; }
trap cleanup EXIT

echo "── build known-good session ──────────────────────────────────────────"
prov_build_known_good "$BUILD"
SD="$BUILD/$PROV_SESSION_DIR"

echo "── verify ────────────────────────────────────────────────────────────"
VERIFY_ARGS=("$SD")
[[ "$PROV_GPG_OK" -eq 1 ]] && VERIFY_ARGS+=(--gpg)
python3 "$PROV_REF" verify "${VERIFY_ARGS[@]}"

echo "── parity check against the expected observable set ───────────────────"
set +e
python3 "$PROV_REF" parity "$SD" "$BUILD"
RC=$?
set -e

[[ "$KEEP" -eq 1 ]] && echo "(build kept at: $BUILD)"
exit $RC
