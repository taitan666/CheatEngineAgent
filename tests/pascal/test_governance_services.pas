program test_governance_services;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_policy_model, cea_lease_service,
  cea_effect_service, cea_governance_gateway, cea_test_ports,
  cea_policy_engine;

var
  Clock: TCEATestClock;
  Hasher: TCEATestHasher;
  Store: TCEATestGovernanceStore;
  Approvals: TCEATestApprovalPort;
  Capabilities: TCEATestCapabilityPort;
  Policy: TCEAPolicyModel;
  Leases: TCEALeaseService;
  Effects: TCEAEffectService;
  Gateway: TCEAGovernanceGateway;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  Decision: TCEAApprovalDecision;
  Effect: TCEAEffect;
  R: TCEAResult;
  LegacyPolicy: TCEAInertPolicyEngine;

begin
  Clock := TCEATestClock.Create;
  Hasher := TCEATestHasher.Create;
  Store := TCEATestGovernanceStore.Create;
  Approvals := TCEATestApprovalPort.Create;
  Capabilities := TCEATestCapabilityPort.Create;
  Policy := TCEAPolicyModel.Create;
  Leases := TCEALeaseService.Create(Store, Clock);
  Effects := TCEAEffectService.Create(Store, Clock, Approvals, Hasher);
  Gateway := TCEAGovernanceGateway.Create(Policy, Leases, Effects,
    Capabilities);
  try
    Clock.CurrentTime := '2026-09-12T10:00:00.000Z';
    FillChar(Context, SizeOf(Context), 0);
    Context.TaskId := 'task-1';
    Context.LeaseId := 'lease-1';
    Context.ProcessIdentityId := 'process-1';
    Context.PolicySnapshotId := 'policy-1';
    Context.TargetClassification := tcSinglePlayerOffline;
    Context.Epoch := 7;
    Context.RequesterOrigin := aoMcpClient;

    FillChar(Lease, SizeOf(Lease), 0);
    Lease.Id := Context.LeaseId;
    Lease.CapabilityId := 'memory_write';
    Lease.ProcessIdentityId := Context.ProcessIdentityId;
    Lease.Epoch := Context.Epoch;
    Lease.IssuedAt := '2026-09-12T09:59:00.000Z';
    Lease.ExpiresAt := '2026-09-12T10:05:00.000Z';
    Lease.RemainingCalls := 2;
    Lease.RemainingBytes := 16;
    Store.AddLease(Lease);

    R := Gateway.InvokeRead('model_training', Context, '{}');
    Assert(R.Code = rcPolicyDenied, 'model training permanently denied');
    R := Gateway.InvokeRead('kernel_driver', Context, '{}');
    Assert(R.Code = rcPolicyDenied, 'kernel driver permanently denied');
    Assert(Capabilities.ExecutionCount = 0, 'denied reads never execute');

    Context.LeaseId := 'missing-read-lease';
    R := Gateway.InvokeRead('memory_read', Context, '{}');
    Assert(R.Code = rcUnauthorized, 'read requires a scoped lease');
    Assert(Capabilities.ExecutionCount = 0,
      'read without lease never reaches capability');
    Context.LeaseId := 'lease-1';

    R := Gateway.RequestEffect('memory_write', Context,
      '{"address":"0x1000","expected":"00","replacement":"01"}',
      'write-once-1');
    Assert(R.Code = rcApprovalRequired, 'write requires local approval');
    Effect := Store.LastEffect;
    Assert(Effect.Id <> '', 'planned effect persisted');
    Assert(Effect.State = esPlanned, 'effect starts planned');

    FillChar(Decision, SizeOf(Decision), 0);
    Decision.Id := 'approval-model';
    Decision.EffectId := Effect.Id;
    Decision.RequestHash := Effect.RequestHash;
    Decision.ProcessIdentityId := Effect.ProcessIdentityId;
    Decision.PolicySnapshotId := Effect.PolicySnapshotId;
    Decision.Origin := aoModel;
    Decision.Outcome := adApproved;
    Decision.DecidedAt := Clock.CurrentTime;
    Decision.ExpiresAt := '2026-09-12T10:01:00.000Z';
    Decision.MaxExecutions := 1;
    Approvals.AddDecision(Decision);
    Assert(Gateway.ExecuteApprovedEffect(Effect.Id).Code = rcUnauthorized,
      'model cannot approve its own effect');
    Assert(Capabilities.ExecutionCount = 0, 'model approval never executes');

    Decision.Id := 'approval-local';
    Decision.Origin := aoLocalUserInterface;
    Approvals.AddDecision(Decision);
    Capabilities.NextResult := TCEAResult.Ok('{"written":true}');
    R := Gateway.ExecuteApprovedEffect(Effect.Id);
    Assert(R.Code = rcOk, 'local approval executes');
    Assert(Capabilities.ExecutionCount = 1, 'effect executes exactly once');
    Assert(Capabilities.LastInvokedEffect.Id = Effect.Id,
      'capability receives the authoritative effect envelope');
    Assert(Capabilities.LastInvokedEffect.ApprovalId = 'approval-local',
      'capability receives the validated local approval id');
    Assert(Capabilities.LastInvokedEffect.State = esExecuting,
      'capability only receives an effect persisted as executing');
    Assert(Store.LastEffect.State = esApplied, 'effect becomes applied');
    R := Gateway.ExecuteApprovedEffect(Effect.Id);
    Assert(R.Code = rcOk, 'applied effect returns stored result');
    Assert(Capabilities.ExecutionCount = 1, 'applied effect is not replayed');

    LegacyPolicy := TCEAInertPolicyEngine.Create;
    try
      Assert(LegacyPolicy.Evaluate('kernel_driver',
        'single_player_offline').Code = rcPolicyDenied,
        'legacy runtime policy uses permanent denies');
      Assert(LegacyPolicy.Evaluate('memory_read', 'unknown').Code =
        rcTargetNotOffline, 'legacy runtime policy requires offline target');
    finally
      LegacyPolicy.Free;
    end;

    WriteLn('PASCAL_TEST=PASS');
  finally
    Gateway.Free;
    Effects.Free;
    Leases.Free;
    Policy.Free;
    Capabilities.Free;
    Approvals.Free;
    Store.Free;
    Hasher.Free;
    Clock.Free;
  end;
end.
