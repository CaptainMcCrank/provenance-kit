# Provenance Manifest Block

**Purpose:** Defines the canonical `prompt_provenance:` YAML block to add to a project's `project.manifest.yaml`, plus supporting fields the module reads/writes. This is the field set the README and earlier drafts assumed existed — this prompt makes it real and authoritative.

**Integration:** Reference this file when initializing or adopting provenance:
> "Read and follow `prompts/Provenance_Manifest_Block.md` and append the `prompt_provenance:` block to project.manifest.yaml."

**Prerequisites:** A `project.manifest.yaml` (see [`templates/project.manifest.yaml`](../templates/project.manifest.yaml)).

**Related:** [`Provenance_Init.md`](Provenance_Init.md), [`Provenance_Attest.md`](Provenance_Attest.md), [`README.md`](README.md)

---

## The canonical block

Append this to `project.manifest.yaml`. [`Provenance_Init.md`](Provenance_Init.md) populates the runtime fields at session start; the rest are static configuration.

```yaml
# Prompt provenance — tamper-evident record of which prompts produced this build.
# Module: provenance-kit (portable). See that directory's README.md.
prompt_provenance:
  enabled: true                       # Master switch. false = module is inert (no sessions opened).
  module_path: "./provenance-kit"     # Where the vendored provenance-kit tool lives in THIS project
  library_repository: "<your prompt library remote, if any>"
  library_path: "<from PROMPT_LIBRARY_PATH in .env>"   # The prompt library being hashed
  library_commit_at_init: null        # Set by Provenance_Init at session start

  storage_root: ".build-provenance"   # Per-session dirs live under here: session_<uuid>/
  current_session: null               # e.g. ".build-provenance/session_<uuid>/" — set by Init

  hash_algorithm: "sha256"            # Used for prompt hashes, audit chain, attestation
  chain: "append-only"                # Audit log is a hash chain; never edited in place

  attestation:
    required: true                    # Build fails at attest time if signing can't complete
    signer_key_id: "<from GPG_SIGNING_KEY_ID in .env>"
    formula: "SHA256(library_commit || project_final_commit || session_id || audit_chain_head)"

  verify_on_build: true               # Run Provenance_Verify (standard level) before declaring success
  counter_capture: "hybrid"           # hybrid = harness wrapper + agent self-report, both recorded
  harness_autodetect: true            # Detect claude-code | opencode | unknown at Init

  archive_after_days: 30              # Sessions older than this move to .build-provenance/archive/
  keep_minimum_sessions: 1            # ...but always keep at least the most recent
```

## Field reference

| Field | Type | Who sets it | Meaning |
|---|---|---|---|
| `enabled` | bool | human | Master switch; `false` makes the module inert |
| `module_path` | path | human | Location of the vendored provenance-kit tool inside this project |
| `library_repository` | url | human | Source repo of the prompt library being hashed (neutral placeholder by default) |
| `library_path` | path | `.env` | Local checkout (from `PROMPT_LIBRARY_PATH`) used to hash prompt files |
| `library_commit_at_init` | sha | Init | Library commit captured at session start |
| `storage_root` | path | human | Root for per-session directories |
| `current_session` | path | Init | The active session directory |
| `hash_algorithm` | enum | human | Hash used throughout (sha256) |
| `chain` | enum | human | Audit log discipline (append-only) |
| `attestation.required` | bool | human | If true, unsigned builds fail |
| `attestation.signer_key_id` | str | `.env` | GPG key id used to sign |
| `attestation.formula` | str | fixed | The attestation hash definition |
| `verify_on_build` | bool | human | Gate build success on a passing verify |
| `counter_capture` | enum | human | `hybrid` / `self_report` / `harness` |
| `harness_autodetect` | bool | human | Detect the harness automatically |
| `archive_after_days` | int | human | Session archival threshold |
| `keep_minimum_sessions` | int | human | Floor on retained sessions |

## Relationship to legacy manifest fields

An earlier, flatter `prompt_provenance:` design pointed `current_session` at a single `.build-provenance/session_<uuid>.yaml` file. This block **supersedes** that: `current_session` now points at a *directory* (`session_<uuid>/`) holding `manifest.yaml`, `audit.yaml`, `attestation.{yaml,asc}`, and `summary.json`. The directory is a strict superset of the earlier single-file schema.

## Validation

After appending, confirm:

- `enabled: true` and `module_path` points at an existing directory in this project.
- `.env` provides `PROMPT_LIBRARY_PATH` (→ `library_path`) and `GPG_SIGNING_KEY_ID` (→ `attestation.signer_key_id`).
- `storage_root` is git-tracked (or intentionally ignored) per project policy.

If `attestation.required: true` but no `GPG_SIGNING_KEY_ID` is configured, surface this at init — the build will otherwise fail later at [`Provenance_Attest.md`](Provenance_Attest.md).
