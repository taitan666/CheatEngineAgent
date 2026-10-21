program test_freeze_service;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_effect_backend_ports,
  cea_effect_service, cea_lease_service, cea_freeze_service, cea_test_ports;

type
  TFreezeBackend = class(TObject, ICEAMemoryEffectBackend)
  public
    CurrentHex: string;
    WriteCount: Cardinal;
    function ReadCurrentHex(const APid: Cardinal; const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
    function CompareWriteReadback(const APid: Cardinal;
      const AAddress: QWord; const AExpectedHex,
      AReplacementHex: string): TCEAResult;
  end;

function TFreezeBackend.ReadCurrentHex(const APid: Cardinal;
  const AAddress: QWord; const AByteCount: Cardinal): TCEAResult;
begin
  Result := TCEAResult.Ok('{"current":"' + CurrentHex + '"}');
end;

function TFreezeBackend.CompareWriteReadback(const APid: Cardinal;
  const AAddress: QWord; const AExpectedHex,
  AReplacementHex: string): TCEAResult;
begin
  if CurrentHex <> AExpectedHex then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'memory_effect_original_changed', '{}'));
  Inc(WriteCount);
  CurrentHex := AReplacementHex;
  Result := TCEAResult.Ok('{"readback_verified":true,"after":"' +
    CurrentHex + '"}');
end;

var
  Store: TCEATestGovernanceStore;
  Clock: TCEATestClock;
  Hasher: TCEATestHasher;
  Approvals: TCEATestApprovalPort;
  Effects: TCEAEffectService;
  Leases: TCEALeaseService;
  Backend: TFreezeBackend;
  Service: TCEAFreezeService;
  Effect, StoredEffect: TCEAEffect;
  Lease: TCEALease;
  Decision: TCEAApprovalDecision;
  Identity, StaleIdentity: TCEProcessIdentity;
  R: TCEAResult;

begin
  Store := TCEATestGovernanceStore.Create;
  Clock := TCEATestClock.Create;
  Hasher := TCEATestHasher.Create;
  Approvals := TCEATestApprovalPort.Create;
  Backend := TFreezeBackend.Create;
  Clock.CurrentTime := '2026-09-15T01:00:00.000Z';
  Effects := TCEAEffectService.Create(Store, Clock, Approvals, Hasher);
  Leases := TCEALeaseService.Create(Store, Clock);
  Service := TCEAFreezeService.Create(Store, Clock, Hasher, Effects,
    Leases, Backend);
  try
    FillChar(Identity, SizeOf(Identity), 0);
    Identity.Id := 'process:test-freeze';
    Identity.Pid := 4242;
    Identity.StartedAt := '2026-09-15T00:59:00.000Z';
    Identity.ExecutableSha256 := 'sha256:' + StringOfChar('a', 64);
    Identity.Epoch := 3;
    Identity.TargetClassification := tcSinglePlayerOffline;

    FillChar(Lease, SizeOf(Lease), 0);
    Lease.Id := 'lease:test-freeze';
    Lease.CapabilityId := 'memory_freeze';
    Lease.ProcessIdentityId := Identity.Id;
    Lease.Epoch := Identity.Epoch;
    Lease.IssuedAt := Clock.CurrentTime;
    Lease.ExpiresAt := '2026-09-15T01:01:00.000Z';
    Lease.RemainingCalls := 2;
    Lease.RemainingBytes := 2;
    Store.AddLease(Lease);

    FillChar(Effect, SizeOf(Effect), 0);
    Effect.Id := 'effect:test-freeze';
    Effect.TaskId := 'task:test-freeze';
    Effect.CapabilityId := 'memory_freeze';
    Effect.RequestHash := Hasher.HashUtf8('freeze-request');
    Effect.RequestJson := '{"target_pid":4242,' +
      '"target_started_at":"2026-09-15T00:59:00.000Z",' +
      '"target_executable_sha256":"sha256:' + StringOfChar('a', 64) + '",' +
      '"address":"0x1000","expected_original_bytes":"10",' +
      '"replacement_bytes":"20","interval_ms":250,"max_writes":2,' +
      '"expires_at":"2026-09-15T01:01:00.000Z"}';
    Effect.ProcessIdentityId := Identity.Id;
    Effect.PolicySnapshotId := 'policy:single-player-v1';
    Effect.LeaseId := Lease.Id;
    Effect.Epoch := Identity.Epoch;
    Effect.State := esPlanned;
    Effect.CreatedAt := Clock.CurrentTime;
    Effect.UpdatedAt := Clock.CurrentTime;
    Effect.TargetClassification := tcSinglePlayerOffline;
    Store.SaveEffect(Effect);

    FillChar(Decision, SizeOf(Decision), 0);
    Decision.Id := 'approval:test-freeze';
    Decision.EffectId := Effect.Id;
    Decision.RequestHash := Effect.RequestHash;
    Decision.ProcessIdentityId := Identity.Id;
    Decision.PolicySnapshotId := Effect.PolicySnapshotId;
    Decision.Origin := aoLocalUserInterface;
    Decision.Outcome := adApproved;
    Decision.DecidedAt := Clock.CurrentTime;
    Decision.ExpiresAt := '2026-09-15T01:00:30.000Z';
    Decision.MaxExecutions := 1;
    Approvals.AddDecision(Decision);

    Backend.CurrentHex := '10';
    Assert(Service.Activate(Effect.Id, Identity).Code = rcOk,
      'locally approved bounded freeze activates without writing');
    Assert(Backend.WriteCount = 0, 'activation never mutates memory');
    Assert(Store.LoadEffect(Effect.Id, StoredEffect).Code = rcOk,
      'active freeze effect remains durable');
    Assert(StoredEffect.State = esExecuting,
      'active freeze is represented by an executing AgentOS Effect');

    R := Service.Tick(Identity);
    Assert((R.Code = rcOk) and (Backend.WriteCount = 1) and
      (Backend.CurrentHex = '20'), 'first tick performs verified write');
    Assert((R.ReceiptId <> '') and (R.ProofId <> ''),
      'every actual freeze write emits Receipt and Proof');
    Assert(Store.LastReceipt.Attempt = 1,
      'first write evidence records attempt one');

    R := Service.Tick(Identity);
    Assert((R.Code = rcOk) and (R.StableCode = 'freeze_value_already_set') and
      (Backend.WriteCount = 1),
      'already-frozen value is observed without another write');

    Backend.CurrentHex := '10';
    R := Service.Tick(Identity);
    Assert((R.Code = rcOk) and (Backend.WriteCount = 2),
      'second permitted original value is re-applied');
    Assert(Store.LastReceipt.Attempt = 2,
      'second write evidence records attempt two');
    Assert(not Service.Active, 'max-write budget closes the session');
    Assert(Store.LoadEffect(Effect.Id, StoredEffect).Code = rcOk,
      'closed freeze effect reloads');
    Assert((StoredEffect.State = esApplied) and
      (Pos('max_writes_reached', StoredEffect.ResultJson) > 0),
      'budget completion is durable and cannot auto-resume');

    Lease.Id := 'lease:test-freeze-stale';
    Lease.RemainingCalls := 1;
    Lease.RemainingBytes := 1;
    Store.AddLease(Lease);
    Effect.Id := 'effect:test-freeze-stale';
    Effect.LeaseId := Lease.Id;
    Effect.State := esPlanned;
    Effect.RequestHash := Hasher.HashUtf8('freeze-stale-request');
    Effect.ResultJson := '';
    Store.SaveEffect(Effect);
    Decision.Id := 'approval:test-freeze-stale';
    Decision.EffectId := Effect.Id;
    Decision.RequestHash := Effect.RequestHash;
    Approvals.AddDecision(Decision);
    Backend.CurrentHex := '10';
    Assert(Service.Activate(Effect.Id, Identity).Code = rcOk,
      'second bounded freeze activates');
    StaleIdentity := Identity;
    Inc(StaleIdentity.Epoch);
    R := Service.Tick(StaleIdentity);
    Assert((R.Code = rcStaleProcessIdentity) and
      (R.StableCode = 'freeze_target_changed'),
      'target change stops the session and reports stale identity');
    Assert(Backend.WriteCount = 2,
      'target change never reaches the write backend');
    Assert(Store.LoadEffect(Effect.Id, StoredEffect).Code = rcOk,
      'target-changed freeze effect remains durable');
    Assert((StoredEffect.State = esRejected) and (not Service.Active),
      'target-changed session is rejected and inactive');

    WriteLn('FREEZE_SERVICE=PASS');
  finally
    Service.Free;
    Leases.Free;
    Effects.Free;
    Backend.Free;
    Approvals.Free;
    Hasher.Free;
    Clock.Free;
    Store.Free;
  end;
end.
