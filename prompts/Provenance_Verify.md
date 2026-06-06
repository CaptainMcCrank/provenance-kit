# Provenance Verify

**Purpose:** Independently re-derive a build's provenance from on-disk artifacts and confirm it is intact and honest: the audit hash chain is unbroken, the prompt files still hash to their recorded values, the attestation hash matches its formula, and the GPG signature is valid. This is the test that proves the proof mechanism works (use case C).

**Integration:** Humans or CI should reference this file:
> "Read and follow `prompts/Provenance_Verify.md` to verify a session's provenance."

**Prerequisites:** A session directory produced by Init/Audit/Attest. For full verification, the prompt library must be available at the recorded commit (to re-hash prompt files).

**Related:** [`Provenance_Attest.md`](Provenance_Attest.md), [`Provenance_Audit.md`](Provenance_Audit.md), [`Provenance_Discover.md`](Provenance_Discover.md)

---

## Verification levels

| Level | Checks | Needs library? |
|---|---|---|
| **chain** | Audit hash chain is internally consistent from genesis to head | No |
| **standard** | chain + attestation hash matches formula + GPG signature valid | No (needs public key) |
| **full** | standard + every recorded `prompt_sha256` matches the file at the recorded library commit + counter-source discrepancy report | Yes |

Run `full` for an authoritative audit; `standard` for routine CI; `chain` for a fast local integrity check.

## Steps

### 1. Locate the session and load anchors

```bash
set -euo pipefail
SESSION_DIR="${1:?usage: verify <session_dir>}"
GENESIS="$(yq -r '.genesis_hash' "$SESSION_DIR/manifest.yaml")"
SESSION_ID="$(yq -r '.session_id' "$SESSION_DIR/manifest.yaml")"
```

Recompute the manifest's genesis hash the same way Init did (canonical body with the `genesis_hash:` line removed) and confirm it equals the stored `genesis_hash`. A mismatch means the manifest was edited after init — **fail immediately**; the whole chain is anchored to it.

```bash
RECOMPUTED_GENESIS="$(grep -v '^genesis_hash:' "$SESSION_DIR/manifest.yaml" | sha256sum | cut -d' ' -f1)"
[[ "$RECOMPUTED_GENESIS" == "$GENESIS" ]] || { echo "FAIL: manifest tampered (genesis hash mismatch)"; exit 1; }
```

### 2. Walk the hash chain (chain level)

For each entry in order, recompute `entry_hash = SHA256( canonical(entry without entry_hash) )` where `canonical` is **canonical JSON** (keys sorted, no insignificant whitespace, `prev_hash` retained) — the **same rule** as [`Provenance_Audit.md`](Provenance_Audit.md), authoritatively codified in [`lib/provenance_chain.py`](lib/provenance_chain.py). Confirm:

- entry 1's `prev_hash` equals `GENESIS`;
- each subsequent entry's `prev_hash` equals the previous entry's recomputed `entry_hash`;
- `seq` increments by 1 with no gaps;
- the recomputed final `entry_hash` (the chain head) is carried forward to step 3.

Any mismatch identifies the exact `seq` where the chain broke — report it and fail.

### 3. Re-derive the attestation (standard level)

```bash
LIB_COMMIT="$(yq -r '.library_commit' "$SESSION_DIR/attestation.yaml")"
PROJ_COMMIT="$(yq -r '.project_final_commit' "$SESSION_DIR/attestation.yaml")"
CHAIN_HEAD="$(yq -r '.audit_chain_head' "$SESSION_DIR/attestation.yaml")"
CLAIMED="$(yq -r '.attestation_hash' "$SESSION_DIR/attestation.yaml")"

# (a) chain head in the attestation must equal the recomputed head from step 2
# (b) recompute the attestation hash
RECOMPUTED="$(printf '%s%s%s%s' "$LIB_COMMIT" "$PROJ_COMMIT" "$SESSION_ID" "$CHAIN_HEAD" | sha256sum | cut -d' ' -f1)"
[[ "$RECOMPUTED" == "$CLAIMED" ]] || { echo "FAIL: attestation hash mismatch"; exit 1; }

# (c) verify the GPG signature over the exact payload bytes
gpg --verify "$SESSION_DIR/attestation.asc" "$SESSION_DIR/attestation.yaml" \
  || { echo "FAIL: GPG signature invalid"; exit 1; }
```

### 4. Re-hash prompt files at the recorded commit (full level)

For each distinct `prompt_file` + `prompt_sha256` in the audit log, fetch the file **at the library commit recorded in the manifest** and confirm the hash matches. This catches the case where a prompt was changed after the build but the audit log still claims the old hash.

```bash
LIB_PATH="$(yq -r '.library.path' "$SESSION_DIR/manifest.yaml")"
LIB_COMMIT_INIT="$(yq -r '.library.commit' "$SESSION_DIR/manifest.yaml")"
# For each (prompt_file, recorded_sha):
ACTUAL="$(git -C "$LIB_PATH" show "${LIB_COMMIT_INIT}:${prompt_file}" | sha256sum | cut -d' ' -f1)"
[[ "$ACTUAL" == "$recorded_sha" ]] || echo "FAIL: prompt drift — $prompt_file"
```

### 5. Counter-discrepancy report (full level)

For each entry, compare `counters.*.harness` vs `counters.*.self_report`. Where both are non-null, flag any difference beyond tolerance (default: exact match for shell/file/network counts; ±2% for tokens). Discrepancies are **reported, not auto-failed** — a wrapped harness disagreeing with self-report is a signal worth a human's eyes, and `null` harness values (unwrapped runs) are expected, not failures.

## Output: a verdict

Emit a structured verdict so CI can gate on it:

```yaml
session_id: "<uuid>"
level: "full"
result: "PASS"            # PASS | FAIL
checks:
  manifest_genesis: pass
  hash_chain: pass        # or: "fail at seq 7"
  attestation_hash: pass
  gpg_signature: pass
  prompt_drift: pass      # or list of drifted files
counter_discrepancies:    # informational
  - { seq: 4, counter: shell_commands, harness: 12, self_report: 9 }
```

`result: FAIL` if any check (other than the informational counter discrepancies) fails. CI should exit non-zero on FAIL.

## The tamper test (use case C)

To prove verification actually catches forgery, run this prompt against two fixtures:

1. **Known-good fixture** → must yield `PASS`.
2. **Tampered fixture** — e.g. a prompt file edited after attestation, an audit entry's counter altered, or the manifest's initial user message changed → must yield `FAIL`, and the verdict must name the broken check (`prompt_drift`, `hash_chain`, or `manifest_genesis`).

If the tampered fixture passes, the provenance mechanism is not trustworthy and the build of this module fails.
