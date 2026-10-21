# CT Draft Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a provenance-bound, deterministic, script-free CT draft pipeline with immutable SQLite persistence, native review UI, proposal/read-only MCP access, and locally approved create-new export with readback proof.

**Architecture:** Typed proposal data is resolved against authoritative persisted Recipe, Verification, Candidate, Evidence and Proof records before a validated immutable draft is stored. A pure Pascal exporter produces deterministic UTF-8 XML; a separate local governed export service alone may create a new file and records Effect, Receipt and Proof. The UI and MCP share repository projections, while MCP has no approval, export, activation or script authority.

**Tech Stack:** Free Pascal 3.2.2, Lazarus/LCL, FCL JSON/XML, SQLDB/SQLite, Win32 create-new file APIs, local governance services, JSON Schema Draft 2020-12 documents.

**Spec:** `docs/superpowers/specs/2026-09-21-ct-draft-generation-design.md`

## Global Constraints

- Only explicitly authorized offline single-player targets are eligible.
- Never train, fine-tune, merge adapters or modify model weights; CT learning remains provenance-bound RAG.
- Version 1 emits no Lua, AutoAssembler, hotkeys, trainer, process opener, enable/disable script, embedded binary or active record.
- LLM text is untrusted display input and never supplies addresses, hashes, XML, Approval, Lease or Effect authority.
- Maximums are 256 entries, pointer depth 32, description 512 UTF-8 bytes, offset text 32 characters and XML 4 MiB.
- Export is local-only, create-new, one-use, short-lived, readback-hashed and never retried automatically after an unknown result.
- MCP may propose/list/get/preview only; it cannot approve, choose a path, export, load or activate.
- The workspace is not a Git repository, so each task ends with a verification checkpoint instead of a commit; no existing user files are discarded.

## Review Focus

- A proposal mixing verified IDs from different compatibility hashes must fail with `ct_draft_compatibility_mismatch`; Task 2 pins this.
- A description containing invalid XML 1.0 controls or exceeding 512 UTF-8 bytes must fail without lossy rewriting; Task 3 pins this.
- A destination created between approval and execution must remain untouched and return `ct_draft_destination_exists`; Task 6 pins this.
- An output written but not conclusively read back must become `export_unknown` and must not be retried; Task 6 pins this.
- MCP input containing path, XML, Lua, AutoAssembler, approval or export fields must fail closed before dispatch; Task 8 pins this.

---

### Task 1: CT draft schemas, typed contracts and stable result codes

**Files:**
- Create: `schemas/ct-draft/entry.schema.json`
- Create: `schemas/ct-draft/proposal.schema.json`
- Create: `schemas/ct-draft/draft.schema.json`
- Create: `schemas/ct-draft/export-request.schema.json`
- Create: `schemas/ct-draft/export-result.schema.json`
- Modify: `schemas/manifest.json`
- Create: `src/domain/ct-draft/cea_ct_draft_types.pas`
- Create: `src/domain/ct-draft/cea_ct_draft_ports.pas`
- Modify: `src/contracts/cea_results.pas`
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`
- Create: `tests/contracts/positive/ct-draft.json`
- Create: `tests/contracts/negative/ct-draft-with-script.json`
- Create: `tests/pascal/test_ct_draft_contracts.pas`

**Interfaces:**
- Consumes: `TCEATargetBinding`, `TCEACandidateLocation`, `TCEAEvidenceReference`, `TCEAReverseRecipe`, `TCEAVerificationRun`, `TCEAResult`.
- Produces: `TCEACTDraft`, `TCEACTDraftEntry`, `TCEACTDraftProposal`, `TCEACTDraftExportRequest`, `TCEACTDraftExportResult`, `ICEACTDraftRepository`, `ICEACTDraftSourceResolver`, `ICEACTXmlExporter`, `ICEACTDraftFilePort`.

- [ ] **Step 1: Write failing contract tests and fixtures**

```pascal
Assert(Draft.IsValid, 'bounded immutable draft is valid');
Assert(CTDraftStateText(dsExportUnknown) = 'export_unknown', 'stable state');
Assert(CTDraftEntryKindText(dePointerChain) = 'pointer_chain', 'stable kind');
```

The negative JSON fixture contains an undeclared `lua_script` member and the positive fixture contains one inactive `module_offset` entry with source IDs and hashes. A static assertion in `check-schemas.ps1` verifies that `TCEACTDraftEntry` contains no Lua/AA/raw-XML member and that the proposal Schema rejects those names.

- [ ] **Step 2: Run RED checks**

Run:

```powershell
& tests/pascal/run-test-program.ps1 -Program tests/pascal/test_ct_draft_contracts.pas
& tools/schema-check/check-schemas.ps1
```

Expected: Pascal compilation fails because the CT draft units do not exist; Schema check fails because the five manifest entries do not exist.

- [ ] **Step 3: Add closed schemas and exact Pascal types**

```pascal
type
  TCEACTDraftState = (dsProposed, dsValidated, dsInvalidated,
    dsExportPlanned, dsExported, dsExportUnknown);
  TCEACTDraftEntryKind = (deGroup, deAbsoluteAddress, deModuleOffset,
    dePointerChain);
  TCEACTDraftValueType = (dvNone, dvByte, dvWord, dvDword, dvQword,
    dvSingle, dvDouble, dvByteArray);
  TCEACTDraftEntryArray = array of TCEACTDraftEntry;
  TCEACTDraft = record
    Id, ParentDraftId, SchemaVersion, StateText, GameName, GameVersion: string;
    TargetExecutableSha256, ModuleSetHash, CompatibilityHash: string;
    RecipeId, VerificationRunId, GeneratorVersion, ContentHash: string;
    EvidenceIdsJson, ProofIdsJson, FindingsJson, FailureModesJson: string;
    CreatedAt, UpdatedAt: string;
    Entries: TCEACTDraftEntryArray;
    function IsValid: Boolean;
  end;
```

Every schema uses `additionalProperties:false`; proposal schemas contain IDs and display suggestions only and structurally omit raw XML, address, offset, path, Lua, AA, approval, lease and effect fields.

- [ ] **Step 4: Add stable result codes and port signatures**

```pascal
ICEACTDraftRepository = interface
  function SaveDraft(const ADraft: TCEACTDraft): TCEAResult;
  function LoadDraft(const ADraftId: string; out ADraft: TCEACTDraft): TCEAResult;
  function ListDrafts(const ALimit: Cardinal; out ADrafts: TCEACTDraftArray): TCEAResult;
  function UpdateExportState(const ADraftId, AExpectedHash: string;
    const AState: TCEACTDraftState; const AExportJson: string): TCEAResult;
end;
ICEACTXmlExporter = interface
  function Render(const ADraft: TCEACTDraft; out ABytes: TBytes;
    out ASha256: string): TCEAResult;
end;
```

Add the thirteen spec failures as stable `TCEAResultCode` mappings without changing existing numeric meanings.

- [ ] **Step 5: Run GREEN and checkpoint**

Run the focused test, Schema check and compile smoke. Expected: all pass; Schema count increases by five and the unit manifest includes both new units.

### Task 2: Authoritative reverse-source persistence and resolver

**Files:**
- Modify: `src/domain/reverse/cea_reverse_ports.pas`
- Create: `src/infrastructure/cea_reverse_repository.pas`
- Create: `src/core/ct-draft/cea_ct_draft_source_resolver.pas`
- Modify: `src/core/reverse/cea_recipe_service.pas`
- Create: `tests/pascal/test_ct_draft_source_resolver.pas`
- Modify: `tests/pascal/fakes/cea_test_ports.pas`
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`

**Interfaces:**
- Consumes: existing reverse-domain records and SQLite connection configuration.
- Produces: `ICEAReverseArtifactStore.Save/LoadCandidate`, `Save/LoadEvidence`, `Save/LoadRecipe`, `Save/LoadVerificationRun`; `TCEACTDraftSourceResolver.Resolve(const AProposal; out ABundle)`.

- [ ] **Step 1: Write a failing resolver test**

```pascal
R := Resolver.Resolve(Proposal, Bundle);
Assert(R.Code = rcOk, 'all authoritative sources resolve');
Store.Verification.Outcome := voInconclusive;
Assert(Resolver.Resolve(Proposal, Bundle).MessageText =
  'ct_draft_source_unverified', 'inconclusive source rejected');
Store.Candidate.CompatibilityHash := OtherHash;
Assert(Resolver.Resolve(Proposal, Bundle).MessageText =
  'ct_draft_compatibility_mismatch', 'mixed hashes rejected');
```

Also cover missing IDs (`ct_draft_source_missing` with the exact JSON Pointer), empty Proof ID, stale candidate/evidence Epoch, non-portable Recipe and proposal-supplied unknown source IDs.

- [ ] **Step 2: Run RED**

Run the focused program. Expected: compile failure for missing reverse repository and resolver.

- [ ] **Step 3: Implement persisted reverse artifacts**

```sql
CREATE TABLE IF NOT EXISTS reverse_recipes(
  recipe_id TEXT PRIMARY KEY, compatibility_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reverse_candidates(
  candidate_id TEXT PRIMARY KEY, process_identity_id TEXT NOT NULL,
  epoch INTEGER NOT NULL, compatibility_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reverse_evidence(
  evidence_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL,
  payload_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS reverse_verification_runs(
  verification_id TEXT PRIMARY KEY, recipe_id TEXT NOT NULL,
  outcome TEXT NOT NULL, proof_id TEXT NOT NULL, payload_json TEXT NOT NULL);
```

Serialize and parse typed fields explicitly; use parameterized `TSQLQuery` statements and reject a second save whose same ID has different content.

- [ ] **Step 4: Implement fail-closed resolution**

```pascal
if Run.Outcome <> voPass then
  Exit(Fail('ct_draft_source_unverified', '/verification_run_id'));
if (Candidate.Target.ProcessIdentityId <> Run.Target.ProcessIdentityId) or
   (Candidate.Target.Epoch <> Run.Target.Epoch) then
  Exit(Fail('ct_draft_stale_runtime_evidence', '/candidate_id'));
if Candidate.CompatibilityHash <> Recipe.CompatibilityHash then
  Exit(Fail('ct_draft_compatibility_mismatch', '/candidate_id'));
```

Proof existence is checked through `IGovernanceStore.LoadProof`; neither proposal labels nor Provider output can replace persisted authoritative values.

- [ ] **Step 5: Run GREEN and checkpoint**

Run resolver, reverse orchestrator, state-store and compile-smoke tests. Expected: all pass with no in-memory-only publication regression.

### Task 3: Deterministic draft validation and immutable revisions

**Files:**
- Create: `src/core/ct-draft/cea_ct_draft_service.pas`
- Create: `src/core/ct-draft/cea_ct_draft_canonical.pas`
- Create: `tests/pascal/test_ct_draft_service.pas`
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`

**Interfaces:**
- Consumes: `ICEACTDraftSourceResolver`, `ICEACTDraftRepository`, `IContentHasher`, `IClock`.
- Produces: `TCEACTDraftService.Propose`, `Revalidate`, `Abandon`; canonical content JSON and deterministic content hash.

- [ ] **Step 1: Write failing validation tests**

```pascal
Assert(Service.Propose(Proposal, Draft).Code = rcOk, 'verified draft');
Assert(Draft.StateText = 'validated', 'valid proposal is reviewable');
Assert(Draft.Entries[0].AddressText = Bundle.Candidate.AddressText,
  'address comes from authoritative candidate');
Assert(Service.Propose(ScriptShapedProposal, Draft).MessageText =
  'ct_draft_entry_kind_unsupported', 'script-shaped proposal denied');
Assert(Service.Propose(InvalidControlDescription, Draft).MessageText =
  'ct_draft_xml_character_invalid', 'invalid XML control denied');
```

Test 257 entries, depth 33, 513 UTF-8 bytes, 33-character offset, byte-array without exact length, duplicates, integer overflow, Unicode, stable order and a revision whose parent hash remains unchanged.

Assert unsupported candidate kinds and value types return `ct_draft_entry_kind_unsupported` and `ct_draft_value_type_unsupported`; every budget case returns `ct_draft_budget_exceeded` with its field pointer. Assert absolute addresses carry the non-portable risk flag, groups have no locator/value, and an AOB reference survives only in evidence metadata and never becomes an exportable entry.

- [ ] **Step 2: Run RED**

Run the focused program. Expected: missing service/canonical units.

- [ ] **Step 3: Implement canonical validation**

```pascal
function ValidateEntry(const E: TCEACTDraftEntry;
  const AIndex: Integer): TCEAResult;
begin
  if Utf8ByteLength(E.Description) > 512 then
    Exit(FieldError('ct_draft_budget_exceeded', EntryPtr(AIndex, 'description')));
  if not IsXml10Text(E.Description) then
    Exit(FieldError('ct_draft_xml_character_invalid', EntryPtr(AIndex, 'description')));
  if Length(E.PointerOffsets) > 32 then
    Exit(FieldError('ct_draft_budget_exceeded', EntryPtr(AIndex, 'pointer_offsets')));
  Result := TCEAResult.Ok('{}');
end;
```

Canonical JSON uses fixed field order, lowercase normalized hashes/module basenames, numeric entry order and no timestamps or state. Hash it as `sha256:<lowercase hex>` and derive the draft ID from hash plus revision.

- [ ] **Step 4: Implement immutable revisions and findings**

`Propose` stores a new validated/invalidated revision. `Revalidate` resolves all source IDs again; changed/missing compatibility invalidates a new revision rather than mutating the old row. `Abandon` records an invalidated successor with finding `abandoned_by_user` and never deletes exported audit data.

- [ ] **Step 5: Run GREEN and checkpoint**

Run the focused test three times and assert identical content hashes and order, then compile smoke.

### Task 4: Pure deterministic CT XML exporter and parser round-trip

**Files:**
- Create: `src/infrastructure/cea_ct_xml_exporter.pas`
- Create: `tests/pascal/test_ct_xml_exporter.pas`
- Create: `tests/fixtures/ct/generated-script-free.expected.ct`
- Modify: `src/knowledge/ct/cea_ct_parser.pas` only if the valid generated subset exposes a parser defect
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`

**Interfaces:**
- Consumes: validated immutable `TCEACTDraft`, `IContentHasher`.
- Produces: `TCEACTXmlExporter.Render(const ADraft; out ABytes; out ASha256)` with no filesystem or Provider access.

- [ ] **Step 1: Write byte-exact and round-trip RED tests**

```pascal
Assert(Exporter.Render(Draft, Bytes1, Hash1).Code = rcOk, 'render');
Assert(Exporter.Render(Draft, Bytes2, Hash2).Code = rcOk, 'repeat render');
Assert(BytesEqual(Bytes1, Bytes2) and (Hash1 = Hash2), 'deterministic bytes');
Assert(Pos('<AssemblerScript>', Utf8(Bytes1)) = 0, 'no AA');
Assert(Pos('<LuaScript>', Utf8(Bytes1)) = 0, 'no Lua');
Assert(Parser.ParseBytes(Bytes1, Artifact).Code = rcOk, 'hardened parser round-trip');
```

Compare the exact bytes with the fixture and prove XML escaping of `& < > "`, Unicode preservation, sequential IDs and equivalent supported locator/value fields.

- [ ] **Step 2: Run RED**

Run exporter and existing parser tests. Expected: exporter unit missing.

- [ ] **Step 3: Implement an allowlisted writer**

```pascal
Append('<?xml version="1.0" encoding="utf-8"?>'#10);
Append('<CheatTable CheatEngineTableVersion="45">'#10);
Append('  <CheatEntries>'#10);
WriteEntryTree(ADraft.Entries, 4, NextId);
Append('  </CheatEntries>'#10'</CheatTable>'#10);
```

Write only `CheatEntry`, integer `ID`, escaped `Description`, `VariableType`, `Address` and `Offsets/Offset`. Reject any non-validated state, duplicate semantic locator, overflow or output beyond 4 MiB before returning bytes.

- [ ] **Step 4: Prove forbidden constructs are impossible**

Scan output for `<!DOCTYPE`, `<!ENTITY`, `<?` after the XML declaration, `LuaScript`, `AssemblerScript`, `Hotkeys`, `Enable`, `Disable` and embedded binary tags. The test fails if any appear.

- [ ] **Step 5: Run GREEN and checkpoint**

Run exporter, CT parser, CT RAG and compile-smoke tests. Expected: byte-exact fixture and semantic round-trip pass without executing imported content.

### Task 5: SQLite draft repository and migration safety

**Files:**
- Create: `src/infrastructure/cea_ct_draft_repository.pas`
- Create: `tests/pascal/test_ct_draft_repository.pas`
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`

**Interfaces:**
- Consumes: `ICEACTDraftRepository`, typed draft records, explicit database path.
- Produces: SQLite-backed immutable save/load/list/update operations and restart persistence.

- [ ] **Step 1: Write repository RED tests**

```pascal
Assert(Repo.SaveDraft(Draft).Code = rcOk, 'first immutable save');
Assert(Repo.SaveDraft(Draft).Code = rcOk, 'identical save idempotent');
Changed := Draft; Changed.GameName := 'different';
Assert(Repo.SaveDraft(Changed).MessageText = 'ct_draft_revision_stale',
  'same id cannot mutate');
Assert(Reopened.LoadDraft(Draft.Id, Loaded).Code = rcOk, 'restart persistence');
```

Cover ordered entry reconstruction, source joins, findings, 1–100 list bounds, exported revision immutability and old database migration.

- [ ] **Step 2: Run RED**

Run the focused program. Expected: repository unit missing.

- [ ] **Step 3: Create normalized tables in one transaction**

```sql
CREATE TABLE IF NOT EXISTS ct_drafts(
  draft_id TEXT PRIMARY KEY, parent_draft_id TEXT NOT NULL,
  content_hash TEXT NOT NULL, state TEXT NOT NULL,
  game_name TEXT NOT NULL, game_version TEXT NOT NULL,
  compatibility_hash TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS ct_draft_entries(
  draft_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
  semantic_key TEXT NOT NULL, payload_json TEXT NOT NULL,
  PRIMARY KEY(draft_id, ordinal), UNIQUE(draft_id, semantic_key));
CREATE TABLE IF NOT EXISTS ct_draft_sources(
  draft_id TEXT NOT NULL, source_kind TEXT NOT NULL, source_id TEXT NOT NULL,
  source_hash TEXT NOT NULL, PRIMARY KEY(draft_id, source_kind, source_id));
CREATE TABLE IF NOT EXISTS ct_draft_exports(
  effect_id TEXT PRIMARY KEY, draft_id TEXT NOT NULL,
  state TEXT NOT NULL, destination_hash TEXT NOT NULL, payload_json TEXT NOT NULL);
```

- [ ] **Step 4: Implement atomic writes and projections**

Use parameterized SQL, one transaction per draft revision, rollback on any entry/source failure, deterministic `ORDER BY ordinal`, and bounded list queries. Do not store raw imported CT, memory bytes, Provider secrets, bearer values or destination paths in draft rows.

- [ ] **Step 5: Run GREEN and checkpoint**

Run repository, state-store and compile-smoke tests twice against a fresh and migrated temporary DB.

### Task 6: Governed local create-new export and unknown reconciliation

**Files:**
- Create: `src/core/ct-draft/cea_ct_draft_export_service.pas`
- Create: `src/platform/windows/cea_win32_ct_draft_file_port.pas`
- Create: `tests/pascal/test_ct_draft_export.pas`
- Create: `tests/pascal/fakes/cea_ct_draft_file_fake.pas`
- Modify: `src/infrastructure/cea_sqlite_store.pas`
- Modify: `src/contracts/cea_types.pas`
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`

**Interfaces:**
- Consumes: validated draft/repository, XML exporter, local approval port, lease/effect/governance store, `ICEACTDraftFilePort`.
- Produces: `PlanExport`, `ApproveAndExecuteLocal`, `ReconcileUnknown`; capability `ct_draft_export` and Receipt/Proof records.

- [ ] **Step 1: Write export RED tests with fault injection**

```pascal
Assert(Service.PlanExport(Draft.Id, Path, Request, Effect).Code = rcOk,
  'preview-bound effect planned');
Assert(Service.Execute(Effect.Id, Approval.Id, ResultData).Code = rcOk,
  'approved create-new export');
Assert(FilePort.CreateCount = 1, 'one write only');
Assert(ResultData.ReadbackSha256 = Request.ExpectedSha256, 'readback bound');
FilePort.CreateDestinationBeforeOpen := True;
Assert(Service.Execute(Effect2.Id, Approval2.Id, ResultData).MessageText =
  'ct_draft_destination_exists', 'TOCTOU existing path refused');
```

Inject short write, close uncertainty, reopen failure and readback mismatch. Assert all uncertain cases become `export_unknown`, remain in reconciliation, never overwrite and never retry.

Execute without a matching local approval and assert `ct_draft_export_approval_required`. Inject a conclusive different readback hash and assert `ct_draft_export_readback_mismatch`; inject an indeterminate reopen/close result and assert `ct_draft_export_unknown`. Change the stored draft revision after planning and assert `ct_draft_revision_stale` before the file port is called.

- [ ] **Step 2: Run RED**

Run the focused program. Expected: export service and file port missing.

- [ ] **Step 3: Implement bound planning and local approval**

```pascal
Request.DraftId := Draft.Id;
Request.RevisionHash := Draft.ContentHash;
Request.DestinationPath := CanonicalAbsolutePath;
Request.ExpectedAbsent := True;
Request.MaxOutputBytes := 4 * 1024 * 1024;
Request.ExpectedSha256 := PreviewHash;
```

The Effect request hash covers every field. Approval display includes path, entry count, compatibility hashes, preview hash, script capabilities `none` and overwrite `forbidden`. Closing/cancelling the dialog rejects the planned Effect.

- [ ] **Step 4: Implement Windows create-new/readback**

Use `CreateFileW(..., CREATE_NEW, ...)`, bounded complete writes, `FlushFileBuffers`, close, reopen read-only, bounded hash and exact hash comparison. Never call `CREATE_ALWAYS`, `ReplaceFileW` or process-memory APIs. Delete only a newly created zero/partial file when failure is conclusively owned and safe; otherwise preserve it and return unknown for manual reconciliation.

- [ ] **Step 5: Implement restart reconciliation**

Extend startup reconciliation so an `executing` `ct_draft_export` Effect becomes `unknown`. `ReconcileUnknown` performs read-only existence/length/hash observation and records a new Receipt/Proof assessment; it never writes, retries or marks applied without exact expected hash.

- [ ] **Step 6: Run GREEN and checkpoint**

Run export, local governance services governance, local approval, state-store, release static safety and compile-smoke tests. Expected: create-new success and every injected failure behave as specified.

### Task 7: Runtime integration, background proposal and native workbench

**Files:**
- Modify: `src/app/cea_application_runtime.pas`
- Create: `src/ui/cea_ct_draft_ui_model.pas`
- Modify: `app/lazarus/cea_main_form.pas`
- Modify: `app/lazarus/cheat_engine_agent.lpr`
- Create: `tests/pascal/test_ct_draft_ui_model.pas`
- Modify: `tests/pascal/test_standalone_app_runtime.pas`
- Modify: `build/unit-manifest.txt`
- Modify: `tests/pascal/compile_smoke.pas`

**Interfaces:**
- Consumes: draft/source repositories, draft/export services, existing owner-thread/runtime queue and local approval UI.
- Produces: runtime methods `ProposeCTDraft`, `ListCTDrafts`, `GetCTDraft`, `PreviewCTDraft`, `RevalidateCTDraft`, `PlanCTDraftExport`, `ExecuteApprovedCTDraftExport`, `AbandonCTDraft`; a `CT 草案` native tab.

- [ ] **Step 1: Write UI-model and runtime RED tests**

```pascal
Assert(Model.CanExport(ValidatedDraft), 'validated local draft can request export');
Assert(not Model.CanExport(InvalidatedDraft), 'invalid draft cannot export');
Assert(Model.ConfirmText.IndexOf('脚本能力：无') >= 0, 'absence is explicit');
Assert(Runtime.ProposeCTDraft(ProposalJson).Code = rcOk, 'runtime proposal');
Assert(Runtime.PreviewCTDraft(DraftId).DataJson = ExpectedPreviewJson,
  'UI and runtime share projection');
```

Cover cancel/close rejection, stale revision, no selected draft, existing destination, background opt-in false for real games, revocation of queued work and self-test default behavior.

- [ ] **Step 2: Run RED**

Run both focused programs. Expected: UI model/runtime APIs missing.

- [ ] **Step 3: Wire services into runtime ownership**

Create repositories/services during `Start`, reconcile unknown exports before accepting new export work, and destroy worker/services in reverse order during `Stop`. Background proposal consumes only a copied verified source bundle and posts repository results to the owner thread; it does not read memory, call a Provider, open a dialog or write a file.

- [ ] **Step 4: Build the `CT 草案` page**

Add list, source panel, entry tree, findings/failure modes, read-only XML preview and buttons `重新验证`, `创建新文件…`, `放弃草案`. The confirmation dialog renders destination, entry count, compatibility hashes, output SHA-256, `脚本能力：无`, `覆盖：禁止`; only its explicit confirm calls local approval and execution.

- [ ] **Step 5: Keep optional LLM description work proposal-only**

An explicit `优化描述` action may call the existing Provider/RAG path under its budgets and returns a new typed proposal revision. It never runs in background, and its output cannot set locator, XML, hashes, state or authority fields. If no Provider is configured, deterministic drafting remains fully usable.

- [ ] **Step 6: Run GREEN and checkpoint**

Run UI-model, standalone runtime, LLM Provider fakes, compile smoke and Lazarus build. Expected: tests pass and `dist/CheatEngineAgent.exe` is rebuilt without touching any game process.

### Task 8: Closed-schema MCP proposal and read-only tools

**Files:**
- Modify: `src/mcp/cea_mcp_registry.pas`
- Modify: `src/app/cea_application_runtime.pas`
- Modify: `tests/pascal/test_mcp_protocol.pas`
- Modify: `tests/pascal/test_standalone_app_runtime.pas`
- Modify: `tests/integration/test-live-mcp-app.ps1`

**Interfaces:**
- Consumes: runtime proposal/list/get/preview methods and pre-dispatch inline Schema validator.
- Produces: `cea.propose_ct_draft`, `cea.list_ct_drafts`, `cea.get_ct_draft`, `cea.get_ct_draft_preview`.

- [ ] **Step 1: Write MCP RED tests**

```pascal
Assert(ToolExists('cea.propose_ct_draft'), 'proposal tool registered');
Assert(ToolExists('cea.get_ct_draft_preview'), 'preview tool registered');
Assert(not ToolExists('cea.export_ct_draft'), 'no MCP export');
Assert(not ToolExists('cea.approve_ct_draft'), 'no MCP approval');
Assert(Call('cea.propose_ct_draft', '{"xml":"<CheatTable/>"}').MessageText =
  'tool_arguments_schema_invalid', 'raw XML rejected before dispatch');
```

Repeat forbidden input cases for `path`, `lua`, `autoassembler`, `approval_id`, `lease_id`, `effect_id`, unknown nested entry fields and over-budget arrays/strings.

- [ ] **Step 2: Run RED**

Run MCP protocol/runtime tests. Expected: four tools missing and live tool count unchanged.

- [ ] **Step 3: Register four closed schemas**

Proposal requires `recipe_id`, `verification_run_id` and 1–256 display-entry suggestions containing only `candidate_id`, `description`, `kind`, `value_type`, `order`, `evidence_ids`, `proof_ids`. List accepts optional `limit` 1–100; get/preview require bounded `draft_id`. All schemas set `additionalProperties:false` recursively.

- [ ] **Step 4: Route without authority expansion**

Dispatch proposal/query methods only. There is no MCP code path to select a destination, request local approval, plan/execute export, load a table, activate a record, write memory or invoke Lua/AA.

- [ ] **Step 5: Run GREEN and checkpoint**

Run protocol/runtime tests, build the app and execute the live loopback initialize/tools-list/health check. Expected: advertised tool count rises from 27 to 31 and the four names appear; direct health still passes.

### Task 9: Full acceptance, documentation and honest gate status

**Files:**
- Create: `tests/integration/test-ct-draft-roundtrip.ps1`
- Create: `docs/delivery/ct-draft-manual-acceptance-template.md`
- Modify: `docs/delivery/verification-report.md`
- Modify: `docs/delivery/2026-09-20-implementation-progress.md`
- Modify: `docs/superpowers/plans/2026-09-13-game-companion-roadmap.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: all CT draft components and existing project verification scripts.
- Produces: reproducible automated evidence, a manual UI/offline-game checklist and accurate experimental/commercial status.

- [ ] **Step 1: Add an end-to-end self-test fixture**

The integration script creates authoritative self-test Recipe/Candidate/Evidence/Verification/Proof rows, proposes the draft, previews twice, locally approves a temporary create-new export, verifies SHA-256, imports it through the hardened CT parser and asserts equivalent module-offset/pointer fields plus absence of script nodes.

- [ ] **Step 2: Run all automated acceptance commands**

```powershell
Get-ChildItem tests/pascal/test_*.pas | ForEach-Object {
  & tests/pascal/run-test-program.ps1 -Program $_.FullName
  if ($LASTEXITCODE -ne 0) { throw "failed: $($_.Name)" }
}
& tests/integration/test-win32-child-process.ps1
& tests/integration/test-ct-draft-roundtrip.ps1
& tools/schema-check/check-schemas.ps1
& tests/acceptance/verify-scaffold.ps1
& tests/pascal/compile-smoke.ps1
& build/build-standalone-app.ps1
& tests/acceptance/test-release-manifest.ps1
```

Expected: every command exits 0. Then run `dist/CheatEngineAgent.exe --self-test`, actual internal-manifest verification and live MCP handshake; record exact counts, binary length and hashes.

- [ ] **Step 3: Add static boundary checks**

Extend Schema/scaffold acceptance to fail if an MCP export/approve/activate tool appears, if CT draft units contain `WriteProcessMemory`, if generated output paths use overwrite APIs, or if Lua/AA XML tag literals occur outside parser-deny tests and documented allowlist checks.

- [ ] **Step 4: Create the manual acceptance template**

Record operator, timestamp, application hash, draft/content/preview hashes, source IDs, target game/version authorization, destination, entry count, UI source/findings/preview review, explicit confirmation, file hash, manual CE open result and proof that no entry auto-activated. A cancelled dialog and existing-path refusal are mandatory cases.

- [ ] **Step 5: Update status without overclaiming**

Mark automated conditions 1–5 as complete only from test evidence. Leave conditions 6–7 open until native UI click-through and a newly authorized offline single-player sample are recorded. Until then label the feature `experimental CT draft preview/export`, not commercial CT generation acceptance.

- [ ] **Step 6: Final self-review checkpoint**

Search the implementation and docs for raw model XML, script output, overwrite behavior, MCP export authority, automatic activation, training/fine-tuning and stale 27-tool counts. Resolve contradictions, rerun the affected focused tests, and preserve all unrelated user changes.
