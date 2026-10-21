program test_ce_readonly_integration;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_memory_read_capability,
  cea_win32_selftest_backend, cea_test_ports;

const
  Sentinel: array[0..7] of Byte = ($DE, $AD, $BE, $EF, $10, $20, $30, $40);

var
  Backend: TCEAWin32SelfTestBackend;
  Hasher: TCEATestHasher;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Memory: TCEAMemoryReadCapability;
  AttachRequest: TCEAttachRequest;
  ReadRequest: TCEMemoryReadRequest;
  Identity, WrongIdentity: TCEProcessIdentity;
  R: TCEAResult;
  ReadsBefore: Cardinal;

begin
  Backend := TCEAWin32SelfTestBackend.Create(GetCurrentProcessId);
  Hasher := TCEATestHasher.Create;
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Memory := TCEAMemoryReadCapability.Create(Backend, Processes, 4096);
  try
    R := Processes.ListProcesses;
    Assert(R.Code = rcOk, 'real process enumeration succeeds');
    Assert(Pos(IntToStr(GetCurrentProcessId), R.DataJson) > 0,
      'process enumeration contains the self-test process');

    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:self-read';
    AttachRequest.LeaseId := 'lease:self-read';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := False;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcUnauthorized,
      'attach without operator attestation is rejected');
    Assert(Backend.AttachCount = 0,
      'rejected attach never reaches runtime backend');

    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcOk, 'authorized self-test attach succeeds');
    Assert(Identity.Pid = GetCurrentProcessId,
      'attached identity refers to the real self-test process');
    Assert(Identity.Epoch = 1, 'first real attachment uses epoch one');

    FillChar(ReadRequest, SizeOf(ReadRequest), 0);
    ReadRequest.TaskId := AttachRequest.TaskId;
    ReadRequest.ProcessIdentityId := Identity.Id;
    ReadRequest.LeaseId := AttachRequest.LeaseId;
    ReadRequest.Address := QWord(PtrUInt(@Sentinel[0]));
    ReadRequest.ByteCount := SizeOf(Sentinel);
    R := Memory.Read(ReadRequest, Identity);
    Assert(R.Code = rcOk, 'real self-process read succeeds');
    Assert(Pos('deadbeef10203040', LowerCase(R.DataJson)) > 0,
      'read result contains the sentinel bytes');

    WrongIdentity := Identity;
    Inc(WrongIdentity.Epoch);
    ReadsBefore := Backend.ReadCount;
    R := Memory.Read(ReadRequest, WrongIdentity);
    Assert(R.Code = rcStaleProcessIdentity,
      'stale identity cannot read memory');
    Assert(Backend.ReadCount = ReadsBefore,
      'stale read never reaches runtime backend');

    ReadRequest.ProcessIdentityId := Identity.Id;
    ReadRequest.ByteCount := 4097;
    ReadsBefore := Backend.ReadCount;
    R := Memory.Read(ReadRequest, Identity);
    Assert(R.Code = rcBudgetExceeded,
      'read beyond configured maximum is rejected');
    Assert(Backend.ReadCount = ReadsBefore,
      'over-budget read never reaches runtime backend');

    ReadRequest.ByteCount := 8;
    ReadRequest.Address := High(QWord) - 3;
    ReadsBefore := Backend.ReadAttemptCount;
    R := Memory.Read(ReadRequest, Identity);
    Assert(R.Code = rcInvalidArgument,
      'wrapping address range is rejected');
    Assert(Backend.ReadAttemptCount = ReadsBefore,
      'wrapping address range never reaches runtime backend');

    Assert(Processes.Detach(Identity).Code = rcOk,
      'self-test process detaches cleanly');
    WriteLn('CE_READONLY_INTEGRATION=PASS');
  finally
    Memory.Free;
    Processes.Free;
    Identities.Free;
    Hasher.Free;
    Backend.Free;
  end;
end.
