#!/usr/bin/env python3
"""provenance_chain — the production audit hash chain for provenance-kit.

Single source of truth for the canonicalization rule referenced by
Provenance_Audit.md and Provenance_Verify.md, and used by the harness hooks
(harness/) and the fixture tests
(tests/provenance_fixture/provenance_ref.py imports canon/entry_hash from here).

    canonical(entry) = JSON of the entry, sorted keys, no insignificant
                       whitespace, with the `entry_hash` field removed.
    entry_hash       = sha256(canonical(entry)).hexdigest()

The first entry's prev_hash is the manifest's genesis_hash; each later entry's
prev_hash is the previous entry's entry_hash.

CLI:
    provenance_chain.py append-entry  --session DIR [--agent ID]
        [--prompt-file F] [--prompt-sha S] [--counters-json JSON]
        [--summary TEXT]
    provenance_chain.py harness-finalize --session DIR --events FILE
        [--agent ID]
        # aggregate Claude-Code/opencode PostToolUse events into one audit
        # entry, then remove the events file.
"""
import sys, os, json, hashlib, argparse
from datetime import datetime, timezone

try:
    import yaml
except Exception:
    sys.stderr.write("provenance_chain requires PyYAML\n")
    sys.exit(2)

COUNTER_KEYS = ["shell_commands", "files_read", "files_written",
                "files_accessed", "network_calls", "tokens_in", "tokens_out"]

# Claude Code / opencode tool name -> which counters it increments.
# files_accessed is a superset (read + write + edit + glob + grep).
TOOL_MAP = {
    "Bash": ["shell_commands"],
    "Read": ["files_read", "files_accessed"],
    "Write": ["files_written", "files_accessed"],
    "Edit": ["files_written", "files_accessed"],
    "NotebookEdit": ["files_written", "files_accessed"],
    "Glob": ["files_accessed"],
    "Grep": ["files_accessed"],
    "WebFetch": ["network_calls"],
    "WebSearch": ["network_calls"],
}


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def canon(entry: dict) -> str:
    """Canonical JSON of the entry with entry_hash removed."""
    e = {k: v for k, v in entry.items() if k != "entry_hash"}
    return json.dumps(e, sort_keys=True, separators=(",", ":"))


def entry_hash(entry: dict) -> str:
    return sha256_text(canon(entry))


def _load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _agent_from_prompt(prompt_file: str) -> str:
    """Best-effort agent id from a prompt filename, e.g.
    agents/prd.md -> prd (harness-captured)."""
    stem = os.path.basename(prompt_file or "").rsplit(".", 1)[0]
    # strip leading NN_ ordinal
    parts = stem.split("_", 1)
    name = parts[1] if len(parts) == 2 and parts[0].isalnum() and parts[0][:2].isdigit() else stem
    return name.lower().replace("_", "-") or "harness-step"


def append_entry(session_dir, agent_id=None, prompt_file=None, prompt_sha=None,
                 counters=None, summary="", inputs=None, outputs=None,
                 source="agent"):
    """Append one entry to audit.yaml, extending the hash chain, and roll the
    new entry into summary.json. Returns the new entry_hash."""
    manifest = _load_yaml(os.path.join(session_dir, "manifest.yaml"))
    audit_path = os.path.join(session_dir, "audit.yaml")
    audit = _load_yaml(audit_path) if os.path.isfile(audit_path) else None
    if not audit:
        audit = {"schema": "provenance/audit@1", "entries": []}
    entries = audit["entries"]

    if entries:
        prev = entries[-1]["entry_hash"]
        seq = entries[-1]["seq"] + 1
    else:
        prev = manifest["genesis_hash"]
        seq = 1

    # Default agent / prompt from the manifest's starting prompt.
    sp = (manifest.get("user_inputs") or {}).get("starting_prompt") or {}
    if not prompt_file:
        prompt_file = sp.get("path", "unknown")
    if not prompt_sha:
        prompt_sha = sp.get("sha256", "unknown")
    if not agent_id:
        agent_id = os.environ.get("PROVENANCE_AGENT_ID") or _agent_from_prompt(prompt_file)

    # Normalize counters to the {harness, self_report} hybrid shape.
    counters = counters or {}
    norm = {}
    for k in COUNTER_KEYS:
        sub = counters.get(k, {})
        if not isinstance(sub, dict):
            sub = {"harness": sub, "self_report": None}
        norm[k] = {"harness": sub.get("harness"), "self_report": sub.get("self_report")}

    now = _now()
    e = {
        "seq": seq,
        "agent_id": agent_id,
        "prompt_file": prompt_file,
        "prompt_sha256": prompt_sha,
        "started_at": now,
        "ended_at": now,
        "inputs": inputs or [],
        "outputs": outputs or [],
        "counters": norm,
        "counter_notes": ("captured by %s PostToolUse/Stop hooks; tokens not "
                          "exposed to the hook API (self_report only)" % source
                          if source != "agent" else ""),
        "source": source,
        "summary": summary,
        "correction_of": None,
        "prev_hash": prev,
    }
    e["entry_hash"] = entry_hash(e)
    entries.append(e)
    with open(audit_path, "w") as f:
        yaml.safe_dump(audit, f, sort_keys=False)

    _roll_summary(session_dir, manifest, e)
    return e["entry_hash"]


def _roll_summary(session_dir, manifest, e):
    p = os.path.join(session_dir, "summary.json")
    if os.path.isfile(p):
        s = json.load(open(p))
    else:
        s = {"schema": "provenance/summary@1",
             "session_id": manifest.get("session_id"),
             "status": "in_progress",
             "genesis_hash": manifest.get("genesis_hash")}
    totals = s.setdefault("totals", dict.fromkeys(
        ["shell", "reads", "writes", "accessed", "network", "tokens_in", "tokens_out"], 0))
    by_agent = s.setdefault("by_agent", {})
    invoked = s.setdefault("agents_invoked", [])

    def val(k):
        sub = e["counters"][k]
        v = sub["harness"]
        if v is None:
            v = sub["self_report"]
        return v or 0

    mapping = {"shell": "shell_commands", "reads": "files_read",
               "writes": "files_written", "accessed": "files_accessed",
               "network": "network_calls", "tokens_in": "tokens_in",
               "tokens_out": "tokens_out"}
    for sk, ck in mapping.items():
        totals[sk] += val(ck)
    a = by_agent.setdefault(e["agent_id"], dict.fromkeys(
        ["steps", "shell", "reads", "writes", "accessed", "network",
         "tokens_in", "tokens_out"], 0))
    a["steps"] += 1
    for sk, ck in mapping.items():
        a[sk] += val(ck)
    if e["agent_id"] not in invoked:
        invoked.append(e["agent_id"])
    s["chain_head"] = e["entry_hash"]
    with open(p, "w") as f:
        json.dump(s, f, indent=2)


def harness_finalize(session_dir, events_file, agent_id=None, source="claude-code"):
    """Aggregate PostToolUse events (one tool_name per line) into one audit
    entry, then remove the events file. No-op (exit 0) if there are no events."""
    if not os.path.isfile(events_file):
        return 0
    counts = {}
    with open(events_file) as f:
        for line in f:
            name = line.strip()
            if name:
                counts[name] = counts.get(name, 0) + 1
    if not counts:
        os.remove(events_file)
        return 0

    counters = {k: {"harness": 0, "self_report": None} for k in COUNTER_KEYS}
    for tool, n in counts.items():
        for ck in TOOL_MAP.get(tool, []):
            counters[ck]["harness"] += n
    # tokens are not available via the hook API
    counters["tokens_in"] = {"harness": None, "self_report": None}
    counters["tokens_out"] = {"harness": None, "self_report": None}

    summary = "harness-captured turn: " + ", ".join(
        f"{t}×{n}" for t, n in sorted(counts.items()))
    append_entry(session_dir, agent_id=agent_id, counters=counters,
                 summary=summary, source=source)
    os.remove(events_file)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    ae = sub.add_parser("append-entry")
    ae.add_argument("--session", required=True)
    ae.add_argument("--agent")
    ae.add_argument("--prompt-file")
    ae.add_argument("--prompt-sha")
    ae.add_argument("--counters-json", default="{}")
    ae.add_argument("--summary", default="")
    ae.add_argument("--source", default="agent")

    hf = sub.add_parser("harness-finalize")
    hf.add_argument("--session", required=True)
    hf.add_argument("--events", required=True)
    hf.add_argument("--agent")
    hf.add_argument("--source", default="claude-code")

    args = ap.parse_args()
    if args.cmd == "append-entry":
        append_entry(args.session, agent_id=args.agent,
                     prompt_file=args.prompt_file, prompt_sha=args.prompt_sha,
                     counters=json.loads(args.counters_json),
                     summary=args.summary, source=args.source)
        return 0
    if args.cmd == "harness-finalize":
        return harness_finalize(args.session, args.events,
                                agent_id=args.agent, source=args.source)


if __name__ == "__main__":
    sys.exit(main())
