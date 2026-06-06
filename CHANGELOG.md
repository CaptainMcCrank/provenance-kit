# Changelog

All notable changes to provenance-kit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
[Semantic Versioning](https://semver.org/) — releases are how consumers vendor
and pin the tool, so versions are cut deliberately.

## [Unreleased]

First public release is being prepared. Everything below ships in `v0.1.0`.

### Added
- **Provenance prompts** (`prompts/`) for the three build moments —
  `Provenance_Init`, `Provenance_Audit`, `Provenance_Attest` — and the three
  consumers — `Provenance_Verify`, `Provenance_Discover`, `Provenance_Compare`,
  plus the canonical `Provenance_Manifest_Block`.
- **Canonical hash chain** (`lib/provenance_chain.py`): the single
  canonicalization/hashing source shared by the writers and the verifier.
- **Shell gate** (`provenance-hook.sh`): enforces the immutable session manifest
  and the signing gate; sourced by a project's launchers. Exports
  `PROVENANCE_KIT_PATH` so the tool is located independently of the library.
- **Harness integration** (`harness/`) for Claude Code (PreToolUse/Stop hooks)
  and an opencode contract.
- **Library-agnostic design**: the tool reads a prompt library only by path
  (`PROMPT_LIBRARY_PATH`) to hash files and read its git commit. Records contain
  hashes, commit SHAs, and counters — never prompt text — so they are safe to
  publish while the library stays private.
- **Hermetic fixture** (`tests/provenance_fixture/`): a self-contained,
  end-to-end example built against a bundled `sample-library/`, with an A/B
  parity test, a tamper matrix (every forgery must be caught), and a harness
  capture test. Run in CI on every push/PR.
- Apache-2.0 license.

[Unreleased]: https://github.com/CaptainMcCrank/provenance-kit/commits/main
