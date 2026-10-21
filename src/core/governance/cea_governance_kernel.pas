unit cea_governance_kernel;

{$mode objfpc}{$H+}

interface

uses
  cea_ports, cea_results;

type
  TCEAGovernanceKernel = class
  private
    FPolicy: IPolicyEngine;
  public
    constructor Create(const APolicy: IPolicyEngine);
    function EvaluateCapability(const ACapabilityId,
      ATargetClassification: string): TCEAResult;
  end;

implementation

constructor TCEAGovernanceKernel.Create(const APolicy: IPolicyEngine);
begin
  inherited Create;
  FPolicy := APolicy;
end;

function TCEAGovernanceKernel.EvaluateCapability(const ACapabilityId,
  ATargetClassification: string): TCEAResult;
begin
  if ACapabilityId = '' then
    Exit(CEAResult(rcInvalidArgument, 'capability ID is required'));
  if (ACapabilityId = 'model_training') or
     (ACapabilityId = 'model_fine_tuning') or
     (ACapabilityId = 'weight_mutation') or
     (ACapabilityId = 'weight_writeback') or
     (ACapabilityId = 'multiplayer_targeting') or
     (ACapabilityId = 'anti_cheat_bypass') or
     (ACapabilityId = 'kernel_driver') then
    Exit(CEAResult(rcRejected, 'capability is permanently denied'));
  if ATargetClassification <> 'single_player_offline' then
    Exit(CEAResult(rcRejected, 'writes require an authorized offline single-player target'));
  if FPolicy = nil then
    Exit(CEAResult(rcRejected, 'policy engine is required'));
  Result := FPolicy.Evaluate(ACapabilityId, ATargetClassification);
end;

end.

