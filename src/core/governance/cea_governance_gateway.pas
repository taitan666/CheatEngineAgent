unit cea_governance_gateway;

{$mode objfpc}{$H+}

interface

uses
  cea_types, cea_results, cea_ports, cea_policy_model, cea_lease_service,
  cea_effect_service;

type
  TCEAGovernanceGateway = class
  private
    FPolicy: TCEAPolicyModel;
    FLeases: TCEALeaseService;
    FEffects: TCEAEffectService;
    FCapabilities: ICEACapabilityPort;
  public
    constructor Create(const APolicy: TCEAPolicyModel;
      const ALeases: TCEALeaseService; const AEffects: TCEAEffectService;
      const ACapabilities: ICEACapabilityPort);
    function InvokeRead(const ACapabilityId: string;
      const AContext: TCEACapabilityContext;
      const ARequestJson: string): TCEAResult;
    function RequestEffect(const ACapabilityId: string;
      const AContext: TCEACapabilityContext; const ARequestJson,
      AIdempotencyKey: string): TCEAResult;
    function ExecuteApprovedEffect(const AEffectId: string): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

constructor TCEAGovernanceGateway.Create(const APolicy: TCEAPolicyModel;
  const ALeases: TCEALeaseService; const AEffects: TCEAEffectService;
  const ACapabilities: ICEACapabilityPort);
begin
  inherited Create;
  FPolicy := APolicy;
  FLeases := ALeases;
  FEffects := AEffects;
  FCapabilities := ACapabilities;
end;

function TCEAGovernanceGateway.InvokeRead(const ACapabilityId: string;
  const AContext: TCEACapabilityContext;
  const ARequestJson: string): TCEAResult;
begin
  if (FPolicy = nil) or (FLeases = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'governance_dependencies_missing', '{}'));
  Result := FPolicy.EvaluateContext(ACapabilityId, AContext);
  if Result.Failed then
    Exit;
  if AContext.ResourceKind = rkSaveFile then
    Result := FLeases.ValidateResource(AContext.LeaseId, ACapabilityId,
      rkSaveFile, AContext.ResourceIdentityId, AContext.Epoch, True)
  else
    Result := FLeases.Validate(AContext.LeaseId, ACapabilityId,
      AContext.ProcessIdentityId, AContext.Epoch, True);
  if Result.Failed then
    Exit;
  if FCapabilities = nil then
    Exit(TCEAResult.Error(rcInternalError, 'capability_port_missing', '{}'));
  Result := FCapabilities.Invoke(ACapabilityId, ARequestJson);
end;

function TCEAGovernanceGateway.RequestEffect(const ACapabilityId: string;
  const AContext: TCEACapabilityContext; const ARequestJson,
  AIdempotencyKey: string): TCEAResult;
begin
  if (FPolicy = nil) or (FLeases = nil) or (FEffects = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'governance_dependencies_missing', '{}'));
  Result := FPolicy.EvaluateContext(ACapabilityId, AContext);
  if Result.Failed then
    Exit;
  if AContext.ResourceKind = rkSaveFile then
    Result := FLeases.ValidateResource(AContext.LeaseId, ACapabilityId,
      rkSaveFile, AContext.ResourceIdentityId, AContext.Epoch, False)
  else
    Result := FLeases.Validate(AContext.LeaseId, ACapabilityId,
      AContext.ProcessIdentityId, AContext.Epoch, False);
  if Result.Failed then
    Exit;
  Result := FEffects.Plan(ACapabilityId, AContext, ARequestJson,
    AIdempotencyKey);
end;

function TCEAGovernanceGateway.ExecuteApprovedEffect(
  const AEffectId: string): TCEAResult;
var
  Effect: TCEAEffect;
  Context: TCEACapabilityContext;
  Data: TJSONData;
begin
  if (FPolicy = nil) or (FLeases = nil) or (FEffects = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'governance_dependencies_missing', '{}'));
  Result := FEffects.Load(AEffectId, Effect);
  if Result.Failed then
    Exit;
  if Effect.State = esApplied then
  begin
    Result := TCEAResult.Ok(Effect.ResultJson);
    if Effect.ResourceKind = rkSaveFile then
    begin
      Data := nil;
      try
        try
          Data := GetJSON(Effect.ResultJson);
          if (Data <> nil) and (Data.JSONType = jtObject) then
          begin
            Result.ReceiptId := TJSONObject(Data).Get('receipt_id', '');
            Result.ProofId := TJSONObject(Data).Get('proof_id', '');
          end;
        except
          // The persisted result remains authoritative; malformed metadata
          // cannot authorize a second invocation.
        end;
      finally
        Data.Free;
      end;
    end;
    Exit;
  end;
  if Effect.State = esUnknown then
    Exit(TCEAResult.Error(rcUnknownOutcome, 'unknown_outcome',
      Effect.ResultJson));
  FillChar(Context, SizeOf(Context), 0);
  Context.TargetClassification := Effect.TargetClassification;
  Context.ResourceKind := Effect.ResourceKind;
  Context.ResourceIdentityId := Effect.ResourceIdentityId;
  Result := FPolicy.EvaluateContext(Effect.CapabilityId, Context);
  if Result.Failed then
    Exit;
  Result := FEffects.ValidateLocalApproval(Effect);
  if Result.Failed then
    Exit;
  if Effect.ResourceKind = rkSaveFile then
    Result := FLeases.ValidateResource(Effect.LeaseId, Effect.CapabilityId,
      rkSaveFile, Effect.ResourceIdentityId, Effect.Epoch, True)
  else
    Result := FLeases.Validate(Effect.LeaseId, Effect.CapabilityId,
      Effect.ProcessIdentityId, Effect.Epoch, True);
  if Result.Failed then
    Exit;
  Result := FEffects.Apply(Effect, FCapabilities);
end;

end.
