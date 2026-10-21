program test_win32_readonly_backend;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, fpjson, jsonparser, cea_types, cea_results,
  cea_runtime_backend_ports,
  cea_process_capability, cea_memory_read_capability,
  cea_module_capability, cea_scan_capability,
  cea_disassembly_capability, cea_windows_sha256,
  cea_win32_readonly_backend;

const
  Sentinel: array[0..7] of Byte = ($52, $45, $41, $44, $4F, $4E, $4C, $59);
  CodeBytes: array[0..2] of Byte = ($90, $90, $C3);

function WaitScanReady(const AScanner: TCEAScanCapability;
  const AScanId: string; const AIdentity: TCEProcessIdentity): TCEAResult;
var
  Data: TJSONData;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 10000;
  repeat
    Result := AScanner.GetStatus(AScanId, AIdentity);
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

var
  ValuePage: Pointer;
  StatusData: TJSONData;
  Hasher: TCEAWindowsSha256;
  Backend: TCEAWin32ReadOnlyBackend;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Memory: TCEAMemoryReadCapability;
  Modules: TCEAModuleCapability;
  Scanner: TCEAScanCapability;
  Disassembly: TCEADisassemblyCapability;
  AttachRequest: TCEAttachRequest;
  ReadRequest: TCEMemoryReadRequest;
  ScanRequest: TCEScanRequest;
  DisassemblyRequest: TCEDisassembleRequest;
  Identity: TCEProcessIdentity;
  Info: TCEARuntimeProcessInfo;
  R: TCEAResult;
  ScopeId: string;
  MixedBase: Pointer;
  MixedPageSize: Cardinal;
  OldProtect: DWORD;
  SystemInfo: TSystemInfo;

begin
  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Memory := TCEAMemoryReadCapability.Create(Backend, Processes, 4096);
  Modules := TCEAModuleCapability.Create(Backend, Processes, 64);
  Scanner := TCEAScanCapability.Create(Backend, Processes, 64 * 1024, 16, 1);
  Disassembly := TCEADisassemblyCapability.Create(Backend, Processes, 64);
  try
    R := Backend.QueryProcessInfo(GetCurrentProcessId, Info);
    Assert(R.Code = rcOk, 'production backend queries current process');
    Assert(Info.ExecutableSha256 = Hasher.HashFile(Info.ExecutablePath),
      'process identity contains the real executable file hash');
    Assert(Length(Info.ModuleSetHash) = 71,
      'process identity contains a SHA-256 module-set hash');

    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:production-readonly';
    AttachRequest.LeaseId := 'lease:production-readonly';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    Assert(Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      Identity).Code = rcOk, 'production backend attaches read-only');

    FillChar(ReadRequest, SizeOf(ReadRequest), 0);
    ReadRequest.TaskId := AttachRequest.TaskId;
    ReadRequest.LeaseId := AttachRequest.LeaseId;
    ReadRequest.ProcessIdentityId := Identity.Id;
    ReadRequest.Address := QWord(PtrUInt(@Sentinel[0]));
    ReadRequest.ByteCount := SizeOf(Sentinel);
    R := Memory.Read(ReadRequest, Identity);
    Assert(R.Code = rcOk, 'production backend reads current process memory');
    Assert(Pos('524541444f4e4c59', LowerCase(R.DataJson)) > 0,
      'production memory read returns the literal sentinel');

    R := Modules.ListModules(AttachRequest.TaskId, AttachRequest.LeaseId,
      Identity, 16);
    Assert(R.Code = rcOk, 'production backend enumerates loaded modules');
    Assert(Pos('test_win32_readonly_backend.exe', LowerCase(R.DataJson)) > 0,
      'production module list contains current executable');

    FillChar(ScanRequest, SizeOf(ScanRequest), 0);
    ScanRequest.TaskId := AttachRequest.TaskId;
    ScanRequest.ProcessIdentityId := Identity.Id;
    ScanRequest.LeaseId := AttachRequest.LeaseId;
    ScanRequest.ScanKind := 'aob';
    ScanRequest.ValueText := '52 45 41 44 4F 4E 4C 59';
    ScanRequest.RangeStart := QWord(PtrUInt(@Sentinel[0]));
    ScanRequest.RangeSize := SizeOf(Sentinel);
    ScanRequest.MaxBytes := SizeOf(Sentinel);
    ScanRequest.MaxResults := 16;
    ScanRequest.Epoch := Identity.Epoch;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk, 'production backend performs bounded AOB scan');
    R := WaitScanReady(Scanner, 'win32-scan-1', Identity);
    Assert(Pos(LowerCase(IntToHex(ScanRequest.RangeStart, 16)),
      LowerCase(R.DataJson)) > 0,
      'production AOB scan finds the exact sentinel address');
    Assert(Scanner.CancelScan('win32-scan-1', Identity).Code = rcOk,
      'production AOB scan session cancels cleanly');

    ValuePage := VirtualAlloc(nil, 4096, MEM_RESERVE or MEM_COMMIT,
      PAGE_READWRITE);
    Assert(ValuePage <> nil, 'private value page allocated');
    PCardinal(ValuePage)^ := 767;
    ScanRequest.ScanKind := 'value';
    ScanRequest.ValueType := 'dword';
    ScanRequest.ValueText := '767';
    ScanRequest.RangeStart := QWord(PtrUInt(ValuePage));
    ScanRequest.RangeSize := SizeOf(Cardinal);
    ScanRequest.MaxBytes := SizeOf(Cardinal);
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert((R.Code = rcApprovalRequired) and
      (R.StableCode = 'local_scan_scope_required'),
      'value scan requires explicit local scope');
    R := Scanner.AuthorizeLocalScope(Identity, ScanRequest.RangeStart,
      ScanRequest.RangeSize, ScanRequest.MaxBytes,
      ScanRequest.MaxResults, ScopeId);
    Assert((R.Code = rcOk) and (ScopeId <> ''),
      'local operator can authorize exact scan scope');
    ScanRequest.ScopeId := ScopeId;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk, 'production backend scans typed dword');
    R := WaitScanReady(Scanner, 'win32-scan-2', Identity);
    Assert(Pos(LowerCase(IntToHex(ScanRequest.RangeStart, 16)),
      LowerCase(R.DataJson)) > 0, 'value scan finds aligned sentinel');
    Assert(Pos('"complete":true', R.DataJson) > 0,
      'fully read exact range reports complete coverage');
    Assert(Pos('"partial_reason":""', R.DataJson) > 0,
      'complete scan has no partial-coverage reason');
    R := Scanner.GetStatus('win32-scan-2', Identity);
    Assert(R.Code = rcOk, 'scan status is available');
    StatusData := GetJSON(R.DataJson);
    try
      Assert((TJSONObject(StatusData).Get('match_count', -1) = 1) and
        (TJSONObject(StatusData).Get('inspected_bytes', -1) = 4) and
        TJSONObject(StatusData).Get('complete', False),
        'status exposes observed candidate and coverage after scan');
    finally
      StatusData.Free;
    end;
    PCardinal(ValuePage)^ := 758;
    ScanRequest.ValueText := '758';
    R := Scanner.RefineScan('win32-scan-2', ScanRequest, Identity);
    Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
      'first value refine preserves candidate');
    PCardinal(ValuePage)^ := 880;
    ScanRequest.ValueText := '880';
    R := Scanner.RefineScan('win32-scan-2', ScanRequest, Identity);
    Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
      'second value refine preserves candidate');
    Assert(VirtualProtect(ValuePage, 4096, PAGE_NOACCESS, OldProtect),
      'candidate page can become unreadable before refinement');
    try
      ScanRequest.ValueText := '881';
      R := Scanner.RefineScan('win32-scan-2', ScanRequest, Identity);
      Assert((R.Code = rcOk) and
        (Pos('"match_count":1', R.DataJson) > 0) and
        (Pos('"complete":false', R.DataJson) > 0) and
        (Pos('"partial_reason":"refine_read_failed"',
          R.DataJson) > 0),
        'unreadable candidate remains unresolved with partial status');
    finally
      Assert(VirtualProtect(ValuePage, 4096, PAGE_READWRITE, OldProtect),
        'candidate page protection restored');
    end;
    Assert(Scanner.CancelScan('win32-scan-2', Identity).Code = rcOk,
      'value scan session cancels cleanly');
    VirtualFree(ValuePage, 0, MEM_RELEASE);

    GetSystemInfo(SystemInfo);
    MixedPageSize := SystemInfo.dwPageSize;
    MixedBase := VirtualAlloc(nil, MixedPageSize * 3,
      MEM_RESERVE or MEM_COMMIT, PAGE_READWRITE);
    Assert(MixedBase <> nil, 'mixed page fixture allocated');
    try
      PCardinal(MixedBase)^ := 767;
      PCardinal(PtrUInt(MixedBase) + MixedPageSize * 2)^ := 767;
      Assert(VirtualProtect(Pointer(PtrUInt(MixedBase) + MixedPageSize),
        MixedPageSize, PAGE_NOACCESS, OldProtect),
        'middle page made unreadable');
      ScanRequest.ValueText := '767';
      ScanRequest.RangeStart := QWord(PtrUInt(MixedBase));
      ScanRequest.RangeSize := QWord(MixedPageSize) * 3;
      ScanRequest.MaxBytes := ScanRequest.RangeSize;
      R := Scanner.AuthorizeLocalScope(Identity, ScanRequest.RangeStart,
        ScanRequest.RangeSize, ScanRequest.MaxBytes,
        ScanRequest.MaxResults, ScopeId);
      Assert(R.Code = rcOk, 'mixed scope is locally authorized');
      ScanRequest.ScopeId := ScopeId;
      R := Scanner.FirstScan(ScanRequest, Identity);
      R := WaitScanReady(Scanner, 'win32-scan-3', Identity);
      Assert((R.Code = rcOk) and (Pos('"match_count":2', R.DataJson) > 0),
        'value scan crosses unreadable middle page and finds both matches');
      Assert((Pos('"complete":false', R.DataJson) > 0) and
        (Pos('"skipped_bytes":' + IntToStr(MixedPageSize),
          R.DataJson) > 0),
        'unreadable page is disclosed as partial coverage');
      Assert(Scanner.CancelScan('win32-scan-3', Identity).Code = rcOk,
        'mixed page scan cancels');
    finally
      VirtualFree(MixedBase, 0, MEM_RELEASE);
    end;

    FillChar(DisassemblyRequest, SizeOf(DisassemblyRequest), 0);
    DisassemblyRequest.TaskId := AttachRequest.TaskId;
    DisassemblyRequest.ProcessIdentityId := Identity.Id;
    DisassemblyRequest.LeaseId := AttachRequest.LeaseId;
    DisassemblyRequest.Address := QWord(PtrUInt(@CodeBytes[0]));
    DisassemblyRequest.ByteCount := SizeOf(CodeBytes);
    R := Disassembly.Disassemble(DisassemblyRequest, Identity);
    Assert(R.Code = rcOk, 'production backend disassembles bounded bytes');
    Assert((Pos('nop', LowerCase(R.DataJson)) > 0) and
      (Pos('ret', LowerCase(R.DataJson)) > 0),
      'production minimal decoder recognizes NOP and RET');

    Assert(Processes.Detach(Identity).Code = rcOk,
      'production backend detaches cleanly');
    WriteLn('WIN32_READONLY_BACKEND=PASS');
  finally
    Disassembly.Free;
    Scanner.Free;
    Modules.Free;
    Memory.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
  end;
end.
