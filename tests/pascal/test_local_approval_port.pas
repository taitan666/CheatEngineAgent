program test_local_approval_port;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_test_ports,
  cea_local_approval_port;

var
  Store: TCEATestGovernanceStore;
  Clock: TCEATestClock;
  Hasher: TCEATestHasher;
  Port: TCEALocalApprovalPort;
  Effect: TCEAEffect;
  Decision: TCEAApprovalDecision;
  R: TCEAResult;

begin
  Store := TCEATestGovernanceStore.Create;
  Clock := TCEATestClock.Create;
  Hasher := TCEATestHasher.Create;
  Port := TCEALocalApprovalPort.Create(Store, Clock, Hasher);
  try
    Clock.CurrentTime := '2026-09-14T10:00:00.000Z';
    FillChar(Effect, SizeOf(Effect), 0);
    Effect.Id := 'effect-local-approval';
    Effect.TaskId := 'task-local-approval';
    Effect.CapabilityId := 'memory_write';
    Effect.RequestHash := 'sha256:' + StringOfChar('a', 64);
    Effect.ProcessIdentityId := 'process-local-approval';
    Effect.PolicySnapshotId := 'policy:single-player-v1';
    Effect.State := esPlanned;
    Effect.TargetClassification := tcSinglePlayerOffline;

    R := Port.Approve(Effect, '2026-09-14T10:01:00.000Z');
    Assert(R.Code = rcOk, 'local UI can approve a planned offline effect');
    Assert(Port.FindDecision(Effect.Id, Decision).Code = rcOk,
      'approval is durably retrievable');
    Assert(Decision.Origin = aoLocalUserInterface,
      'approval origin is local UI');
    Assert(Decision.RequestHash = Effect.RequestHash,
      'approval is bound to exact request hash');
    Assert(Decision.ProcessIdentityId = Effect.ProcessIdentityId,
      'approval is bound to exact process identity');
    Assert((Decision.MaxExecutions = 1) and
      (Decision.Outcome = adApproved), 'approval is single-use');

    Effect.TargetClassification := tcMultiplayerOrOnline;
    Assert(Port.Approve(Effect, '2026-09-14T10:01:00.000Z').Code =
      rcTargetNotOffline, 'online target cannot be approved');
    Effect.TargetClassification := tcSinglePlayerOffline;
    Effect.State := esExecuting;
    Assert(Port.Approve(Effect, '2026-09-14T10:01:00.000Z').Code =
      rcConflict, 'only planned effects can be approved');
    WriteLn('LOCAL_APPROVAL_PORT=PASS');
  finally
    Port.Free;
    Hasher.Free;
    Clock.Free;
    Store.Free;
  end;
end.
