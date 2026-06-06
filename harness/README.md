# Harness hooks — automatic provenance capture

**Purpose:** Turn the per-step audit log from *instructed* (the agent is told to append entries) into *enforced* (the harness appends them automatically as the agent works). This closes the gap noted in [`../README.md`](../README.md) and `provenance-hook.sh`.

**Status:** Claude Code is implemented and tested (`tests/provenance_fixture/harness_capture_test.sh`). opencode is a documented template pending validation against its live hook API — see [`opencode/`](opencode/).

---

## What it does

The launcher (`provenance-hook.sh`) already opens the session and writes the immutable `manifest.yaml`. These hooks add the next layer: while the agent runs, every tool call is recorded, and when the agent stops the recorded activity is folded into one hash-chained audit entry in `audit.yaml` — with real counters, no reliance on the agent remembering to do it.

```
launcher (provenance-hook.sh)  →  manifest.yaml  (genesis anchor)   [enforced]
   exports PROVENANCE_SESSION_DIR into the agent process
agent runs under the harness:
   each tool call    → PostToolUse hook  → append tool name to .hook_events.jsonl
   agent stops       → Stop hook         → aggregate events → append audit entry  [now enforced]
build completion     → Provenance_Attest → GPG-signed attestation
```

Counters follow the hybrid model: the harness fills `counters.*.harness`; the agent's own `self_report` (if it also writes one) is preserved; `Provenance_Verify` flags discrepancies. Tokens are **not** exposed to the hook API, so token counts remain `self_report`-only — recorded honestly as `harness: null`.

Tool → counter mapping (`provenance_chain.py` `TOOL_MAP`):

| Tool | Counter(s) |
|---|---|
| `Bash` | `shell_commands` |
| `Read` | `files_read`, `files_accessed` |
| `Write`, `Edit`, `NotebookEdit` | `files_written`, `files_accessed` |
| `Glob`, `Grep` | `files_accessed` |
| `WebFetch`, `WebSearch` | `network_calls` |

## Install (Claude Code)

1. Ensure the prompt library is available to the project (submodule at `prompts/`, the path assumed by the snippet — adjust if different).
2. Merge the `hooks` block from [`claude-code/settings.snippet.json`](claude-code/settings.snippet.json) into your project's `.claude/settings.json`.
3. Build via a provenance-enabled launcher (`start-prd.sh` etc.). The launcher exports `PROVENANCE_SESSION_DIR`; the hooks read it. **If you run `claude` directly (no launcher), the hooks no-op silently** — there's no session to append to, by design.

That's the whole install. The hooks never block the agent and never print to the model (they always `exit 0`); failures are written to `<session>/.hook.log`.

## How it stays consistent with the rest of the module

Both hooks delegate hashing to [`../lib/provenance_chain.py`](../lib/provenance_chain.py), the single source of the canonicalization rule (canonical JSON, sorted keys, `entry_hash` excluded). `tests/provenance_fixture/provenance_ref.py` imports the same `canon`/`entry_hash`, so the parity, tamper, and harness-capture tests all prove the identical rule the hooks use.

## Limitation

A turn maps to one audit entry. A multi-turn session (the agent pauses for input, you reply) produces one entry per turn, each capturing that turn's deltas — all under the same session and chain. Per-tool timing and tokens aren't captured (the hook API doesn't expose them).
