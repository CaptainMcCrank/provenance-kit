# Provenance Compare

**Purpose:** Compare the provenance of two (or more) projects or sessions side by side, presenting the data so the questions you'd naturally ask — which used more tokens, did either phone home, did either skip an agent, where did the time go — are visible at a glance and drillable to their evidence.

**Integration:** Reference this file when comparing builds:
> "Read and follow `prompts/Provenance_Compare.md` with two session directories to produce a comparison report."

**Prerequisites:** Each input has a `summary.json` (and `audit.yaml` for drill-down) produced by this module.

**Related:** [`Provenance_Discover.md`](Provenance_Discover.md), [`Provenance_Verify.md`](Provenance_Verify.md)

> **Runnable reference + sample.** [`tests/provenance_fixture/provenance_ref.py`](../../tests/provenance_fixture/provenance_ref.py) `compare <sessionA> <sessionB>` implements this prompt and emits the table below. A worked sample comparing two deliberately-divergent fixture builds (one skips an agent, phones home, and burns more tokens) lives at [`tests/provenance_fixture/sample_report.md`](../../tests/provenance_fixture/sample_report.md); regenerate it with `tests/provenance_fixture/gen_sample_report.sh`.

---

## Design principle: anticipate the question, pre-place the answer

Comparison reads from the pre-rolled `summary.json` of each session, so a basic question never requires parsing a full chain. Each row of the comparison maps to a question someone actually asks, and each row links to the `audit.yaml` slice that explains it.

| Question you'll ask | Row that answers it | Drill-down |
|---|---|---|
| Which build used more tokens? | `tokens_in` / `tokens_out` totals | per-agent token table |
| Which agents wrote the most files? | `writes` by agent | `audit.yaml` outputs[] |
| Did either build phone home? | `network` total (⚠ if non-zero) | entries with `network_calls > 0` |
| Did either skip an agent? | `agents_invoked` vs manifest's expected set | manifest `agents:` |
| Where did the time go? | `duration_s` by agent | entry `started_at`/`ended_at` |
| Did a prompt change between builds? | `library_commit` diff | `git diff <a>..<b>` over prompt files |
| What was each actually asked to do? | `initial_user_message` | manifest `user_inputs` |
| Is each build's proof intact? | Verify verdict per session | run `Provenance_Verify.md` |

## Steps

### 1. Load each input's summary and manifest

```bash
set -euo pipefail
A="${1:?usage: compare <session_dir_A> <session_dir_B> [more...]}"
B="${2:?}"
# Read summary.json (totals, by_agent, agents_invoked, chain_head, artifacts)
# and manifest.yaml (harness, user_inputs, library, project) for each.
```

Normalize counters the same way `summary.json` does: prefer `harness` values, fall back to `self_report` when `harness` is null. **Annotate** which source was used per column when they differ across the inputs being compared (comparing a wrapped run against an unwrapped one is valid but worth flagging).

### 2. Emit the comparison table

```markdown
# Provenance Comparison — A vs B

| Dimension          | A (`<short-uuid>`) | B (`<short-uuid>`) | Δ            |
|--------------------|--------------------|--------------------|--------------|
| Harness            | claude-code        | opencode           | differ       |
| Library commit     | `abc123`           | `def456`           | diverged →   |
| Tokens (in/out)    | 120k / 22k         | 70k / 19k          | +50k / +3k   |
| Shell commands     | 87                 | 134                | −47          |
| Files written      | 38                 | 22                 | +16          |
| Files read         | 412                | 380                | +32          |
| Network calls      | 0                  | 4                  | +4 ⚠         |
| Agents invoked     | 11/11              | 9/11               | A +2 (B skipped review, validation) |
| Duration           | 30m 20s            | 18m 12s            | +12m 8s      |
| Verify             | ✅ PASS            | ✅ PASS            | —            |
```

Rules for the Δ column:
- Numeric: show signed difference (A − B).
- `network_calls`: append ⚠ whenever **either** side is non-zero.
- `agents_invoked`: name the missing agents, not just the count, by diffing each side's set against the manifest's expected `agents:`.
- `library_commit`: when divergent, add a "Prompt changes" subsection (below).

### 3. Prompt-change subsection (when library commits differ)

```bash
# Which prompt files differ between the two builds' library commits:
git -C "$LIB_PATH" diff --stat "$LIB_COMMIT_A".."$LIB_COMMIT_B" -- Standards/
```

List the changed prompt files so a reader sees *which* prompts differed, not merely that the commit changed.

### 4. Per-dimension drill-down

Under the table, for any flagged or surprising row, include the supporting `audit.yaml` slice. Example for a non-zero network row:

```markdown
#### B — network calls (4)
| seq | agent | network_calls | summary |
|-----|-------|---------------|---------|
| 5 | build-agent-v1.0 | 4 | npm install pulled 4 registry requests |
```

### 5. Scale beyond two

For N inputs, widen the table to one column per input and make Δ a short note ("max: B, min: D"). Keep the same row set so the report shape is stable regardless of N.

## Output

A Markdown comparison report. It reads top-down from headline differences to drill-down evidence, so the first screen answers the common questions and every number is one click from its source in `audit.yaml`.
