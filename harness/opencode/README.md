# opencode harness hooks — template (pending validation)

**Status:** Template + contract only. **Not yet validated against opencode's live hook API.** The Claude Code implementation in [`../claude-code/`](../claude-code/) is the working reference; this directory documents how to port it and what must be confirmed.

## The contract (harness-agnostic)

Any harness integration must do exactly two things, and nothing else:

1. **Per tool call:** append the tool's name as one line to
   `"$PROVENANCE_SESSION_DIR/.hook_events.jsonl"`. No-op if `PROVENANCE_SESSION_DIR` is unset or not a directory.
2. **When the agent stops:** run
   `python3 "$PROVENANCE_KIT_PATH/lib/provenance_chain.py" harness-finalize --session "$PROVENANCE_SESSION_DIR" --events "$PROVENANCE_SESSION_DIR/.hook_events.jsonl" --source opencode`
   then let it remove the events file. Always exit 0; never block the agent; never print to the model.

If a harness uses different tool names than Claude Code's (`Bash`/`Read`/`Write`/`Edit`/`Glob`/`Grep`/`WebFetch`/`WebSearch`), extend `TOOL_MAP` in `provenance_chain.py` with the opencode equivalents — that is the only code change the chain library should need.

## What must be confirmed before this is more than a template

- opencode's hook configuration format and where it lives (the equivalent of `.claude/settings.json` `hooks`).
- The post-tool / stop event names and whether opencode passes the tool name to the hook (and under which field).
- Whether opencode hook processes inherit the launcher-exported environment (`PROVENANCE_SESSION_DIR`, `PROVENANCE_KIT_PATH`). The whole design depends on this.
- opencode's session-id and working-directory exposure (already handled generically by `provenance-hook.sh`'s harness autodetect, but worth re-checking).

This is tracked separately; validate against a real opencode install before relying on it.
