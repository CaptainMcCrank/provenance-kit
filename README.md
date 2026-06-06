# provenance-kit

***Warning.  BETA Build.  📣 Only intended for the courageous.📣  **

**A tamper-evident record of which prompts, at which versions, produced which software — and the tooling to verify, inspect, and compare it later.**

When AI agents write your code, the prompts *are* the source- but for most builders, they're the one build input version control wasn't capturing. provenance-kit closes that gap: it treats each prompt as a first-class, hashable, signable build input, so "which instructions produced this software, and can you prove it?" stops being vague memory and is replaced by a command you run.

It's a drop-in tool. Point it at a prompt library — any directory under version control — and builds that use it start producing provenance. Works under Claude Code or opencode.

> ℹ️ This repository is a work-in-progress extraction from a private prompt library. Some references are still being genericized — see [`CHANGELOG.md`](CHANGELOG.md).

## Your prompts never leave your control

provenance-kit records **hashes of** your prompts, not the prompts themselves. A build's provenance — manifest, audit chain, signed attestation — contains SHA-256 digests, git commit SHAs, and activity counters. **No prompt text.**

- You can publish a provenance record, attach it to an incident report, or hand it to an auditor — it discloses nothing about what your instructions say.
- Verifying a record requires *possessing the library* to recompute the hashes. The proof is meaningful to anyone holding the prompts and opaque to everyone else.

This tool is public, but your library stays private.  Records are safe to share. Nothing about provenance requires exposing a internal prompts.

## What it answers

| | Question | You get… |
|---|---|---|
| **A** | What prompts produced this version, at what version? | A per-build ledger: every prompt file + content hash + the library commit |
| **B** | How do I *prove* the software was built with these prompts? | An append-only **hash chain**, sealed with a **GPG-signed attestation** |
| **C** | How do I test the proof itself works? | A `verify` step (run in CI) that re-derives every hash and rejects tampering |
| **D** | Handed an unfamiliar project — where are its prompts? | A `discover` step that writes a one-page `PROVENANCE.md` |

## Two paths, two jobs

provenance-kit deliberately keeps two things separate:

| | What | How you install it |
|---|---|---|
| **`module_path`** | the **tool** (this repo) | **Vendor it** — copy a tagged release into your project and commit it, so the exact version that builds/verifies your records is reproducible from the project itself. |
| **`library_path`** (`PROMPT_LIBRARY_PATH`) | the **subject** being hashed (your prompts) | **Reference by path** — a gitignored symlink, a sibling checkout, anywhere. Never bundled, never needs to be public. |

The tool reads the library only to hash files and read its git commit (`git -C "$PROMPT_LIBRARY_PATH" rev-parse HEAD`). It is never a code dependency. That separation is what lets the tool be public while the library stays private.

## Quickstart

```bash
# 1. Vendor the tool (committed, pinned) — no submodule of anything private
cp -r ~/src/provenance-kit ./provenance-kit
git add provenance-kit && git commit -m "vendor provenance-kit vX.Y.Z"

# 2. Point at your prompt library however you manage it (symlink + gitignore)
ln -s ~/path/to/your-prompt-library ./prompts
echo "/prompts" >> .gitignore

# 3. Add the prompt_provenance block to project.manifest.yaml
#    (canonical block: prompts/Provenance_Manifest_Block.md)
#      module_path:  ./provenance-kit
#      library_path: <from PROMPT_LIBRARY_PATH below>

# 4. Configure .env
cat > .env <<'EOF'
PROMPT_LIBRARY_PATH=./prompts
GPG_SIGNING_KEY_ID=ABCD1234EFGH5678
EOF
```

Your launchers source `provenance-kit/provenance-hook.sh`; every agent run then opens a session and records provenance. Day-to-day workflow is unchanged, and your library files never enter the project's git history.

## How it works (in brief)

Three moments of a build, then consume on demand:

1. **Init** (`prompts/Provenance_Init.md`) writes an immutable `manifest.yaml` — starting prompt + SHA, verbatim user request, library commit, project commit, harness + session id — hashed into a `genesis_hash`.
2. **Audit** (`prompts/Provenance_Audit.md`) appends one hash-chained `audit.yaml` entry per agent step (prompt path + hash, reads/writes, activity counters). Each entry folds in the previous one, so altering any earlier entry breaks every hash after it.
3. **Attest** (`prompts/Provenance_Attest.md`) computes `attestation_hash = SHA256(library_commit ‖ project_final_commit ‖ session_id ‖ audit_chain_head)` and GPG-signs it. No key + attestation required → the build fails loudly at launch.

Consume with **Verify** (re-derives every hash + checks the signature; runs in CI against known-good *and* tampered fixtures), **Discover** (writes `PROVENANCE.md`), and **Compare** (diffs two builds: tokens, network, agents, library drift).

### Enforced vs. instructed (honest status)

The **signing gate** and **immutable manifest** are enforced at the shell boundary today (`provenance-hook.sh`). The per-step audit entries and final attestation are currently *instructed* (an agent follows the prompts to write them); fully automatic capture needs a harness hook — the Claude Code hooks under `harness/` are the first step. Format and verifier don't change when capture becomes automatic.

## Layout

```
prompts/            # the agent-facing provenance prompts (Init/Audit/Attest/Verify/Discover/Compare + Manifest_Block)
lib/                # provenance_chain.py — the canonical hashing/canonicalization source
harness/            # Claude Code + opencode hook integration
templates/          # a minimal project.manifest.yaml with the prompt_provenance block
provenance-hook.sh  # sourced by your launchers; enforces the gate + opens sessions
tests/provenance_fixture/   # runnable end-to-end example + tamper matrix
```

## Try the fixture

```bash
cd tests/provenance_fixture
./run_parity_test.sh     # builds a known-good session and verifies it
./tamper_test.sh         # confirms verification rejects forgery
```

## License

Apache License 2.0 — see [`LICENSE`](LICENSE). Copyright 2026 Patrick McCanna; see [`NOTICE`](NOTICE).
