program test_win32_child_process;

{$mode objfpc}{$H+}

uses
  SysUtils, FPJSON, JSONParser, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability,
  cea_memory_read_capability, cea_module_capability,
  cea_scan_capability, cea_disassembly_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

function WaitScanReady(const AScanner: TCEAScanCapability;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  Data: TJSONData;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 10000;
  repeat
    Result := AScanner.GetStatus('win32-scan-1', AIdentity);
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
  TargetPid: Cardinal;
  TargetAddress, RangeSize: QWord;
  ParseCode: Integer;
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
  IdentityAfter: TCEProcessIdentity;
  InfoAfter: TCEARuntimeProcessInfo;
  MarkerFile: TextFile;
  ModuleDeadline: QWord;
  R: TCEAResult;

begin
  Assert(ParamCount = 4,
    'pid, address, range size and module marker are required');
  Val(ParamStr(1), TargetPid, ParseCode);
  Assert(ParseCode = 0, 'pid is valid');
  Assert((Copy(ParamStr(2), 1, 2) = '0x') and
    TryStrToQWord('$' + Copy(ParamStr(2), 3, MaxInt), TargetAddress),
    'address is valid');
  Assert(TryStrToQWord(ParamStr(3), RangeSize) and (RangeSize >= 7),
    'range size is valid');

  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Memory := TCEAMemoryReadCapability.Create(Backend, Processes, 4096);
  Modules := TCEAModuleCapability.Create(Backend, Processes, 64);
  Scanner := TCEAScanCapability.Create(Backend, Processes,
    64 * 1024 * 1024, 16, 1);
  Disassembly := TCEADisassemblyCapability.Create(Backend, Processes, 64);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:child-process';
    AttachRequest.LeaseId := 'lease:child-process';
    AttachRequest.Pid := TargetPid;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcOk, 'separate self-target attaches read-only');

    FillChar(ReadRequest, SizeOf(ReadRequest), 0);
    ReadRequest.TaskId := AttachRequest.TaskId;
    ReadRequest.LeaseId := AttachRequest.LeaseId;
    ReadRequest.ProcessIdentityId := Identity.Id;
    ReadRequest.Address := TargetAddress;
    ReadRequest.ByteCount := 7;
    R := Memory.Read(ReadRequest, Identity);
    Assert((R.Code = rcOk) and
      (Pos('9090c3deadbeef', LowerCase(R.DataJson)) > 0),
      'separate self-target sentinel reads correctly');

    R := Modules.ListModules(AttachRequest.TaskId, AttachRequest.LeaseId,
      Identity, 16);
    Assert((R.Code = rcOk) and
      (Pos('cea_self_target.exe', LowerCase(R.DataJson)) > 0),
      'separate self-target module identity is visible');

    FillChar(ScanRequest, SizeOf(ScanRequest), 0);
    ScanRequest.TaskId := AttachRequest.TaskId;
    ScanRequest.LeaseId := AttachRequest.LeaseId;
    ScanRequest.ProcessIdentityId := Identity.Id;
    ScanRequest.ScanKind := 'aob';
    ScanRequest.ValueText := '90 90 C3 DE AD BE EF';
    ScanRequest.RangeStart := TargetAddress;
    ScanRequest.RangeSize := RangeSize;
    ScanRequest.MaxBytes := RangeSize;
    ScanRequest.MaxResults := 16;
    ScanRequest.Epoch := Identity.Epoch;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk, 'separate self-target AOB scan starts');
    R := WaitScanReady(Scanner, Identity);
    Assert((R.Code = rcOk) and
      (Pos(LowerCase(IntToHex(TargetAddress, 16)),
        LowerCase(R.DataJson)) > 0),
      'separate self-target AOB scan finds the exact address');
    Assert(Scanner.CancelScan('win32-scan-1', Identity).Code = rcOk,
      'separate self-target scan cancels');

    FillChar(DisassemblyRequest, SizeOf(DisassemblyRequest), 0);
    DisassemblyRequest.TaskId := AttachRequest.TaskId;
    DisassemblyRequest.LeaseId := AttachRequest.LeaseId;
    DisassemblyRequest.ProcessIdentityId := Identity.Id;
    DisassemblyRequest.Address := TargetAddress;
    DisassemblyRequest.ByteCount := 3;
    R := Disassembly.Disassemble(DisassemblyRequest, Identity);
    Assert((R.Code = rcOk) and (Pos('nop', LowerCase(R.DataJson)) > 0) and
      (Pos('ret', LowerCase(R.DataJson)) > 0),
      'separate self-target bounded disassembly succeeds');

    Assert(Processes.Detach(Identity).Code = rcOk,
      'separate self-target detaches before module-set change');
    AssignFile(MarkerFile, ParamStr(4));
    Rewrite(MarkerFile);
    CloseFile(MarkerFile);
    ModuleDeadline := GetTickCount64 + 5000;
    repeat
      Sleep(10);
      R := Backend.QueryProcessInfo(TargetPid, InfoAfter);
      Assert(R.Code = rcOk, 'changed target identity remains queryable');
    until (InfoAfter.ModuleSetHash <> Identity.ModuleSetHash) or
      (GetTickCount64 >= ModuleDeadline);
    Assert(InfoAfter.ModuleSetHash <> Identity.ModuleSetHash,
      'real target module-set hash changes after loading fixture DLL');
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      IdentityAfter);
    Assert((R.Code = rcOk) and (IdentityAfter.Epoch = Identity.Epoch + 1) and
      (IdentityAfter.Id <> Identity.Id),
      'same PID/start time with a changed module set advances identity epoch');
    R := Memory.Read(ReadRequest, Identity);
    Assert(R.Code = rcStaleProcessIdentity,
      'old identity is rejected after module-set change');
    Assert(Processes.Detach(IdentityAfter).Code = rcOk,
      'changed self-target detaches');
    WriteLn('WIN32_CHILD_PROCESS=PASS');
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
