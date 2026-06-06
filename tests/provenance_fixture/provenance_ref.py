#!/usr/bin/env python3
"""Reference implementation for the provenance-kit audit hash chain,
attestation, and parity checks. Used by run_parity_test.sh.

This codifies the canonicalization the prompts describe in prose:

    canonical(entry) = JSON of the entry, sorted keys, no whitespace,
                       with the `entry_hash` field removed.
    entry_hash       = sha256(canonical(entry)).hexdigest()

Provenance_Audit.md and Provenance_Verify.md MUST use this identical rule.
The first entry's prev_hash is the manifest's genesis_hash; each subsequent
entry's prev_hash is the previous entry's entry_hash. The signed attestation
folds in the chain head:

    attestation_hash = sha256(library_commit + project_final_commit +
                              session_id + audit_chain_head).hexdigest()

Subcommands:
    seed-audit  <session_dir> <lib_path>
    attest      <session_dir> <project_final_commit> [signer_key_id]
    finalize    <session_dir>                 # summary.json status=complete
    verify      <session_dir> [--gpg] [--full]
    parity      <session_dir> <project_dir>   # exits 1 if any observable FAILs
"""
import sys, os, json, hashlib, subprocess

try:
    import yaml
except Exception:
    sys.stderr.write("provenance_ref.py requires PyYAML (python3 -m pip install pyyaml)\n")
    sys.exit(2)


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# Import the canonicalization from the PRODUCTION chain lib so the tests prove
# the same rule the harness hooks use. Fall back to a local copy only if the
# lib can't be found (keeps the fixture runnable in isolation).
_LIB = os.path.join(os.path.dirname(__file__), "..", "..", "lib")
sys.path.insert(0, os.path.abspath(_LIB))
try:
    from provenance_chain import canon, entry_hash  # noqa: E402
except Exception:
    def canon(entry: dict) -> str:
        e = {k: v for k, v in entry.items() if k != "entry_hash"}
        return json.dumps(e, sort_keys=True, separators=(",", ":"))

    def entry_hash(entry: dict) -> str:
        return sha256_text(canon(entry))


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f)


# ── the four agent steps the fixture exercises (one per pipeline stage) ──
AGENTS = [
    ("initialization-agent-v1.0", "agents/init.md",
     [], [{"path": "project.manifest.yaml"}]),
    ("prd-agent-v1.0", "agents/prd.md",
     [{"path": "docs/inputs/product_proposal.md"}], [{"path": "docs/prd.md"}]),
    ("techstack-agent-v1.0", "agents/techstack.md",
     [{"path": "docs/prd.md"}], [{"path": "docs/techstack_decision.md"}]),
    ("validation-agent-v1.0", "agents/validation.md",
     [{"path": "docs/techstack_decision.md"}], []),
]


def agents_for(variant):
    """Variant 'b' diverges from 'a' so the sample comparison is interesting:
    it skips the techstack agent (a "skipped agent" the compare must surface)."""
    if variant == "b":
        return [AGENTS[0], AGENTS[1], AGENTS[3]]   # init, prd, validation (no techstack)
    return AGENTS


def cmd_seed_audit(session_dir, lib_path, variant="a"):
    manifest = load_yaml(os.path.join(session_dir, "manifest.yaml"))
    prev = manifest["genesis_hash"]
    entries = []
    by_agent = {}
    totals = dict(shell=0, reads=0, writes=0, accessed=0, network=0,
                  tokens_in=0, tokens_out=0)
    agents = agents_for(variant)
    tok_mult = 1000 if variant == "a" else 1500          # B is more token-hungry
    for i, (agent_id, prompt_file, inputs, outputs) in enumerate(agents, start=1):
        psha = "unknown"
        p = os.path.join(lib_path, prompt_file)
        if os.path.isfile(p):
            psha = sha256_file(p)
        # deterministic, internally-consistent counters; harness == self_report
        n = i * 5
        # Variant B phones home on its validation step — a non-zero network
        # signal the comparison must flag.
        net = 3 if (variant == "b" and agent_id == "validation-agent-v1.0") else 0
        counters = {
            "shell_commands": {"harness": n, "self_report": n},
            "files_read": {"harness": n * 3, "self_report": n * 3},
            "files_written": {"harness": len(outputs), "self_report": len(outputs)},
            "files_accessed": {"harness": n * 4, "self_report": n * 4},
            "network_calls": {"harness": net, "self_report": net},
            "tokens_in": {"harness": n * tok_mult, "self_report": n * tok_mult},
            "tokens_out": {"harness": n * 200, "self_report": n * 200},
        }
        e = {
            "seq": i,
            "agent_id": agent_id,
            "prompt_file": prompt_file,
            "prompt_sha256": psha,
            "started_at": f"2026-06-01T00:0{i}:00Z",
            "ended_at": f"2026-06-01T00:0{i}:30Z",
            "inputs": inputs,
            "outputs": outputs,
            "counters": counters,
            "counter_notes": "",
            "summary": f"{agent_id} step",
            "correction_of": None,
            "prev_hash": prev,
        }
        e["entry_hash"] = entry_hash(e)
        prev = e["entry_hash"]
        entries.append(e)
        by_agent[agent_id] = {
            "steps": 1, "shell": n, "reads": n * 3, "writes": len(outputs),
            "accessed": n * 4, "network": net, "tokens_in": n * tok_mult,
            "tokens_out": n * 200, "duration_s": 30 * i,
        }
        totals["shell"] += n
        totals["reads"] += n * 3
        totals["writes"] += len(outputs)
        totals["accessed"] += n * 4
        totals["network"] += net
        totals["tokens_in"] += n * tok_mult
        totals["tokens_out"] += n * 200

    with open(os.path.join(session_dir, "audit.yaml"), "w") as f:
        yaml.safe_dump({"schema": "provenance/audit@1", "entries": entries},
                       f, sort_keys=False)

    summary = {
        "schema": "provenance/summary@1",
        "session_id": manifest["session_id"],
        "status": "in_progress",
        "genesis_hash": manifest["genesis_hash"],
        "chain_head": prev,
        "totals": totals,
        "by_agent": by_agent,
        "agents_invoked": [a[0] for a in agents],
        "duration_s": sum(v["duration_s"] for v in by_agent.values()),
        "artifacts": ["docs/prd.md", "docs/techstack_decision.md"],
    }
    with open(os.path.join(session_dir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(f"seeded {len(entries)} audit entries; chain_head={prev[:16]}…")


def cmd_attest(session_dir, project_final_commit, signer_key_id="unsigned"):
    manifest = load_yaml(os.path.join(session_dir, "manifest.yaml"))
    audit = load_yaml(os.path.join(session_dir, "audit.yaml"))
    chain_head = audit["entries"][-1]["entry_hash"]
    lib_commit = manifest["library"]["commit"]
    session_id = manifest["session_id"]
    att_hash = sha256_text(lib_commit + project_final_commit + session_id + chain_head)
    payload = {
        "schema": "provenance/attestation@1",
        "session_id": session_id,
        "library_commit": lib_commit,
        "project_final_commit": project_final_commit,
        "audit_chain_head": chain_head,
        "attestation_hash": att_hash,
        "signer_key_id": signer_key_id,
        "signed_at": "2026-06-01T00:05:00Z",
        "formula": "SHA256(library_commit || project_final_commit || session_id || audit_chain_head)",
    }
    with open(os.path.join(session_dir, "attestation.yaml"), "w") as f:
        yaml.safe_dump(payload, f, sort_keys=False)
    print(f"attestation_hash={att_hash[:16]}… (signer={signer_key_id})")


def cmd_finalize(session_dir):
    p = os.path.join(session_dir, "summary.json")
    with open(p) as f:
        s = json.load(f)
    att = load_yaml(os.path.join(session_dir, "attestation.yaml"))
    s["status"] = "complete"
    s["attestation_hash"] = att["attestation_hash"]
    s["signer_key_id"] = att["signer_key_id"]
    with open(p, "w") as f:
        json.dump(s, f, indent=2)
    print("summary finalized (status=complete)")


def _walk_chain(session_dir):
    """Return (ok, message, chain_head)."""
    manifest = load_yaml(os.path.join(session_dir, "manifest.yaml"))
    # genesis recompute
    lines = open(os.path.join(session_dir, "manifest.yaml")).readlines()
    body = "".join(l for l in lines if not l.startswith("genesis_hash:"))
    if sha256_text(body) != manifest["genesis_hash"]:
        return False, "manifest genesis_hash mismatch (manifest tampered)", None
    audit = load_yaml(os.path.join(session_dir, "audit.yaml"))
    prev = manifest["genesis_hash"]
    expected_seq = 1
    for e in audit["entries"]:
        if e.get("seq") != expected_seq:
            return False, f"chain break: expected seq {expected_seq}, got {e.get('seq')}", None
        if e.get("prev_hash") != prev:
            return False, f"chain break at seq {e.get('seq')}: prev_hash mismatch", None
        recomputed = entry_hash(e)
        if recomputed != e.get("entry_hash"):
            return False, f"chain break at seq {e.get('seq')}: entry_hash mismatch", None
        prev = e["entry_hash"]
        expected_seq += 1
    return True, "chain intact", prev


def cmd_verify(session_dir, use_gpg=False):
    ok, msg, head = _walk_chain(session_dir)
    print(f"chain: {'PASS' if ok else 'FAIL'} ({msg})")
    if not ok:
        return 1
    manifest = load_yaml(os.path.join(session_dir, "manifest.yaml"))
    att = load_yaml(os.path.join(session_dir, "attestation.yaml"))
    if att["audit_chain_head"] != head:
        print("attestation: FAIL (chain head does not match audit log)")
        return 1
    recomputed = sha256_text(att["library_commit"] + att["project_final_commit"]
                             + manifest["session_id"] + head)
    if recomputed != att["attestation_hash"]:
        print("attestation: FAIL (hash mismatch)")
        return 1
    print("attestation: PASS (hash matches formula)")
    if use_gpg:
        asc = os.path.join(session_dir, "attestation.asc")
        pay = os.path.join(session_dir, "attestation.yaml")
        if os.path.isfile(asc):
            r = subprocess.run(["gpg", "--verify", asc, pay],
                               capture_output=True)
            print(f"gpg signature: {'PASS' if r.returncode == 0 else 'FAIL'}")
            if r.returncode != 0:
                return 1
        else:
            print("gpg signature: SKIP (no attestation.asc)")
    return 0


# ── parity: assert every observable in the expected observable set ──
def cmd_parity(session_dir, project_dir):
    results = []  # (status, label)

    def check(cond, label, skip=False, superseded=None):
        if superseded:
            results.append(("SUPERSEDED", f"{label}  → {superseded}"))
        elif skip:
            results.append(("SKIP", label))
        else:
            results.append(("PASS" if cond else "FAIL", label))

    manifest_path = os.path.join(session_dir, "manifest.yaml")
    have_manifest = os.path.isfile(manifest_path)
    m = load_yaml(manifest_path) if have_manifest else {}

    # Legacy single-file session log → superseded by the session directory.
    check(have_manifest,
          "legacy session_<uuid>.yaml",
          superseded="manifest.yaml + audit.yaml in session_<uuid>/ directory")

    # manifest / Init observables (legacy prompt_library.commit; rows 10–12)
    ui = (m.get("user_inputs") or {})
    sp = (ui.get("starting_prompt") or {})
    check(bool(m.get("session_id")), "session_id present")
    check(bool(m.get("started_at")), "started_at present")
    check(bool(m.get("invocation_cwd")), "invocation_cwd present  [new dim]")
    check(bool((m.get("harness") or {}).get("name")), "harness.name present  [new dim]")
    check(bool(sp.get("path")), "starting_prompt.path present")
    check(len(str(sp.get("sha256", ""))) == 64, "starting_prompt.sha256 (64 hex)")
    check("initial_user_message" in ui, "user_inputs.initial_user_message present  [new dim]")
    check(len(str((m.get("library") or {}).get("commit", ""))) >= 7,
          "library.commit present  (legacy prompt_library.commit)")
    check(bool((m.get("project") or {}).get("commit_at_init")),
          "project.commit_at_init present")
    check(len(str(m.get("genesis_hash", ""))) == 64,
          "genesis_hash anchor (64 hex)  [new dim]")

    # audit observables (legacy prompts_used[]; rows 10/12 + new dims)
    audit_path = os.path.join(session_dir, "audit.yaml")
    a = load_yaml(audit_path) if os.path.isfile(audit_path) else {"entries": []}
    entries = a.get("entries", [])
    check(len(entries) >= 1, "audit has >=1 entry  (legacy prompts_used[])")
    if entries:
        e = entries[0]
        check(bool(e.get("agent_id")), "entry.agent_id present")
        check(bool(e.get("prompt_file")), "entry.prompt_file present  (row 12)")
        check(len(str(e.get("prompt_sha256", ""))) == 64, "entry.prompt_sha256 (64 hex)  (row 12)")
        check("outputs" in e, "entry.outputs present  (legacy outputs[])")
        c = (e.get("counters") or {})
        for k in ("shell_commands", "files_read", "files_written",
                  "files_accessed", "network_calls", "tokens_in", "tokens_out"):
            sub = c.get(k) or {}
            check("harness" in sub and "self_report" in sub,
                  f"counter {k} (harness+self_report)  [new dim]")
        check("prev_hash" in e and "entry_hash" in e,
              "entry hash-chain fields (prev_hash, entry_hash)  [new dim]")

    # hash chain integrity
    ok, msg, head = _walk_chain(session_dir)
    check(ok, f"audit hash chain intact  [new dim]  ({msg})")

    # attestation observables (rows 13–15; formula superseded)
    att_path = os.path.join(session_dir, "attestation.yaml")
    have_att = os.path.isfile(att_path)
    att = load_yaml(att_path) if have_att else {}
    check(len(str(att.get("attestation_hash", ""))) == 64,
          "attestation_hash (64 hex)  (rows 13/15)")
    check("audit_chain_head" in att,
          "legacy attestation formula",
          superseded="SHA256(lib || project_final || session || audit_chain_head)")
    asc = os.path.join(session_dir, "attestation.asc")
    if os.path.isfile(asc):
        check(True, "attestation.asc GPG signature present  (row 14)")
        check(bool(att.get("signer_key_id")) and att.get("signer_key_id") != "unsigned",
              "signer_key_id present  (row 14/15)")
        check(bool(att.get("signed_at")), "signed_at present  (row 14/15)")
    else:
        check(False, "attestation.asc GPG signature  (row 14)", skip=True)
        check(False, "signer_key_id  (row 14/15)", skip=True)
        check(False, "signed_at  (row 14/15)", skip=True)

    # summary.json
    sjson = os.path.join(session_dir, "summary.json")
    s = json.load(open(sjson)) if os.path.isfile(sjson) else {}
    check(s.get("status") == "complete", "summary.json status=complete")
    check(bool(s.get("agents_invoked")), "summary.agents_invoked present  [new dim]")

    # launcher.log (rows 2/3)
    storage_root = os.path.dirname(session_dir.rstrip("/"))
    check(os.path.isfile(os.path.join(storage_root, "launcher.log")),
          "launcher.log present  (rows 2/3)")

    # final commit Prompt: + Attestation: trailer (row 16)
    try:
        log = subprocess.run(["git", "-C", project_dir, "log", "-5", "--format=%B"],
                             capture_output=True, text=True).stdout
    except Exception:
        log = ""
    check("Prompt:" in log and "@ sha256:" in log,
          "final commit carries 'Prompt: ... @ sha256:'  (row 16)")
    check("Attestation:" in log,
          "final commit carries 'Attestation:'  [new dim]")

    # ── report ──
    width = max(len(l) for _, l in results)
    print("\nParity report (expected observable set)\n")
    counts = {}
    for status, label in results:
        counts[status] = counts.get(status, 0) + 1
        mark = {"PASS": "✓", "FAIL": "✗", "SKIP": "•", "SUPERSEDED": "→"}[status]
        print(f"  {mark} [{status:10}] {label}")
    print("\nSummary: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    fails = counts.get("FAIL", 0)
    print(("\nRESULT: PASS — parity satisfied" if fails == 0
           else f"\nRESULT: FAIL — {fails} observable(s) missing without supersession"))
    return 1 if fails else 0


def _load_session(session_dir):
    s = json.load(open(os.path.join(session_dir, "summary.json")))
    m = load_yaml(os.path.join(session_dir, "manifest.yaml"))
    return s, m


def cmd_compare(dir_a, dir_b):
    """Emit the Markdown comparison from Provenance_Compare.md, organized around
    the anticipated questions (tokens, phone-home, skipped agent, time, drift)."""
    sa, ma = _load_session(dir_a)
    sb, mb = _load_session(dir_b)
    ida, idb = sa["session_id"][:8], sb["session_id"][:8]
    ta, tb = sa.get("totals", {}), sb.get("totals", {})

    def delta(a, b):
        try:
            d = int(a) - int(b)
            return f"+{d}" if d > 0 else str(d)
        except Exception:
            return "—"

    out = []
    out.append(f"# Provenance Comparison — A (`{ida}`) vs B (`{idb}`)\n")
    out.append("| Dimension | A | B | Δ (A−B) |")
    out.append("|-----------|---|---|---------|")

    ha = (ma.get("harness") or {}).get("name", "?")
    hb = (mb.get("harness") or {}).get("name", "?")
    out.append(f"| Harness | {ha} | {hb} | {'same' if ha == hb else 'differ'} |")

    ca = ma.get("library", {}).get("commit", "?")[:12]
    cb = mb.get("library", {}).get("commit", "?")[:12]
    out.append(f"| Library commit | `{ca}` | `{cb}` | {'same' if ca == cb else 'diverged ⚠'} |")

    for label, key in [("Tokens in", "tokens_in"), ("Tokens out", "tokens_out"),
                       ("Shell commands", "shell"), ("Files written", "writes"),
                       ("Files read", "reads"), ("Files accessed", "accessed")]:
        out.append(f"| {label} | {ta.get(key, 0)} | {tb.get(key, 0)} | {delta(ta.get(key, 0), tb.get(key, 0))} |")

    na, nb = ta.get("network", 0), tb.get("network", 0)
    warn = " ⚠" if (na or nb) else ""
    out.append(f"| Network calls | {na} | {nb} | {delta(na, nb)}{warn} |")

    aa = set(sa.get("agents_invoked", []))
    ab = set(sb.get("agents_invoked", []))
    only_a = sorted(aa - ab)
    only_b = sorted(ab - aa)
    note = "same set"
    if only_a or only_b:
        bits = []
        if only_b:
            bits.append("A skipped " + ", ".join(x.replace("-agent-v1.0", "") for x in only_b))
        if only_a:
            bits.append("B skipped " + ", ".join(x.replace("-agent-v1.0", "") for x in only_a))
        note = "; ".join(bits)
    out.append(f"| Agents invoked | {len(aa)} | {len(ab)} | {note} |")

    da, db = sa.get("duration_s", 0), sb.get("duration_s", 0)
    out.append(f"| Duration (s) | {da} | {db} | {delta(da, db)} |")

    # Drill-downs for the flagged rows.
    out.append("\n## Drill-down\n")

    # phone-home
    if na or nb:
        out.append("### Network calls (phone-home check)\n")
        for tag, d in (("A", dir_a), ("B", dir_b)):
            audit = load_yaml(os.path.join(d, "audit.yaml"))
            hits = [(e["seq"], e["agent_id"], e["counters"]["network_calls"]["harness"])
                    for e in audit["entries"]
                    if (e["counters"]["network_calls"]["harness"] or 0) > 0]
            if hits:
                out.append(f"**{tag}** made network calls:\n")
                out.append("| seq | agent | network_calls |")
                out.append("|-----|-------|---------------|")
                for seq, agent, nc in hits:
                    out.append(f"| {seq} | {agent} | {nc} |")
                out.append("")
        out.append("> Non-zero network from a build that should be hermetic is a red flag — inspect the agent above.\n")

    # skipped agent
    if only_a or only_b:
        out.append("### Skipped agents\n")
        if only_b:
            out.append(f"- Present in A but not B: {', '.join(only_b)}")
        if only_a:
            out.append(f"- Present in B but not A: {', '.join(only_a)}")
        out.append("")

    # prompt drift / library divergence
    out.append("### Prompt drift / library divergence\n")
    if ca == cb:
        out.append(f"Both builds used prompt-library commit `{ca}` — no library divergence, so no prompt drift between them.\n")
    else:
        out.append(f"Library commits differ (`{ca}` vs `{cb}`). Inspect which prompt files changed:\n")
        out.append(f"```bash\ngit -C <library> diff --stat {ca}..{cb} -- agents/\n```\n")

    out.append("> Each number above is one drill-down from its evidence: open the named "
               "`audit.yaml` slice, or re-run `provenance_ref.py verify <session>` to confirm integrity.\n")
    print("\n".join(out))
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "seed-audit":
        variant = sys.argv[4] if len(sys.argv) > 4 else "a"
        cmd_seed_audit(sys.argv[2], sys.argv[3], variant); return 0
    if cmd == "compare":
        return cmd_compare(sys.argv[2], sys.argv[3])
    if cmd == "attest":
        signer = sys.argv[4] if len(sys.argv) > 4 else "unsigned"
        cmd_attest(sys.argv[2], sys.argv[3], signer); return 0
    if cmd == "finalize":
        cmd_finalize(sys.argv[2]); return 0
    if cmd == "verify":
        return cmd_verify(sys.argv[2], use_gpg=("--gpg" in sys.argv))
    if cmd == "parity":
        return cmd_parity(sys.argv[2], sys.argv[3])
    print(f"unknown subcommand: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
