#!/usr/bin/env bash
#
# Claude Code Stop hook for provenance capture.
# Aggregates the events recorded by post_tool_use.sh during this turn into one
# hash-chained audit entry (via provenance_chain.py), then clears the events.
#
# Reads the Stop JSON on stdin (fields: session_id, cwd, …). Relies on
# PROVENANCE_SESSION_DIR (exported by the launcher) and PROVENANCE_KIT_PATH
# (exported by provenance-hook.sh) to locate the chain library.
#
# Contract: never block the agent, never print to the model. Always exit 0.

cat >/dev/null   # drain stdin; we don't need the Stop payload

[[ -n "${PROVENANCE_SESSION_DIR:-}" && -d "${PROVENANCE_SESSION_DIR:-/nonexistent}" ]] || exit 0

events="$PROVENANCE_SESSION_DIR/.hook_events.jsonl"
[[ -f "$events" ]] || exit 0   # nothing happened this turn

# Locate the chain library. Prefer PROVENANCE_KIT_PATH (exported by
# provenance-hook.sh, pointing at the vendored TOOL); fall back to this script's
# own location in the tool tree.
lib=""
if [[ -n "${PROVENANCE_KIT_PATH:-}" && -f "$PROVENANCE_KIT_PATH/lib/provenance_chain.py" ]]; then
  lib="$PROVENANCE_KIT_PATH/lib/provenance_chain.py"
else
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lib="$here/../../lib/provenance_chain.py"
fi
[[ -f "$lib" ]] || exit 0   # can't find the lib; degrade silently

# Append the entry; swallow errors so the agent is never blocked. Diagnostics
# (if any) go to a side log, never to stdout/stderr-to-model.
python3 "$lib" harness-finalize \
  --session "$PROVENANCE_SESSION_DIR" \
  --events "$events" \
  --source claude-code \
  >>"$PROVENANCE_SESSION_DIR/.hook.log" 2>&1 || true
exit 0
