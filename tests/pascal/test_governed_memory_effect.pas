program test_governed_memory_effect;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_types, cea_results, cea_policy_model,
  cea_lease_service, cea_effect_service, cea_governance_gateway,
  cea_test_ports, cea_windows_sha256, cea_win32_readonly_backend,
  cea_win32_effect_backend, cea_win32_engine_runtime,
  cea_win32_governed_capability_port;

var
  Value: array[0..3] of Byte;
  Hasher: TCEAWindowsSha256;
  ReadBackend: TCEAWin32ReadOnlyBackend;
  EffectBackend: TCEAWin32EffectBackend;
  CapabilityPort: TCEAWin32GovernedCapabilityPort;
  Store: TCEATestGovernanceStore;
  Clock: TCEATestClock;
  Approvals: TCEATestApprovalPort;
  Policy: TCEAPolicyModel;
  Leases: TCEALeaseService;
  Effects: TCEAEffectService;
  Gateway: TCEAGovernanceGateway;
  AttachRequest: TCEAttachRequest;
  Identity: TCEProcessIdentity;
  Context: TCEACapabilityContext;
  Lease: TCEALease;
  Effect: TCEAEffect;
  Decision: TCEAApprovalDecision;
  RequestJson: string;
  R: TCEAResult;

begin
  Value[0] := $10; Value[1] := $20; Value[2] := $30; Value[3] := $40;
  Hasher := TCEAWindowsSha256.Create;
  ReadBackend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  EffectBackend := TCEAWin32EffectBackend.Create(4096);
  Store := TCEATestGovernanceStore.Create;
  Clock := TCEATestClock.Create;
  Approvals := TCEATestApprovalPort.Create;
  Policy := TCEAPolicyModel.Create;
  Leases := TCEALeaseService.Create(Store, Clock);
  Effects := TCEAEffectService.Create(Store, Clock, Approvals, Hasher);
  CapabilityPort := nil;
  Gateway := nil;
  try
    Assert(RegisterEngine(ReadBackend, Hasher).Code = rcOk,
      'process runtime registers');
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:governed-write';
    AttachRequest.LeaseId := 'lease:governed-write';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    Assert(EngineRuntime.Processes.Attach(AttachRequest,
      tcSinglePlayerOffline, Identity).Code = rcOk,
      'self-test process attaches read-only');

    CapabilityPort := TCEAWin32GovernedCapabilityPort.Create(
      EngineRuntime, EffectBackend, Hasher);
    Gateway := TCEAGovernanceGateway.Create(Policy, Leases, Effects,
      CapabilityPort);
    Clock.CurrentTime := '2026-09-14T10:00:00.000Z';
    FillChar(Context, SizeOf(Context), 0);
    Context.TaskId := AttachRequest.TaskId;
    Context.LeaseId := AttachRequest.LeaseId;
    Context.ProcessIdentityId := Identity.Id;
    Context.PolicySnapshotId := 'policy:single-player-v1';
    Context.TargetClassification := tcSinglePlayerOffline;
    Context.Epoch := Identity.Epoch;
    Context.RequesterOrigin := aoLocalUserInterface;

    FillChar(Lease, SizeOf(Lease), 0);
    Lease.Id := Context.LeaseId;
    Lease.CapabilityId := 'memory_write';
    Lease.ProcessIdentityId := Identity.Id;
    Lease.Epoch := Identity.Epoch;
    Lease.IssuedAt := '2026-09-14T09:59:00.000Z';
    Lease.ExpiresAt := '2026-09-14T10:05:00.000Z';
    Lease.RemainingCalls := 1;
    Lease.RemainingBytes := 4;
    Store.AddLease(Lease);

    RequestJson := Format('{"task_id":"%s",' +
      '"process_identity_ref":"%s","lease_ref":"%s",' +
      '"address":"0x%x","expected_original_bytes":"10203040",' +
      '"replacement_bytes":"a1b2c3d4"}',
      [Context.TaskId, Identity.Id, Context.LeaseId,
       QWord(PtrUInt(@Value[0]))]);
    R := Gateway.RequestEffect('memory_write', Context, RequestJson,
      'governed-write-once');
    Assert(R.Code = rcApprovalRequired, 'write is planned, not executed');
    Assert(Value[0] = $10, 'planning does not modify memory');
    Effect := Store.LastEffect;

    FillChar(Decision, SizeOf(Decision), 0);
    Decision.Id := 'approval:local-write';
    Decision.EffectId := Effect.Id;
    Decision.RequestHash := Effect.RequestHash;
    Decision.ProcessIdentityId := Effect.ProcessIdentityId;
    Decision.PolicySnapshotId := Effect.PolicySnapshotId;
    Decision.Origin := aoLocalUserInterface;
    Decision.Outcome := adApproved;
    Decision.DecidedAt := Clock.CurrentTime;
    Decision.ExpiresAt := '2026-09-14T10:01:00.000Z';
    Decision.MaxExecutions := 1;
    Approvals.AddDecision(Decision);

    R := Gateway.ExecuteApprovedEffect(Effect.Id);
    Assert(R.Code = rcOk, 'locally approved write executes');
    Assert((Value[0] = $A1) and (Value[3] = $D4),
      'governed write changes exact bytes');
    Assert((R.ReceiptId <> '') and (R.ProofId <> ''),
      'governed write returns Receipt and Proof ids');
    Assert(Store.LastReceipt.Id = R.ReceiptId,
      'Receipt is persisted before success returns');
    Assert(Store.LastProof.Id = R.ProofId,
      'Proof is persisted before success returns');
    Assert(Store.LastEffect.State = esApplied,
      'successful governed write is durably applied');
    WriteLn('GOVERNED_MEMORY_EFFECT=PASS');
  finally
    if (Value[0] = $A1) then
      EffectBackend.CompareWriteReadback(GetCurrentProcessId,
        QWord(PtrUInt(@Value[0])), 'a1b2c3d4', '10203040');
    Gateway.Free;
    CapabilityPort.Free;
    UnregisterEngine;
    Effects.Free;
    Leases.Free;
    Policy.Free;
    Approvals.Free;
    Clock.Free;
    Store.Free;
    EffectBackend.Free;
    ReadBackend.Free;
    Hasher.Free;
  end;
end.
