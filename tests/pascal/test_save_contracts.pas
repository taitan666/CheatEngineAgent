program test_save_contracts;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_save_types, cea_save_ports,
  cea_test_ports, cea_policy_model, cea_lease_service,
  cea_effect_service, cea_governance_gateway;

var
  Context: TCEACapabilityContext;
  Snapshot: TCEASaveSnapshot;
  Clock: TCEATestClock;
  Store: TCEATestGovernanceStore;
  Hasher: TCEATestHasher;
  Approvals: TCEATestApprovalPort;
  Capabilities: TCEATestCapabilityPort;
  Policy: TCEAPolicyModel;
  Leases: TCEALeaseService;
  Effects: TCEAEffectService;
  Gateway: TCEAGovernanceGateway;
  Lease: TCEALease;
  R: TCEAResult;
begin
  FillChar(Context, SizeOf(Context), 0);
  Context.ResourceKind := rkSaveFile;
  Context.ResourceIdentityId := 'file:volume:identity';
  Assert(Ord(rkProcess) <> Ord(rkSaveFile));
  Assert(Context.ResourceKind = rkSaveFile);
  Assert(Context.ResourceIdentityId <> '');
  FillChar(Snapshot, SizeOf(Snapshot), 0);
  Assert(not Snapshot.Editable);
  Clock := TCEATestClock.Create;
  Store := TCEATestGovernanceStore.Create;
  Hasher := TCEATestHasher.Create;
  Approvals := TCEATestApprovalPort.Create;
  Capabilities := TCEATestCapabilityPort.Create;
  Policy := TCEAPolicyModel.Create;
  Leases := TCEALeaseService.Create(Store, Clock);
  Effects := TCEAEffectService.Create(Store, Clock, Approvals, Hasher);
  Gateway := TCEAGovernanceGateway.Create(Policy, Leases, Effects,
    Capabilities);
  try
    Clock.CurrentTime := '2026-09-19T10:00:00.000Z';
    Context.TaskId := 'save-task';
    Context.LeaseId := 'save-lease';
    Context.PolicySnapshotId := 'offline-policy';
    Context.TargetClassification := tcSinglePlayerOffline;
    Context.Epoch := 1;
    FillChar(Lease, SizeOf(Lease), 0);
    Lease.Id := Context.LeaseId;
    Lease.CapabilityId := 'save_edit';
    Lease.ResourceKind := rkSaveFile;
    Lease.ResourceIdentityId := Context.ResourceIdentityId;
    Lease.ExpiresAt := '2026-09-19T10:05:00.000Z';
    Lease.RemainingCalls := 1;
    Lease.Epoch := Context.Epoch;
    Store.AddLease(Lease);
    R := Gateway.RequestEffect('save_edit', Context, '{}', 'same-key');
    Assert(R.Code = rcApprovalRequired, 'save effect planned');
    Assert(Store.LastEffect.ResourceKind = rkSaveFile);
    Assert(Store.LastEffect.ResourceIdentityId = Context.ResourceIdentityId);
    Context.ResourceIdentityId := '';
    Assert(Gateway.RequestEffect('save_edit', Context, '{}', 'new-key').Code =
      rcInvalidArgument, 'empty file identity rejected');
  finally
    Gateway.Free;
    Effects.Free;
    Leases.Free;
    Policy.Free;
    Capabilities.Free;
    Approvals.Free;
    Hasher.Free;
    Store.Free;
    Clock.Free;
  end;
  WriteLn('SAVE_CONTRACTS=PASS');
end.
