# Cheat Engine Agent Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Create the complete architecture documentation, versioned JSON Schemas, policy/configuration files, Pascal contracts and inert adapter skeleton for the approved Cheat Engine Agent design.

**Architecture:** The scaffold is a single-process, modular Free Pascal design with AgentOS State, Governance and Execution kernels behind contracts. Cheat Engine runtime access, CT knowledge/RAG and OpenAI-compatible model access are adapters; all effectful calls remain inert in this delivery and expose explicit `not_implemented` results.

**Tech Stack:** Lazarus/Free Pascal, JSON Schema 2020-12, YAML configuration, SQLite contract, PowerShell verification scripts, Cheat Engine 7.5 source interfaces.

**Spec:** `docs/superpowers/specs/2026-09-12-cheat-engine-agent-design.md`

## Global Constraints

- Preserve the user-requested root directory spelling `cheat-engine-agnet`; use `CheatEngineAgent` inside code and documentation.
- The product is restricted to offline single-player processes the user is authorized to debug.
- Multiplayer targeting, anti-cheat bypass, concealment and kernel-driver access are denied features.
- Model fine-tuning, online training, weight modification, weight writeback and autonomous model updates are permanently prohibited.
- CT learning means provenance-bound parsing, indexing and retrieval only.
- Runtime profile is `lite`; enabled conditional features are `external_writes`, `durable_work_ledger`, `execution_hold`, `ct_rag` and `real_process_access`.
- This delivery must not modify the existing `Cheat Engine/` source tree or claim that real process operations work.
- The workspace is not a Git repository. Do not initialize Git without a separate user request; verification checkpoints replace commit steps.

---

### Task 1: Project Bootstrap and Documentation Surface

**Files:**
- Create: `README.md`
- Create: `LICENSE-NOTICE.md`
- Create: `bootstrap/project-bootstrap.yaml`
- Create: `bootstrap/application-descriptor.yaml`
- Create: `bootstrap/feature-set-lite.yaml`
- Create: `docs/architecture/system-overview.md`
- Create: `docs/architecture/kernel-boundaries.md`
- Create: `docs/architecture/ce-runtime-integration.md`
- Create: `docs/architecture/ct-rag-pipeline.md`
- Create: `docs/architecture/security-and-governance.md`
- Create: `docs/architecture/state-machines.md`
- Create: `docs/architecture/failure-recovery.md`
- Create: `docs/source-analysis/game-cheats-manager-search.md`
- Create: `docs/decisions/0001-single-process-modular.md`
- Create: `docs/decisions/0002-rag-never-training.md`
- Create: `docs/decisions/0003-single-player-only.md`

**Interfaces:**
- Consumes: Approved design spec and AgentOS 1.2-draft requirements.
- Produces: Human-readable project boundaries, feature declarations, acceptance requirements and source analysis used by every later task.

- [x] **Step 1: Write bootstrap contracts**

Create YAML with stable IDs `cea.project.v1`, `cea.application.v1` and `cea.features.lite.v1`. `project-bootstrap.yaml` must name the user as operator, enumerate goals/non-goals, declare high risk for memory writes, and list the unresolved library choices as implementation-time validation items. `feature-set-lite.yaml` must explicitly enable the five approved features and explicitly deny every feature listed in Global Constraints.

- [x] **Step 2: Write architecture documents**

Each document must define purpose, owned objects, dependencies, public interfaces, success path, failure path and non-goals. `state-machines.md` must include Task and Effect transition tables. `failure-recovery.md` must define PID reuse, Epoch invalidation, AOB ambiguity, write/readback failure, model timeout and CT index publication failure.

- [x] **Step 3: Document GCM source findings**

Record that GCM reads local `cheat_table.json`, expands bilingual terms, and matches `game_name` with exact/substring/acronym/pinyin/fuzzy rules before returning metadata and download URLs. Link the official repository and exact source files; distinguish verified source behavior from proposed CheatEngineAgent extensions.

- [x] **Step 4: Verify document coverage**

Run:

```powershell
rg -n "single-player|单机|no-model-training|模型训练|Effect|unknown|GCM|RAG|ProcessIdentity" .\README.md .\bootstrap .\docs
```

Expected: every required topic has at least one authoritative project document and no document says the scaffold already accesses a process.

### Task 2: AgentOS Core JSON Schemas

**Files:**
- Create: `schemas/common/definitions.schema.json`
- Create: `schemas/agentos/envelope.schema.json`
- Create: `schemas/agentos/task-contract.schema.json`
- Create: `schemas/agentos/task.schema.json`
- Create: `schemas/agentos/feature-set.schema.json`
- Create: `schemas/agentos/resolved-execution-manifest.schema.json`
- Create: `schemas/agentos/lease.schema.json`
- Create: `schemas/agentos/approval.schema.json`
- Create: `schemas/agentos/effect.schema.json`
- Create: `schemas/agentos/receipt.schema.json`
- Create: `schemas/agentos/proof.schema.json`
- Create: `schemas/agentos/commit-request.schema.json`
- Create: `schemas/agentos/work-ledger.schema.json`
- Create: `schemas/agentos/verification-ledger.schema.json`
- Create: `schemas/agentos/remaining-boundary.schema.json`
- Create: `schemas/manifest.json`

**Interfaces:**
- Consumes: Stable IDs and enabled features from Task 1.
- Produces: JSON Schema 2020-12 contracts referenced by Pascal DTOs and test fixtures.

- [x] **Step 1: Define shared primitives**

`definitions.schema.json` must define UUID-like IDs, `schema_version`, ISO-8601 timestamps, `sha256:` digests, tenant/actor/task references, version references and non-negative budgets. Set `additionalProperties: false` for closed core objects.

- [x] **Step 2: Define task and feature contracts**

Encode Task execution states `created|queued|claimed|running|waiting|verifying|recovering|canceling|finished`, outcomes, wait reasons and FeatureSet enabled/denied arrays. Use `if/then` rules so `finished` requires an outcome and non-finished states require `outcome: null`.

- [x] **Step 3: Define governance and effect contracts**

Encode Lease scope/Epoch/expiry, approval bindings, Effect states `planned|executing|applied|rejected|unknown`, Receipt result and Proof result `pass|fail|inconclusive`. Effect requires target, request hash, idempotency key and process identity reference.

- [x] **Step 4: Define delivery integrity contracts**

Encode CommitRequest, WorkLedger, VerificationLedger and RemainingBoundary. `schemas/manifest.json` must enumerate every schema file with `$id`, relative path and SHA field format without embedding fabricated hashes.

- [x] **Step 5: Verify JSON syntax and references**

Run:

```powershell
Get-ChildItem .\schemas -Recurse -Filter *.json | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json | Out-Null }
rg -n '"\$schema": "https://json-schema.org/draft/2020-12/schema"' .\schemas
```

Expected: all JSON parses; each schema file declares draft 2020-12.

### Task 3: CE Domain, CT Knowledge and LLM Schemas

**Files:**
- Create: `schemas/ce-domain/process.schema.json`
- Create: `schemas/ce-domain/memory.schema.json`
- Create: `schemas/ce-domain/scan.schema.json`
- Create: `schemas/ce-domain/debug.schema.json`
- Create: `schemas/ce-domain/script-execution.schema.json`
- Create: `schemas/ct-knowledge/catalog-source.schema.json`
- Create: `schemas/ct-knowledge/cheat-table.schema.json`
- Create: `schemas/ct-knowledge/search.schema.json`
- Create: `schemas/ct-knowledge/rag-context.schema.json`
- Create: `schemas/llm/provider.schema.json`
- Create: `schemas/llm/model-invocation.schema.json`
- Create: `schemas/llm/tool-proposal.schema.json`

**Interfaces:**
- Consumes: Shared digest, ID, version and timestamp definitions from Task 2.
- Produces: Domain request/result types mirrored by Task 5 Pascal interfaces.

- [x] **Step 1: Define process and memory contracts**

`ProcessIdentity` must require PID, start time, canonical executable path digest, executable SHA-256, architecture, module-set digest and Epoch. Memory requests must use unsigned hexadecimal strings for addresses and bound byte counts; write requests require expected original bytes and approval/Lease references.

- [x] **Step 2: Define scan, debug and script contracts**

Scan requests must bind ProcessIdentity, ranges, value type, scan mode and budget. AOB requests must state expected match count. Script requests must distinguish `autoassembler|lua`, bind script content hash and list declared capabilities; arbitrary network, filesystem and child-process capabilities are invalid.

- [x] **Step 3: Define CT knowledge contracts**

Use a discriminated union for `AddressSpec` variants `absolute|module_offset|pointer_chain`. Require every CheatTableArtifact to carry source, content hash, parser version and provenance. Preserve CheatEntry tree paths and ScriptArtifact static analysis. Search results must separate hard compatibility from lexical and vector scores.

- [x] **Step 4: Define provider and tool proposal contracts**

Provider configuration contains endpoint, model, timeout and secret reference, never a raw API key. ModelInvocation binds TaskContract, PolicySnapshot, Lease, FeatureSet, disclosure manifest, request/response hashes, tokens, cost and provider request ID. ToolProposal has no execution authority.

- [x] **Step 5: Verify forbidden fields are absent**

Run:

```powershell
rg -n -i 'api[_-]?key|fine.?tun|training|weight.?write' .\schemas
```

Expected: no raw API key field exists; training terms occur only in explicit prohibition enums or descriptions.

### Task 4: Policies, Provider Example and Acceptance Fixtures

**Files:**
- Create: `config/policies/single-player-only.yaml`
- Create: `config/policies/memory-effects.yaml`
- Create: `config/policies/no-model-training.yaml`
- Create: `config/providers/openai-compatible.example.yaml`
- Create: `tests/fixtures/ct/minimal-valid.ct`
- Create: `tests/fixtures/ct/aob-and-pointer.ct`
- Create: `tests/fixtures/ct/dangerous-lua.ct`
- Create: `tests/contracts/positive/task.json`
- Create: `tests/contracts/positive/effect.json`
- Create: `tests/contracts/positive/cheat-table.json`
- Create: `tests/contracts/negative/finished-without-outcome.json`
- Create: `tests/contracts/negative/write-without-approval.json`
- Create: `tests/contracts/negative/provider-with-api-key.json`
- Create: `tests/policies/scenarios.yaml`
- Create: `tests/acceptance/phase-1-scenarios.yaml`

**Interfaces:**
- Consumes: Schemas from Tasks 2-3.
- Produces: Positive/negative fixtures and policy decisions used by the schema checker and future runtime tests.

- [x] **Step 1: Encode immutable deny policies**

`single-player-only.yaml` must deny multiplayer indicators, anti-cheat processes and unresolved target classification for writes. `no-model-training.yaml` must deny capability IDs matching model training, fine-tuning, dataset export for training and weight mutation with `override_allowed: false`.

- [x] **Step 2: Encode memory risk policy**

Allow bounded reads with a valid Lease. Require approval for memory write, freeze, debug state change, AA/Lua execution and CT auto-execution. Deny DBK/kernel capabilities and scripts declaring network, filesystem, process creation, persistence or anti-cheat bypass.

- [x] **Step 3: Create inert provider example**

Use endpoint `https://api.example.invalid/v1`, model `replace-with-model-id` and secret reference `windows-credential-manager:CheatEngineAgent/OpenAICompatible`; include `enabled: false` so the example cannot cause network access.

- [x] **Step 4: Create CT and JSON fixtures**

The valid CT files must use harmless synthetic modules and addresses. `dangerous-lua.ct` contains a script calling a prohibited network or process API solely for static-policy rejection tests and is never executed.

- [x] **Step 5: Verify fixture classification**

Run:

```powershell
rg -n 'override_allowed: false|multiplayer|anti_cheat|model_training|kernel|requires_approval' .\config .\tests\policies
rg -n 'openURL|executeCommand|createProcess' .\tests\fixtures\ct\dangerous-lua.ct
```

Expected: immutable denies and dangerous fixture markers are visible; no fixture targets a real game.

### Task 5: Pascal Contracts and Kernel Skeleton

**Files:**
- Create: `src/contracts/cea_types.pas`
- Create: `src/contracts/cea_results.pas`
- Create: `src/contracts/cea_ports.pas`
- Create: `src/core/state/cea_state_kernel.pas`
- Create: `src/core/governance/cea_governance_kernel.pas`
- Create: `src/core/execution/cea_execution_kernel.pas`
- Create: `src/core/cea_runtime.pas`

**Interfaces:**
- Consumes: Domain and AgentOS schema names from Tasks 2-3.
- Produces: `ICEProcessPort`, `IMemoryPort`, `ICTKnowledgePort`, `ILLMProvider`, `IStateStore`, `IPolicyEngine`, `ISecretStore`, `ISchemaValidator`, and inert kernel classes.

- [x] **Step 1: Define result and identity records**

Define `TCEAResultCode = (rcOk, rcRejected, rcUnknown, rcNotImplemented, rcInvalidArgument, rcConflict)` and `TCEAResult` with `Code`, `MessageText`, `ReceiptId` and `ProofId`. Define ProcessIdentity and request records with the same names and field meanings as schemas.

- [x] **Step 2: Define narrow port interfaces**

Required signatures:

```pascal
ICEProcessPort = interface
  function ListProcesses: TCEAResult;
  function Attach(const ARequest: TCEAttachRequest): TCEAResult;
  function Detach(const AProcess: TCEProcessIdentity): TCEAResult;
end;

IMemoryPort = interface
  function Scan(const ARequest: TCEScanRequest): TCEAResult;
  function ReadMemory(const ARequest: TCEMemoryReadRequest): TCEAResult;
  function WriteMemory(const ARequest: TCEMemoryWriteRequest): TCEAResult;
  function Disassemble(const ARequest: TCEDisassembleRequest): TCEAResult;
end;

ICTKnowledgePort = interface
  function ImportArtifact(const ARequest: TCTImportRequest): TCEAResult;
  function Search(const AQuery: TCTRetrievalQuery): TCEAResult;
  function BuildContext(const AQuery: TCTRetrievalQuery): TCEAResult;
end;

ILLMProvider = interface
  function Invoke(const ARequest: TCEAModelInvocationRequest): TCEAResult;
end;
```

- [x] **Step 3: Implement inert kernels**

Constructors accept only interfaces. Every operation validates non-empty task/process references and then returns `rcNotImplemented` without touching the OS, CE globals, network or SQLite. Governance evaluates the immutable deny IDs before any adapter call.

- [x] **Step 4: Add runtime composition root**

`TCEAgentRuntime` owns the three kernels and exposes `Initialize`, `Shutdown` and `IsInitialized`. Initialization fails closed when schema, policy or state-store ports are missing.

- [x] **Step 5: Verify dependency direction**

Run:

```powershell
rg -n -i 'MainForm|TMemScan|Windows|WinApi|fphttp|SQLDB' .\src\core .\src\contracts
```

Expected: no match. Core and contracts remain independent of CE, Windows, HTTP and concrete database units.

### Task 6: CE, CT, LLM and Infrastructure Adapter Skeletons

**Files:**
- Create: `src/domain/ce/cea_ce_process_adapter.pas`
- Create: `src/domain/ce/cea_ce_memory_adapter.pas`
- Create: `src/domain/ce/cea_ce_debug_adapter.pas`
- Create: `src/domain/ce/cea_ce_script_adapter.pas`
- Create: `src/knowledge/ct/cea_ct_catalog.pas`
- Create: `src/knowledge/ct/cea_ct_parser.pas`
- Create: `src/knowledge/ct/cea_ct_search.pas`
- Create: `src/knowledge/ct/cea_ct_rag.pas`
- Create: `src/llm/cea_llm_provider.pas`
- Create: `src/llm/cea_openai_compatible.pas`
- Create: `src/llm/cea_tool_dispatcher.pas`
- Create: `src/infrastructure/cea_sqlite_store.pas`
- Create: `src/infrastructure/cea_schema_validator.pas`
- Create: `src/infrastructure/cea_secret_store.pas`
- Create: `src/infrastructure/cea_structured_log.pas`
- Create: `src/ui/cea_ui_projection.pas`

**Interfaces:**
- Consumes: Port interfaces from Task 5.
- Produces: Concrete class names and constructor boundaries for later TDD implementation; every effectful method remains inert.

- [x] **Step 1: Add CE adapter class shells**

Each class implements exactly one port/responsibility. Methods return `rcNotImplemented` and include no process handle acquisition, memory API call, debugger command or script execution.

- [x] **Step 2: Add CT pipeline shells**

Create separate catalog, XML parser, hybrid search and RAG context classes. Parser accepts bytes plus provenance rather than a trusted file path. Search exposes compatibility, lexical and vector scores separately.

- [x] **Step 3: Add LLM shells**

The OpenAI-compatible class consumes endpoint/model/secret reference through constructor configuration. `Invoke` returns `rcNotImplemented`; no default endpoint, API key or automatic retry is embedded.

- [x] **Step 4: Add infrastructure and UI shells**

SQLite, schema validation, secret store and structured log classes implement their ports without opening files or credentials. UI projection only maps task/effect states to display records.

- [x] **Step 5: Verify inertness**

Run:

```powershell
rg -n -i 'OpenProcess|ReadProcessMemory|WriteProcessMemory|VirtualProtect|CreateRemoteThread|http[s]?://|Authorization:|sqlite3_open' .\src
```

Expected: no operational call or credential literal. The only URL appears in disabled example configuration outside `src`.

### Task 7: Cheat Engine Registration Boundary and Build Manifest

**Files:**
- Create: `integration/cheat-engine/README.md`
- Create: `integration/cheat-engine/ce_agent_registration.pas`
- Create: `integration/cheat-engine/ce-unit-map.yaml`
- Create: `integration/game-cheats-manager/catalog-contract.md`
- Create: `build/unit-manifest.txt`
- Create: `build/README.md`

**Interfaces:**
- Consumes: `TCEAgentRuntime` and all adapter class names from Tasks 5-6.
- Produces: One inert registration boundary and an explicit map from future adapters to CE 7.5 units.

- [x] **Step 1: Define registration boundary**

`ce_agent_registration.pas` exports `RegisterCheatEngineAgent` and `UnregisterCheatEngineAgent`. Registration constructs no real adapters and returns a disabled status unless an explicit future composition root supplies every dependency.

- [x] **Step 2: Map future CE dependencies**

Document candidate integrations: `ProcessHandlerUnit`, `memscan`, `symbolhandler`, `disassembler`, `autoassembler`, `LuaHandler`, `MemoryBrowserFormUnit` and `MainUnit`. Mark this map as implementation evidence, not an authorization to edit existing CE files.

- [x] **Step 3: Define GCM catalog contract**

Specify accepted JSON fields `game_name`, `gcm_url`, `version`, `author`, `custom_name`, `custom_name_en`, `custom_name_zh`; define normalization, provenance, atomic update, URL allow-list and license validation requirements.

- [x] **Step 4: Create deterministic unit manifest**

List Pascal units in dependency/build order: contracts, core, infrastructure ports, domain adapters, knowledge, LLM, UI, registration.

- [x] **Step 5: Verify existing CE source remains unchanged**

Run:

```powershell
Get-ChildItem '.\Cheat Engine' -Recurse -File | Get-FileHash -Algorithm SHA256 | Sort-Object Path | Export-Csv "$env:TEMP\cea-ce-after.csv" -NoTypeInformation
```

Expected: compare against a snapshot captured immediately before execution; no hash differs. If no pre-execution snapshot exists, disclose verification as inconclusive rather than claiming preservation.

### Task 8: Schema Checker and Final Verification

**Files:**
- Create: `tools/schema-check/check-schemas.ps1`
- Create: `tools/schema-check/README.md`
- Create: `tests/acceptance/requirements-traceability.md`
- Create: `docs/delivery/verification-report.md`
- Create: `docs/delivery/remaining-boundary.md`

**Interfaces:**
- Consumes: Every artifact from Tasks 1-7.
- Produces: Reproducible syntax checks, reference inventory, requirements trace and truthful delivery boundary.

- [x] **Step 1: Implement schema inventory checker**

The PowerShell checker must parse every JSON file, require `$schema` and `$id` on schema files, detect duplicate `$id` values, resolve local relative `$ref` targets, and return non-zero on failure. It must not install packages or call the network.

- [x] **Step 2: Add policy and Pascal consistency checks**

Check that immutable deny IDs exist in bootstrap, policies and tests; check that each required Pascal unit appears in `build/unit-manifest.txt`; check that forbidden operational calls are absent.

- [x] **Step 3: Write requirement traceability**

Map every approved requirement to document, schema, interface and test fixture references. Mark runtime process access and CT RAG execution as planned/unimplemented, while marking architecture/schema/interface coverage as implemented only after checks pass.

- [x] **Step 4: Run final verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
$forbidden = @('T'+'BD', 'T'+'ODO', 'implement'+' later', 'fill in'+' details') -join '|'
rg -n -i $forbidden .
rg -n -i 'OpenProcess|ReadProcessMemory|WriteProcessMemory|CreateRemoteThread|Authorization:' .\src .\integration
```

Expected: schema checker exits 0; placeholder scan has no matches; operational-call scan has no matches.

- [x] **Step 5: Read back delivery artifacts**

Open and inspect `README.md`, all bootstrap files, schema manifest, `cea_ports.pas`, registration unit, requirements trace, verification report and remaining boundary. Confirm no runtime completion claim exceeds evidence.

- [x] **Step 6: Record version-control limitation**

Document that no commit was created because `C:\Users\taitan666\Downloads\cheat-engine-7.5` is not a Git repository. Do not initialize a repository or alter the parent source-control state.
