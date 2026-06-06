# Contributing to provenance-kit

Thanks for your interest. This project is in early extraction (see
[`CHANGELOG.md`](CHANGELOG.md)); the notes below will firm up before `v0.1.0`.

## Principles

- **The tool never depends on a specific prompt library.** A library is read
  only as a path (`PROMPT_LIBRARY_PATH`) to hash files and read a git commit.
  Don't introduce assumptions about library contents or layout.
- **Records are hashes, never prompt text.** Anything written under
  `.build-provenance/` must contain digests, paths, SHAs, and counters — not
  prompt bodies. This is what keeps provenance records safe to publish.
- **Format stability.** The canonicalization in `lib/provenance_chain.py` is the
  single source of truth; the verifier and the writers must agree on it. Changes
  there are breaking and need a version bump.

## Tests

The fixture is the contract. Before sending a change, run:

```bash
cd tests/provenance_fixture
./run_parity_test.sh     # known-good build must verify PASS
./tamper_test.sh         # every forgery must be caught
```

CI runs both on pull requests.
