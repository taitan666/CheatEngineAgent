program read_sdv_heap;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_memory_read_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

var
  TargetPid: Cardinal;
  TargetAddress: QWord;
  ParseCode: Integer;
  Hasher: TCEAWindowsSha256;
  Backend: TCEAWin32ReadOnlyBackend;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Memory: TCEAMemoryReadCapability;
  AttachRequest: TCEAttachRequest;
  ReadRequest: TCEMemoryReadRequest;
  Identity: TCEProcessIdentity;
  R: TCEAResult;

begin
  Assert(ParamCount = 2, 'pid and address are required');
  Val(ParamStr(1), TargetPid, ParseCode);
  Assert(ParseCode = 0, 'pid is valid');
  Assert((Copy(ParamStr(2), 1, 2) = '0x') and
    TryStrToQWord('$' + Copy(ParamStr(2), 3, MaxInt), TargetAddress),
    'address is valid');

  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Memory := TCEAMemoryReadCapability.Create(Backend, Processes, 4096);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:read-heap';
    AttachRequest.LeaseId := 'lease:read-heap';
    AttachRequest.Pid := TargetPid;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcOk, 'attach');

    FillChar(ReadRequest, SizeOf(ReadRequest), 0);
    ReadRequest.TaskId := AttachRequest.TaskId;
    ReadRequest.LeaseId := AttachRequest.LeaseId;
    ReadRequest.ProcessIdentityId := Identity.Id;
    ReadRequest.Address := TargetAddress;
    ReadRequest.ByteCount := 32;
    R := Memory.Read(ReadRequest, Identity);
    WriteLn('READ code=' + R.StableCode);
    WriteLn('READ data=' + R.DataJson);
  finally
    Memory.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
  end;
end.
