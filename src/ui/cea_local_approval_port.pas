unit cea_local_approval_port;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports;

type
  TCEALocalApprovalPort = class(TObject, IApprovalPort)
  private
    FStore: IGovernanceStore;
    FClock: ICEAClock;
    FHasher: ICEAHasher;
  public
    constructor Create(const AStore: IGovernanceStore;
      const AClock: ICEAClock; const AHasher: ICEAHasher);
    function Approve(const AEffect: TCEAEffect;
      const AExpiresAt: string): TCEAResult;
    function Reject(const AEffect: TCEAEffect): TCEAResult;
    function FindDecision(const AEffectId: string;
      out ADecision: TCEAApprovalDecision): TCEAResult;
  end;

implementation

constructor TCEALocalApprovalPort.Create(const AStore: IGovernanceStore;
  const AClock: ICEAClock; const AHasher: ICEAHasher);
begin
  inherited Create;
  FStore := AStore;
  FClock := AClock;
  FHasher := AHasher;
end;

function TCEALocalApprovalPort.Approve(const AEffect: TCEAEffect;
  const AExpiresAt: string): TCEAResult;
var
  Decision: TCEAApprovalDecision;
begin
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'local_approval_dependencies_missing', '{}'));
  if AEffect.TargetClassification <> tcSinglePlayerOffline then
    Exit(TCEAResult.Error(rcTargetNotOffline, 'target_not_offline', '{}'));
  if AEffect.State <> esPlanned then
    Exit(TCEAResult.Error(rcConflict, 'effect_not_planned', '{}'));
  if (AEffect.Id = '') or (AEffect.RequestHash = '') or
     (((AEffect.ResourceKind = rkProcess) and
       (AEffect.ProcessIdentityId = '')) or
      ((AEffect.ResourceKind = rkSaveFile) and
       (AEffect.ResourceIdentityId = ''))) or
     (AEffect.PolicySnapshotId = '') or
     (AExpiresAt <= FClock.UtcNowIso8601) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'local_approval_binding_invalid', '{}'));
  FillChar(Decision, SizeOf(Decision), 0);
  Decision.Id := 'approval-' + Copy(FHasher.HashUtf8(AEffect.Id + #0 +
    AEffect.RequestHash + #0 + FClock.UtcNowIso8601), 8, 32);
  Decision.EffectId := AEffect.Id;
  Decision.RequestHash := AEffect.RequestHash;
  Decision.ProcessIdentityId := AEffect.ProcessIdentityId;
  Decision.ResourceKind := AEffect.ResourceKind;
  Decision.ResourceIdentityId := AEffect.ResourceIdentityId;
  Decision.PolicySnapshotId := AEffect.PolicySnapshotId;
  Decision.Origin := aoLocalUserInterface;
  Decision.Outcome := adApproved;
  Decision.DecidedAt := FClock.UtcNowIso8601;
  Decision.ExpiresAt := AExpiresAt;
  Decision.MaxExecutions := 1;
  Result := FStore.SaveApproval(Decision);
  if not Result.Failed then
    Result := TCEAResult.Ok('{"approval_id":"' + Decision.Id + '"}');
end;

function TCEALocalApprovalPort.Reject(
  const AEffect: TCEAEffect): TCEAResult;
var
  Decision: TCEAApprovalDecision;
begin
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'local_approval_dependencies_missing', '{}'));
  if AEffect.State <> esPlanned then
    Exit(TCEAResult.Error(rcConflict, 'effect_not_planned', '{}'));
  FillChar(Decision, SizeOf(Decision), 0);
  Decision.Id := 'approval-' + Copy(FHasher.HashUtf8(AEffect.Id + #0 +
    'rejected' + #0 + FClock.UtcNowIso8601), 8, 32);
  Decision.EffectId := AEffect.Id;
  Decision.RequestHash := AEffect.RequestHash;
  Decision.ProcessIdentityId := AEffect.ProcessIdentityId;
  Decision.ResourceKind := AEffect.ResourceKind;
  Decision.ResourceIdentityId := AEffect.ResourceIdentityId;
  Decision.PolicySnapshotId := AEffect.PolicySnapshotId;
  Decision.Origin := aoLocalUserInterface;
  Decision.Outcome := adRejected;
  Decision.DecidedAt := FClock.UtcNowIso8601;
  Decision.ExpiresAt := Decision.DecidedAt;
  Decision.MaxExecutions := 0;
  Result := FStore.SaveApproval(Decision);
end;

function TCEALocalApprovalPort.FindDecision(const AEffectId: string;
  out ADecision: TCEAApprovalDecision): TCEAResult;
begin
  if FStore = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'local_approval_store_missing', '{}'));
  Result := FStore.LoadApproval(AEffectId, ADecision);
end;

end.
