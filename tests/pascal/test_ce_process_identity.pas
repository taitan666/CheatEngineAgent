program test_ce_process_identity;

{$mode objfpc}{$H+}

uses
  cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_test_ports;

var
  Hasher: TCEATestHasher;
  Service: TCEAProcessIdentityService;
  Info: TCEARuntimeProcessInfo;
  Identity1, Identity2: TCEProcessIdentity;
  FirstId: string;

begin
  Hasher := TCEATestHasher.Create;
  Service := TCEAProcessIdentityService.Create(Hasher);
  try
    FillChar(Info, SizeOf(Info), 0);
    Info.Pid := 4321;
    Info.StartedAt := '2026-09-13T10:00:00.000Z';
    Info.ExecutablePath := 'C:\Games\SelfTest.exe';
    Info.ExecutableSha256 :=
      'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    Info.Architecture := caX86_64;
    Info.ModuleSetHash :=
      'sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';

    Assert(Service.Observe(Info, tcSinglePlayerOffline,
      Identity1).Code = rcOk, 'first process identity is created');
    Assert(Identity1.Epoch = 1, 'first identity starts at epoch one');
    Assert(Identity1.Pid = 4321, 'identity retains PID');
    Assert(Identity1.TargetClassification = tcSinglePlayerOffline,
      'identity retains admitted classification');
    FirstId := Identity1.Id;

    Assert(Service.Observe(Info, tcSinglePlayerOffline,
      Identity2).Code = rcOk, 'same process can be observed again');
    Assert(Identity2.Epoch = 1, 'unchanged process keeps epoch');
    Assert(Identity2.Id = FirstId, 'unchanged process keeps identity ID');

    Info.StartedAt := '2026-09-13T10:01:00.000Z';
    Assert(Service.Observe(Info, tcSinglePlayerOffline,
      Identity2).Code = rcOk, 'PID reuse creates a new identity');
    Assert(Identity2.Epoch = 2, 'PID reuse advances epoch');
    Assert(Identity2.Id <> FirstId, 'PID reuse changes identity ID');

    Info.ModuleSetHash :=
      'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    Assert(Service.Observe(Info, tcSinglePlayerOffline,
      Identity2).Code = rcOk, 'module change is observed');
    Assert(Identity2.Epoch = 3, 'module change advances epoch');

    Info.Pid := 0;
    Assert(Service.Observe(Info, tcSinglePlayerOffline,
      Identity2).Code = rcInvalidArgument, 'PID zero is rejected');
    Info.Pid := 4321;
    Assert(Service.Observe(Info, tcUnknown,
      Identity2).Code = rcTargetNotOffline,
      'unclassified target is not admitted');

    WriteLn('CE_PROCESS_IDENTITY=PASS');
  finally
    Service.Free;
    Hasher.Free;
  end;
end.
