unit cea_lease_service;

{$mode objfpc}{$H+}

interface

uses
  cea_types, cea_results, cea_ports;

type
  TCEALeaseService = class
  private
    FStore: IGovernanceStore;
    FClock: ICEAClock;
  public
    constructor Create(const AStore: IGovernanceStore;
      const AClock: ICEAClock);
    function Validate(const ALeaseId, ACapabilityId,
      AProcessIdentityId: string; const AEpoch: QWord;
      const AConsumeCall: Boolean): TCEAResult;
    function ValidateResource(const ALeaseId, ACapabilityId: string;
      const AResourceKind: TCEAResourceKind;
      const AResourceIdentityId: string; const AEpoch: QWord;
      const AConsumeCall: Boolean): TCEAResult;
  end;

implementation

constructor TCEALeaseService.Create(const AStore: IGovernanceStore;
  const AClock: ICEAClock);
begin
  inherited Create;
  FStore := AStore;
  FClock := AClock;
end;

function TCEALeaseService.Validate(const ALeaseId, ACapabilityId,
  AProcessIdentityId: string; const AEpoch: QWord;
  const AConsumeCall: Boolean): TCEAResult;
begin
  Result := ValidateResource(ALeaseId, ACapabilityId, rkProcess,
    AProcessIdentityId, AEpoch, AConsumeCall);
end;

function TCEALeaseService.ValidateResource(const ALeaseId,
  ACapabilityId: string; const AResourceKind: TCEAResourceKind;
  const AResourceIdentityId: string; const AEpoch: QWord;
  const AConsumeCall: Boolean): TCEAResult;
var
  Lease: TCEALease;
  LeaseIdentity: string;
begin
  if AResourceIdentityId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'resource_identity_required', '{}'));
  if (FStore = nil) or (FClock = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'lease_dependencies_missing', '{}'));
  Result := FStore.LoadLease(ALeaseId, Lease);
  if Result.Failed then
    Exit;
  if Lease.Revoked then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_revoked', '{}'));
  if FClock.UtcNowIso8601 > Lease.ExpiresAt then
    Exit(TCEAResult.Error(rcLeaseExpired, 'lease_expired', '{}'));
  LeaseIdentity := Lease.ResourceIdentityId;
  if (Lease.ResourceKind = rkProcess) and (LeaseIdentity = '') then
    LeaseIdentity := Lease.ProcessIdentityId;
  if (Lease.CapabilityId <> ACapabilityId) or
     (Lease.ResourceKind <> AResourceKind) or
     (LeaseIdentity <> AResourceIdentityId) or
     (Lease.Epoch <> AEpoch) then
    Exit(TCEAResult.Error(rcUnauthorized, 'lease_scope_mismatch', '{}'));
  if Lease.RemainingCalls = 0 then
    Exit(TCEAResult.Error(rcBudgetExceeded, 'lease_calls_exhausted', '{}'));
  if AConsumeCall then
    Exit(FStore.ConsumeLeaseCall(ALeaseId));
  Result := TCEAResult.Ok('{"lease_id":"' + Lease.Id + '"}');
end;

end.
