unit cea_experiment_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_reverse_types,
  cea_governance_gateway;

type
  TCEAExperimentService = class
  private
    FGateway: TCEAGovernanceGateway;
    FAudit: IStateStore;
    FCurrent: TCEAExperiment;
    FHasCurrent: Boolean;
    function ValidateCurrent(const AContext: TCEACapabilityContext): TCEAResult;
  public
    constructor Create(const AGateway: TCEAGovernanceGateway;
      const AAudit: IStateStore);
    function Start(const AExperiment: TCEAExperiment): TCEAResult;
    function RunReadStep(const AContext: TCEACapabilityContext;
      const AStep: TCEAExperimentStep; const ARequestJson: string): TCEAResult;
    function ProposeEffect(const AContext: TCEACapabilityContext;
      const ACapabilityId, ARequestJson, AIdempotencyKey: string): TCEAResult;
    function ApplyVerification(
      const ARun: TCEAVerificationRun): TCEAResult;
    function CompleteWithRecipe(
      const ARecipe: TCEAReverseRecipe): TCEAResult;
    function Cancel(const AContext: TCEACapabilityContext;
      const AScanId: string): TCEAResult;
    function Current: TCEAExperiment;
  end;

implementation

constructor TCEAExperimentService.Create(const AGateway: TCEAGovernanceGateway;
  const AAudit: IStateStore);
begin
  inherited Create;
  FGateway := AGateway;
  FAudit := AAudit;
end;

function TCEAExperimentService.ValidateCurrent(
  const AContext: TCEACapabilityContext): TCEAResult;
begin
  if not FHasCurrent then
    Exit(TCEAResult.Error(rcConflict, 'experiment_not_started', '{}'));
  if (FCurrent.Target.ProcessIdentityId <> AContext.ProcessIdentityId) or
     (FCurrent.Target.Epoch <> AContext.Epoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'experiment_target_changed', '{}'));
  if FCurrent.State in [xsCompleted, xsFailed, xsCancelled] then
    Exit(TCEAResult.Error(rcConflict, 'experiment_terminal', '{}'));
  Result := TCEAResult.Ok('{}');
end;

function TCEAExperimentService.Start(
  const AExperiment: TCEAExperiment): TCEAResult;
begin
  if (AExperiment.Id = '') or (AExperiment.TaskId = '') or
     (AExperiment.Goal = '') or not AExperiment.Target.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'experiment_invalid', '{}'));
  if FHasCurrent and not (FCurrent.State in
     [xsCompleted, xsFailed, xsCancelled]) then
    Exit(TCEAResult.Error(rcConflict, 'experiment_already_active', '{}'));
  FCurrent := AExperiment;
  FCurrent.State := xsPlanned;
  FHasCurrent := True;
  Result := TCEAResult.Ok('{"experiment_id":"' + FCurrent.Id + '"}');
end;

function TCEAExperimentService.RunReadStep(
  const AContext: TCEACapabilityContext; const AStep: TCEAExperimentStep;
  const ARequestJson: string): TCEAResult;
begin
  Result := ValidateCurrent(AContext);
  if Result.Failed then
    Exit;
  if (AStep.Id = '') or (AStep.ExperimentId <> FCurrent.Id) or
     (AStep.RequiredCapabilityId = '') or
     (AStep.Kind = skProposeEffect) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'experiment_step_invalid', '{}'));
  if FGateway = nil then
    Exit(TCEAResult.Error(rcInternalError, 'governance_gateway_missing', '{}'));
  Result := FGateway.InvokeRead(AStep.RequiredCapabilityId, AContext,
    ARequestJson);
  if not Result.Failed then
    FCurrent.State := xsRunning;
end;

function TCEAExperimentService.ProposeEffect(
  const AContext: TCEACapabilityContext; const ACapabilityId,
  ARequestJson, AIdempotencyKey: string): TCEAResult;
begin
  Result := ValidateCurrent(AContext);
  if Result.Failed then
    Exit;
  if (ACapabilityId = '') or (AIdempotencyKey = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'effect_proposal_invalid', '{}'));
  if FGateway = nil then
    Exit(TCEAResult.Error(rcInternalError, 'governance_gateway_missing', '{}'));
  Result := FGateway.RequestEffect(ACapabilityId, AContext, ARequestJson,
    AIdempotencyKey);
end;

function TCEAExperimentService.ApplyVerification(
  const ARun: TCEAVerificationRun): TCEAResult;
begin
  if not FHasCurrent then
    Exit(TCEAResult.Error(rcConflict, 'experiment_not_started', '{}'));
  if (ARun.ExperimentId <> FCurrent.Id) or
     (ARun.Target.ProcessIdentityId <> FCurrent.Target.ProcessIdentityId) or
     (ARun.Target.Epoch <> FCurrent.Target.Epoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'verification_target_changed', '{}'));
  case ARun.Outcome of
    voPass:
      begin
        if ARun.ProofId = '' then
          Exit(TCEAResult.Error(rcVerificationFailed,
            'verification_proof_required', '{}'));
        FCurrent.State := xsVerifying;
        Result := TCEAResult.Ok('{"state":"verifying"}');
      end;
    voFail:
      begin
        FCurrent.State := xsFailed;
        Result := TCEAResult.Error(rcVerificationFailed,
          'verification_failed', '{}');
      end;
    voInconclusive:
      begin
        FCurrent.State := xsVerifying;
        Result := TCEAResult.Error(rcVerificationFailed,
          'verification_inconclusive', '{}');
      end;
    voUnknown:
      begin
        FCurrent.State := xsVerifying;
        Result := TCEAResult.Error(rcUnknownOutcome,
          'unknown_outcome', '{}');
      end;
  else
    Result := TCEAResult.Error(rcConflict, 'verification_pending', '{}');
  end;
end;

function TCEAExperimentService.CompleteWithRecipe(
  const ARecipe: TCEAReverseRecipe): TCEAResult;
begin
  if not FHasCurrent then
    Exit(TCEAResult.Error(rcConflict, 'experiment_not_started', '{}'));
  if FCurrent.State <> xsVerifying then
    Exit(TCEAResult.Error(rcConflict,
      'experiment_not_verified', '{}'));
  if not ARecipe.IsPortableDefinition then
    Exit(TCEAResult.Error(rcInvalidArgument, 'recipe_invalid', '{}'));
  FCurrent.State := xsCompleted;
  Result := TCEAResult.Ok('{"state":"completed","recipe_id":"' +
    ARecipe.Id + '"}');
end;

function TCEAExperimentService.Cancel(
  const AContext: TCEACapabilityContext; const AScanId: string): TCEAResult;
var
  AuditResult: TCEAResult;
begin
  Result := ValidateCurrent(AContext);
  if Result.Failed then
    Exit;
  if AScanId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'scan_id_required', '{}'));
  if FGateway = nil then
    Exit(TCEAResult.Error(rcInternalError, 'governance_gateway_missing', '{}'));
  Result := FGateway.InvokeRead('scan_cancel', AContext,
    '{"scan_id":"' + StringReplace(AScanId, '"', '\"', [rfReplaceAll]) + '"}');
  FCurrent.State := xsCancelled;
  if FAudit <> nil then
  begin
    AuditResult := FAudit.AppendEvent('{"event_type":"experiment_cancelled",' +
      '"experiment_id":"' + FCurrent.Id + '","scan_id":"' +
      StringReplace(AScanId, '"', '\"', [rfReplaceAll]) + '"}');
    if (not Result.Failed) and AuditResult.Failed then
      Result := AuditResult;
  end;
end;

function TCEAExperimentService.Current: TCEAExperiment;
begin
  Result := FCurrent;
end;

end.
