#!/usr/bin/env bash
#
# Claude Code PostToolUse hook for provenance capture.
# Records one event line (the tool name) per tool call into the active
# session's event log. Aggregated into an audit entry by stop.sh on Stop.
#
# Reads the PostToolUse JSON on stdin (fields: tool_name, session_id, cwd, …).
# Relies on PROVENANCE_SESSION_DIR being exported by the launcher
# (provenance-hook.sh). No-ops silently if provenance isn't active.
#
# Contract: never block the agent, never print to the model. Always exit 0.

# No session → provenance not active for this run. Silent no-op.
[[ -n "${PROVENANCE_SESSION_DIR:-}" && -d "${PROVENANCE_SESSION_DIR:-/nonexistent}" ]] || { cat >/dev/null; exit 0; }

events="$PROVENANCE_SESSION_DIR/.hook_events.jsonl"

# Extract tool_name from stdin JSON. Prefer jq; fall back to python3.
tool=""
if command -v jq >/dev/null 2>&1; then
  tool="$(jq -r '.tool_name // empty' 2>/dev/null)"
else
  tool="$(python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_name",""))
except Exception: pass' 2>/dev/null)"
fi

# Atomic single-line append (avoids read-modify-write races across tool calls).
[[ -n "$tool" ]] && printf '%s\n' "$tool" >> "$events"
exit 0
