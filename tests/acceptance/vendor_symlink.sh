#!/usr/bin/env bash
# Acceptance: a consumer project that VENDORS the kit at ./provenance-kit and
# points PROMPT_LIBRARY_PATH at a SEPARATE, EXTERNAL prompt library (symlinked
# as ./prompts) must build and verify cleanly. Proves the tool is decoupled from
# the library — it does not assume it lives inside the library it hashes.
set -uo pipefail
KIT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # repo root = the tool
PROJECT="$(mktemp -d)"; EXT_LIB="$(mktemp -d)"
cleanup(){ rm -rf "$PROJECT" "$EXT_LIB" "${GNUPGHOME:-}" 2>/dev/null; }
trap cleanup EXIT
fail(){ echo "✗ FAIL: $*"; exit 1; }
echo "kit=$KIT_SRC"; echo "project=$PROJECT"; echo "external library=$EXT_LIB"; echo

# 1) Vendor the kit into the project (exclude local-only dirs, like a real vendor)
mkdir -p "$PROJECT/provenance-kit"
( cd "$KIT_SRC" && tar --exclude=.git --exclude=.beads --exclude=.claude \
    --exclude=__pycache__ --exclude='*.pyc' -cf - . ) | tar -xf - -C "$PROJECT/provenance-kit" || fail "vendor copy"
echo "✓ vendored kit -> ./provenance-kit"

# 2) Build a DIFFERENT, EXTERNAL prompt library (separate path, tweaked content) as a git repo
cp -r "$KIT_SRC/tests/provenance_fixture/sample-library/." "$EXT_LIB/" || fail "seed external lib"
printf '\n- acceptance marker: a DIFFERENT library at an external path\n' >> "$EXT_LIB/agents/validation.md"
git -C "$EXT_LIB" init -q
git -C "$EXT_LIB" config user.email lib@acceptance; git -C "$EXT_LIB" config user.name lib
git -C "$EXT_LIB" config commit.gpgsign false
git -C "$EXT_LIB" add -A && git -C "$EXT_LIB" commit -q -m "external library initial"
EXT_LIB_COMMIT="$(git -C "$EXT_LIB" rev-parse HEAD)"
echo "✓ external library git repo (commit ${EXT_LIB_COMMIT:0:8})"

# 3) Project: symlink the external library as ./prompts (gitignored), copy manifest + proposal
cd "$PROJECT" || fail "cd project"
ln -s "$EXT_LIB" prompts
printf '/prompts\n.env\n.build-provenance/\n' > .gitignore
cp "$PROJECT/provenance-kit/tests/provenance_fixture/fixture/project.manifest.yaml" . || fail "copy manifest"
mkdir -p docs/inputs
cp "$PROJECT/provenance-kit/tests/provenance_fixture/fixture/docs/inputs/product_proposal.md" docs/inputs/ || fail "copy proposal"
sed -i 's#module_path:.*#module_path: "./provenance-kit"#' project.manifest.yaml
phash="$(sha256sum docs/inputs/product_proposal.md | cut -d' ' -f1)"
sed -i "s/PLACEHOLDER_SET_BY_RUNNER/$phash/" project.manifest.yaml
echo "✓ project: ./prompts -> $(readlink prompts)  (symlink, gitignored); module_path=./provenance-kit"

# 4) Source the VENDORED helpers (sets KIT, PROV_HOOK, PROV_REF, PROVENANCE_KIT_PATH, prov_setup_gpg)
source "$PROJECT/provenance-kit/tests/provenance_fixture/lib_build.sh" || fail "source vendored lib_build"
echo "  PROVENANCE_KIT_PATH=$PROVENANCE_KIT_PATH"

# 5) ephemeral throwaway signing key (isolated GNUPGHOME — never touches a real key)
prov_setup_gpg "$PROJECT"
printf 'PROMPT_LIBRARY_PATH=%s\n' "$PROJECT/prompts" > .env
git init -q; git config user.email proj@acceptance; git config user.name proj; git config commit.gpgsign false
git add -A && git commit -q -m "project initial"

# 6) Open a session via the VENDORED hook, pointed at the SYMLINKED external library
source "$PROV_HOOK" || fail "source hook"
provenance_gate "$PROJECT/project.manifest.yaml" || fail "provenance_gate"
SESSION="$(PROV_INITIAL_MESSAGE="acceptance build." PROV_CLI_ARGS="shape=proposal-driven" \
  provenance_open_session "$PROJECT/project.manifest.yaml" "$PROJECT" "$PROJECT/prompts" "agents/prd.md" "acceptance-launcher")"
[ -n "$SESSION" ] || fail "no session opened"
echo "✓ session opened: $SESSION"

# 7) Simulated agent chain via the VENDORED provenance_ref.py, hashing the symlinked library
mkdir -p docs; echo "# PRD" > docs/prd.md
printf '%s acceptance-launcher proposal=%s sha256=%s\n' "2026-06-01T00:00:00Z" "docs/inputs/product_proposal.md" "$phash" \
  >> "$PROJECT/.build-provenance/launcher.log"
python3 "$PROV_REF" seed-audit "$PROJECT/$SESSION" "$PROJECT/prompts" a || fail "seed-audit"
git add -A && git commit -q -m "build artifacts"
BUILD_COMMIT="$(git rev-parse HEAD)"
python3 "$PROV_REF" attest "$PROJECT/$SESSION" "$BUILD_COMMIT" "${GPG_SIGNING_KEY_ID:-unsigned}" || fail "attest"
if [ "${PROV_GPG_OK:-0}" -eq 1 ]; then
  gpg --armor --detach-sign --local-user "$GPG_SIGNING_KEY_ID" \
      --output "$PROJECT/$SESSION/attestation.asc" "$PROJECT/$SESSION/attestation.yaml" || fail "sign"
fi
python3 "$PROV_REF" finalize "$PROJECT/$SESSION" || fail "finalize"

# 8) VERIFY
echo "── verify ───────────────────────────────"
VARGS=("$PROJECT/$SESSION"); [ "${PROV_GPG_OK:-0}" -eq 1 ] && VARGS+=("--gpg")
python3 "$PROV_REF" verify "${VARGS[@]}" || fail "verify did not pass"

# 9) Decouple assertions
echo "── decouple checks ──────────────────────"
MAN_LIB_COMMIT="$(python3 -c "import yaml;print(yaml.safe_load(open('$PROJECT/$SESSION/manifest.yaml')).get('library',{}).get('commit',''))")"
echo "manifest library.commit=${MAN_LIB_COMMIT:0:8}  external-lib=${EXT_LIB_COMMIT:0:8}"
[ "$MAN_LIB_COMMIT" = "$EXT_LIB_COMMIT" ] || fail "manifest did not record the external/symlinked library commit"
echo "✓ manifest records the external/symlinked library commit (not the tool's)"
case "$PROVENANCE_KIT_PATH" in "$EXT_LIB"*) fail "tool path is INSIDE the library";; *) echo "✓ tool ($PROVENANCE_KIT_PATH) lives outside the library";; esac

echo; echo "════════════════════════════════════════"
echo "ACCEPTANCE PASSED — vendored kit + symlinked external library builds & verifies"
