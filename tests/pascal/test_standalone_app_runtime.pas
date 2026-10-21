program test_standalone_app_runtime;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows, fpjson, jsonparser, cea_types, cea_results,
  cea_application_runtime, cea_sqlite_store, cea_save_types,
  cea_save_discovery_types, cea_windows_sha256, cea_win32_engine_runtime,
  cea_win32_pointer_reader;

function WaitLocalScanReady(const ARuntime: TCEAStandaloneRuntime;
  const AScanId: string): TCEAResult;
var
  Data: TJSONData;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 10000;
  repeat
    Result := ARuntime.GetLocalValueScanStatus(AScanId);
    if Result.Failed then Exit;
    Data := GetJSON(Result.DataJson);
    try
      if TJSONObject(Data).Get('state', '') = 'ready' then Exit;
    finally
      Data.Free;
    end;
    Sleep(1);
  until GetTickCount64 >= Deadline;
  Result := TCEAResult.Error(rcTimeout, 'test_scan_timeout', '{}');
end;

function WaitMCPScanReady(const ARuntime: TCEAStandaloneRuntime;
  const AScanId: string): string;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 10000;
  repeat
    Result := ARuntime.HandleMCP('{"jsonrpc":"2.0","id":212,' +
      '"method":"tools/call","params":{"name":"cea.get_scan_status",' +
      '"arguments":{"scan_id":"' + AScanId + '"}}}');
    if Pos('"state":"ready"', Result) > 0 then Exit;
    Sleep(1);
  until GetTickCount64 >= Deadline;
end;

function FixtureSaveText(const Hp, Gold: Integer): string;
var
  Body: string;
  Hasher: TCEAWindowsSha256;
begin
  Body := 'CEA-SAVE-1' + #10 + '{"hp":' + IntToStr(Hp) +
    ',"gold":' + IntToStr(Gold) + '}';
  Hasher := TCEAWindowsSha256.Create;
  try
    Result := Body + #10 + Hasher.HashUtf8(Body) + #10;
  finally
    Hasher.Free;
  end;
end;

var
  ScanPage: Pointer;
  Runtime: TCEAStandaloneRuntime;
  R: TCEAResult;
  Response: string;
  ResponseData: TJSONData;
  ResultObject, StructuredObject, HealthObject, SearchObject: TJSONObject;
  EntryKey: string;
  EventId: string;
  LocalScanId: string;
  LocalScopeId: string;
  RevokedScopeId: string;
  MCPScanArguments: string;
  MCPRefineArguments: string;
  DatabasePath: string;
  DataDirectory: string;
  Identity: TCEProcessIdentity;
  Effect: TCEAEffect;
  FreezeEffect: TCEAEffect;
  RecoveryEffect, RecoveredEffect: TCEAEffect;
  RecoveryStore: TCEASqliteStore;
  Value: array[0..3] of Byte;
  SaveSnapshot: TCEASaveSnapshot;
  DiscoverySnapshot: TCEASaveSnapshot;
  DiscoveryProposal: TCEASaveEditProposal;
  DiscoveryBudget: TCEADiscoveryBudget;
  DiscoveryScope: TCEADiscoveryScope;
  DiscoveryCandidates: TCEASaveCandidateArray;
  DiscoveryEffectId, DiscoveryRoot, DiscoverySavePath: string;
  SessionDiscoveryEffectId: string;
  DiscoveryBackupId, DiscoveryEditId: string;
  RevokedDiscoveryEffectId: string;
  DiscoveryStream: TFileStream;
  DiscoveryIndex: Integer;
  DiscoveryGuid: TGUID;
  AobScanId: string;
  AobPattern: string;
  AobIndex: Integer;
  // A 16-byte marker written into this program's own module image at run time:
  // the local AOB scan walks the module and must find it exactly once.
  AobMarker: array[0..15] of Byte;
  ChainReader: TCEAWin32PointerReader;
  ChainModuleBase, ChainOffset: QWord;
  ChainSpec: string;
  // A slot inside this program's own module image: the chain reads the pointer
  // from there, exactly like a game's singleton pointer.
  ChainSlot: Pointer;
  ChainValueA, ChainValueB: DWord;
  RoundId: string;
  GoalId: string;

begin
  // The runtime derives its sibling stores (events/ui-pages) from the database
  // directory, so every run needs its own directory: a leftover ui-pages
  // database would make the version counters start above 1.
  DataDirectory := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'cea-app-runtime-' + IntToStr(GetProcessID) + '-' +
    IntToStr(GetTickCount64);
  ForceDirectories(DataDirectory);
  DatabasePath := IncludeTrailingPathDelimiter(DataDirectory) + 'agentos.sqlite3';
  SysUtils.DeleteFile(DatabasePath);
  Value[0] := $10; Value[1] := $20; Value[2] := $30; Value[3] := $40;
  Runtime := TCEAStandaloneRuntime.Create(DatabasePath,
    30000 + Word(GetProcessID mod 20000));
  try
    R := Runtime.Start;
    Assert(R.Code = rcOk, 'standalone runtime starts');
    Assert(Runtime.Started, 'standalone runtime exposes started state');
    R := Runtime.ConfigureLLM('https://api.deepseek.com/anthropic/v1/messages',
      'deepseek-flash', 'cred:test-anthropic', 'anthropic-compatible');
    Assert((R.Code = rcOk) and
      (Pos('anthropic-compatible', R.DataJson) > 0),
      'runtime explicitly selects the Anthropic-compatible adapter');
    Assert(Runtime.ConfigureLLM('https://example.invalid/v1', 'model',
      'cred:test', 'unknown-provider').Code = rcInvalidArgument,
      'runtime rejects an unknown provider adapter');
    Assert(Runtime.InspectSaveFile('save-mcp-test', ExpandFileName(
      'tests\fixtures\ct\minimal-valid.ct'), SaveSnapshot).Code = rcOk);
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":101,"method":"tools/call",' +
      '"params":{"name":"cea.get_save_snapshot","arguments":{}}}');
    Assert((Pos(SaveSnapshot.Sha256, Response) > 0) and
      (Pos('<CheatTable', Response) = 0) and
      (Pos('minimal-valid.ct', Response) = 0),
      'MCP save snapshot returns only bounded metadata');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":102,"method":"tools/call",' +
      '"params":{"name":"cea.approve_save_edit","arguments":{}}}');
    Assert(Pos('tool_not_found', Response) > 0,
      'MCP cannot approve a save edit');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":103,"method":"tools/call",' +
      '"params":{"name":"cea.propose_save_edit","arguments":{' +
      '"field_path":"/hp","expected_json":"400",' +
      '"new_json":"500"}}}');
    Assert(Pos('save_edit_format_unknown', Response) > 0,
      'unknown format cannot generate an edit proposal');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":104,"method":"tools/call",' +
      '"params":{"name":"cea.request_save_backup","arguments":{' +
      '"task_id":"mcp-save-backup-test"}}}');
    Assert((Pos('effect_id', Response) > 0) and
      (Pos('minimal-valid.ct', Response) = 0),
      'MCP can only plan a backup of the locally selected save');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"cea.health","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      ResultObject := TJSONObject(ResponseData).Objects['result'];
      StructuredObject := ResultObject.Objects['structuredContent'];
      HealthObject := StructuredObject.Objects['data'];
      Assert(not ResultObject.Get('isError', True),
        'standalone runtime serves MCP health through the real protocol');
      Assert(HealthObject.Get('status', '') = 'ready',
        'standalone runtime health is ready');
    finally
      ResponseData.Free;
    end;
    R := Runtime.ImportCTFile(ExpandFileName(
      'tests\fixtures\ct\aob-and-pointer.ct'));
    Assert(R.Code = rcOk, 'standalone runtime imports local CT as RAG');
    R := Runtime.BuildCTRagContext('Synthetic AOB', 10);
    Assert((R.Code = rcOk) and (Pos('content_hash', R.DataJson) > 0) and
      (Pos('authority', R.DataJson) > 0),
      'standalone CT RAG retains hash and no-authority marker');
    R := Runtime.SearchCT('Synthetic AOB', 10);
    ResponseData := GetJSON(R.DataJson);
    try
      SearchObject := TJSONObject(ResponseData);
      EntryKey := SearchObject.Arrays['results'].Objects[0].Get(
        'entry_key', '');
    finally
      ResponseData.Free;
    end;
    R := Runtime.GetCTEntry(EntryKey);
    Assert((R.Code = rcOk) and (Pos('Synthetic AOB', R.DataJson) > 0),
      'runtime retrieves one exact CT entry');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
      '"params":{"name":"cea.search_ct","arguments":{' +
      '"query":"Synthetic AOB","max_results":10}}}');
    Assert((Pos('Synthetic AOB', Response) > 0) and
      (Pos('content_hash', Response) > 0),
      'MCP can retrieve provenance-bound CT evidence');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":20,"method":"tools/call",' +
      '"params":{"name":"cea.get_ct_entry","arguments":{' +
      '"entry_key":"' + EntryKey + '"}}}');
    Assert((Pos('Synthetic AOB', Response) > 0) and
      (Pos('not_implemented', Response) = 0),
      'MCP exact CT entry tool is operational');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":205,"method":"tools/call",' +
      '"params":{"name":"cea.scan_save_directory","arguments":{}}}');
    Assert(Pos('tool_not_found', Response) > 0,
      'MCP cannot authorize or start save directory discovery');
    Assert(CreateGUID(DiscoveryGuid) = 0,
      'unique discovery test directory id created');
    DiscoveryRoot := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'cea-runtime-discovery-' + GUIDToString(DiscoveryGuid);
    Assert(ForceDirectories(DiscoveryRoot),
      'private discovery test directory exists');
    DiscoverySavePath := IncludeTrailingPathDelimiter(DiscoveryRoot) +
      'slot.sav';
    DiscoveryStream := TFileStream.Create(DiscoverySavePath, fmCreate);
    try
      Response := FixtureSaveText(400, 900);
      DiscoveryStream.WriteBuffer(Response[1], Length(Response));
    finally
      DiscoveryStream.Free;
    end;
    DiscoveryBudget.MaxFiles := 10;
    DiscoveryBudget.MaxDepth := 1;
    DiscoveryBudget.MaxDurationMs := 5000;
    Assert(Runtime.AuthorizeSaveDirectory(DiscoveryRoot,
      DiscoveryBudget, DiscoveryScope).Code = rcOk,
      'local operator authorizes one save directory');
    Assert(Runtime.ScanSaveDirectory(DiscoveryScope.Id,
      DiscoveryCandidates).Code = rcOk,
      'authorized save directory yields metadata candidates');
    Assert(Length(DiscoveryCandidates) = 1,
      'fixture directory contains one candidate');
    DiscoveryIndex := 0;
    Assert(Runtime.SelectSaveCandidate(DiscoveryScope.Id,
      DiscoveryCandidates[DiscoveryIndex].Id,
      DiscoverySnapshot).Code = rcOk,
      'selected candidate undergoes existing save inspection');
    Assert(DiscoverySnapshot.FileIdentityId =
      DiscoveryCandidates[DiscoveryIndex].FileIdentityId,
      'inspected snapshot retains the enumerated file identity');
    Assert(Runtime.RequestSaveBackup('task-discovery-backup',
      DiscoverySnapshot, DiscoveryEffectId).Code = rcApprovalRequired,
      'discovered save backup is only planned');
    Assert(Runtime.RevokeSaveDirectory(DiscoveryScope.Id).Code = rcOk,
      'local operator revokes directory scope');
    Assert(Runtime.LoadEffect(DiscoveryEffectId, Effect).Code = rcOk,
      'discovery backup remains durably queryable after revocation');
    Assert(Effect.State = esRejected,
      'revocation durably rejects a planned discovery Effect');
    RevokedDiscoveryEffectId := DiscoveryEffectId;
    Assert(Runtime.SelectSaveCandidate(DiscoveryScope.Id,
      DiscoveryCandidates[DiscoveryIndex].Id,
      DiscoverySnapshot).Code <> rcOk,
      'revoked candidate cannot be selected');
    Assert(Runtime.ApproveAndExecute(DiscoveryEffectId).Code <> rcOk,
      'revocation blocks a planned backup from that scope');
    Assert(Runtime.InspectSaveFile('task-direct-save', DiscoverySavePath,
      DiscoverySnapshot).Code = rcOk,
      'direct single-file inspection remains available after revocation');
    Assert(Runtime.RequestSaveBackup('task-direct-backup',
      DiscoverySnapshot, DiscoveryEffectId).Code = rcApprovalRequired,
      'fresh direct-file selection remains plan-capable');
    Assert((DiscoveryEffectId <> RevokedDiscoveryEffectId) and
      (Runtime.LoadEffect(DiscoveryEffectId, Effect).Code = rcOk) and
      (Effect.State = esPlanned),
      'new task receives a fresh direct-file Effect after revoked plan');
    R := Runtime.RejectEffect(DiscoveryEffectId);
    if R.Code <> rcOk then
      WriteLn('DIRECT_SAVE_REJECT_DIAGNOSTIC effect=', DiscoveryEffectId,
        ' code=', Ord(R.Code), ' stable=', R.StableCode);
    Assert(R.Code = rcOk,
      'direct-file test plan is closed without execution');
    Assert(Runtime.AuthorizeSaveDirectory(DiscoveryRoot,
      DiscoveryBudget, DiscoveryScope).Code = rcOk,
      'edit-revocation discovery scope is authorized');
    Assert(Runtime.ScanSaveDirectory(DiscoveryScope.Id,
      DiscoveryCandidates).Code = rcOk,
      'edit-revocation scope can scan');
    Assert(Runtime.SelectSaveCandidate(DiscoveryScope.Id,
      DiscoveryCandidates[0].Id, DiscoverySnapshot).Code = rcOk,
      'fixture candidate is selected for edit-revocation coverage');
    Assert(Runtime.RequestSaveBackup('task-discovery-edit-backup',
      DiscoverySnapshot, DiscoveryBackupId).Code = rcApprovalRequired,
      'discovered fixture backup is planned');
    Assert(Runtime.ApproveAndExecute(DiscoveryBackupId).Code = rcOk,
      'fixture backup is verified before edit planning');
    Assert(Runtime.ProposeSaveFieldEdit(DiscoverySnapshot, '/hp', '400',
      '401', DiscoveryProposal).Code = rcOk,
      'fixture edit proposal is structurally valid');
    Assert(Runtime.PlanSaveEdit('task-discovery-edit', DiscoverySnapshot,
      DiscoveryProposal, DiscoveryBackupId,
      DiscoveryEditId).Code = rcApprovalRequired,
      'discovered fixture edit remains planned');
    Assert(Runtime.RevokeSaveDirectory(DiscoveryScope.Id).Code = rcOk,
      'revoking fixture discovery scope succeeds');
    Assert((Runtime.LoadEffect(DiscoveryEditId, Effect).Code = rcOk) and
      (Effect.State = esRejected),
      'revocation durably rejects a planned discovered edit');
    Assert(Runtime.ApproveAndExecute(DiscoveryEditId).Code <> rcOk,
      'revoked discovered edit cannot execute');
    Assert(Runtime.AuthorizeSaveDirectory(DiscoveryRoot,
      DiscoveryBudget, DiscoveryScope).Code = rcOk,
      'new session-only discovery scope is authorized');
    Assert(Runtime.ScanSaveDirectory(DiscoveryScope.Id,
      DiscoveryCandidates).Code = rcOk,
      'new session-only scope can scan');
    Assert(Runtime.SelectSaveCandidate(DiscoveryScope.Id,
      DiscoveryCandidates[0].Id, DiscoverySnapshot).Code = rcOk,
      'new session-only candidate can be selected');
    R := Runtime.RequestSaveBackup('task-session-discovery-backup',
      DiscoverySnapshot, SessionDiscoveryEffectId);
    Assert(R.Code = rcApprovalRequired,
      'session-only discovery backup remains planned');
    Runtime.Stop;
    Assert(Runtime.Start.Code = rcOk,
      'runtime restarts after closing discovery authority');
    Assert((Runtime.LoadEffect(SessionDiscoveryEffectId, Effect).Code = rcOk) and
      (Effect.State = esRejected),
      'application stop durably rejects pending discovery Effects');
    Assert(Runtime.AttachAuthorizedOffline('task-app-runtime',
      GetCurrentProcessId, Identity).Code = rcOk,
      'standalone runtime attaches authorized self-test process');
    ScanPage := VirtualAlloc(nil, 4096, MEM_RESERVE or MEM_COMMIT,
      PAGE_READWRITE);
    Assert(ScanPage <> nil, 'private scan page allocated');
    try
      PCardinal(ScanPage)^ := 767;
      R := Runtime.StartLocalValueScan('0x' +
        IntToHex(QWord(PtrUInt(ScanPage)), 16), SizeOf(Cardinal),
        'dword', '767', 10);
      Assert((R.Code = rcOk) and
        (Pos('"state":"running"', R.DataJson) > 0),
        'local numeric scan binds explicit scope and starts in background');
      ResponseData := GetJSON(R.DataJson);
      try
        LocalScanId := TJSONObject(ResponseData).Get('scan_id', '');
      finally
        ResponseData.Free;
      end;
      Assert(LocalScanId <> '', 'local numeric scan returns session id');
      R := WaitLocalScanReady(Runtime, LocalScanId);
      Assert((R.Code = rcOk) and
        (Pos('"match_count":1', R.DataJson) > 0) and
        (Pos('"complete":true', R.DataJson) > 0),
        'background numeric scan returns complete coverage');
      PCardinal(ScanPage)^ := 758;
      R := Runtime.RefineLocalValueScan(LocalScanId, '758');
      Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
        'local refinement keeps the same candidate after 767 to 758');
      PCardinal(ScanPage)^ := 880;
      R := Runtime.RefineLocalValueScan(LocalScanId, '880');
      Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
        'local refinement keeps the same candidate after 758 to 880');
      Assert(Runtime.CancelLocalValueScan(LocalScanId).Code = rcOk,
        'local numeric scan can be cancelled');
      Assert(Runtime.RefineLocalValueScan(LocalScanId, '880').Code <> rcOk,
        'cancelled local scan cannot be refined');
      R := Runtime.StartProcessValueScan('private', 8192, 'dword',
        '3735928559', 10);
      Assert((R.Code = rcOk) and
        (Pos('"state":"running"', R.DataJson) > 0),
        'local process-level private scan starts from an authorized plan');
      ResponseData := GetJSON(R.DataJson);
      try
        LocalScanId := TJSONObject(ResponseData).Get('scan_id', '');
      finally
        ResponseData.Free;
      end;
      R := WaitLocalScanReady(Runtime, LocalScanId);
      Assert((R.Code = rcOk) and
        (Pos('"partial_reason":"byte_limit"', R.DataJson) > 0),
        'process-level byte-budget truncation remains visible');
      Assert(Runtime.CancelLocalValueScan(LocalScanId).Code = rcOk,
        'process-level local scan can be cancelled');
      R := Runtime.StartLocalValueScan('0x' +
        IntToHex(QWord(PtrUInt(ScanPage)), 16), SizeOf(Cardinal),
        'dword', '880', 10);
      Assert(R.Code = rcOk, 'second local scan starts');
      Assert(EngineRuntime.Processes.Detach(Identity).Code = rcOk,
        'operator detaches while local scan session exists');
      Assert(Runtime.AttachAuthorizedOffline('task-app-runtime-reattach',
        GetCurrentProcessId, Identity).Code = rcOk,
        'operator reattaches the same process');
      R := Runtime.StartLocalValueScan('0x' +
        IntToHex(QWord(PtrUInt(ScanPage)), 16), SizeOf(Cardinal),
        'dword', '880', 10);
      Assert(R.Code = rcOk,
        'reattach invalidates stale UI scan before a new start');
      ResponseData := GetJSON(R.DataJson);
      try
        LocalScanId := TJSONObject(ResponseData).Get('scan_id', '');
      finally
        ResponseData.Free;
      end;
      Assert(Runtime.CancelLocalValueScan(LocalScanId).Code = rcOk,
        'reattached local scan can be cancelled');

      R := Runtime.AuthorizeLocalValueScanScope('0x' +
        IntToHex(QWord(PtrUInt(ScanPage)), 16), SizeOf(Cardinal), 10);
      Assert(R.Code = rcOk, 'local operator separately authorizes MCP scope');
      ResponseData := GetJSON(R.DataJson);
      try
        LocalScopeId := TJSONObject(ResponseData).Get('scope_id', '');
      finally
        ResponseData.Free;
      end;
      Assert(LocalScopeId <> '', 'local authorization returns opaque scope id');
      RevokedScopeId := LocalScopeId;
      Assert(Runtime.RevokeLocalValueScanScope(LocalScopeId).Code = rcOk,
        'unused local scope can be revoked');
      MCPScanArguments := '{"task_id":"task-mcp-value",' +
        '"process_identity_ref":"' + Identity.Id + '",' +
        '"lease_ref":"lease-mcp-value",' +
        '"scan_kind":"value","value_type":"dword",' +
        '"value":"880","scope_id":"' + LocalScopeId + '",' +
        '"epoch":' + IntToStr(Identity.Epoch) + ',' +
        '"budget":{"max_bytes":4,"max_results":10},' +
        '"ranges":[{"start":"0x' +
          IntToHex(QWord(PtrUInt(ScanPage)), 16) + '","size":4}]}';
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":210,' +
        '"method":"tools/call","params":{"name":"cea.start_scan",' +
        '"arguments":' + MCPScanArguments + '}}');
      Assert(Pos('local_scan_scope_required', Response) > 0,
        'revoked scope cannot start an MCP scan');
      R := Runtime.AuthorizeLocalValueScanScope('0x' +
        IntToHex(QWord(PtrUInt(ScanPage)), 16), SizeOf(Cardinal), 10);
      Assert(R.Code = rcOk, 'operator can authorize a fresh scope');
      ResponseData := GetJSON(R.DataJson);
      try
        LocalScopeId := TJSONObject(ResponseData).Get('scope_id', '');
      finally
        ResponseData.Free;
      end;
      MCPScanArguments := StringReplace(MCPScanArguments,
        '"scope_id":"' + RevokedScopeId + '"',
        '"scope_id":"' + LocalScopeId + '"', []);
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":209,' +
        '"method":"tools/call","params":{"name":"cea.start_scan",' +
        '"arguments":' + StringReplace(MCPScanArguments,
          '"max_bytes":4', '"max_bytes":5', []) + '}}');
      Assert(Pos('local_scan_scope_required', Response) > 0,
        'MCP cannot raise the locally authorized byte budget');
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":208,' +
        '"method":"tools/call","params":{"name":"cea.start_scan",' +
        '"arguments":' + StringReplace(MCPScanArguments,
          '"epoch":' + IntToStr(Identity.Epoch),
          '"epoch":' + IntToStr(Identity.Epoch + 1), []) + '}}');
      Assert(Pos('scan_target_changed', Response) > 0,
        'MCP cannot scan using a stale Epoch');
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":211,' +
        '"method":"tools/call","params":{"name":"cea.start_scan",' +
        '"arguments":' + MCPScanArguments + '}}');
    ResponseData := GetJSON(Response);
      try
        LocalScanId := ResponseData.FindPath(
          'result.structuredContent.data.scan_id').AsString;
        Assert(ResponseData.FindPath(
          'result.structuredContent.data.state').AsString = 'running',
          'MCP starts numeric scan in the background');
      finally
        ResponseData.Free;
      end;
      Assert(LocalScanId <> '', 'MCP scan returns active session id');
      Response := WaitMCPScanReady(Runtime, LocalScanId);
    ResponseData := GetJSON(Response);
      try
        Assert(ResponseData.FindPath(
          'result.structuredContent.data.match_count').AsInteger = 1,
          'MCP background scan stays inside locally authorized scope');
      finally
        ResponseData.Free;
      end;
      PCardinal(ScanPage)^ := 881;
      MCPRefineArguments := StringReplace(MCPScanArguments,
        '{"task_id"', '{"scan_id":"' + LocalScanId + '","task_id"',
        []);
      MCPRefineArguments := StringReplace(MCPRefineArguments,
        '"value":"880"', '"value":"881"', []);
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":214,' +
        '"method":"tools/call","params":{"name":"cea.refine_scan",' +
        '"arguments":' + MCPRefineArguments + '}}');
    ResponseData := GetJSON(Response);
      try
        Assert(ResponseData.FindPath(
          'result.structuredContent.data.match_count').AsInteger = 1,
          'MCP refines within the original scope and candidate set');
      finally
        ResponseData.Free;
      end;
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":212,' +
        '"method":"tools/call","params":{"name":"cea.get_scan_status",' +
        '"arguments":{"scan_id":"' + LocalScanId + '"}}}');
      Assert(Pos('inspected_bytes', Response) > 0,
        'MCP status projects observed scan coverage');
      Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":213,' +
        '"method":"tools/call","params":{"name":"cea.cancel_scan",' +
        '"arguments":{"scan_id":"' + LocalScanId + '"}}}');
      Assert(Pos('cancelled', Response) > 0,
        'MCP cancels the authorized scan session');
    finally
      VirtualFree(ScanPage, 0, MEM_RELEASE);
    end;

    { AOB signature scan end to end: the real-game workflow is "find the
      instruction that touches this value, then anchor writes on its signature",
      and that only works when the signature is unique. The marker is generated
      at run time and written into this program's own module image; the pattern
      text is assembled from those bytes at run time too, because a Pascal
      literal would also live in .rdata and turn one hit into two. }
    for AobIndex := 0 to High(AobMarker) do
      AobMarker[AobIndex] := Byte($A5 + AobIndex * 7);
    AobPattern := '';
    for AobIndex := 0 to High(AobMarker) do
    begin
      if AobIndex > 0 then AobPattern := AobPattern + ' ';
      AobPattern := AobPattern + IntToHex(AobMarker[AobIndex], 2);
    end;
    Assert(Runtime.StartAobScan('', AobPattern, 1024 * 1024, 10).Code <>
      rcOk, 'an AOB scan without a module is rejected');
    R := Runtime.StartAobScan(ExtractFileName(ParamStr(0)), AobPattern,
      16 * 1024 * 1024, 100);
    Assert((R.Code = rcOk) and (Pos('"state":"running"', R.DataJson) > 0),
      'AOB scan starts inside the named module: ' + R.StableCode + ' ' +
      R.DataJson);
    ResponseData := GetJSON(R.DataJson);
    try
      AobScanId := TJSONObject(ResponseData).Get('scan_id', '');
    finally
      ResponseData.Free;
    end;
    Assert(AobScanId <> '', 'AOB scan returns a session id');
    R := WaitLocalScanReady(Runtime, AobScanId);
    Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
      'AOB scan finds the marker exactly once: ' + R.DataJson);
    R := Runtime.GetAobScanUniqueness(AobScanId);
    Assert((R.Code = rcOk) and
      (Pos('"verdict":"unique"', R.DataJson) > 0) and
      (Pos('"writable_anchor":true', R.DataJson) > 0),
      'a unique signature becomes a writable anchor: ' + R.DataJson);
    Assert((Pos('"module":"0x', R.DataJson) > 0) and
      (Pos('"pattern":"' + AobPattern + '"', R.DataJson) > 0),
      'local uniqueness reports the module base and pattern it used: ' +
      R.DataJson);
    // The MCP surface may ask the same read-only question, but it must never
    // be the one that starts the scan (that needs local authorization).
    Response := Runtime.HandleMCP('{"jsonrpc":"2.0","id":45,' +
      '"method":"tools/call","params":{"name":"cea.judge_aob_uniqueness",' +
      '"arguments":{"scan_id":"' + AobScanId + '"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.verdict').AsString = 'unique',
        'MCP can judge an existing scan: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.writable_anchor').AsBoolean,
        'MCP judgement agrees the anchor is writable');
    finally
      ResponseData.Free;
    end;
    Assert(Runtime.CancelLocalValueScan(AobScanId).Code = rcOk,
      'AOB scan session can be cancelled');
    Assert(Runtime.GetAobScanUniqueness(AobScanId).Code <> rcOk,
      'a cancelled AOB session is no longer judged');

    { A signature that matches many places is not an anchor: "00 00" is
      everywhere in a module image, so the verdict must be ambiguous rather than
      quietly picking the first hit. }
    R := Runtime.StartAobScan(ExtractFileName(ParamStr(0)), '00 00',
      16 * 1024 * 1024, 100);
    Assert(R.Code = rcOk, 'an ambiguous signature still scans: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      AobScanId := TJSONObject(ResponseData).Get('scan_id', '');
    finally
      ResponseData.Free;
    end;
    R := WaitLocalScanReady(Runtime, AobScanId);
    Assert((R.Code = rcOk) and (Pos('"match_count":100', R.DataJson) > 0),
      'the ambiguous scan saturates the result budget: ' + R.DataJson);
    R := Runtime.GetAobScanUniqueness(AobScanId);
    Assert((R.Code = rcOk) and
      (Pos('"verdict":"ambiguous"', R.DataJson) > 0) and
      (Pos('"writable_anchor":false', R.DataJson) > 0),
      'an ambiguous signature is refused as a write anchor: ' + R.DataJson);
    Assert(Runtime.CancelLocalValueScan(AobScanId).Code = rcOk,
      'ambiguous AOB scan session can be cancelled');
    R := Runtime.PlanMemoryWrite('task-app-write',
      '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)),
      '10203040', 'a1b2c3d4', Effect);
    if R.Code <> rcApprovalRequired then
      WriteLn('APP_PLAN_DIAGNOSTIC stable=', R.StableCode,
        ' data=', R.DataJson, ' effect=', Effect.Id);
    Assert(R.Code = rcApprovalRequired,
      'standalone runtime plans write before execution');
    Assert(Value[0] = $10, 'planning cannot mutate target memory');
    R := Runtime.ApproveAndExecute(Effect.Id);
    if R.Code <> rcOk then
      WriteLn('APP_EFFECT_DIAGNOSTIC stable=', R.StableCode,
        ' data=', R.DataJson, ' receipt=', R.ReceiptId,
        ' proof=', R.ProofId);
    Assert((R.Code = rcOk) and (R.ReceiptId <> '') and (R.ProofId <> ''),
      'local approval executes with Receipt and Proof');
    Assert((Value[0] = $A1) and (Value[3] = $D4),
      'standalone governed effect changes exact bytes');
    R := Runtime.PlanMemoryWrite('task-app-restore',
      '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)),
      'a1b2c3d4', '10203040', Effect);
    Assert(R.Code = rcApprovalRequired, 'restore is separately planned');
    Assert(Runtime.ApproveAndExecute(Effect.Id).Code = rcOk,
      'restore requires and receives separate approval');
    Assert(Value[0] = $10, 'self-test memory is restored');

    R := Runtime.PlanMemoryFreeze('task-app-freeze',
      '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)),
      '10203040', 'a1b2c3d4', 100, 2, 60, FreezeEffect);
    Assert(R.Code = rcApprovalRequired,
      'bounded freeze is planned before activation');
    Assert(Value[0] = $10, 'freeze planning cannot mutate memory');
    Assert(Runtime.ApproveAndStartFreeze(FreezeEffect.Id).Code = rcOk,
      'local approval activates the bounded freeze session');
    Assert(Value[0] = $10, 'freeze activation itself cannot mutate memory');
    R := Runtime.TickFreeze;
    Assert((R.Code = rcOk) and (Value[0] = $A1) and
      (R.ReceiptId <> '') and (R.ProofId <> ''),
      'first freeze tick writes with durable evidence');
    Value[0] := $10; Value[1] := $20; Value[2] := $30; Value[3] := $40;
    R := Runtime.TickFreeze;
    Assert((R.Code = rcOk) and (Value[0] = $A1),
      'second permitted tick reapplies the exact value');
    Assert(not Runtime.FreezeActive,
      'max-write budget closes the runtime freeze session');
    Assert(Runtime.LoadEffect(FreezeEffect.Id, Effect).Code = rcOk,
      'closed freeze Effect remains queryable');
    Assert((Effect.State = esApplied) and
      (Pos('max_writes_reached', Effect.ResultJson) > 0),
      'freeze budget completion is durable');
    R := Runtime.PlanMemoryWrite('task-app-freeze-restore',
      '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)),
      'a1b2c3d4', '10203040', Effect);
    Assert((R.Code = rcApprovalRequired) and
      (Runtime.ApproveAndExecute(Effect.Id).Code = rcOk),
      'post-freeze restore is a separately approved Effect');
    Assert(Value[0] = $10, 'post-freeze self-test memory is restored');

    { Player-level MCP surface (PRD 6.x). Reads are allowed, every mutating
      player action must come back as a local-only approval request, and the
      governed write path stays unreachable from MCP. }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":31,"method":"tools/call",' +
      '"params":{"name":"cea.start_game_session","arguments":{' +
      '"game_name":"Self Test Game","game_version":"1.0"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.target_pid').AsInteger =
        Integer(GetCurrentProcessId),
        'MCP starts a player session on the attached target: ' + Response);
    finally
      ResponseData.Free;
    end;
    Assert(Runtime.GameSessionActive, 'player session is active after MCP start');
    R := Runtime.DeclareField('test.gold', 'Gold', 'dword',
      '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)));
    Assert(R.Code = rcOk, 'operator declares a field locally');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":32,"method":"tools/call",' +
      '"params":{"name":"cea.list_game_fields","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.fields').Items[0].FindPath(
        'field_id').AsString = 'test.gold',
        'MCP lists the declared field');
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.fields').Items[0].FindPath(
        'access').AsString = 'read_only',
        'declared fields stay read-only until verified');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":33,"method":"tools/call",' +
      '"params":{"name":"cea.declare_field","arguments":{' +
      '"field_id":"test.hp","display_name":"HP","value_type":"dword",' +
      '"address":"0x1000"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot declare a field on its own');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":34,"method":"tools/call",' +
      '"params":{"name":"cea.write_field_value","arguments":{' +
      '"field_id":"test.gold","target_value":"99",' +
      '"expected_current_value":"1"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP field write is only an approval request');
    Assert(Value[0] = $10, 'MCP cannot write through the field command bus');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":35,"method":"tools/call",' +
      '"params":{"name":"cea.capture_field_value","arguments":{' +
      '"field_id":"test.gold"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.field_id').AsString = 'test.gold',
        'MCP rereads the field from target memory');
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.bytes_hex').AsString = '10203040',
        'MCP capture returns the exact observed bytes');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":36,"method":"tools/call",' +
      '"params":{"name":"cea.build_ui_render_json","arguments":{' +
      '"page_title":"Self Test"}}}');
    Assert((Pos('"components"', Response) > 0) and
      (Pos('test.gold', Response) > 0),
      'MCP can build the secondary-screen render model');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":37,"method":"tools/call",' +
      '"params":{"name":"cea.mark_event","arguments":{' +
      '"tag":"mcp-mark"}}}');
    ResponseData := GetJSON(Response);
    try
      EventId := ResponseData.FindPath(
        'result.structuredContent.data.event_id').AsString;
    finally
      ResponseData.Free;
    end;
    Assert(Copy(EventId, 1, 6) = 'event-', 'MCP can mark a timeline event');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":38,"method":"tools/call",' +
      '"params":{"name":"cea.list_events","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger >= 1,
        'MCP lists recorded events');
      EventId := ResponseData.FindPath(
        'result.structuredContent.data.events').Items[0].FindPath(
        'event_id').AsString;
    finally
      ResponseData.Free;
    end;
    Assert(EventId <> '', 'listed event carries an id');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":39,"method":"tools/call",' +
      '"params":{"name":"cea.delete_event","arguments":{' +
      '"event_id":"' + EventId + '"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.event_id').AsString = EventId,
        'MCP can delete a recorded event');
    finally
      ResponseData.Free;
    end;
    { 事件录像与唤醒队列（FR-071/074/077/079）。这里只断言确定性部分：
      录像需要真实可见的游戏窗口，测试进程没有游戏窗口，所以开启录像要么
      成功（本机控制台窗口恰好可见）要么明确报 window_not_found —— 两者都
      是正确行为，不允许的是「静默失败」。 }
    R := Runtime.ListRecordingSegments;
    Assert(R.Code = rcOk, 'list segments before recording: ' + R.StableCode);
    Assert(Pos('"active":false', R.DataJson) > 0,
      'no recording session is active yet: ' + R.DataJson);
    Assert(Pos('"count":0', R.DataJson) > 0,
      'nothing has been captured yet: ' + R.DataJson);

    R := Runtime.StartEventRecording('', 500, 300000, QWord(64) * 1024 * 1024, 0);
    if R.Code = rcOk then
    begin
      Assert(Runtime.EventRecordingActive, 'recording reports itself active');
      Assert(Runtime.EventRecordingEndpoint <> '',
        'active recording exposes its storage directory');
      R := Runtime.ListRecordingSegments;
      Assert((R.Code = rcOk) and (Pos('"active":true', R.DataJson) > 0),
        'segments list follows the recording state: ' + R.DataJson);
      Runtime.StopEventRecording;
      Assert(not Runtime.EventRecordingActive, 'stop really stops recording');
    end
    else
    begin
      // 没有可见窗口时必须给出稳定码，而不是 rcOk + 空录像。
      Assert(Pos('window_not_found', R.StableCode) > 0,
        'recording without a game window fails with a stable code: ' +
        R.StableCode);
      Assert(not Runtime.EventRecordingActive,
        'a failed start leaves recording off');
    end;

    { 唤醒队列：排队只表示「值得让模型看」，队列自己绝不调用模型。
      同一事件重复排队不重复占位（上游已做冷却与合并）。 }
    R := Runtime.QueueEventForAnalysis('event-does-not-exist');
    Assert((R.Code = rcUnknown) and (R.StableCode = 'event_not_found'),
      'unknown events cannot be queued: ' + R.StableCode);
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":54,"method":"tools/call",' +
      '"params":{"name":"cea.mark_event","arguments":{"tag":"queue-me"}}}');
    ResponseData := GetJSON(Response);
    try
      EventId := ResponseData.FindPath(
        'result.structuredContent.data.event_id').AsString;
    finally
      ResponseData.Free;
    end;
    R := Runtime.QueueEventForAnalysis(EventId);
    Assert(R.Code = rcOk, 'event can be queued for analysis: ' + R.StableCode);
    Assert(Pos('"analysis_state":"queued"', R.DataJson) > 0,
      'queued event is marked as queued: ' + R.DataJson);
    R := Runtime.PeekAnalysisQueue;
    Assert(R.Code = rcOk, 'peek queue: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('queued').AsInteger >= 1,
        'queue holds the pending event: ' + R.DataJson);
      Assert(ResponseData.FindPath('next_event_id').AsString = EventId,
        'queue head is the event we just queued: ' + R.DataJson);
    finally
      ResponseData.Free;
    end;
    { 再次排队同一事件：仍在队里，但不重复占位。 }
    R := Runtime.QueueEventForAnalysis(EventId);
    Assert(R.Code = rcOk, 're-queueing is accepted: ' + R.StableCode);
    R := Runtime.PeekAnalysisQueue;
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('queued').AsInteger = 1,
        'the same event is never queued twice: ' + R.DataJson);
    finally
      ResponseData.Free;
    end;
    { MCP 面：开启/停止录像与锁定片段都会驱动真实抓帧或改保留策略 → 审批；
      查看队列与片段列表只读 → 直接执行。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":55,"method":"tools/call",' +
      '"params":{"name":"cea.start_event_recording","arguments":{}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot start recording on its own: ' + Response);
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":56,"method":"tools/call",' +
      '"params":{"name":"cea.stop_event_recording","arguments":{}}}');
    Assert(Pos('approval_required', Response) > 0,
      'MCP cannot stop recording on its own: ' + Response);
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":57,"method":"tools/call",' +
      '"params":{"name":"cea.lock_recording_segment","arguments":' +
      '{"segment_id":"seg-00000001","locked":true}}}');
    Assert(Pos('approval_required', Response) > 0,
      'MCP cannot pin a segment on its own: ' + Response);
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":58,"method":"tools/call",' +
      '"params":{"name":"cea.peek_analysis_queue","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.queued').AsInteger >= 1,
        'MCP can read the pending queue: ' + Response);
    finally
      ResponseData.Free;
    end;
    { 队列只是本地待办，任何模型调用都必须由本地操作者发起。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":59,"method":"tools/call",' +
      '"params":{"name":"cea.analyze_event_with_model","arguments":' +
      '{"event_id":"' + EventId + '","consent_to_send_values":true}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot send event values to a model: ' + Response);

    { Pointer chain fields (real-game verification): a module+offsets chain is
      re-resolved on every read/write, so the field keeps working when the
      target relocates the value - which is what a Unity IL2CPP game does on
      every restart. The slot lives in our own module image (as a game's
      singleton pointer would) and points at the value. }
    ChainSlot := @ChainValueA;
    ChainReader := TCEAWin32PointerReader.Create(GetCurrentProcessId, 64);
    try
      R := ChainReader.ModuleBaseAddress(
        ExtractFileName(ParamStr(0)), ChainModuleBase);
      Assert(R.Code = rcOk, 'own module base is resolvable: ' + R.StableCode);
    finally
      ChainReader.Free;
    end;
    Assert(QWord(PtrUInt(@ChainSlot)) > ChainModuleBase,
      'the slot lives above the module base');
    ChainOffset := QWord(PtrUInt(@ChainSlot)) - ChainModuleBase;
    ChainSpec := '{"base":"0x' + IntToHex(ChainOffset, 16) +
      '","offsets":["0"]}';
    ChainValueA := 777;
    R := Runtime.DeclarePointerField('test.chain', 'Chain Value', 'dword',
      ExtractFileName(ParamStr(0)), ChainSpec, 64);
    Assert(R.Code = rcOk, 'operator declares a pointer chain field: ' +
      R.StableCode + ' ' + R.DataJson);
    Assert(Pos('"resolved":true', R.DataJson) > 0,
      'declaration resolves the chain immediately: ' + R.DataJson);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('address').AsString =
        '0x' + LowerCase(IntToHex(QWord(PtrUInt(@ChainValueA)), 16)),
        'chain resolves to the pointee, not the slot: ' + R.DataJson);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":42,"method":"tools/call",' +
      '"params":{"name":"cea.capture_field_value","arguments":{' +
      '"field_id":"test.chain"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.bytes_hex').AsString = '09030000',
        'chained field reads the value behind the pointer: ' + Response);
    finally
      ResponseData.Free;
    end;
    // Relocate the pointee: a plain absolute field would keep reading the old
    // address, a chained field must follow the pointer.
    ChainValueB := 4242;
    ChainSlot := @ChainValueB;
    R := Runtime.ResolveFieldAddress('test.chain');
    Assert((R.Code = rcOk) and
      (Pos('0x' + LowerCase(IntToHex(QWord(PtrUInt(@ChainValueB)), 16)),
        R.DataJson) > 0),
      're-resolution follows the relocated pointer: ' + R.DataJson);
    ResponseData := GetJSON(Runtime.CaptureFieldValue('test.chain').DataJson);
    try
      Assert(ResponseData.FindPath('bytes_hex').AsString = '92100000',
        'capture re-resolves before reading');
    finally
      ResponseData.Free;
    end;
    { FR-054: writing is a separate permission from reading. Nothing below can
      reach the target until the session grant exists, and the field itself must
      have been declared writable by intent before it can be verified. Both steps
      are asserted here so the gate cannot be quietly removed later. }
    R := Runtime.ConfirmFieldWritable('test.chain', '5150', '4242');
    Assert((R.Code = rcUnauthorized) and
      (R.StableCode = 'writes_not_enabled'),
      'a write without a session grant is refused: ' + R.StableCode);
    R := Runtime.EnableWriteAccess('verify the pointer chain end to end');
    Assert(R.Code = rcOk, 'operator enables writes for this session: ' +
      R.StableCode + ' ' + R.DataJson);
    R := Runtime.ConfirmFieldWritable('test.chain', '5150', '4242');
    Assert((R.Code = rcUnauthorized) and
      (R.StableCode = 'field_write_not_requested'),
      'a field must be asked for before it can be verified: ' + R.StableCode);
    R := Runtime.RequestFieldWrite('test.chain');
    Assert((R.Code = rcOk) and (Pos('"changed":true', R.DataJson) > 0),
      'requesting a write moves the field to pending_write: ' + R.DataJson);
    R := Runtime.ConfirmFieldWritable('test.chain', '5150', '4242');
    Assert((R.Code = rcOk) and (Pos('"verified":true', R.DataJson) > 0),
      'chained field is promoted through a verified write: ' + R.DataJson);
    Assert(ChainValueB = 5150, 'chained write lands on the pointee');
    Assert(ChainValueA = 777, 'chained write never touches the stale address');
    R := Runtime.WriteFieldValue('test.chain', '1234', '5150');
    Assert((R.Code = rcOk) and (Pos('"verified":true', R.DataJson) > 0),
      'a promoted chained field writes through the re-resolved address: ' +
      R.DataJson);
    Assert(ChainValueB = 1234, 'second chained write follows the pointer again');
    // A chain that no longer resolves must fail closed, not write anywhere.
    ChainSlot := nil;
    R := Runtime.ResolveFieldAddress('test.chain');
    Assert((R.Code = rcVerificationFailed) and
      (R.StableCode = 'pointer_chain_null_pointer'),
      'dead chain reports a null pointer: ' + R.StableCode + ' ' + R.DataJson);
    R := Runtime.CaptureFieldValue('test.chain');
    Assert(R.Code = rcVerificationFailed,
      'capture fails closed when the chain dies');
    ChainSlot := @ChainValueA;

    { The chain tools on the MCP surface: re-resolution is read-only, declaring a
      chain changes the state model and therefore only asks for local approval. }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":43,"method":"tools/call",' +
      '"params":{"name":"cea.resolve_field_address","arguments":{' +
      '"field_id":"test.chain"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP can re-resolve a chained field: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.address').AsString =
        '0x' + LowerCase(IntToHex(QWord(PtrUInt(@ChainValueA)), 16)),
        'MCP re-resolution returns the live pointee address: ' + Response);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":44,"method":"tools/call",' +
      '"params":{"name":"cea.declare_pointer_field","arguments":{' +
      '"field_id":"test.chain2","display_name":"Chain Two",' +
      '"value_type":"dword","module_name":"x.dll",' +
      '"offsets_json":"{\"base\":\"0x0\",\"offsets\":[\"0\"]}",' +
      '"address_width_bits":64}}}');
    Assert((Pos('local_operator_approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot declare a pointer chain without local approval: ' + Response);

    { The verified-write payload is real JSON: a JSON boolean, not Pascal
      True/False. Parsing it is the assertion, so a regression cannot hide behind
      a substring match. }
    { The slot points back at ChainValueA (777) after the dead-chain probe, so
      the expected current value must be 777: a stale 4242 would prove the field
      still reads the old pointee. }
    R := Runtime.ConfirmFieldWritable('test.chain', '1234', '777');
    Assert(R.Code = rcOk, 're-promotion after a fresh resolve succeeds: ' +
      R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('verified').AsBoolean,
        'verified is a JSON boolean');
      Assert(ResponseData.FindPath('command_sent').AsBoolean,
        'command_sent is a JSON boolean');
    finally
      ResponseData.Free;
    end;

    { FR-042/FR-045 命令预览：写之前先把「字段、原值、目标值、适配器」摆出来，
      并比对操作者依据的那个原值是否已经变了。预览本身绝不写入，所以它既不该
      改动内存，也不该在操作历史里多出一条。 }
    R := Runtime.PreviewFieldWrite('test.chain', '9999', '1234');
    Assert(R.Code = rcOk, 'preview of a writable field succeeds: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('field_id').AsString = 'test.chain',
        'preview names the field');
      Assert(ResponseData.FindPath('original_value').AsString = '1234',
        'preview shows the live original value: ' + R.DataJson);
      Assert(ResponseData.FindPath('target_value').AsString = '9999',
        'preview shows the target value');
      Assert(ResponseData.FindPath('adapter_id').AsString =
        'command_bus/win32_compare_write_readback',
        'preview names the adapter that would perform the write');
      Assert(not ResponseData.FindPath('conflict').AsBoolean,
        'the live value matches the expected one');
      Assert(ResponseData.FindPath('can_execute').AsBoolean,
        'a clean preview says the write would go through');
      Assert(ResponseData.FindPath('requires_confirmation').AsBoolean,
        'a preview always demands a second confirmation (FR-043)');
      Assert(ResponseData.FindPath('blocking_reason').AsString = '',
        'nothing blocks a clean preview');
    finally
      ResponseData.Free;
    end;
    { FR-045: the operator edited against 777, but the field now holds 1234. The
      preview must surface that instead of silently overwriting the new value. }
    R := Runtime.PreviewFieldWrite('test.chain', '9999', '777');
    Assert(R.Code = rcOk, 'a stale expected value is a preview result, not an error: '
      + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('conflict').AsBoolean,
        'preview detects that the original value changed: ' + R.DataJson);
      Assert(ResponseData.FindPath('blocking_reason').AsString =
        'expected_value_changed', 'the conflict is named');
      Assert(not ResponseData.FindPath('can_execute').AsBoolean,
        'a conflicting preview must not be executable');
    finally
      ResponseData.Free;
    end;
    { The preview ran twice and must not have written anything. }
    Assert(DWord(ChainSlot^) = 1234,
      'a preview never writes to the target');

    { FR-041 输入校验：字段自己声明的范围优先于调用方的意图。声明一个上限后，
      超出范围的目标值必须被挡在写入之前，而不是等到写进进程才发现不对。 }
    R := Runtime.SetFieldConstraints('test.chain', '{"min":100,"max":500}');
    Assert(R.Code = rcOk, 'constraints can be declared: ' + R.StableCode);
    R := Runtime.PreviewFieldWrite('test.chain', '9999', '1234');
    Assert(R.Code = rcOk, 'an out-of-range preview is still a preview: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(not ResponseData.FindPath('constraints_satisfied').AsBoolean,
        'preview knows the value violates the declared range: ' + R.DataJson);
      Assert(ResponseData.FindPath('constraint_stable_code').AsString =
        'field_value_above_max', 'the violated bound is named');
      Assert(ResponseData.FindPath('blocking_reason').AsString =
        'constraints_not_satisfied', 'constraints block execution');
      Assert(not ResponseData.FindPath('can_execute').AsBoolean,
        'an out-of-range value must not be executable');
    finally
      ResponseData.Free;
    end;
    { The write path itself must refuse it, not just the preview. }
    R := Runtime.WriteFieldValue('test.chain', '9999', '1234');
    Assert(R.Failed, 'the write path refuses an out-of-range value');
    Assert(Pos('field_value_above_max', R.DataJson + R.StableCode) > 0,
      'the refusal names the bound: ' + R.StableCode + ' ' + R.DataJson);
    Assert(DWord(ChainSlot^) = 1234,
      'a rejected value never reaches the target process');
    { An in-range value still goes through. }
    R := Runtime.WriteFieldValue('test.chain', '300', '1234');
    Assert(R.Code = rcOk, 'an in-range value is still writable: ' + R.StableCode);
    Assert(DWord(ChainSlot^) = 300, 'the in-range write landed');
    { Clearing the constraints restores the unconstrained behaviour. }
    R := Runtime.SetFieldConstraints('test.chain', '');
    Assert(R.Code = rcOk, 'constraints can be cleared: ' + R.StableCode);
    R := Runtime.PreviewFieldWrite('test.chain', '9999', '300');
    Assert(R.Code = rcOk, 'unconstrained preview after clearing: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('constraints_satisfied').AsBoolean,
        'no constraints means nothing is violated');
      Assert(ResponseData.FindPath('can_execute').AsBoolean,
        'an unconstrained preview is executable');
    finally
      ResponseData.Free;
    end;
    { A malformed block is refused at declaration time rather than stored. }
    R := Runtime.SetFieldConstraints('test.chain', '{"maximun":500}');
    Assert(R.Failed, 'a malformed constraint block is rejected on declaration');
    Assert(Pos('field_constraints_unknown_key', R.StableCode + R.DataJson) > 0,
      'the unknown key is named: ' + R.StableCode);
    { Put the target back so the later assertions see the value they expect. }
    R := Runtime.WriteFieldValue('test.chain', '1234', '300');
    Assert(R.Code = rcOk, 'restore the chain value: ' + R.StableCode);
    Assert(DWord(ChainSlot^) = 1234, 'the chain value is restored');



    R := Runtime.ListFieldWriteHistory('test.chain', 50);
    Assert(R.Code = rcOk, 'write history is queryable: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      { Five real writes touched this field: the original pair plus the two the
        FR-041 block performed (an in-range write and the restore). The rejected
        out-of-range attempt is deliberately absent: it never reached an
        adapter, and the journal records what happened, not what was attempted. }
      Assert(ResponseData.FindPath('count').AsInteger = 5,
        'every real write is journaled exactly once: ' + R.DataJson);
      Assert(ResponseData.FindPath('writes').Items[0].FindPath(
        'outcome').AsString = 'verified',
        'the newest record is the most recent write');
      Assert(ResponseData.FindPath('writes').Items[0].FindPath(
        'target_value').AsString = '1234',
        'journal keeps the target value');
      Assert(ResponseData.FindPath('writes').Items[0].FindPath(
        'original_value').AsString = '300',
        'journal keeps the original value');
      Assert(ResponseData.FindPath('writes').Items[0].FindPath(
        'adapter_id').AsString = 'command_bus/win32_compare_write_readback',
        'journal names the adapter that performed the write');
      Assert(ResponseData.FindPath('writes').Items[2].FindPath(
        'adapter_id').AsString = 'direct_verify/win32_compare_write_readback',
        'the direct verify path is journaled separately from the command bus');
      Assert(ResponseData.FindPath('writes').Items[2].FindPath(
        'original_value').AsString = '777',
        'the direct verify record keeps its own original value');
      Assert(ResponseData.FindPath('writes').Items[1].FindPath(
        'command_sent').AsBoolean,
        'journal records that the command actually reached the target');
      Assert(ResponseData.FindPath('writes').Items[0].FindPath(
        'process_identity_id').AsString <> '',
        'journal binds each write to a process identity');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":45,"method":"tools/call",' +
      '"params":{"name":"cea.list_field_write_history","arguments":{' +
      '"field_id":"test.chain","limit":10}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP can read the write history: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger = 5,
        'MCP sees the same durable records the desktop sees: ' + Response);
    finally
      ResponseData.Free;
    end;

    { FR-042: a preview changes nothing, so MCP may run it directly — unlike the
      write it describes, which stays behind local approval. }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":46,"method":"tools/call",' +
      '"params":{"name":"cea.preview_field_write","arguments":{' +
      '"field_id":"test.chain","target_value":"9999",' +
      '"expected_current_value":"1234"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP may preview a write: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.can_execute').AsBoolean,
        'MCP sees the same executability verdict the desktop sees: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.original_value').AsString = '1234',
        'MCP preview reports the live original value: ' + Response);
    finally
      ResponseData.Free;
    end;


    { FR-041: constraints decide which values a write may ever carry, so MCP may
      not set them — only a local operator can. }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":47,"method":"tools/call",' +
      '"params":{"name":"cea.set_field_constraints","arguments":{' +
      '"field_id":"test.chain","constraints_json":"{\"min\":100}"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP may not widen a field constraint set: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.surface').AsString = 'field_constraints',
        'the refusal names the constraint surface: ' + Response);
    finally
      ResponseData.Free;
    end;

    R := Runtime.ListFieldEvidence('test.chain', 50);
    Assert(R.Code = rcOk, 'field evidence is queryable: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('count').AsInteger >= 2,
        'captures produce evidence records: ' + R.DataJson);
      Assert(ResponseData.FindPath('evidence').Items[0].FindPath(
        'kind').AsString = 'verification',
        'the newest test.chain record is the verified write');
      Assert(ResponseData.FindPath('evidence').Items[0].FindPath(
        'outcome').AsString = 'pass',
        'a verified write carries a passing outcome');
      Assert(ResponseData.FindPath('evidence').Items[0].FindPath(
        'supports_write_claim').AsBoolean,
        'verification evidence supports a write claim');
      Assert(ResponseData.FindPath('evidence').Items[0].FindPath(
        'process_identity_id').AsString <> '',
        'evidence binds to a process identity');
      Assert(ResponseData.FindPath('evidence').Items[0].FindPath(
        'epoch').AsInt64 > 0, 'evidence binds to an epoch');
    finally
      ResponseData.Free;
    end;

    { 用户确认只记录「这个字段是什么」，不证明可写——这是证据层与权限层的
      分界线，必须在返回体里明说，否则调用方会把记录当授权。 }
    R := Runtime.RecordFieldUserConfirmation('test.chain');
    Assert(R.Code = rcOk, 'user confirmation recorded: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('kind').AsString = 'user_statement',
        'confirmation is user evidence');
      Assert(not ResponseData.FindPath('supports_write_claim').AsBoolean,
        'a user statement does not prove writability');
    finally
      ResponseData.Free;
    end;

    { MCP 能看到同一批证据，但只能看，不能造。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":47,"method":"tools/call",' +
      '"params":{"name":"cea.list_field_evidence","arguments":{' +
      '"field_id":"test.chain","limit":10}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP can read field evidence: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger >= 2,
        'MCP sees the same durable evidence: ' + Response);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":48,"method":"tools/call",' +
      '"params":{"name":"cea.record_field_confirmation","arguments":{' +
      '"field_id":"test.chain"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP cannot fabricate evidence: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.approval_surface').AsString =
        'local_ui_only', 'only the local operator can confirm: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.surface').AsString = 'field_evidence',
        'the approval names the evidence surface: ' + Response);
    finally
      ResponseData.Free;
    end;

    { FR-051 分轮验证：每轮扫描/修改之前先把目的、操作、预期写下来。
      这里验证三件事：三项缺一不可、同一时刻只能有一个未收尾轮次、
      一致性由操作者显式判定而不是从数值推断。 }
    R := Runtime.PlanDiscoveryRound('scan', '', 'dword 扫描 100',
      '血量变成 90', '');
    Assert((R.Code = rcInvalidArgument) and
      (R.StableCode = 'discovery_purpose_required'),
      'a round without a purpose is refused: ' + R.StableCode);
    R := Runtime.PlanDiscoveryRound('guessing', '找血量', 'dword 扫描 100',
      '血量变成 90', '');
    Assert(R.StableCode = 'discovery_kind_invalid',
      'unknown round kind is refused: ' + R.StableCode);
    R := Runtime.CurrentDiscoveryRound;
    Assert(Pos('"has_active_round":false', R.DataJson) > 0,
      'no round is active before planning: ' + R.DataJson);
    R := Runtime.PlanDiscoveryRound('scan', '找血量', 'dword 扫描 100',
      '血量变成 90', 'test.chain');
    Assert(R.Code = rcOk, 'plan a discovery round: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      RoundId := ResponseData.FindPath('round.round_id').AsString;
      Assert(RoundId <> '', 'a planned round has an id: ' + R.DataJson);
      Assert(ResponseData.FindPath('round.kind').AsString = 'scan',
        'round kind roundtrips');
      Assert(ResponseData.FindPath('round.state').AsString = 'planned',
        'a planned round is planned');
      Assert(ResponseData.FindPath('round.field_id').AsString = 'test.chain',
        'the round names its field');
      Assert(not ResponseData.FindPath(
        'round.matched_expectation').AsBoolean,
        'a planned round has not matched anything yet');
    finally
      ResponseData.Free;
    end;
    R := Runtime.PlanDiscoveryRound('refine', '缩小范围', 'dword 扫描 90',
      '结果集缩小到个位数', '');
    Assert((R.Code = rcConflict) and (R.StableCode = 'discovery_round_active'),
      'a second active round is refused: ' + R.StableCode);
    Assert(Pos(RoundId, R.DataJson) > 0,
      'the refusal names the round that is still open: ' + R.DataJson);
    R := Runtime.CurrentDiscoveryRound;
    Assert(Pos('"has_active_round":true', R.DataJson) > 0,
      'the planned round is the active one: ' + R.DataJson);
    R := Runtime.CompleteDiscoveryRound(RoundId, '血量从 100 变成 90，剩 3 个候选',
      False);
    Assert(R.Code = rcOk, 'complete the round: ' + R.StableCode);
    Assert(Pos('"matched_expectation":false', R.DataJson) > 0,
      'mismatch is recorded as the operator said it: ' + R.DataJson);
    Assert(Pos('"state":"completed"', R.DataJson) > 0,
      'a completed round is completed: ' + R.DataJson);
    R := Runtime.CurrentDiscoveryRound;
    Assert(Pos('"has_active_round":false', R.DataJson) > 0,
      'nothing is active after completion: ' + R.DataJson);
    // 放弃必须有理由，否则「跳过」会变成不留痕迹。
    R := Runtime.PlanDiscoveryRound('compare', '确认是同一个字段',
      '连续两次采集对比', '两次读到同一个值', 'test.chain');
    Assert(R.Code = rcOk, 'plan a comparison round: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      RoundId := ResponseData.FindPath('round.round_id').AsString;
    finally
      ResponseData.Free;
    end;
    Assert(Runtime.AbandonDiscoveryRound(RoundId, '').StableCode =
      'discovery_abandon_reason_required', 'abandoning needs a reason');
    R := Runtime.AbandonDiscoveryRound(RoundId, '游戏被关掉了');
    Assert(R.Code = rcOk, 'abandon the round: ' + R.StableCode);
    Assert(Pos('"state":"abandoned"', R.DataJson) > 0,
      'an abandoned round is still on record: ' + R.DataJson);
    R := Runtime.ListDiscoveryRounds(50);
    Assert(R.Code = rcOk, 'list rounds: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('count').AsInteger = 2,
        'both rounds are listed: ' + R.DataJson);
      Assert(ResponseData.FindPath('rounds[0].state').AsString = 'completed',
        'the list is chronological');
      Assert(ResponseData.FindPath('rounds[1].state').AsString = 'abandoned',
        'the abandoned round is kept');
    finally
      ResponseData.Free;
    end;
    // MCP 只能读计划：替操作者声明「我预期看到 X」等于伪造验收标准。
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":49,"method":"tools/call",' +
      '"params":{"name":"cea.list_discovery_rounds","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP can read the discovery rounds: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger = 2,
        'MCP sees the same rounds: ' + Response);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":50,"method":"tools/call",' +
      '"params":{"name":"cea.plan_discovery_round","arguments":{' +
      '"kind":"scan","purpose":"找血量","operation":"dword 扫描 100",' +
      '"expected_observation":"血量变成 90"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP cannot author the operator''s expectation: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.approval_surface').AsString =
        'local_ui_only', 'only the local operator plans a round: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.surface').AsString =
        'discovery_round', 'the approval names the round surface: ' + Response);
    finally
      ResponseData.Free;
    end;

    { FR-050 目标描述：操作者用自己的话描述想找什么。目标只是意图，
      不是证据——接受目标既不授权扫描也不授权写入。 }
    R := Runtime.ProposeDiscoveryGoal('', '', '', '');
    Assert(R.Code = rcInvalidArgument, 'an empty description is not a goal: ' +
      R.StableCode);
    Assert(R.StableCode = 'discovery_goal_description_required',
      'the empty description names the missing field: ' + R.StableCode);
    R := Runtime.ProposeDiscoveryGoal('找金币', 'player.gold', 'dword',
      'increase');
    Assert(R.Code = rcOk, 'propose an operator goal: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      GoalId := ResponseData.FindPath('goal.goal_id').AsString;
      Assert(GoalId <> '', 'a goal has an id: ' + R.DataJson);
      Assert(ResponseData.FindPath('goal.state').AsString = 'proposed',
        'a fresh goal is only proposed');
      Assert(ResponseData.FindPath('goal.source').AsString = 'operator',
        'the operator spoke it');
      Assert(not ResponseData.FindPath('goal.advisory').AsBoolean,
        'the operator''s own words are not a model suggestion');
      // 断言用字节子串：AsString 会把 UTF-8 转成本地码页，比较结果取决于
      // 编译期码页标签而不是内容本身。
      Assert(Pos('"description":"找金币"', R.DataJson) > 0,
        'the description is kept verbatim: ' + R.DataJson);
    finally
      ResponseData.Free;
    end;
    // 提案还不算「我在找这个」：没有人接受过，就没有活跃目标。
    R := Runtime.CurrentDiscoveryGoal;
    Assert(R.Code = rcOk, 'current goal: ' + R.StableCode);
    Assert(Pos('"has_active_goal":false', R.DataJson) > 0,
      'a proposal alone does not become the active goal: ' + R.DataJson);
    R := Runtime.AcceptDiscoveryGoal(GoalId);
    Assert(R.Code = rcOk, 'accept the goal: ' + R.StableCode);
    Assert(Pos('"state":"accepted"', R.DataJson) > 0,
      'accepting moves the goal to accepted: ' + R.DataJson);
    // 接受目标只表示意图：它不授权扫描，也不授权写入。
    Assert(Pos('"grants_scan":false', R.DataJson) > 0,
      'accepting a goal does not authorise a scan: ' + R.DataJson);
    Assert(Pos('"grants_write":false', R.DataJson) > 0,
      'accepting a goal does not authorise a write: ' + R.DataJson);
    R := Runtime.CurrentDiscoveryGoal;
    Assert(Pos('"has_active_goal":true', R.DataJson) > 0,
      'the accepted goal is active: ' + R.DataJson);
    // 人会改主意：接受第二个目标不是错误，但前一个必须被标成 superseded，
    // 否则两个目标同时「活跃」，分轮计划就不知道在服务哪个意图。
    R := Runtime.ProposeDiscoveryGoal('找血量', '', 'dword', 'decrease');
    Assert(R.Code = rcOk, 'propose a second goal: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      GoalId := ResponseData.FindPath('goal.goal_id').AsString;
    finally
      ResponseData.Free;
    end;
    R := Runtime.AcceptDiscoveryGoal(GoalId);
    Assert(R.Code = rcOk, 'accepting a second goal is allowed: ' + R.StableCode);
    R := Runtime.ListDiscoveryGoals(50);
    Assert(R.Code = rcOk, 'list goals: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('count').AsInteger = 2,
        'both goals are kept: ' + R.DataJson);
      Assert(ResponseData.FindPath('goals[0].state').AsString = 'superseded',
        'the older goal is superseded, not silently dropped: ' + R.DataJson);
      Assert(ResponseData.FindPath('goals[0].decided_at').AsString <> '',
        'a superseded goal records when it was replaced');
      Assert(ResponseData.FindPath('goals[1].state').AsString = 'accepted',
        'the newer goal is the active one');
    finally
      ResponseData.Free;
    end;
    // 拒绝必须给理由：没有理由的拒绝和没拒绝一样，下一个人看不出为什么。
    R := Runtime.RejectDiscoveryGoal(GoalId, '');
    Assert(R.Code = rcInvalidArgument, 'a rejection needs a reason: ' +
      R.StableCode);
    Assert(R.StableCode = 'discovery_goal_reject_reason_required',
      'the rejection names the missing reason: ' + R.StableCode);
    R := Runtime.RejectDiscoveryGoal(GoalId, '这是经验值不是血量');
    Assert(R.Code = rcOk, 'reject with a reason: ' + R.StableCode);
    Assert(Pos('"state":"rejected"', R.DataJson) > 0,
      'the goal is rejected: ' + R.DataJson);
    R := Runtime.AcceptDiscoveryGoal(GoalId);
    Assert(R.Code = rcConflict,
      'a rejected goal cannot be accepted later: ' + R.StableCode);
    R := Runtime.RejectDiscoveryGoal('goal-does-not-exist', 'whatever');
    Assert(R.Code = rcUnknown, 'an unknown goal is not found: ' + R.StableCode);
    // 没有配置模型时，模型解读必须 fail closed，而不是本地瞎猜。
    R := Runtime.ProposeDiscoveryGoalWithModel('找血量', 0);
    Assert(R.Code = rcConflict, 'no model configured: ' + R.StableCode);
    Assert(R.StableCode = 'llm_not_configured',
      'the model path names the missing provider: ' + R.StableCode);
    // MCP 只能读目标：替操作者声明「我要找这个」等于伪造意图。
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":51,"method":"tools/call",' +
      '"params":{"name":"cea.list_discovery_goals","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP can read the goals: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger = 2,
        'MCP sees the same goals: ' + Response);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":52,"method":"tools/call",' +
      '"params":{"name":"cea.propose_discovery_goal","arguments":{' +
      '"description":"找金币"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP cannot author the operator''s intent: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.approval_surface').AsString =
        'local_ui_only', 'only the local operator states a goal: ' + Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.surface').AsString = 'discovery_goal',
        'the approval names the goal surface: ' + Response);
    finally
      ResponseData.Free;
    end;

    { Game Profile：把当前字段集合连定位配方存下来，再还原回模型。
      还原的关键约束是「不能继承可写性」——test.chain 刚刚被验证为可写，
      但 Profile 里的这条证明只属于上一轮会话，还原后必须退回 read_only，
      否则一次存档就能把任意字段洗成可写。 }
    R := Runtime.SaveGameProfile;
    Assert(R.Code = rcOk, 'save game profile: ' + R.StableCode);
    Assert(Pos('"field_count":2', R.DataJson) > 0,
      'profile stores the whole field set: ' + R.DataJson);
    R := Runtime.RestoreGameProfile('Self Test Game');
    Assert(R.Code = rcOk, 'restore game profile: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('compatible').AsBoolean,
        'same executable hash is compatible');
      Assert(ResponseData.FindPath('restored').AsInteger = 2,
        'both fields restored');
      Assert(ResponseData.FindPath('downgraded').AsInteger = 0,
        'compatible profile is not downgraded');
    finally
      ResponseData.Free;
    end;
    R := Runtime.ListGameFields;
    Assert(R.Code = rcOk, 'list after restore: ' + R.StableCode);
    ResponseData := GetJSON(R.DataJson);
    try
      Assert(ResponseData.FindPath('count').AsInteger = 2,
        'both fields are back in the model');
      Assert(ResponseData.FindPath('fields').Items[0].FindPath(
        'access').AsString = 'read_only',
        'restored field drops back to read-only');
      Assert(ResponseData.FindPath('fields').Items[1].FindPath(
        'access').AsString = 'read_only',
        'chained field drops back to read-only too');
      Assert(ResponseData.FindPath('fields').Items[1].FindPath(
        'module_name').AsString = ExtractFileName(ParamStr(0)),
        'chain recipe survives the round trip');
      Assert(ResponseData.FindPath('fields').Items[0].FindPath(
        'value').AsString = '',
        'a profile never carries a stale live value');
    finally
      ResponseData.Free;
    end;

    { Profile 的 MCP 面：只申请、不执行（写持久配置 + 改活模型）。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":52,"method":"tools/call",' +
      '"params":{"name":"cea.save_game_profile","arguments":{}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot save a profile on its own: ' + Response);
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":53,"method":"tools/call",' +
      '"params":{"name":"cea.restore_game_profile","arguments":' +
      '{"game_name":"Self Test Game"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot restore a profile on its own: ' + Response);

    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":40,"method":"tools/call",' +
      '"params":{"name":"cea.end_game_session","arguments":{}}}');
    Assert(not Runtime.GameSessionActive, 'player session is closed by MCP');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":41,"method":"tools/call",' +
      '"params":{"name":"cea.list_game_fields","arguments":{}}}');
    Assert(Pos('game_session_not_started', Response) > 0,
      'player reads fail closed after the session ends');

    { CE 文件库的 MCP 面：列出已发布文件是只读；导入/发布/翻译只能申请。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":51,"method":"tools/call",' +
      '"params":{"name":"cea.list_published_cheat_files","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(not ResponseData.FindPath(
        'result.structuredContent.is_error').AsBoolean,
        'MCP can list the published cheat library');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":52,"method":"tools/call",' +
      '"params":{"name":"cea.import_cheat_file","arguments":{' +
      '"path":"tests\\fixtures\\ct\\minimal-valid.ct"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot import a cheat file on its own');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":53,"method":"tools/call",' +
      '"params":{"name":"cea.publish_cheat_file","arguments":{' +
      '"path":"tests\\fixtures\\ct\\minimal-valid.ct"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot publish a cheat file on its own');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":54,"method":"tools/call",' +
      '"params":{"name":"cea.translate_cheat_descriptions","arguments":{' +
      '"path":"tests\\fixtures\\ct\\minimal-valid.ct"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot send CT text off-device without local approval');

    { 1D 增强：多页面 / 版本回退 / 自然语言定制（FR-025/026/033）。
      页面存的是 schema JSON 而不是数值快照，回退只换布局、不回写游戏。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":61,"method":"tools/call",' +
      '"params":{"name":"cea.save_ui_page","arguments":{' +
      '"page_id":"page-attributes","title":"Attributes",' +
      '"schema_id":"ui-self-test","schema_json":' +
      '"{\"id\":\"ui-self-test\",\"page_title\":\"Attributes\",' +
      '\"sections\":[{\"id\":\"s1\",\"title\":\"S\",\"components\":[' +
      '{\"id\":\"c1\",\"kind\":\"text\",\"title\":\"C\",' +
      '\"field_id\":\"\",\"access\":\"read_only\"}]}]}"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.version').AsInteger = 1,
        'MCP stores the first UI page version: ' + Response);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":62,"method":"tools/call",' +
      '"params":{"name":"cea.save_ui_page","arguments":{' +
      '"page_id":"page-attributes","title":"Attributes v2",' +
      '"schema_id":"ui-self-test","schema_json":' +
      '"{\"id\":\"ui-self-test\",\"page_title\":\"Attributes v2\",' +
      '\"sections\":[{\"id\":\"s1\",\"title\":\"S\",\"components\":[' +
      '{\"id\":\"c1\",\"kind\":\"text\",\"title\":\"C\",' +
      '\"field_id\":\"\",\"access\":\"read_only\"}]}]}"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.version').AsInteger = 2,
        'second save appends a new version: ' + Response);
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":63,"method":"tools/call",' +
      '"params":{"name":"cea.list_ui_schema_versions","arguments":{' +
      '"schema_id":"ui-self-test"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger = 2,
        'version history lists both versions');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":64,"method":"tools/call",' +
      '"params":{"name":"cea.restore_ui_schema_version","arguments":{' +
      '"schema_id":"ui-self-test","version":1}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.version').AsInteger = 3,
        'rollback appends a third version instead of deleting history: ' +
        Response);
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.restored_from').AsInteger = 1,
        'rollback reports which version it restored');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":65,"method":"tools/call",' +
      '"params":{"name":"cea.list_ui_schema_versions","arguments":{' +
      '"schema_id":"ui-self-test"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger = 3,
        'rollback never destroys earlier versions');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":66,"method":"tools/call",' +
      '"params":{"name":"cea.list_ui_pages","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.count').AsInteger = 1,
        'only one page exists after two saves of the same page');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":67,"method":"tools/call",' +
      '"params":{"name":"cea.set_active_ui_page","arguments":{' +
      '"page_id":"page-attributes"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.active').AsBoolean,
        'MCP can activate a stored page');
    finally
      ResponseData.Free;
    end;
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":68,"method":"tools/call",' +
      '"params":{"name":"cea.get_ui_page","arguments":{' +
      '"page_id":"page-attributes"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(Pos('ui-self-test', ResponseData.FindPath(
        'result.structuredContent.data.schema_json').AsString) > 0,
        'page read returns the stored schema JSON');
    finally
      ResponseData.Free;
    end;
    { 非白名单组件必须被拒绝：页面 JSON 不能绕开受控组件集合。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":69,"method":"tools/call",' +
      '"params":{"name":"cea.save_ui_page","arguments":{' +
      '"page_id":"page-bad","title":"Bad","schema_id":"ui-bad",' +
      '"schema_json":' +
      '"{\"id\":\"ui-bad\",\"page_title\":\"Bad\",\"sections\":[' +
      '{\"id\":\"s1\",\"title\":\"S\",\"components\":[' +
      '{\"id\":\"c1\",\"kind\":\"iframe\",\"title\":\"C\",' +
      '\"field_id\":\"f1\",\"access\":\"read_only\"}]}]}"}}}');
    Assert(Pos('ui_component_kind_not_whitelisted', Response) > 0,
      'unlisted component kinds are rejected before storage');
    { 自然语言定制：MCP 能发起提案，但确认必须回到本地操作者。 }
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":70,"method":"tools/call",' +
      '"params":{"name":"cea.confirm_ui_customization","arguments":{' +
      '"proposal_id":"uip-1"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP cannot confirm a model-authored page on its own');
    Assert(Runtime.RejectUiCustomization('uip-unknown').Code = rcUnknown,
      'an unknown proposal id is rejected instead of guessed');
    Assert(Runtime.ConfirmUiCustomization('uip-unknown', 'page-x',
      'X').Code = rcUnknown,
      'an unconfirmed proposal can never be stored');

    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":21,"method":"tools/call",' +
      '"params":{"name":"cea.request_freeze","arguments":{' +
      '"task_id":"task-mcp-freeze","address":"0x' +
      LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)) + '",' +
      '"expected_original_bytes":"10203040",' +
      '"replacement_bytes":"05060708","interval_ms":100,' +
      '"max_writes":1,"duration_seconds":30}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP freeze request can only create a locally approved Effect');
    Assert(Value[0] = $10, 'MCP cannot activate its own freeze');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
      '"params":{"name":"cea.request_memory_write","arguments":{' +
      '"task_id":"task-mcp-plan","address":"0x' +
      LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)) + '",' +
      '"expected_original_bytes":"10203040",' +
      '"replacement_bytes":"05060708"}}}');
    Assert((Pos('approval_required', Response) > 0) and
      (Pos('local_ui_only', Response) > 0),
      'MCP write request creates a locally approved Effect only');
    Assert(Value[0] = $10, 'MCP cannot approve or execute its own write');
    R := Runtime.PlanMemoryWrite('task-crash-recovery',
      '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Value[0])), 16)),
      '10203040', '05060708', RecoveryEffect);
    Assert(R.Code = rcApprovalRequired,
      'recovery fixture is planned without mutation');
    Response := Runtime.HandleMCP(
      '{"jsonrpc":"2.0","id":4,"method":"tools/call",' +
      '"params":{"name":"cea.emergency_stop","arguments":{}}}');
    Assert(Pos('emergency_stop_applied', Response) > 0,
      'MCP can trigger emergency stop without granting authority');
    Assert(Value[0] = $10, 'emergency stop never mutates target memory');
    Runtime.Stop;
    Assert(not Runtime.Started, 'standalone runtime stops');

    RecoveryStore := TCEASqliteStore.Create(DatabasePath);
    try
      Assert(RecoveryStore.Initialize.Code = rcOk,
        'recovery fixture store opens');
      RecoveryEffect.State := esExecuting;
      RecoveryEffect.UpdatedAt := '2026-09-15T00:00:00.000Z';
      Assert(RecoveryStore.SaveEffect(RecoveryEffect).Code = rcOk,
        'simulated crash leaves effect executing');
      FreezeEffect.State := esExecuting;
      FreezeEffect.UpdatedAt := '2026-09-15T00:00:00.000Z';
      FreezeEffect.ResultJson := '{"freeze_active":true}';
      Assert(RecoveryStore.SaveEffect(FreezeEffect).Code = rcOk,
        'simulated crash leaves freeze effect executing');
    finally
      RecoveryStore.Free;
    end;

    FreeAndNil(Runtime);
    Runtime := TCEAStandaloneRuntime.Create(DatabasePath,
      30000 + Word(GetProcessID mod 20000));
    Assert(Runtime.Start.Code = rcOk, 'runtime restarts after crash window');
    Assert(Runtime.LoadEffect(FreezeEffect.Id, Effect).Code = rcOk,
      'interrupted freeze effect reloads after restart');
    Assert((Effect.State = esUnknown) and (not Runtime.FreezeActive),
      'interrupted freeze becomes unknown and never auto-resumes');
    Assert(Runtime.AttachAuthorizedOffline('task-reconcile',
      GetCurrentProcessId, Identity).Code = rcOk,
      'recovery reattaches exact authorized process');
    R := Runtime.ReconcileUnknownEffect(RecoveryEffect.Id);
    if (R.Code <> rcOk) or
       (R.StableCode <> 'effect_reconciled_not_applied') then
      WriteLn('RECOVERY_DIAGNOSTIC code=', Ord(R.Code),
        ' stable=', R.StableCode, ' data=', R.DataJson);
    Assert((R.Code = rcOk) and
      (R.StableCode = 'effect_reconciled_not_applied') and
      (R.ReceiptId <> '') and (R.ProofId <> ''),
      'explicit observation proves interrupted write was not applied');
    Assert(Runtime.LoadEffect(RecoveryEffect.Id,
      RecoveredEffect).Code = rcOk, 'reconciled effect reloads');
    Assert(RecoveredEffect.State = esRejected,
      'proven not-applied effect is closed without automatic retry');
    Runtime.Stop;
    WriteLn('STANDALONE_APP_RUNTIME=PASS');
  finally
    Runtime.Free;
    if DiscoverySavePath <> '' then
      SysUtils.DeleteFile(DiscoverySavePath);
    if DiscoveryRoot <> '' then
      RemoveDir(DiscoveryRoot);
    SysUtils.DeleteFile(DatabasePath);
    SysUtils.DeleteFile(DatabasePath + '-wal');
    SysUtils.DeleteFile(DatabasePath + '-shm');
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DataDirectory) +
      'ui-pages.sqlite3');
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DataDirectory) +
      'events.sqlite3');
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DataDirectory) +
      'profiles.sqlite3');
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DataDirectory) +
      'ui-layout.sqlite3');
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DataDirectory) +
      'write-journal.sqlite3');
    SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DataDirectory) +
      'field-evidence.sqlite3');
    RemoveDir(DataDirectory);
  end;
end.
