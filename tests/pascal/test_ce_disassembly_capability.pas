program test_ce_disassembly_capability;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_disassembly_capability,
  cea_win32_selftest_backend, cea_test_ports;

const
  Instructions: array[0..2] of Byte = ($90, $90, $C3);

var
  Backend: TCEAWin32SelfTestBackend;
  Hasher: TCEATestHasher;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Disassembly: TCEADisassemblyCapability;
  AttachRequest: TCEAttachRequest;
  Request: TCEDisassembleRequest;
  Identity, StaleIdentity: TCEProcessIdentity;
  R: TCEAResult;
  CallsBefore: Cardinal;

begin
  Backend := TCEAWin32SelfTestBackend.Create(GetCurrentProcessId);
  Hasher := TCEATestHasher.Create;
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Disassembly := TCEADisassemblyCapability.Create(Backend, Processes, 64);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:self-disassembly';
    AttachRequest.LeaseId := 'lease:self-disassembly';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    Assert(Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      Identity).Code = rcOk, 'authorized self-test attach succeeds');

    FillChar(Request, SizeOf(Request), 0);
    Request.TaskId := AttachRequest.TaskId;
    Request.ProcessIdentityId := Identity.Id;
    Request.LeaseId := AttachRequest.LeaseId;
    Request.Address := QWord(PtrUInt(@Instructions[0]));
    Request.ByteCount := SizeOf(Instructions);
    R := Disassembly.Disassemble(Request, Identity);
    Assert(R.Code = rcOk, 'bounded self-process disassembly succeeds');
    Assert(Pos('"mnemonic":"nop"', LowerCase(R.DataJson)) > 0,
      'disassembly decodes NOP');
    Assert(Pos('"mnemonic":"ret"', LowerCase(R.DataJson)) > 0,
      'disassembly decodes RET');
    Assert(Backend.DisassembleCount = 1,
      'valid disassembly reaches backend once');

    Request.ByteCount := 65;
    CallsBefore := Backend.DisassembleCount;
    R := Disassembly.Disassemble(Request, Identity);
    Assert(R.Code = rcBudgetExceeded,
      'disassembly byte budget is enforced before dispatch');
    Assert(Backend.DisassembleCount = CallsBefore,
      'over-budget disassembly never reaches backend');

    Request.ByteCount := 8;
    Request.Address := High(QWord) - 3;
    R := Disassembly.Disassemble(Request, Identity);
    Assert(R.Code = rcInvalidArgument,
      'wrapping disassembly range is rejected before dispatch');
    Assert(Backend.DisassembleCount = CallsBefore,
      'wrapping disassembly never reaches backend');

    Request.Address := QWord(PtrUInt(@Instructions[0]));
    Request.ByteCount := SizeOf(Instructions);
    StaleIdentity := Identity;
    Inc(StaleIdentity.Epoch);
    R := Disassembly.Disassemble(Request, StaleIdentity);
    Assert(R.Code = rcStaleProcessIdentity,
      'stale identity cannot disassemble memory');
    Assert(Backend.DisassembleCount = CallsBefore,
      'stale disassembly never reaches backend');

    Assert(Processes.Detach(Identity).Code = rcOk,
      'self-test process detaches cleanly');
    WriteLn('CE_DISASSEMBLY_CAPABILITY=PASS');
  finally
    Disassembly.Free;
    Processes.Free;
    Identities.Free;
    Hasher.Free;
    Backend.Free;
  end;
end.
