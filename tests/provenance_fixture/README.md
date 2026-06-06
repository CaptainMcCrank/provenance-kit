# Provenance fixture — self-contained end-to-end example

**Purpose:** A hermetic, runnable example that exercises provenance-kit end to
end. It produces a known-good build, proves that build verifies clean, and runs
a tamper matrix proving that any forgery is caught. Nothing here reaches outside
this directory — the prompt library being hashed is a throwaway git repo built
from the bundled `sample-library/`.

## Run it

```bash
tests/provenance_fixture/run_parity_test.sh          # known-good build → verify → parity report (exit 0 = PASS)
tests/provenance_fixture/run_parity_test.sh --keep   # leave the build dir for inspection
tests/provenance_fixture/tamper_test.sh              # tamper matrix: exit 0 = every forgery caught
tests/provenance_fixture/harness_capture_test.sh     # Claude Code hooks capture a valid audit entry
```

All three run in CI via [`.github/workflows/provenance.yml`](../../.github/workflows/provenance.yml).

Requirements: `git`, `python3` + PyYAML. `gpg` is optional — without it the tests
relax `attestation.required` and mark the signature observables `SKIP` instead of
failing.

## What's real vs. simulated

A full agent pipeline needs live LLM calls and can't run in CI, so the test
splits the work:

| Part | How |
|---|---|
| Prompt library being hashed | **HERMETIC** — `sample-library/` is copied into a temp dir and turned into a throwaway git repo per run; the fixture hashes those files, never any real library |
| Session open (manifest, genesis anchor, gate) | **REAL** — calls `provenance_gate` + `provenance_open_session` from the actual [`provenance-hook.sh`](../../provenance-hook.sh) |
| Per-agent audit chain + attestation | **SIMULATED** — [`provenance_ref.py`](provenance_ref.py) seeds a valid hash chain and a signed attestation, standing in for what a live pipeline's agents would write |
| GPG signing | **REAL** — an ephemeral throwaway key is generated in a temp `GNUPGHOME` and used to sign the attestation, which is then verified |

## Files

| File | Role |
|---|---|
| `sample-library/agents/*.md` | Four short, neutral, fake agent prompts (`init`, `prd`, `techstack`, `validation`) that stand in for a consumer's prompt library |
| `fixture/` | The minimal project (manifest opting into provenance + a tiny proposal) copied into a temp dir per run |
| `provenance_ref.py` | Reference codification of the audit hash chain, attestation, verify, and parity checks. **Authoritative source of the canonicalization rule** (`canon()` / `entry_hash()`) that `Provenance_Audit.md` and `Provenance_Verify.md` reference |
| `lib_build.sh` | Shared helper that builds one known-good session (hermetic library, real hook for Init, `provenance_ref.py` for the simulated audit chain + signed attestation). Used by all test scripts so the canonical "good build" lives in one place |
| `run_parity_test.sh` | Builds the known-good session, verifies it, and prints a parity report over the expected observable set |
| `tamper_test.sh` | Tamper matrix: build known-good, assert it verifies, then assert verify FAILS on a copy for each forgery (altered counter, forged prompt hash, deleted entry, edited manifest, bad attestation hash, altered signed payload) |
| `harness_capture_test.sh` | Drives the real Claude Code hooks with synthetic events and asserts they produce a valid, verifiable audit entry |

## How to read the results

`provenance_ref.py parity` prints one line per observable with one of:

- **PASS** — observable present in the build
- **FAIL** — observable missing without supersession (test fails, exit 1)
- **SUPERSEDED** — an earlier observable intentionally replaced; the replacement is named. Two are expected:
  - a single-file `session_<uuid>.yaml` → the `session_<uuid>/` directory (`manifest.yaml` + `audit.yaml`)
  - the earlier attestation formula → `SHA256(library_commit ‖ project_final_commit ‖ session_id ‖ audit_chain_head)`
- **SKIP** — not exercised in this environment (e.g. GPG absent)

The tamper matrix has teeth: corrupting any audit entry breaks the chain and
flips the relevant check to FAIL; deleting or editing the attestation FAILs the
attestation observables. A known-good build must PASS and every deliberate
tamper must FAIL for the suite to be green.
