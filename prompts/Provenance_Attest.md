# Provenance Attest

**Purpose:** At build completion, compute the build attestation hash — binding the prompt-library commit, project commit, session id, and audit chain head — and GPG-sign it, producing non-repudiable proof that this exact combination of prompts and code produced this build.

**Integration:** The final build/validation agent should reference this file:
> "At build completion, read and follow `prompts/Provenance_Attest.md` to compute and sign the attestation."

**Prerequisites:**
- A completed audit chain from [`Provenance_Audit.md`](Provenance_Audit.md) (at least one entry).
- `GPG_SIGNING_KEY_ID` set in `.env`, with the secret key available to `gpg`.

**Related:** [`Provenance_Verify.md`](Provenance_Verify.md), [`Provenance_Audit.md`](Provenance_Audit.md), [`README.md`](README.md)

---

## What the attestation binds

```
attestation_hash = SHA256( library_commit ‖ project_final_commit ‖ session_id ‖ audit_chain_head )
```

This **supersedes** the simpler formula `SHA256(library_commit ‖ project_commit ‖ session_id)`. Folding in `audit_chain_head` extends the signature's coverage from "which versions" to "which versions **and** every prompt step that ran, in order" — an equivalent guarantee plus tamper-evidence over the whole audit log.

## Steps

### 1. Finalize the chain head and project commit

```bash
set -euo pipefail
source .env
SESSION_DIR="$(yq -r '.prompt_provenance.current_session' project.manifest.yaml)"

# Everything that should be in the build must already be committed.
PROJECT_FINAL_COMMIT="$(git rev-parse HEAD)"
LIB_COMMIT="$(yq -r '.library.commit' "$SESSION_DIR/manifest.yaml")"
SESSION_ID="$(yq -r '.session_id' "$SESSION_DIR/manifest.yaml")"
CHAIN_HEAD="$(yq -r '.entries[-1].entry_hash' "$SESSION_DIR/audit.yaml")"

if [[ -z "$CHAIN_HEAD" || "$CHAIN_HEAD" == "null" ]]; then
  echo "ERROR: audit chain is empty — nothing to attest. Did agents run Provenance_Audit?" >&2
  exit 1
fi
```

### 2. Verify the chain before signing

Do not sign a broken chain. Run the chain-only check from [`Provenance_Verify.md`](Provenance_Verify.md) (recompute every `entry_hash` from `genesis_hash` forward; confirm the recomputed head equals `CHAIN_HEAD`). Abort on any mismatch.

### 3. Compute the attestation hash

```bash
ATTESTATION_HASH="$(printf '%s%s%s%s' \
  "$LIB_COMMIT" "$PROJECT_FINAL_COMMIT" "$SESSION_ID" "$CHAIN_HEAD" \
  | sha256sum | cut -d' ' -f1)"
SIGNED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
```

### 4. Write the plaintext payload

Write `$SESSION_DIR/attestation.yaml`. This is the exact text that gets signed — the signature covers this file byte-for-byte.

```yaml
# .build-provenance/session_<uuid>/attestation.yaml
schema: provenance/attestation@1
session_id: "<SESSION_ID>"
library_commit: "<LIB_COMMIT>"
project_final_commit: "<PROJECT_FINAL_COMMIT>"
audit_chain_head: "<CHAIN_HEAD>"
attestation_hash: "<ATTESTATION_HASH>"   # SHA256(library ‖ project ‖ session ‖ chain_head)
signer_key_id: "<GPG_SIGNING_KEY_ID>"
signed_at: "<SIGNED_AT>"
formula: "SHA256(library_commit || project_final_commit || session_id || audit_chain_head)"
```

### 5. GPG-sign the payload (required — fail loudly)

```bash
if [[ -z "${GPG_SIGNING_KEY_ID:-}" ]]; then
  echo "ERROR: GPG_SIGNING_KEY_ID required but not set in .env. Build provenance cannot be attested." >&2
  exit 1
fi

if ! gpg --list-secret-keys "$GPG_SIGNING_KEY_ID" >/dev/null 2>&1; then
  echo "ERROR: GPG secret key $GPG_SIGNING_KEY_ID not found. Run: gpg --list-secret-keys --keyid-format LONG" >&2
  exit 1
fi

# Detached, ASCII-armored signature over the exact payload bytes.
gpg --armor --detach-sign --local-user "$GPG_SIGNING_KEY_ID" \
    --output "$SESSION_DIR/attestation.asc" \
    "$SESSION_DIR/attestation.yaml" \
  || { echo "ERROR: GPG signing failed. Is gpg-agent running?" >&2; exit 1; }
```

A detached signature (`attestation.asc` over `attestation.yaml`) keeps the signed payload human-readable while still being verifiable with `gpg --verify attestation.asc attestation.yaml`.

### 6. Finalize `summary.json` and embed provenance in artifacts

```bash
# Flip status and record the attestation in the rolled-up summary.
yq -i '.status = "complete" | .attestation_hash = "'"$ATTESTATION_HASH"'" | .signer_key_id = "'"$GPG_SIGNING_KEY_ID"'"' \
  "$SESSION_DIR/summary.json" 2>/dev/null || true
```

For deployable artifacts, write a `provenance.json` (or `/etc/build_provenance.yaml` for devices) referencing `session_id`, `attestation_hash`, and `signer_key_id`, so a fielded artifact can be traced back to this session.

### 7. Embed the prompt reference in the final commit

Keep the established condensed commit line so provenance is visible in `git log` too:

```
Prompt: <final-agent-prompt-path> @ sha256:<prompt_sha>
Attestation: <attestation_hash> (session <session_id>)
```

## Failure handling (build must fail)

| Condition | Error |
|---|---|
| `GPG_SIGNING_KEY_ID` unset | "GPG_SIGNING_KEY_ID required but not set in .env" |
| Secret key not found | "GPG secret key <id> not found" |
| Signing fails | "GPG signing failed. Check gpg-agent is running." |
| Audit chain empty or broken | "audit chain empty/broken — nothing valid to attest" |
| Uncommitted changes in build scope | "working tree dirty — commit build inputs before attesting" |

## Output

`attestation.yaml` (plaintext payload) and `attestation.asc` (GPG signature) in the session directory, a finalized `summary.json`, and a final commit carrying the attestation reference. Verifiable with [`Provenance_Verify.md`](Provenance_Verify.md).
