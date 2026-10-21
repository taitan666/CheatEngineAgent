# CT Draft Generation Design

Date: 2026-09-21  
Status: approved by user on 2026-09-21  
Product scope: Windows-first offline single-player game assistant

## 1. Purpose

Add a provenance-bound pipeline that can turn verified reverse-engineering evidence into a reviewable Cheat Engine table draft. The application may produce the draft asynchronously after a Recipe reaches a verified state, but the draft has no execution authority. A player must review it locally and explicitly export it to a new `.CT` file.

Success means the application can explain where every generated record came from, refuse incompatible or incomplete evidence, generate deterministic XML without model-authored markup, and prove exactly what bytes were written to a newly created file. Success does not mean automatically activating a table or modifying a game.

## 2. Permanent boundaries

- Only user-authorized offline single-player targets are eligible.
- CT learning remains parsing, indexing, retrieval and RAG. No training, fine-tuning, adapter merging or model-weight mutation is added.
- LLM output is untrusted proposal data. It cannot provide raw CT XML, Lua, AutoAssembler, approval, Lease or Effect authority.
- Version 1 generates no Lua, AutoAssembler, hotkey, trainer, process-opening or activation script.
- Generated records are inactive data records. The application never loads the result into Cheat Engine and never activates it.
- MCP may propose and query drafts. It cannot approve export, select an output path, export a file or execute a generated record.
- Export is a governed local `ct_draft_export` Effect. It uses create-new semantics, never overwrites, verifies the written SHA-256 and records Receipt and Proof.
- Downloaded/imported CT artifacts remain untrusted evidence. Their scripts are never copied into a generated version-1 draft.

## 3. Alternatives considered

### 3.1 Deterministic evidence compiler — selected

The model or user proposes typed fields. Pascal validates those fields against verified Recipe, Candidate and Evidence objects, then a deterministic exporter emits XML. This gives reproducible output, stable errors and a narrow attack surface.

### 3.2 Model-generated CT XML — rejected

Free-form XML can smuggle scripts, malformed nesting, active records or unsupported CE behavior. Post-filtering arbitrary output cannot establish the same guarantees as constructing an allowlisted document.

### 3.3 Clone and rewrite a retrieved CT — rejected as the primary path

Cloning preserves unknown semantics and creates compatibility and licensing risks. Retrieved tables may supply cited evidence and field suggestions, but their XML or scripts are not copied into the generated draft.

## 4. Domain model

### 4.1 `CTDraft`

A draft contains:

- stable draft ID and schema version;
- state: `proposed`, `validated`, `invalidated`, `export_planned`, `exported` or `export_unknown`;
- game name and optional game version;
- target executable SHA-256, module-set hash and Recipe compatibility hash;
- source Recipe ID, VerificationRun ID, Evidence IDs and Proof IDs;
- generator version and deterministic content hash;
- bounded ordered entries;
- validation findings and known failure modes;
- creation/update timestamps;
- no Approval, Lease, Effect authority or output path.

Draft immutability is content-based. Editing a field creates a new draft revision with a new content hash; an exported revision is never mutated.

### 4.2 `CTDraftEntry`

Version 1 supports only these entry kinds:

- `absolute_address`: explicit 32/64-bit address, marked non-portable;
- `module_offset`: normalized module basename plus hexadecimal offset;
- `pointer_chain`: module/absolute base plus an ordered bounded offset list;
- `group`: description-only hierarchy node.

Every data entry includes description, CE variable type, address width, source Candidate ID, source Evidence IDs, verification outcome, compatibility hash and risk flags. Supported value types are the existing bounded numeric types plus byte arrays whose exact length is known. Descriptions are plain text and are XML-escaped by the exporter.

`aob_reference` may be stored as non-exported evidence metadata so the UI can explain a locator. It is not emitted as an AutoAssembler script in version 1. Lua and AutoAssembler fields are structurally absent from the version-1 draft schema.

### 4.3 Proposal input

`CTDraftProposal` contains only IDs and typed display suggestions:

- Recipe, VerificationRun, Candidate, Evidence and Proof references;
- proposed game/version labels;
- proposed entry descriptions and ordering;
- requested supported entry kind and value type.

Addresses, offsets, compatibility hashes and verification outcomes are resolved from authoritative stored objects, not trusted from the model. Unknown references, stale Epoch evidence, inconclusive verification or incompatible hashes reject the proposal.

## 5. Architecture

```text
Verified Recipe / Candidate / Evidence / Proof
                  |
                  v
          CT Draft Proposal Port
                  |
                  v
       CT Draft Validation Service
       - resolve authoritative IDs
       - compatibility/Epoch checks
       - allowlisted entry conversion
       - risk and failure annotations
                  |
                  v
        Immutable Draft Repository
                  |
          +-------+--------+
          |                |
          v                v
   Native review UI    MCP read/propose
          |
          v
   Local export request
          |
          v
   locally approved ct_draft_export Effect
          |
          v
 Deterministic CT XML exporter
 - create new only
 - bounded UTF-8 XML
 - readback SHA-256
 - Receipt + Proof
```

Dependencies remain Host/UI/Transport → CT Draft Core → local governance ports. The core does not reference LCL controls, MCP JSON objects, Win32 dialogs or a concrete Provider.

## 6. Background proposal behavior

The application may enqueue a draft proposal worker only when a VerificationRun has outcome `pass` and its Recipe is portable. The worker performs database reads and deterministic draft construction; it does not read process memory, call an LLM automatically, open a save dialog or write a file.

Background proposal is locally configurable and defaults to enabled only for the project's verified self-test workflow. For a real game, the UI asks once whether verified Recipes may create review drafts in the background. Revocation stops queued work. Failure produces a bounded finding and never retries an unknown result automatically.

An LLM may be invoked from the workbench to improve plain-language descriptions, but only after explicit user action and within the existing Provider/RAG budgets. The deterministic draft remains valid without an LLM.

## 7. Deterministic CT output

The exporter constructs a new XML document using an allowlist:

- root `CheatTable` with a fixed supported table version;
- one `CheatEntries` collection;
- nested `CheatEntry` records with generated integer IDs;
- `Description`, `VariableType`, `Address` and bounded `Offsets` only;
- no `LuaScript`, `AssemblerScript`, `Hotkeys`, `Enable`, `Disable`, process opener or embedded binary data;
- UTF-8 encoding, no DTD, ENTITY, external reference or processing instruction.

Entry order and generated IDs are deterministic for the same draft content. Output is capped at 256 entries, pointer depth 32, description 512 UTF-8 bytes, offset text 32 characters, and total XML 4 MiB. Unsupported value types, invalid XML characters, duplicate semantic records and arithmetic overflow reject validation before an Effect is planned.

## 8. Persistence and governance

SQLite stores draft headers, entries, source-reference joins, validation findings and export records. Source references are immutable and retain content hashes. Raw imported CT text, process memory dumps, Provider secrets and bearer tokens are not stored in draft rows.

The export request binds:

- draft ID, revision and content hash;
- exact player-selected destination path;
- expected non-existence of the destination;
- maximum output length;
- deterministic XML SHA-256 expected from preview;
- one-use Lease and short expiry.

Execution rechecks the draft revision, destination identity and absence immediately before create-new. After writing, it closes and reopens the file, hashes it and compares the readback hash. A mismatch or uncertain filesystem outcome becomes `export_unknown`; it is never reported as success and is not automatically retried.

## 9. Native UI

Add a `CT 草案` workbench page containing:

- draft list with game/version, state, compatibility and creation time;
- source panel for Recipe, Verification, Evidence and Proof references;
- entry tree showing kind, description, value type, locator and risk flags;
- validation panel with errors, warnings and known failure modes;
- deterministic XML preview rendered as read-only text;
- `重新验证`, `创建新文件…` and `放弃草案` actions.

The export confirmation shows destination, entry count, compatibility hashes, output hash, absent script capabilities and overwrite prohibition. Closing the dialog rejects the pending Effect. The UI reads the same repository projection used by MCP and does not maintain an authoritative duplicate.

## 10. MCP surface

Add closed-schema tools:

- `cea.propose_ct_draft`: accepts authoritative source IDs and bounded display suggestions; returns a proposal/draft ID but performs no file write;
- `cea.list_ct_drafts`: returns bounded metadata only;
- `cea.get_ct_draft`: returns one draft, validation findings, entry projection and provenance;
- `cea.get_ct_draft_preview`: returns bounded deterministic XML preview and hash.

There is deliberately no MCP export, approve, activate, load, Lua or AutoAssembler tool. All tools reject undeclared fields before dispatch and return stable validation codes.

## 11. Stable failures

- `ct_draft_source_missing`
- `ct_draft_source_unverified`
- `ct_draft_stale_runtime_evidence`
- `ct_draft_compatibility_mismatch`
- `ct_draft_entry_kind_unsupported`
- `ct_draft_value_type_unsupported`
- `ct_draft_budget_exceeded`
- `ct_draft_xml_character_invalid`
- `ct_draft_revision_stale`
- `ct_draft_destination_exists`
- `ct_draft_export_approval_required`
- `ct_draft_export_readback_mismatch`
- `ct_draft_export_unknown`

Validation failures preserve a JSON Pointer to the rejected field. User cancellation is distinct from failure and leaves no output file.

## 12. Schemas and interfaces

New schemas:

- `schemas/ct-draft/draft.schema.json`
- `schemas/ct-draft/proposal.schema.json`
- `schemas/ct-draft/entry.schema.json`
- `schemas/ct-draft/export-request.schema.json`
- `schemas/ct-draft/export-result.schema.json`

Core Pascal units:

- `src/domain/ct-draft/cea_ct_draft_types.pas`
- `src/domain/ct-draft/cea_ct_draft_ports.pas`
- `src/core/ct-draft/cea_ct_draft_service.pas`
- `src/core/ct-draft/cea_ct_draft_export_service.pas`
- `src/infrastructure/cea_ct_draft_repository.pas`
- `src/infrastructure/cea_ct_xml_exporter.pas`

The ports accept typed records, not raw MCP or Provider JSON. The XML exporter accepts only a validated immutable draft and returns bytes plus SHA-256; it has no filesystem access. A separate governed file port performs create-new and readback.

## 13. Verification strategy

Automated tests must cover:

- verified module-offset and pointer-chain drafts;
- rejection of missing, inconclusive, stale-Epoch and hash-mismatched evidence;
- rejection of any Lua/AA/script-shaped field;
- deterministic byte-identical XML and hash across repeated runs;
- XML escaping, invalid control characters and Unicode descriptions;
- entry, depth, string and 4 MiB budgets;
- duplicate record normalization and stable ordering;
- create-new success, existing-path refusal, stale revision and readback mismatch;
- crash-window reconciliation to `export_unknown` without overwrite or retry;
- MCP proposal/read access and absence of export/approval tools;
- native UI projection and local export-confirmation model;
- import of the generated fixture through the existing hardened CT parser without executing anything;
- full Pascal, Schema, scaffold, build, release and MCP regression suites.

Manual acceptance uses only the self-test target until a player supplies a newly authorized offline game and accepts the exact export preview. Generated files are opened manually by the player only after hash verification.

## 14. Acceptance gate

The subsystem is complete only when:

1. A verified self-test Recipe produces a deterministic, inactive `.CT` containing supported entries and provenance comments.
2. The generated file round-trips through the existing CT parser with equivalent supported fields.
3. Raw XML, Lua, AutoAssembler, active records, overwrite and MCP export attempts are rejected.
4. Local create-new export records Approval, Effect, Receipt, Proof and readback SHA-256.
5. A crash/uncertain export is reconciled as unknown and is never retried automatically.
6. Native UI review and export confirmation are manually exercised.
7. A newly authorized offline single-player sample completes proposal, review and create-new export without automatic activation.

Until all seven conditions have evidence, the application may advertise CT draft preview as experimental but must not claim commercial CT generation acceptance.
