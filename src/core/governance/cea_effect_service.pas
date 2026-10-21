unit cea_effect_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports;

type
  TCEAEffectService = class
  private
    FStore: IGovernanceStore;
    FClock: ICEAClock;
    FApprovals: IApprovalPort;
    FHasher: ICEAHasher;
  public
    constructor Create(const AStore: IGovernanceStore;
      const AClock: ICEAClock; const AApprovals: IApprovalPort;
      const AHasher: ICEAHasher);
    function Plan(const ACapabilityId: string;
      const AContext: TCEACapabilityContext; const ARequestJson,
      AIdempotencyKey: string): TCEAResult;
    function Load(const AEffectId: string; out AEffect: TCEAEffect): TCEAResult;
    function ValidateLocalApproval(var AEffect: TCEAEffect): TCEAResult;
    function Apply(var AEffect: TCEAEffect;
      const ACapabilities: ICEACapabilityPort): TCEAResult;
  end;

implementation

constructor TCEAEffectService.Create(const AStore: IGovernanceStore;
  const AClock: ICEAClock; const AApprovals: IApprovalPort;
  const AHasher: ICEAHasher);
begin
  inherited Create;
  FStore := AStore;
  FClock := AClock;
  FApprovals := AApprovals;
  FHasher := AHasher;
end;

function TCEAEffectService.Plan(const ACapabilityId: string;
  const AContext: TCEACapabilityContext; const ARequestJson,
  AIdempotencyKey: string): TCEAResult;
var
  Effect: TCEAEffect;
  Existing: TCEAEffect;
begin
  if (FStore = nil) or (FClock = nil) or (FHasher = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'effect_dependencies_missing', '{}'));
  if (AContext.TaskId = '') or
     (AContext.PolicySnapshotId = '') or (AIdempotencyKey = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'effect_identity_required', '{}'));
  if ((AContext.ResourceKind = rkSaveFile) and
      (AContext.ResourceIdentityId = '')) or
     ((AContext.ResourceKind = rkProcess) and
      ((AContext.ProcessIdentityId = '') or
       ((AContext.ResourceIdentityId <> '') and
        (AContext.ResourceIdentityId <> AContext.ProcessIdentityId)))) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'resource_identity_required', '{}'));
  FillChar(Effect, SizeOf(Effect), 0);
  if AContext.ResourceKind = rkSaveFile then
    Effect.RequestHash := FHasher.HashUtf8(ACapabilityId + #0 + ARequestJson +
      #0 + 'save_file' + #0 + AContext.ResourceIdentityId + #0 +
      AContext.PolicySnapshotId + #0 + AIdempotencyKey)
  else
    Effect.RequestHash := FHasher.HashUtf8(ACapabilityId + #0 + ARequestJson +
      #0 + AContext.ProcessIdentityId + #0 + AContext.PolicySnapshotId +
      #0 + AIdempotencyKey);
  Effect.Id := 'effect-' + Copy(FHasher.HashUtf8(
    Effect.RequestHash + #0 + AIdempotencyKey), 8, 32);
  if not FStore.LoadEffect(Effect.Id, Existing).Failed then
    Exit(TCEAResult.Error(rcApprovalRequired, 'approval_required',
      '{"effect_id":"' + Existing.Id + '"}'));
  Effect.TaskId := AContext.TaskId;
  Effect.CapabilityId := ACapabilityId;
  Effect.RequestJson := ARequestJson;
  Effect.ProcessIdentityId := AContext.ProcessIdentityId;
  Effect.ResourceKind := AContext.ResourceKind;
  if AContext.ResourceKind = rkProcess then
    Effect.ResourceIdentityId := AContext.ProcessIdentityId
  else
    Effect.ResourceIdentityId := AContext.ResourceIdentityId;
  Effect.PolicySnapshotId := AContext.PolicySnapshotId;
  Effect.LeaseId := AContext.LeaseId;
  Effect.IdempotencyKey := AIdempotencyKey;
  Effect.Epoch := AContext.Epoch;
  Effect.State := esPlanned;
  Effect.CreatedAt := FClock.UtcNowIso8601;
  Effect.UpdatedAt := Effect.CreatedAt;
  Effect.TargetClassification := AContext.TargetClassification;
  Result := FStore.SaveEffect(Effect);
  if Result.Failed then
    Exit;
  Result := TCEAResult.Error(rcApprovalRequired, 'approval_required',
    '{"effect_id":"' + Effect.Id + '"}');
end;

function TCEAEffectService.Load(const AEffectId: string;
  out AEffect: TCEAEffect): TCEAResult;
begin
  if FStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'effect_store_missing', '{}'));
  Result := FStore.LoadEffect(AEffectId, AEffect);
end;

function TCEAEffectService.ValidateLocalApproval(
  var AEffect: TCEAEffect): TCEAResult;
var
  Decision: TCEAApprovalDecision;
begin
  if (FApprovals = nil) or (FClock = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'approval_dependencies_missing', '{}'));
  Result := FApprovals.FindDecision(AEffect.Id, Decision);
  if Result.Failed then
    Exit;
  if Decision.Origin <> aoLocalUserInterface then
    Exit(TCEAResult.Error(rcUnauthorized, 'approval_origin_invalid', '{}'));
  if Decision.Outcome <> adApproved then
    Exit(TCEAResult.Error(rcUnauthorized, 'approval_not_granted', '{}'));
  if Decision.RequestHash <> AEffect.RequestHash then
    Exit(TCEAResult.Error(rcUnauthorized, 'approval_hash_mismatch', '{}'));
  if Decision.ResourceKind <> AEffect.ResourceKind then
    Exit(TCEAResult.Error(rcUnauthorized, 'approval_resource_kind_changed', '{}'));
  if (AEffect.ResourceKind = rkSaveFile) and
     (Decision.ResourceIdentityId <> AEffect.ResourceIdentityId) then
    Exit(TCEAResult.Error(rcUnauthorized, 'approval_resource_changed', '{}'));
  if Decision.ProcessIdentityId <> AEffect.ProcessIdentityId then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'approval_target_changed', '{}'));
  if Decision.PolicySnapshotId <> AEffect.PolicySnapshotId then
    Exit(TCEAResult.Error(rcUnauthorized, 'approval_policy_changed', '{}'));
  if (Decision.MaxExecutions <> 1) or
     (FClock.UtcNowIso8601 > Decision.ExpiresAt) then
    Exit(TCEAResult.Error(rcLeaseExpired, 'approval_expired', '{}'));
  AEffect.ApprovalId := Decision.Id;
  Result := TCEAResult.Ok('{"approval_id":"' + Decision.Id + '"}');
end;

function TCEAEffectService.Apply(var AEffect: TCEAEffect;
  const ACapabilities: ICEACapabilityPort): TCEAResult;
var
  InvocationResult, PersistResult: TCEAResult;
  Receipt: TCEAReceipt;
  Proof: TCEAProof;
begin
  if AEffect.State = esApplied then
    Exit(TCEAResult.Ok(AEffect.ResultJson));
  if AEffect.State = esUnknown then
    Exit(TCEAResult.Error(rcUnknownOutcome, 'unknown_outcome',
      AEffect.ResultJson));
  if ACapabilities = nil then
    Exit(TCEAResult.Error(rcInternalError, 'capability_port_missing', '{}'));
  AEffect.State := esExecuting;
  AEffect.UpdatedAt := FClock.UtcNowIso8601;
  Result := FStore.SaveEffect(AEffect);
  if Result.Failed then
    Exit;
  InvocationResult := ACapabilities.InvokeEffect(AEffect);
  Result := InvocationResult;
  if (InvocationResult.ReceiptId <> '') and
     (InvocationResult.ProofId <> '') and (FHasher <> nil) then
  begin
    FillChar(Receipt, SizeOf(Receipt), 0);
    Receipt.Id := InvocationResult.ReceiptId;
    Receipt.EffectId := AEffect.Id;
    Receipt.Attempt := 1;
    Receipt.RecordedAt := FClock.UtcNowIso8601;
    if InvocationResult.Code = rcOk then
      Receipt.Outcome := roApplied
    else if InvocationResult.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
      Receipt.Outcome := roUnknown
    else
      Receipt.Outcome := roRejected;
    Receipt.ResponseHash := FHasher.HashUtf8(InvocationResult.StableCode +
      #0 + InvocationResult.DataJson);
    Receipt.DetailsJson := InvocationResult.DataJson;
    PersistResult := FStore.SaveReceipt(Receipt);
    if PersistResult.Failed then
    begin
      Result := TCEAResult.Error(rcUnknownOutcome,
        'receipt_persist_failed', InvocationResult.DataJson);
      Result.ReceiptId := Receipt.Id;
      Result.ProofId := InvocationResult.ProofId;
    end
    else
    begin
      FillChar(Proof, SizeOf(Proof), 0);
      Proof.Id := InvocationResult.ProofId;
      Proof.EffectId := AEffect.Id;
      Proof.ReceiptId := Receipt.Id;
      Proof.RecordedAt := Receipt.RecordedAt;
      if InvocationResult.Code = rcOk then
        Proof.Outcome := poPass
      else if InvocationResult.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
        Proof.Outcome := poInconclusive
      else
        Proof.Outcome := poFail;
      Proof.VerificationHash := FHasher.HashUtf8(Receipt.ResponseHash +
        #0 + InvocationResult.DataJson);
      Proof.DetailsJson := InvocationResult.DataJson;
      PersistResult := FStore.SaveProof(Proof);
      if PersistResult.Failed then
      begin
        Result := TCEAResult.Error(rcUnknownOutcome,
          'proof_persist_failed', InvocationResult.DataJson);
        Result.ReceiptId := Receipt.Id;
        Result.ProofId := Proof.Id;
      end;
    end;
  end;
  AEffect.ResultJson := Result.DataJson;
  AEffect.UpdatedAt := FClock.UtcNowIso8601;
  if Result.Code = rcOk then
    AEffect.State := esApplied
  else if Result.Code in [rcUnknown, rcTimeout, rcUnknownOutcome] then
    AEffect.State := esUnknown
  else
    AEffect.State := esRejected;
  if FStore.SaveEffect(AEffect).Failed then
    Exit(TCEAResult.Error(rcUnknownOutcome, 'effect_outcome_persist_failed', '{}'));
end;

end.
