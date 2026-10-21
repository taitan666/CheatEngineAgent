# CT RAG, LLM, and Codex Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement provenance-bound CT retrieval, the in-process OpenAI-compatible client, Codex MCP configuration, and the final live tool-call verification.

**Architecture:** CT files are parsed without execution, normalized into immutable SQLite documents and retrieved using structured plus full-text scoring. The LLM receives bounded RAG context and can emit schema-valid proposals only; a separate credential helper lets Codex authenticate to the already-running loopback MCP server without storing tokens in config.

**Tech Stack:** Free Pascal 3.2.2, FCL XML/JSON/HTTP, SQLite/SQLDB, Windows Credential Manager and ACL APIs, PowerShell, Codex project MCP configuration.

**Spec:** `docs/superpowers/specs/2026-09-12-cheat-engine-agent-mcp-design.md`

## Global Constraints

- Complete the MCP and local governance foundation before live Codex testing; CE adapter tasks may run independently except for final E2E.
- CT XML parsing must disable external entities and must never execute AA or Lua.
- Every indexed record and RAG result includes source URI and SHA-256.
- Provider secrets are resolved by reference and never appear in configuration, logs or MCP responses.
- No code path may train, fine-tune, merge adapters or alter model weights.
- Codex configuration contains no bearer token and connects only to `http://127.0.0.1:32176/mcp`.
- The workspace has no Git metadata; use verification checkpoints and do not initialize Git.

---

## File Structure

- `src/knowledge/ct/cea_ct_xml_reader.pas`: hardened CT XML parsing.
- `src/knowledge/ct/cea_ct_model.pas`: normalized CT artifact/entry/script records.
- `src/knowledge/ct/cea_ct_parser.pas`: extraction and hashing orchestration.
- `src/knowledge/ct/cea_ct_catalog.pas`: immutable SQLite index publication.
- `src/knowledge/ct/cea_ct_search.pas`: structured and FTS retrieval.
- `src/knowledge/ct/cea_ct_rag.pas`: bounded provenance manifest.
- `src/llm/cea_openai_compatible.pas`: HTTP model invocation.
- `src/llm/cea_tool_dispatcher.pas`: schema-valid proposal dispatch.
- `src/infrastructure/windows/cea_windows_credential_store.pas`: provider secret resolution.
- `tools/mcp-auth-helper/cea_mcp_auth_helper.pas`: temporary MCP header helper.
- `tools/codex/install-project-mcp.ps1`: project config installer/updater.
- `.codex/config.toml.example`: token-free MCP settings template.
- `tests/integration/test-ct-rag.pas`: CT fixture pipeline.
- `tests/integration/test-llm-provider.pas`: local fake HTTP provider tests.
- `tests/integration/test-codex-mcp.ps1`: live preflight and MCP calls.

### Task 1: Normalized CT model and hardened XML parser

**Files:**
- Create: `src/knowledge/ct/cea_ct_model.pas`
- Create: `src/knowledge/ct/cea_ct_xml_reader.pas`
- Modify: `src/knowledge/ct/cea_ct_parser.pas`
- Create: `tests/pascal/test_ct_parser.pas`
- Modify: `schemas/ct-knowledge/cheat-table.schema.json`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: CT fixtures and SHA-256 helper.
- Produces: `TCTParser.ParseFile` and `ParseBytes` returning `TCTParseResult`; `TCTParseResult` contains a stable result code and one `TCTArtifact` with entries, pointer chains, AOB, AA/Lua blocks, source and hash.

- [ ] **Step 1: Write failing extraction and XXE tests**

```pascal
Parsed := Parser.ParseFile('tests/fixtures/ct/aob-and-pointer.ct', 'file:test');
Assert(Parsed.Code = rcOk);
Artifact := Parsed.Artifact;
Assert(Artifact.GameName <> '');
Assert(Pos('sha256:', Artifact.ContentHash) = 1);
Assert(Artifact.Entries.Count > 0);
Assert(Artifact.Entries[0].SourceUri = 'file:test');
Assert(Artifact.Entries[0].PointerOffsets.Count > 0);
Assert(Parser.ParseBytes(XxeFixture, 'file:xxe').Code = rcPolicyDenied);
```

- [ ] **Step 2: Run and verify parser failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ct_parser.pas
```

Expected: compilation fails because the normalized CT model and `ParseFile` are absent.

- [ ] **Step 3: Implement secure XML loading**

```pascal
if ContainsDoctypeOrEntity(ABytes) then
  Exit(TCTParseResult.Error(rcPolicyDenied, 'xml_external_entity_forbidden'));
if Length(ABytes) > 64 * 1024 * 1024 then
  Exit(TCTParseResult.Error(rcBudgetExceeded, 'ct_file_too_large'));
ReadXMLFile(Document, Stream, [xrfAllowSpecialChars]);
if Document.DocumentElement.NodeName <> 'CheatTable' then
  Exit(TCTParseResult.Error(rcInvalidArgument, 'ct_root_invalid'));
```

Enforce maximum depth 64, maximum 100,000 entries and maximum 4 MiB per script. Do not resolve external resources.

- [ ] **Step 4: Extract all required CT semantics**

```pascal
Entry.Description := ChildText(Node, 'Description');
Entry.AddressExpression := ChildText(Node, 'Address');
Entry.ModuleName := ExtractModuleName(Entry.AddressExpression);
Entry.PointerOffsets := ReadOffsets(ChildNode(Node, 'Offsets'));
Entry.AutoAssembler := ReadScript(Node, 'Auto Assembler Script');
Entry.LuaScript := ReadScript(Node, 'Lua Script');
Entry.AobPatterns := ExtractAobPatterns(Entry.AutoAssembler);
Entry.EntryHash := HashCanonicalEntry(Entry);
```

Preserve parent/child hierarchy, CE ID, variable type, enabled description and table/game metadata. Store raw scripts for retrieval but never pass them to CE execution during import.

- [ ] **Step 5: Run parser and schema checks**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ct_parser.pas
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
```

Expected: valid fixtures parse, dangerous Lua is stored and flagged, XXE/over-limit input is rejected.

### Task 2: Immutable SQLite CT catalog

**Files:**
- Modify: `src/knowledge/ct/cea_ct_catalog.pas`
- Create: `src/knowledge/ct/cea_ct_schema.sql`
- Create: `tests/pascal/test_ct_catalog.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: normalized `TCTArtifact`.
- Produces: `TCTCatalog.ImportArtifact`, `PublishIndex`, `GetEntry`, `CurrentVersion`.

- [ ] **Step 1: Write failing hash deduplication test**

```pascal
First := Catalog.ImportArtifact(Artifact);
Second := Catalog.ImportArtifact(Artifact);
Assert(First.Code = rcOk);
Assert(Second.Code = rcOk);
Assert(JsonValue(First.DataJson, 'artifact_id') = JsonValue(Second.DataJson, 'artifact_id'));
Assert(Catalog.CountArtifactsByHash(Artifact.ContentHash) = 1);
```

- [ ] **Step 2: Run and verify catalog failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ct_catalog.pas
```

Expected: current catalog returns `rcNotImplemented`.

- [ ] **Step 3: Create normalized tables and FTS shadow index**

```sql
CREATE TABLE ct_artifact(
  artifact_id TEXT PRIMARY KEY,
  content_hash TEXT NOT NULL UNIQUE,
  source_uri TEXT NOT NULL,
  game_name TEXT NOT NULL,
  game_version TEXT,
  imported_at TEXT NOT NULL
);
CREATE TABLE ct_entry(
  entry_id TEXT PRIMARY KEY,
  artifact_id TEXT NOT NULL REFERENCES ct_artifact(artifact_id),
  parent_entry_id TEXT,
  description TEXT NOT NULL,
  module_name TEXT,
  address_expression TEXT,
  canonical_json TEXT NOT NULL,
  entry_hash TEXT NOT NULL
);
CREATE VIRTUAL TABLE ct_entry_fts USING fts5(entry_id UNINDEXED, game_name,
  description, module_name, address_expression, scripts);
```

Add pointer offsets, AOB patterns and scripts tables. Publish imports in a transaction; increment catalog version only after all rows and FTS records succeed.

- [ ] **Step 4: Implement immutable import semantics**

```pascal
ExistingId := FindArtifactByHash(Artifact.ContentHash);
if ExistingId <> '' then
  Exit(TCEAResult.Ok('{"artifact_id":"' + ExistingId + '","deduplicated":true}'));
Connection.StartTransaction;
try
  InsertArtifact(Artifact);
  InsertEntriesAndIndex(Artifact);
  IncrementCatalogVersion;
  Connection.Commit;
except
  Connection.Rollback;
  raise;
end;
```

- [ ] **Step 5: Run catalog durability tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\pascal\test_ct_catalog.pas
```

Expected: duplicate hash produces one artifact; interrupted import leaves the prior catalog version unchanged.

### Task 3: Hybrid retrieval and bounded RAG context

**Files:**
- Modify: `src/knowledge/ct/cea_ct_search.pas`
- Modify: `src/knowledge/ct/cea_ct_rag.pas`
- Create: `tests/integration/test-ct-rag.pas`
- Modify: `schemas/ct-knowledge/search.schema.json`
- Modify: `schemas/ct-knowledge/rag-context.schema.json`

**Interfaces:**
- Consumes: CT catalog, query text and optional exact game/process metadata.
- Produces: `TCTHybridSearch.Search`; `TCTKnowledgeAdapter.BuildContext` with provenance manifest.

- [ ] **Step 1: Write failing relevance and provenance tests**

```pascal
R := Knowledge.Search(Query('infinite health', 5));
Assert(R.Code = rcOk);
Assert(ResultCount(R) > 0);
Assert(ResultSourceUri(R, 0) <> '');
Assert(Pos('sha256:', ResultContentHash(R, 0)) = 1);
Context := Knowledge.BuildContext(Query('health pointer', 5));
Assert(ContextBytes(Context) <= 32768);
Assert(ContextHasProvenanceForEveryChunk(Context));
```

- [ ] **Step 2: Run and verify retrieval failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-ct-rag.pas
```

Expected: current search and RAG adapters return `rcNotImplemented`.

- [ ] **Step 3: Implement deterministic hybrid scoring**

```sql
SELECT e.entry_id, bm25(ct_entry_fts) AS text_score,
       CASE WHEN lower(a.game_name)=lower(:game) THEN 3.0 ELSE 0 END AS game_boost,
       CASE WHEN lower(e.module_name)=lower(:module) THEN 2.0 ELSE 0 END AS module_boost
FROM ct_entry_fts
JOIN ct_entry e USING(entry_id)
JOIN ct_artifact a USING(artifact_id)
WHERE ct_entry_fts MATCH :fts_query
ORDER BY (text_score - game_boost - module_boost), e.entry_id
LIMIT :max_results;
```

Normalize Chinese/English punctuation and case. Add exact hash, module and address-expression matches before FTS. Vector search is optional only when an embedding provider is configured; deterministic structured/FTS retrieval remains functional without it.

- [ ] **Step 4: Build provenance-bound context**

```pascal
for Hit in Hits do begin
  Chunk := BuildChunk(Hit, 4096);
  if TotalUtf8Bytes + Utf8Length(Chunk.Text) > 32768 then Break;
  Manifest.Add(Chunk.Id, Hit.ArtifactId, Hit.EntryId,
    Hit.SourceUri, Hit.ContentHash, Hit.EntryHash);
  Chunks.Add(Chunk);
end;
```

Mark AA/Lua as untrusted source text and include static capability flags. Never infer execution approval from ranking or provenance.

- [ ] **Step 5: Run CT RAG and reproducibility tests**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-ct-rag.pas
```

Expected: repeated queries return stable ordering, every hit has provenance, and context stays within 32 KiB.

### Task 4: Windows secret store and OpenAI-compatible LLM client

**Files:**
- Create: `src/infrastructure/windows/cea_windows_credential_store.pas`
- Modify: `src/infrastructure/cea_secret_store.pas`
- Modify: `src/llm/cea_openai_compatible.pas`
- Modify: `src/llm/cea_tool_dispatcher.pas`
- Create: `tests/fakes/fake_openai_server.pas`
- Create: `tests/integration/test-llm-provider.pas`
- Modify: `build/unit-manifest.txt`

**Interfaces:**
- Consumes: provider config, secret reference, disclosure manifest and RAG context.
- Produces: `TOpenAICompatibleProvider.Invoke`; schema-valid `ToolProposal` with `authority = none`.

- [ ] **Step 1: Write failing secret-redaction and proposal tests**

```pascal
Provider := TOpenAICompatibleProvider.Create(Config, Secrets, Http, Validator);
R := Provider.Invoke(Request);
Assert(R.Code = rcOk);
Assert(JsonValue(R.DataJson, 'authority') = 'none');
Assert(Pos('test-secret-value', R.DataJson) = 0);
Assert(Pos('test-secret-value', LogSink.Text) = 0);
FakeServer.DelayMs := Config.TimeoutMs + 100;
Assert(Provider.Invoke(Request).Code = rcTimeout);
Assert(FakeCapabilities.ExecutionCount = 0);
```

- [ ] **Step 2: Run and verify provider failure**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-llm-provider.pas
```

Expected: provider returns `rcNotImplemented`.

- [ ] **Step 3: Implement referenced credential resolution**

```pascal
if Copy(ASecretRef, 1, Length('windows-credential-manager:')) <>
   'windows-credential-manager:' then
  Exit(TCEAResult.Error(rcInvalidArgument, 'secret_reference_invalid', '{}'));
TargetName := ASecretRef.Substring(Length('windows-credential-manager:'));
if not CredReadW(PWideChar(UTF8Decode(TargetName)), CRED_TYPE_GENERIC, 0, Credential) then
  Exit(MapCredentialError(GetLastError));
```

Copy the secret into a short-lived buffer, zero it after the HTTP request and never include it in exceptions. Keep provider config `enabled: false` until the user supplies a valid reference.

- [ ] **Step 4: Implement bounded HTTP invocation and schema validation**

```pascal
Http.AddHeader('Authorization', 'Bearer ' + Secret);
Http.AddHeader('Content-Type', 'application/json');
Http.ConnectTimeout := FConfiguration.TimeoutMs;
Http.IOTimeout := FConfiguration.TimeoutMs;
ResponseJson := Http.Post(FConfiguration.Endpoint + '/responses', RequestJson);
Validation := Validator.Validate('llm/tool-proposal.schema.json', ExtractOutput(ResponseJson));
if Validation.Failed then Exit(Validation);
Result := TCEAResult.Ok(ForceAuthorityNone(ExtractOutput(ResponseJson)));
```

Record provider request ID, actual model ID, token usage, disclosure hash and request/response hashes. A timeout never replays a proposal or any effectful tool call.

- [ ] **Step 5: Assert no training or weight path exists**

```powershell
$matches = rg -n -i "fine[-_ ]?tun|train(ing)?_job|weight[_ -]?(write|update|merge)|lora" .\src .\config
if ($LASTEXITCODE -eq 0) {
  $denies = $matches | Select-String -Pattern "deny|denied|forbid|no_model_training" -NotMatch
  if ($denies) { throw "Non-deny model mutation path found: $denies" }
}
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\run-test-program.ps1 -Program .\tests\integration\test-llm-provider.pas
```

Expected: provider tests pass and there is no operational training/weight mutation path.

### Task 5: MCP credential helper and project configuration installer

**Files:**
- Create: `tools/mcp-auth-helper/cea_mcp_auth_helper.pas`
- Create: `tools/mcp-auth-helper/build.ps1`
- Create: `tools/codex/install-project-mcp.ps1`
- Create: `.codex/config.toml.example`
- Create: `tests/integration/test-mcp-auth-helper.ps1`
- Modify: `.gitignore` if the file exists; otherwise create `cheat-engine-agnet/.gitignore` for generated binaries and runtime secrets only.

**Interfaces:**
- Consumes: ACL-protected runtime descriptor produced by the running CE MCP server.
- Produces: one JSON object on stdout, `{"Authorization":"Bearer <token>"}`; token-free project MCP configuration.

- [ ] **Step 1: Write failing helper behavior test**

```powershell
$env:CEA_MCP_DESCRIPTOR = $fixture
$headers = (& $helper | ConvertFrom-Json)
if ($headers.Authorization -ne 'Bearer fixture-token') { throw 'wrong header' }
Remove-Item Env:CEA_MCP_DESCRIPTOR
& $helper 2>$null
if ($LASTEXITCODE -eq 0) { throw 'helper accepted missing descriptor' }
```

- [ ] **Step 2: Run and verify helper absence**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-mcp-auth-helper.ps1
```

Expected: failure because the helper binary has not been built.

- [ ] **Step 3: Implement strict descriptor checks**

```pascal
DescriptorPath := GetEnvironmentVariable('CEA_MCP_DESCRIPTOR');
if DescriptorPath = '' then
  DescriptorPath := IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('LOCALAPPDATA')) +
    'CheatEngineAgent\runtime\mcp-32176.json';
if not FileExists(DescriptorPath) then Halt(2);
Descriptor := ReadBoundedJsonFile(DescriptorPath, 4096);
if Descriptor.Port <> 32176 then Halt(3);
if Descriptor.Pid = 0 then Halt(4);
if not IsOwnedByCurrentUser(DescriptorPath) then Halt(5);
WriteLn('{"Authorization":"Bearer ' + JsonEscape(Descriptor.Token) + '"}');
```

The helper writes nothing except header JSON to stdout. Errors go to stderr without token content. It verifies file owner, restrictive ACL, CE PID liveness, port and descriptor expiry.

- [ ] **Step 4: Implement idempotent project config installation**

```toml
[mcp_servers.cheat_engine_agent]
url = "http://127.0.0.1:32176/mcp"
http_headers_helper = "C:\\Users\\taitan666\\Downloads\\cheat-engine-7.5\\cheat-engine-agnet\\tools\\mcp-auth-helper\\cea_mcp_auth_helper.exe"
default_tools_approval_mode = "writes"
startup_timeout_sec = 10
tool_timeout_sec = 60
enabled = true
```

The installer resolves absolute paths, merges only `[mcp_servers.cheat_engine_agent]`, preserves other project settings, writes through a temporary sibling and atomically replaces `.codex/config.toml`. It prints that Codex must be restarted.

- [ ] **Step 5: Run helper/config tests and secret scan**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\mcp-auth-helper\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-mcp-auth-helper.ps1
rg -n "Bearer [A-Za-z0-9+/=_-]{16,}|fixture-token" .\.codex .\config .\docs
```

Expected: helper tests pass; the only `fixture-token` occurrence is inside the test fixture and no real bearer value exists.

### Task 6: Live Codex MCP verification

**Files:**
- Create: `tests/integration/test-codex-mcp.ps1`
- Create: `docs/delivery/codex-mcp-connection.md`
- Modify: `docs/delivery/verification-report.md`
- Modify: `docs/delivery/remaining-boundary.md`
- Modify: `tests/acceptance/requirements-traceability.md`

**Interfaces:**
- Consumes: running CE MCP server, built helper and project config.
- Produces: repeatable restart/preflight procedure and live Codex tool evidence.

- [ ] **Step 1: Implement pre-restart connection checks**

```powershell
$listener = Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 32176 -ErrorAction Stop
if (-not $listener) { throw 'CE MCP listener is not running' }
$headers = (& $helper | ConvertFrom-Json)
$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"preflight","version":"1"}}}'
$response = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:32176/mcp' -Headers @{Authorization=$headers.Authorization} -ContentType 'application/json' -Body $body
if (-not $response.result.serverInfo) { throw 'MCP initialize failed' }
```

- [ ] **Step 2: Install config and run preflight**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\codex\install-project-mcp.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-codex-mcp.ps1 -Mode Preflight
```

Expected: config is written without a token and initialize succeeds. Then restart Codex desktop; MCP tools cannot appear in the already-running tool catalog before this restart.

- [ ] **Step 3: Verify read-only calls from the restarted Codex task**

```text
Call cea.health and require status=ready.
Call cea.get_runtime_state and require mcp_enabled=true.
Call cea.list_processes and require redacted paths plus nonzero candidate count.
Import tests/fixtures/ct/minimal-valid.ct with cea.import_ct.
Call cea.search_ct and require source_uri plus sha256 content_hash.
```

Expected: each response validates against its output schema and contains no token or provider secret.

- [ ] **Step 4: Verify policy denials from Codex**

```text
Submit a memory write without local approval -> approval_required.
Request model_training -> policy_denied.
Request kernel_driver -> policy_denied.
Use a stale ProcessIdentity after detach/reattach -> stale_process_identity.
```

Expected: no target memory changes and each denial appears in the audit ledger.

- [ ] **Step 5: Complete the locally approved live path**

```text
Start the controlled self-target.
Use Codex cea.attach_process, cea.read_memory and cea.start_scan.
Use cea.request_memory_write with exact original/replacement bytes.
Approve once in the CE UI.
Poll cea.get_effect_status and require applied plus Receipt and passing Proof.
Use a second locally approved Effect to restore the original value.
Call cea.emergency_stop.
```

Expected: full path succeeds once, restoration succeeds, emergency stop revokes the session, and no implicit retry occurs.

- [ ] **Step 6: Run final verification and update evidence**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\schema-check\check-schemas.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\verify-scaffold.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\pascal\compile-smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-mcp-foundation.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-ce-runtime.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\integration\test-codex-mcp.ps1 -Mode Preflight
```

Expected: every automated command passes. Mark requirements implemented only when the corresponding live evidence IDs are recorded; retain any unexecuted authorized-game check as an explicit remaining boundary.
