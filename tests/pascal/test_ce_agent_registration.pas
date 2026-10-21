program test_ce_agent_registration;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_types, cea_results, cea_owner_thread_queue,
  cea_runtime_backend_ports,
  cea_win32_selftest_backend,
  cea_test_ports, cea_win32_engine_runtime;

var
  Backend: TCEAWin32SelfTestBackend;
  Hasher: TCEATestHasher;
  R: TCEAResult;
  Ticket: TCEACommandTicket;
  Identity: TCEProcessIdentity;
  MultiRanges: TCEScanRangeArray;
  ScopeId: string;
  FirstAddress, SecondAddress: QWord;

const
  Sentinel: array[0..3] of Byte = ($CA, $FE, $BA, $BE);
  Sentinel2: array[0..3] of Byte = ($CA, $FE, $BA, $BE);

begin
  UnregisterEngine;
  R := RegisterEngine;
  Assert(R.Code = rcInternalError,
    'registration without host dependencies fails closed');
  Assert(not EngineRegistered,
    'failed registration leaves no partial runtime');

  Backend := TCEAWin32SelfTestBackend.Create(GetCurrentProcessId);
  Hasher := TCEATestHasher.Create;
  try
    R := RegisterEngine(Backend, Hasher);
    Assert(R.Code = rcOk, 'validated dependencies register runtime');
    Assert(EngineRegistered, 'runtime reports registered state');
    Assert(Assigned(EngineRuntime),
      'successful registration publishes composition root');
    Assert(Assigned(EngineRuntime.Processes),
      'composition root exposes process capability');
    Assert(Assigned(EngineRuntime.Memory),
      'composition root exposes memory-read capability');
    Assert(Assigned(EngineRuntime.Modules),
      'composition root exposes module capability');
    Assert(Assigned(EngineRuntime.Scanner),
      'composition root exposes scan capability');
    Assert(Assigned(EngineRuntime.Disassembly),
      'composition root exposes disassembly capability');
    Assert(EngineRuntime.CommandQueue.OwnerThreadId =
      GetCurrentThreadId, 'command queue binds registration thread');

    Ticket := EngineRuntime.CommandQueue.Submit(
      'runtime_health', '{}');
    Assert(Assigned(Ticket), 'runtime command is queued');
    Assert(EngineRuntime.PumpCommands(8) = 1,
      'runtime pumps one command on the owner thread');
    R := EngineRuntime.CommandQueue.WaitFor(Ticket, 0);
    Assert(R.Code = rcOk, 'runtime health command succeeds');
    Assert(Pos('"status":"ready"', R.DataJson) > 0,
      'runtime health reports ready');
    R := EngineRuntime.CommandQueue.Release(Ticket);
    Assert(R.Code = rcOk, 'completed runtime command is released');

    R := EngineRuntime.Execute('process_attach', Format(
      '{"task_id":"task:router","lease_ref":"lease:router",' +
      '"pid":%d,"operator_attests_authorized_debugging":true}',
      [GetCurrentProcessId]));
    Assert(R.Code = rcOk, 'runtime router attaches an authorized target');
    R := EngineRuntime.Processes.Current(Identity);
    Assert(R.Code = rcOk, 'runtime router publishes current identity');
    R := EngineRuntime.Execute('memory_read', Format(
      '{"task_id":"task:router","process_identity_ref":"%s",' +
      '"lease_ref":"lease:router","address":"0x%x","byte_count":4}',
      [Identity.Id, QWord(PtrUInt(@Sentinel[0]))]));
    Assert(R.Code = rcOk, 'runtime router performs bounded read');
    Assert(Pos('cafebabe', LowerCase(R.DataJson)) > 0,
      'runtime router returns sentinel bytes');
    R := EngineRuntime.Execute('memory_scan_start', Format(
      '{"task_id":"task:router","process_identity_ref":"%s",' +
      '"lease_ref":"lease:router","scan_kind":"value",' +
      '"value_type":"dword","value":"767","epoch":%d,' +
      '"budget":{"max_bytes":4,"max_results":10},' +
      '"ranges":[{"start":"0x%x","size":4}]}',
      [Identity.Id, Identity.Epoch, QWord(PtrUInt(@Sentinel[0]))]));
    Assert((R.Code = rcApprovalRequired) and
      (R.StableCode = 'local_scan_scope_required'),
      'value scan through remote router needs a local scope');
    FirstAddress := QWord(PtrUInt(@Sentinel[0]));
    SecondAddress := QWord(PtrUInt(@Sentinel2[0]));
    if FirstAddress > SecondAddress then
    begin
      FirstAddress := QWord(PtrUInt(@Sentinel2[0]));
      SecondAddress := QWord(PtrUInt(@Sentinel[0]));
    end;
    SetLength(MultiRanges, 2);
    MultiRanges[0].StartAddress := FirstAddress;
    MultiRanges[0].Size := 4;
    MultiRanges[1].StartAddress := SecondAddress;
    MultiRanges[1].Size := 4;
    Assert(EngineRuntime.Scanner.AuthorizeLocalRanges(Identity,
      MultiRanges, 8, 10, ScopeId).Code = rcOk,
      'local operator authorizes an exact two-range scope');
    Backend.ConfigureScanRegion(FirstAddress, 4);
    R := EngineRuntime.Execute('memory_scan_start', Format(
      '{"task_id":"task:router","process_identity_ref":"%s",' +
      '"lease_ref":"lease:router","scope_id":"%s",' +
      '"scan_kind":"value","value_type":"dword",' +
      '"value":"cafebabe","epoch":%d,' +
      '"budget":{"max_bytes":8,"max_results":10},' +
      '"ranges":[{"start":"0x%x","size":4},' +
      '{"start":"0x%x","size":4}]}',
      [Identity.Id, ScopeId, Identity.Epoch, FirstAddress, SecondAddress]));
    Assert(R.Code = rcOk,
      'runtime router preserves an authorized multi-range request');
    Assert(EngineRuntime.Scanner.CancelScan('selftest-scan-1',
      Identity).Code = rcOk, 'multi-range router scan is released');
    R := EngineRuntime.Execute('process_detach', Format(
      '{"process_identity_ref":"%s","epoch":%d}',
      [Identity.Id, Identity.Epoch]));
    Assert(R.Code = rcOk, 'runtime router detaches the exact identity');

    R := RegisterEngine(Backend, Hasher);
    Assert(R.Code = rcConflict, 'duplicate registration is rejected');

    UnregisterEngine;
    Assert(not EngineRegistered,
      'unregister releases and unpublishes runtime');
    WriteLn('cea_win32_engine_runtime=PASS');
  finally
    UnregisterEngine;
    Hasher.Free;
    Backend.Free;
  end;
end.
