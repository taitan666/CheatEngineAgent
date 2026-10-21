# AgentOS MCP Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a locally authenticated Streamable HTTP MCP server whose tools can reach the AgentOS governance gateway, using fake capabilities only in this subproject.

**Architecture:** A protocol-only HTTP layer validates MCP messages and delegates to a schema-backed tool registry. The registry calls one governance gateway; the gateway owns policy, leases, effects, receipts and proof records, and test doubles stand in for Cheat Engine capabilities until the next plan.

**Tech Stack:** Free Pascal 3.2.2, Lazarus/FCL `fphttpserver`, `fpjson`, `jsonparser`, `sqldb`, `sqlite3conn`, Windows API, PowerShell test runners.

**Spec:** `docs/superpowers/specs/2026-09-12-cheat-engine-agent-mcp-design.md`

## Global Constraints

- Listen only on `127.0.0.1`, default port `32176`; reject non-loopback binding.
- Generate a new 256-bit token per runtime start; never write it to repository files or logs.
- MCP and UI callers must use the same governance gateway and dispatcher.
- MCP must not expose an approval tool.
- Model training, fine-tuning and weight mutation remain permanently denied.
- Multiplayer/online targeting, anti-cheat bypass and kernel/DBK capabilities remain permanently denied.
- The workspace currently has no Git metadata; do not initialize Git. Each task ends with a reproducible verification checkpoint instead of a commit.

---

## File Structure

- `src/contracts/cea_results.pas`: stable result codes and JSON payload ownership.
- `src/contracts/cea_types.pas`: lease, effect, proof and MCP-neutral request records.
- `src/contracts/cea_ports.pas`: store, clock, entropy, approval and capability interfaces.
- `src/core/governance/cea_policy_model.pas`: immutable capability decisions.
- `src/core/governance/cea_lease_service.pas`: issue, validate and revoke bounded leases.
- `src/core/governance/cea_effect_service.pas`: effect state machine and content-bound approval validation.
- `src/core/governance/cea_governance_gateway.pas`: only public capability dispatch boundary.
- `src/core/state/cea_event_store.pas`: durable append/read façade.
- `src/infrastructure/cea_sqlite_store.pas`: SQLite schema and transactions.
- `src/infrastructure/cea_schema_validator.pas`: compiled schema registry and payload validation.
- `src/mcp/cea_mcp_protocol.pas`: JSON-RPC/MCP decoding and encoding.
- `src/mcp/cea_mcp_registry.pas`: tool metadata and handlers.
- `src/mcp/cea_mcp_auth.pas`: constant-time bearer validation and token lifecycle.
- `src/mcp/cea_mcp_http_server.pas`: loopback HTTP lifecycle and request limits.
- `src/mcp/cea_mcp_dispatcher.pas`: maps MCP calls to the governance gateway.
- `tests/pascal/fakes/cea_test_ports.pas`: deterministic fake clock, entropy, store and capabilities.
- `tests/pascal/test_agentos_governance.pas`: policy, lease and effect tests.
- `tests/pascal/test_mcp_protocol.pas`: MCP initialize/list/call/error tests.
- `tests/pascal/test_mcp_http.pas`: loopback authentication and request-limit tests.
- `tests/pascal/run-test-program.ps1`: isolated FPC compile/run helper.

### Task 1: Stable contracts and isolated test runner

**Files:**
- Modify: `src/contracts/cea_results.pas`
- Modify: `src/contracts/cea_types.pas`
- Modify: `src/contracts/cea_ports.pas`
- Create: `tests/pascal/run-test-program.ps1`
- Create: `tests/pascal/test_contracts.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: existing `TCEAResult`, process and memory request records.
- Produces: `TCEAResult.Create`, `TCEAResult.Ok`, `TCEAResult.Error`, `TCEAResult.Failed`, `TCEAResult.DataJson`; `ICEAClock.UtcNowIso8601`; `ICEAEntropy.RandomBytes`; `IApprovalPort.FindDecision`.

- [x] **Step 1: Create the isolated runner and write the failing contract test**

```powershell
param([Parameter(Mandatory=$true)][string]$Program)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = Join-Path $env:TEMP ('cea-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out | Out-Null
$unitDirs = @(
  'src\contracts', 'src\core', 'src\core\state', 'src\core\governance',
  'src\core\execution', 'src\domain\ce', 'src\knowledge\ct', 'src\llm',
  'src\infrastructure', 'src\infrastructure\windows', 'src\mcp', 'src\ui',
  'integration\cheat-engine', 'tests\pascal', 'tests\pascal\fakes',
  'tests\fakes', 'tests\integration'
) | ForEach-Object { '-Fu' + (Join-Path $root $_) }
$compilerArgs = @('-B', '-Mobjfpc', '-Sh', '-Sa', ('-FU' + $out), ('-FE' + $out)) +
  $unitDirs + @((Resolve-Path $Program).Path)
& 'C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe' @compilerArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$exe = Join-Path $out ([System.IO.Path]::GetFileNameWithoutExtension($Program) + '.exe')
$dependencyDir = Join-Path (Split-Path $root -Parent) 'Cheat Engine\bin\win64'
$previousPath = $env:PATH
try {
  $env:PATH = $dependencyDir + [System.IO.Path]::PathSeparator + $env:PATH
  & $exe
  $programExitCode = $LASTEXITCODE
} finally {
  $env:PATH = $previousPath
}
exit $programExitCode
```

```pascal
program test_contracts;
{$mode objfpc}{$H+}
uses SysUtils, cea_results;
var R: TCEAResult;
begin
  R := TCEAResult.Ok('{"status":"ready"}');
  Assert(R.Code = rcOk);
  Assert(R.StableCode = 'ok');
  Assert(R.DataJson = '{"status":"ready"}');
  Assert(not R.Failed);
end.
```

- [x] **Step 2: Run the test and verify the expected compile failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_contracts.pas
```

Expected: compilation fails because `Ok`, `StableCode`, `DataJson` and `Failed` do not exist.

- [x] **Step 3: Extend results and ports without transport dependencies**

```pascal
TCEAResultCode = (rcOk, rcRejected, rcUnknown, rcNotImplemented,
  rcInvalidArgument, rcConflict, rcUnauthenticated,
  rcUnauthorized, rcApprovalRequired, rcPolicyDenied,
  rcTargetNotOffline, rcStaleProcessIdentity, rcLeaseExpired,
  rcBudgetExceeded, rcScanRunning, rcAmbiguousMatch,
  rcVerificationFailed, rcCancelled, rcTimeout,
  rcUnknownOutcome, rcInternalError);

TCEAResult = record
  Code: TCEAResultCode;
  StableCode: string;
  MessageText: string;
  DataJson: string;
  ReceiptId: string;
  ProofId: string;
  class function Ok(const ADataJson: string): TCEAResult; static;
  class function Error(const ACode: TCEAResultCode; const AStableCode,
    ADataJson: string): TCEAResult; static;
  function Failed: Boolean;
end;
```

Enable `{$modeswitch advancedrecords}` in `cea_results.pas` so the class functions compile under FPC 3.2.2.

Add `TCEALease`, `TCEAApprovalDecision`, `TCEAEffect`, `TCEAReceipt` and `TCEAProof` records with explicit IDs, request hashes, process identity references, Epoch, timestamps and states. Add clock, entropy and approval ports; keep contracts free of HTTP, Windows, CE and SQLite units.

- [x] **Step 4: Execute the contract test**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_contracts.pas
```

Expected: `test_contracts.exe` exits with code 0 and no `.o`, `.ppu` or `.exe` appears under the project.

- [x] **Step 5: Run the existing compile smoke checkpoint**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\compile-smoke.ps1
```

Expected: `PASCAL_COMPILE_SMOKE=PASS`.

### Task 2: SQLite state store and schema validation

**Files:**
- Create: `src/core/state/cea_event_store.pas`
- Modify: `src/infrastructure/cea_sqlite_store.pas`
- Modify: `src/infrastructure/cea_schema_validator.pas`
- Create: `tests/pascal/test_state_store.pas`
- Create: `schemas/mcp/tool-result.schema.json`
- Modify: `schemas/manifest.json`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: `IStateStore.Initialize`, `IStateStore.AppendEvent`, stable result contracts.
- Produces: `TCEAEventStore.AppendValidated`; SQLite tables `events`, `leases`, `approvals`, `effects`, `receipts`, `proofs`, `idempotency`.

- [ ] **Step 1: Write a failing durability and uniqueness test**

```pascal
Db := TCEASqliteStore.Create(DbPath);
Assert(Db.Initialize.Code = rcOk);
Assert(Db.AppendEvent('{"id":"evt-1","kind":"test"}').Code = rcOk);
Assert(Db.AppendEvent('{"id":"evt-1","kind":"test"}').Code = rcConflict);
Db := nil;
Db := TCEASqliteStore.Create(DbPath);
Assert(Db.Initialize.Code = rcOk);
Assert(Db.EventExists('evt-1'));
```

- [ ] **Step 2: Run and observe the constructor/API failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_state_store.pas
```

Expected: compilation fails because the concrete store constructor and `EventExists` are absent.

- [ ] **Step 3: Implement transactional SQLite initialization**

```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS events (
  event_id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS effects (
  effect_id TEXT PRIMARY KEY,
  request_hash TEXT NOT NULL,
  process_identity_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('planned','executing','applied','rejected','unknown')),
  payload_json TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS effects_request_hash ON effects(request_hash);
```

Create the remaining tables using foreign keys from receipt/proof to effect and unique indexes on approval ID and idempotency key. Use parameterized SQL only. Map busy/locked to `rcConflict` and malformed records to `rcInvalidArgument`.

- [ ] **Step 4: Implement schema registration and validation**

```pascal
function TCEASchemaValidator.Validate(const ASchemaId,
  APayloadJson: string): TCEAResult;
begin
  if not FRegistry.Contains(ASchemaId) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'unknown_schema', ASchemaId));
  Result := FRegistry[ASchemaId].ValidateJson(APayloadJson);
end;
```

The validator must reject unknown properties where the repository schema declares `additionalProperties: false`, validate required fields and preserve a stable JSON pointer in error data.

- [ ] **Step 5: Run state, schema and smoke checks**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_state_store.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\compile-smoke.ps1
```

Expected: all three commands pass.

### Task 3: Policy, Lease and Effect services

**Files:**
- Create: `src/core/governance/cea_policy_model.pas`
- Create: `src/core/governance/cea_lease_service.pas`
- Create: `src/core/governance/cea_effect_service.pas`
- Create: `src/core/governance/cea_governance_gateway.pas`
- Modify: `src/core/governance/cea_governance_kernel.pas`
- Modify: `src/infrastructure/cea_policy_engine.pas`
- Create: `tests/pascal/fakes/cea_test_ports.pas`
- Create: `tests/pascal/test_agentos_governance.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: state store, clock, entropy, approval and capability ports.
- Produces: `TCEAGovernanceGateway.InvokeRead`, `RequestEffect`, `ExecuteApprovedEffect`, `EmergencyStop`.

- [ ] **Step 1: Write failing hard-deny and self-approval tests**

```pascal
Assert(Gateway.InvokeRead('model_training', OfflineContext, '{}').Code = rcPolicyDenied);
Assert(Gateway.InvokeRead('kernel_driver', OfflineContext, '{}').Code = rcPolicyDenied);
EffectResult := Gateway.RequestEffect('memory_write', OfflineContext, WriteJson);
Assert(EffectResult.Code = rcApprovalRequired);
FakeApprovals.AddModelIssuedApproval(EffectId, RequestHash);
Assert(Gateway.ExecuteApprovedEffect(EffectId).Code = rcUnauthorized);
```

- [ ] **Step 2: Run and verify failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_agentos_governance.pas
```

Expected: compile failure because `TCEAGovernanceGateway` is absent.

- [ ] **Step 3: Implement immutable policy and bounded leases**

```pascal
const PermanentDenies: array[0..8] of string = (
  'model_training', 'model_fine_tuning', 'online_learning',
  'weight_mutation', 'weight_writeback', 'multiplayer_targeting',
  'anti_cheat_bypass', 'kernel_driver', 'concealment');

function TCEALeaseService.Validate(const ALeaseId, ACapability,
  AProcessIdentityId: string; AEpoch: QWord): TCEAResult;
begin
  Lease := FStore.LoadLeaseForUpdate(ALeaseId);
  if Lease.Id = '' then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_not_found', '{}'));
  if Lease.Revoked then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_revoked', '{}'));
  if FClock.UtcNowIso8601 > Lease.ExpiresAt then
    Exit(TCEAResult.Error(rcLeaseExpired, 'lease_expired', '{}'));
  if (Lease.CapabilityId <> ACapability) or
     (Lease.ProcessIdentityId <> AProcessIdentityId) or
     (Lease.Epoch <> AEpoch) then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_scope_mismatch', '{}'));
  if Lease.RemainingCalls = 0 then
    Exit(TCEAResult.Error(rcBudgetExceeded, 'lease_calls_exhausted', '{}'));
  FStore.DecrementLeaseCallsAndCommit(Lease.Id);
  Result := TCEAResult.Ok('{"lease_id":"' + Lease.Id + '"}');
end;
```

The store methods above run under one immediate transaction. A Lease validation that cannot read durable state returns `rcUnknownOutcome`, never allow.

- [ ] **Step 4: Implement Effect transitions and approval binding**

```pascal
if Decision.Origin <> aoLocalUserInterface then
  Exit(TCEAResult.Error(rcUnauthorized, 'approval_origin_invalid', '{}'));
if Decision.RequestHash <> Effect.RequestHash then
  Exit(TCEAResult.Error(rcUnauthorized, 'approval_hash_mismatch', '{}'));
if Decision.ProcessIdentityId <> Effect.ProcessIdentityId then
  Exit(TCEAResult.Error(rcStaleProcessIdentity, 'approval_target_changed', '{}'));
if Clock.UtcNowIso8601 > Decision.ExpiresAt then
  Exit(TCEAResult.Error(rcLeaseExpired, 'approval_expired', '{}'));
```

Persist `executing` before calling the capability. Persist one Receipt and one Proof afterward. A timeout or indeterminate adapter response becomes `unknown`; the same idempotency key returns the stored outcome without executing again.

- [ ] **Step 5: Run governance tests and inspect forbidden terms**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_agentos_governance.pas
rg -n "model_training|weight_mutation|multiplayer_targeting|kernel_driver" .\src\core\governance .\config\policies
```

Expected: tests pass and every match is a deny declaration or deny test.

### Task 4: MCP protocol codec and tool registry

**Files:**
- Create: `src/mcp/cea_mcp_protocol.pas`
- Create: `src/mcp/cea_mcp_registry.pas`
- Create: `src/mcp/cea_mcp_dispatcher.pas`
- Create: `schemas/mcp/initialize.schema.json`
- Create: `schemas/mcp/tool-call.schema.json`
- Create: `schemas/mcp/tool-result.schema.json`
- Create: `tests/pascal/test_mcp_protocol.pas`
- Modify: `schemas/manifest.json`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: `TCEAGovernanceGateway`, JSON Schemas and stable result codes.
- Produces: `TMCPProtocol.HandleJsonRpc`; `TMCPToolRegistry.RegisterTool`, `ListTools`, `CallTool`.

- [ ] **Step 1: Write failing initialize/list/call tests**

```pascal
Response := Protocol.HandleJsonRpc(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
  '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}');
Assert(Pos('"serverInfo"', Response) > 0);
Response := Protocol.HandleJsonRpc(
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');
Assert(Pos('cea.health', Response) > 0);
Assert(Pos('cea.approve', Response) = 0);
```

- [ ] **Step 2: Run and verify missing protocol unit**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_mcp_protocol.pas
```

Expected: compilation fails because `cea_mcp_protocol` is absent.

- [ ] **Step 3: Implement strict JSON-RPC and MCP routing**

```pascal
case MethodName of
  'initialize': Result := BuildInitializeResult(RequestId);
  'notifications/initialized': Result := '';
  'ping': Result := BuildEmptyResult(RequestId);
  'tools/list': Result := BuildToolList(RequestId, Registry.ListTools);
  'tools/call': Result := BuildToolCallResult(RequestId, Registry.CallTool(Params));
else
  Result := BuildJsonRpcError(RequestId, -32601, 'Method not found');
end;
```

Reject batches, invalid UTF-8, duplicate object keys, messages above 1 MiB and unknown top-level fields. Tool business errors remain successful JSON-RPC responses with `isError: true` and structured content.

- [ ] **Step 4: Register the first fake-backed tool set**

```pascal
Registry.RegisterTool(TMCPToolDefinition.Create(
  'cea.health', 'Return local AgentOS and MCP health',
  '{"type":"object","properties":{},"additionalProperties":false}',
  True, False, 'runtime_health'));
Registry.RegisterTool(TMCPToolDefinition.Create(
  'cea.request_memory_write', 'Create a locally approved write Effect',
  MemoryWriteSchemaJson, False, True, 'memory_write'));
```

Register every tool from spec section 5. Tools whose real adapters are not part of this plan return `not_implemented` through the gateway; `cea.health` and governance denial paths must work.

- [ ] **Step 5: Run protocol and schema checks**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_mcp_protocol.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
```

Expected: both pass; tool list contains no approval capability.

### Task 5: Loopback HTTP server and token lifecycle

**Files:**
- Create: `src/mcp/cea_mcp_auth.pas`
- Create: `src/mcp/cea_mcp_http_server.pas`
- Create: `src/infrastructure/windows/cea_windows_entropy.pas`
- Create: `src/infrastructure/windows/cea_runtime_secret_file.pas`
- Create: `tests/pascal/test_mcp_http.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: `TMCPProtocol.HandleJsonRpc`, `ICEAEntropy.RandomBytes`.
- Produces: `TMCPHttpServer.Start`, `Stop`, `BoundAddress`; `TMCPAuth.RotateToken`, `ValidateAuthorization`.

- [ ] **Step 1: Write failing authentication and binding tests**

```pascal
Assert(Server.Start('0.0.0.0', 32176).Code = rcPolicyDenied);
Assert(Server.Start('127.0.0.1', TestPort).Code = rcOk);
Assert(HttpPost(Server.Url, '{}', '').StatusCode = 401);
Assert(HttpPost(Server.Url, InitializeJson, 'Bearer wrong').StatusCode = 401);
Assert(HttpPost(Server.Url, InitializeJson, 'Bearer ' + Auth.Token).StatusCode = 200);
Server.Stop;
Assert(not Auth.ValidateAuthorization('Bearer ' + OldToken));
```

- [ ] **Step 2: Run and verify missing server units**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_mcp_http.pas
```

Expected: compilation fails because HTTP/auth units are absent.

- [ ] **Step 3: Implement CSPRNG token and constant-time comparison**

```pascal
if BCryptGenRandom(nil, @Buffer[0], Length(Buffer),
  BCRYPT_USE_SYSTEM_PREFERRED_RNG) <> 0 then
  Exit(TCEAResult.Error(rcInternalError, 'entropy_failed', '{}'));

Diff := Length(A) xor Length(B);
for I := 1 to Min(Length(A), Length(B)) do
  Diff := Diff or (Ord(A[I]) xor Ord(B[I]));
Result := Diff = 0;
```

Write the token descriptor with a Windows security descriptor granting only the current user and SYSTEM access. On shutdown, overwrite the in-memory token, close the listener, delete the exact runtime credential file and increment the server generation.

- [ ] **Step 4: Implement bounded HTTP behavior**

```pascal
if Request.RemoteAddress <> '127.0.0.1' then
  ExitHttp(403, 'loopback_required');
if not IsAllowedLoopbackOrigin(Request.GetHeader('Origin')) then
  ExitHttp(403, 'origin_not_allowed');
if Request.ContentLength > 1024 * 1024 then
  ExitHttp(413, 'request_too_large');
if not Auth.ValidateAuthorization(Request.Authorization) then
  ExitHttp(401, 'invalid_token');
if Request.PathInfo <> '/mcp' then
  ExitHttp(404, 'not_found');
Response.ContentType := 'application/json; charset=utf-8';
Response.Content := Protocol.HandleJsonRpc(Request.Content);
```

Accept `POST /mcp` for the stateless JSON transport. Return 405 for GET and DELETE in this phase, require `Content-Type: application/json`, honor the client's `MCP-Protocol-Version` after initialization, and accept the MCP media types declared by the client. Treat a missing Origin as a local non-browser client; if Origin is present, allow only loopback origins. Set request timeout to 60 seconds, cap concurrent calls at 8 and attach a cancellation token to each dispatch. Do not log Authorization or full memory payloads.

- [ ] **Step 5: Run HTTP, governance and compile checkpoints**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_mcp_http.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_agentos_governance.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\compile-smoke.ps1
```

Expected: all pass and `Get-NetTCPConnection -LocalPort 32176` shows no listener after the test exits.

### Task 6: Runtime composition with fake capabilities

**Files:**
- Modify: `src/core/cea_runtime.pas`
- Modify: `integration/cheat-engine/ce_agent_registration.pas`
- Create: `tests/pascal/mcp_fixture_server.pas`
- Create: `tests/integration/test-mcp-foundation.ps1`
- Modify: `tests/acceptance/requirements-traceability.md`
- Modify: `docs/delivery/remaining-boundary.md`

**Interfaces:**
- Consumes: AgentOS services, MCP server and fake capability ports.
- Produces: a standalone fixture server answering `initialize`, `tools/list` and `cea.health` through the same runtime composition used later by CE.

- [ ] **Step 1: Write the failing integration script**

```powershell
$health = Invoke-RestMethod -Method Post -Uri $url -Headers @{Authorization="Bearer $token"} `
  -ContentType 'application/json' -Body '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cea.health","arguments":{}}}'
if ($health.result.isError) { throw 'cea.health returned an error' }
if ($health.result.structuredContent.status -ne 'ready') { throw 'runtime is not ready' }
```

- [ ] **Step 2: Run and verify fixture absence**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-mcp-foundation.ps1
```

Expected: failure because `mcp_fixture_server` is not built.

- [ ] **Step 3: Compose a fail-closed runtime**

```pascal
FEventStore := TCEAEventStore.Create(Store, Validator);
FLeaseService := TCEALeaseService.Create(Store, Clock);
FEffectService := TCEAEffectService.Create(Store, Clock, Approvals);
FGateway := TCEAGovernanceGateway.Create(Policy, FLeaseService,
  FEffectService, Capabilities);
FRegistry := BuildDefaultToolRegistry(FGateway, Validator);
FProtocol := TMCPProtocol.Create(FRegistry, ServerInstructions);
FServer := TMCPHttpServer.Create(FProtocol, Auth);
```

If any dependency initialization fails, do not start the listener. `Shutdown` first rejects new Effects and revokes leases, then cancels requests, stops HTTP and closes SQLite.

- [ ] **Step 4: Build and execute the foundation integration test**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-mcp-foundation.ps1
```

Expected: initialize, tools/list and health pass; an unauthenticated call receives 401; a memory write request returns `approval_required` and does not alter memory.

- [ ] **Step 5: Run the full foundation verification set**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\verify-scaffold.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\compile-smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-mcp-foundation.ps1
```

Expected: all commands pass. Update traceability to mark MCP protocol, authentication and governance as implemented; CE adapters, CT RAG, LLM transport and Codex live connection remain explicitly unimplemented.
