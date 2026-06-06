# Changelog

All notable changes to provenance-kit are documented here. This project aims to
follow [Semantic Versioning](https://semver.org/) — releases are how consumers
vendor and pin the tool, so versions are cut deliberately.

## [Unreleased]

### Extraction in progress
provenance-kit is being lifted out of a private prompt library into this
standalone repo. Tracking work before the first tagged release:

- [ ] **Decouple the two paths** — harness hooks and prompts must locate
      `lib/provenance_chain.py` and the reference tooling under the *tool*
      (`module_path` / exported `PROVENANCE_KIT_PATH`), not under
      `PROMPT_LIBRARY_PATH`.
- [ ] **Genericize references** — remove private repo URLs, real agent file
      paths, and internal issue IDs. Target: zero references to the originating
      private library.
- [ ] **Hermetic fixture** — the fixture currently hashes files from the real
      private library; ship a small neutral `sample-library/` so the test
      leaks nothing and runs standalone.
- [ ] Choose a license; flesh out `CONTRIBUTING.md`.
- [ ] Tag `v0.1.0` once the publishable-when-green checklist passes.

See the extraction plan in the originating library for the full plan.
