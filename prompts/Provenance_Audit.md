# Provenance Audit

**Purpose:** Append one tamper-evident entry to the session's audit hash chain for each agent step, recording which prompt ran (path + content SHA-256), its inputs/outputs, and a hybrid set of activity counters (shell commands, file reads/writes/accesses, network calls, tokens).

**Integration:** Every agent should reference this file:
> "At the start and end of your phase, read and follow `prompts/Provenance_Audit.md` to append your audit entries."

**Prerequisites:** A session opened by [`Provenance_Init.md`](Provenance_Init.md) (a `manifest.yaml` with a `genesis_hash` must exist).

**Related:** [`Provenance_Init.md`](Provenance_Init.md), [`Provenance_Attest.md`](Provenance_Attest.md), [`Provenance_Verify.md`](Provenance_Verify.md)

---

## The hash chain (why this proves authorship)

`audit.yaml` is **append-only**. Each entry carries:

- `prev_hash` — the `entry_hash` of the previous entry (or the manifest's `genesis_hash` for `seq: 1`).
- `entry_hash` — `SHA256( canonical(entry-without-entry_hash) ‖ prev_hash )`.

Because each entry's hash folds in the previous one, changing any earlier entry (or the manifest) breaks every hash after it. The final entry's hash — the **chain head** — is later folded into the GPG-signed attestation ([`Provenance_Attest.md`](Provenance_Attest.md)). That is what makes "these prompts produced this build" provable rather than asserted: to forge the record you would have to re-sign with the attestor's private key.

Never edit or delete an entry. Corrections are new entries with `correction_of: <seq>`.

## Automatic capture (recommended)

If the harness hooks in [`harness/`](harness/) are installed, you do **not** append entries by hand — the Stop hook calls [`lib/provenance_chain.py`](lib/provenance_chain.py) `harness-finalize`, which aggregates the turn's tool calls into a hash-chained entry automatically. The steps below describe the manual/agent-driven path, which remains the contract the hooks implement (and the fallback when no harness hook is wired). Either way the canonicalization is identical — see [`lib/provenance_chain.py`](lib/provenance_chain.py).

## Counters: hybrid capture (Claude Code + opencode)

Record **two** sources for every counter and never fabricate:

- `harness` — captured by the shell hook (`provenance-hook.sh`, once wired) or the harness's own metadata.
- `self_report` — the agent's own count of what it did this step.

Write `null` for any source you genuinely cannot obtain, and explain in `counter_notes`. `Provenance_Verify.md` compares the two sources and flags discrepancies beyond tolerance — a divergence is a signal, not an error to hide.

| Counter | What it counts |
|---|---|
| `shell_commands` | Distinct shell commands executed this step |
| `files_read` | Files opened for reading |
| `files_written` | Files created or modified |
| `files_accessed` | Superset incl. stat/exists checks (≥ read+written) |
| `network_calls` | Outbound network requests (any non-zero is noteworthy) |
| `tokens_in` / `tokens_out` | Prompt/response tokens for this step, if the harness exposes them |

## Steps (per agent step)

### 1. Identify the step and hash the prompt that ran

```bash
set -euo pipefail
source .env
SESSION_DIR="$(yq -r '.prompt_provenance.current_session' project.manifest.yaml 2>/dev/null || true)"
SESSION_DIR="${SESSION_DIR:-$(ls -d .build-provenance/session_* | head -1)}"

AGENT_ID="<agent-id, e.g. prd-agent-v1.0>"
PROMPT_FILE="<path relative to library root, e.g. agents/prd.md>"
PROMPT_SHA="$(sha256sum "$PROMPT_LIBRARY_PATH/$PROMPT_FILE" | cut -d' ' -f1)"
NOW="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
```

### 2. Determine `seq` and `prev_hash`

```bash
LAST_SEQ="$(yq -r '.entries[-1].seq // 0' "$SESSION_DIR/audit.yaml")"
SEQ=$((LAST_SEQ + 1))
if [[ "$SEQ" -eq 1 ]]; then
  PREV_HASH="$(yq -r '.genesis_hash' "$SESSION_DIR/manifest.yaml")"
else
  PREV_HASH="$(yq -r '.entries[-1].entry_hash' "$SESSION_DIR/audit.yaml")"
fi
```

### 3. Build the entry (without `entry_hash`)

```yaml
- seq: <SEQ>
  agent_id: "<AGENT_ID>"
  prompt_file: "<PROMPT_FILE>"
  prompt_sha256: "<PROMPT_SHA>"
  started_at: "<step start ISO 8601>"
  ended_at: "<NOW>"
  inputs:                                  # artifacts this step consumed
    - { path: "docs/prd.md", sha256: "<...>" }
  outputs:                                 # artifacts this step produced
    - { path: "docs/feature_list.md", sha256: "<...>", commit: "<git SHA>" }
  counters:
    shell_commands:  { harness: <n|null>, self_report: <n> }
    files_read:      { harness: <n|null>, self_report: <n> }
    files_written:   { harness: <n|null>, self_report: <n> }
    files_accessed:  { harness: <n|null>, self_report: <n> }
    network_calls:   { harness: <n|null>, self_report: <n> }
    tokens_in:       { harness: <n|null>, self_report: <n|null> }
    tokens_out:      { harness: <n|null>, self_report: <n|null> }
  counter_notes: "<why any source is null, or any discrepancy you already know about>"
  summary: "<one line: what this step did>"
  correction_of: null                      # set to a prior seq only when correcting
  prev_hash: "<PREV_HASH>"
```

### 4. Compute `entry_hash` and append

The canonical form is **canonical JSON**: the entry object with the `entry_hash` field removed (everything else, including `prev_hash`, retained), serialized with keys sorted lexicographically and no insignificant whitespace. Hash that, set `entry_hash`, then append the full entry to `audit.yaml`.

```
canonical(entry) = JSON(entry without `entry_hash`, sort_keys=true, no spaces)
entry_hash        = sha256( canonical(entry) )
```

Canonical JSON (not raw YAML text) is the rule because it is independent of field order and whitespace — two agents serializing the same logical entry get the same hash. Example using the reference codification:

```bash
python3 "$PROMPT_LIBRARY_PATH/tests/provenance_fixture/provenance_ref.py" \
  seed-audit "$SESSION_DIR" "$PROMPT_LIBRARY_PATH"   # appends a valid chain
```

> **Authoritative codification:** [`lib/provenance_chain.py`](lib/provenance_chain.py) (`canon()` / `entry_hash()`) is the source of truth for the exact bytes hashed; the harness hooks and the fixture test (`tests/provenance_fixture/provenance_ref.py`, which imports from it) all use it. [`Provenance_Verify.md`](Provenance_Verify.md) MUST use the identical rule — if you change it in one place, change it everywhere in the same commit.

### 5. Update `summary.json` (pre-rolled aggregates)

After appending, roll the new entry into `summary.json` so comparison tools never have to parse the whole chain. Prefer `harness` counter values; fall back to `self_report` when `harness` is `null`.

```json
{
  "schema": "provenance/summary@1",
  "session_id": "<uuid>",
  "status": "in_progress",
  "totals": { "shell": 0, "reads": 0, "writes": 0, "accessed": 0, "network": 0, "tokens_in": 0, "tokens_out": 0 },
  "by_agent": {
    "prd-agent-v1.0": { "steps": 1, "shell": 12, "reads": 47, "writes": 3, "accessed": 51, "network": 0, "tokens_in": 18234, "tokens_out": 4102, "duration_s": 540 }
  },
  "agents_invoked": ["initialization-agent-v1.0", "prd-agent-v1.0"],
  "chain_head": "<entry_hash of the latest entry>",
  "artifacts": ["docs/prd.md", "docs/feature_list.md"]
}
```

## Failure handling

| Condition | Action |
|---|---|
| No `manifest.yaml` / `genesis_hash` for this session | Abort — Init has not run; do not start work untracked |
| `prompt_file` not found in library | Abort — cannot prove a prompt you can't hash |
| A counter source unavailable | Write `null`, note the reason; never invent a value |
| `audit.yaml` previous `entry_hash` missing/malformed | Abort — the chain is broken; surface it, do not paper over it |

## Output

One new append-only entry in `.build-provenance/session_<uuid>/audit.yaml` and an updated `summary.json`. The latest `entry_hash` is the current chain head.
