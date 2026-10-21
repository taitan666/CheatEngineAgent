program test_ce_module_capability;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_module_capability,
  cea_win32_selftest_backend, cea_test_ports;

var
  Backend: TCEAWin32SelfTestBackend;
  Hasher: TCEATestHasher;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Modules: TCEAModuleCapability;
  AttachRequest: TCEAttachRequest;
  Identity, StaleIdentity: TCEProcessIdentity;
  R: TCEAResult;
  CallsBefore: Cardinal;

begin
  Backend := TCEAWin32SelfTestBackend.Create(GetCurrentProcessId);
  Hasher := TCEATestHasher.Create;
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Modules := TCEAModuleCapability.Create(Backend, Processes, 32);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:self-modules';
    AttachRequest.LeaseId := 'lease:self-modules';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    Assert(Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      Identity).Code = rcOk, 'authorized self-test attach succeeds');

    R := Modules.ListModules(AttachRequest.TaskId, AttachRequest.LeaseId,
      Identity, 8);
    Assert(R.Code = rcOk, 'real current-process module listing succeeds');
    Assert(Pos('test_ce_module_capability.exe', LowerCase(R.DataJson)) > 0,
      'module listing contains the current executable');
    Assert(Pos('"base_address":"0x', LowerCase(R.DataJson)) > 0,
      'module listing includes explicit hexadecimal base addresses');
    Assert(Backend.ListModulesCount = 1,
      'valid module listing reaches backend once');

    CallsBefore := Backend.ListModulesCount;
    R := Modules.ListModules(AttachRequest.TaskId, AttachRequest.LeaseId,
      Identity, 33);
    Assert(R.Code = rcBudgetExceeded,
      'module result budget is enforced before dispatch');
    Assert(Backend.ListModulesCount = CallsBefore,
      'over-budget module listing never reaches backend');

    StaleIdentity := Identity;
    Inc(StaleIdentity.Epoch);
    R := Modules.ListModules(AttachRequest.TaskId, AttachRequest.LeaseId,
      StaleIdentity, 8);
    Assert(R.Code = rcStaleProcessIdentity,
      'stale identity cannot enumerate modules');
    Assert(Backend.ListModulesCount = CallsBefore,
      'stale module listing never reaches backend');

    Assert(Processes.Detach(Identity).Code = rcOk,
      'self-test process detaches cleanly');
    WriteLn('CE_MODULE_CAPABILITY=PASS');
  finally
    Modules.Free;
    Processes.Free;
    Identities.Free;
    Hasher.Free;
    Backend.Free;
  end;
end.
