unit cea_policy_model;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports;

type
  TCEAPolicyModel = class(TObject, IPolicyEngine)
  public
    function Evaluate(const ACapabilityId,
      ATargetClassification: string): TCEAResult;
    function EvaluateContext(const ACapabilityId: string;
      const AContext: TCEACapabilityContext): TCEAResult;
  end;

implementation

function IsPermanentDeny(const ACapabilityId: string): Boolean;
const
  Denied: array[0..12] of string = (
    'model_training', 'model_fine_tuning', 'online_learning',
    'weight_mutation', 'weight_writeback', 'training_dataset_export',
    'multiplayer_targeting', 'anti_cheat_bypass', 'kernel_driver',
    'concealment', 'script_network', 'script_filesystem',
    'script_child_process');
var
  I: Integer;
begin
  for I := Low(Denied) to High(Denied) do
    if SameText(ACapabilityId, Denied[I]) then
      Exit(True);
  Result := False;
end;

function RequiresOfflineTarget(const ACapabilityId: string): Boolean;
begin
  Result := SameText(ACapabilityId, 'process_attach') or
    SameText(ACapabilityId, 'memory_read') or
    SameText(ACapabilityId, 'memory_scan') or
    SameText(ACapabilityId, 'memory_write') or
    SameText(ACapabilityId, 'memory_freeze') or
    SameText(ACapabilityId, 'disassemble') or
    SameText(ACapabilityId, 'debug_state_change') or
    SameText(ACapabilityId, 'script_execution');
  Result := Result or SameText(ACapabilityId, 'save_backup') or
    SameText(ACapabilityId, 'save_edit') or
    SameText(ACapabilityId, 'save_restore');
end;

function TCEAPolicyModel.Evaluate(const ACapabilityId,
  ATargetClassification: string): TCEAResult;
begin
  if ACapabilityId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'capability_required', '{}'));
  if IsPermanentDeny(ACapabilityId) then
    Exit(TCEAResult.Error(rcPolicyDenied, 'policy_denied',
      '{"capability":"' + ACapabilityId + '"}'));
  if RequiresOfflineTarget(ACapabilityId) and
     (ATargetClassification <> 'single_player_offline') then
    Exit(TCEAResult.Error(rcTargetNotOffline, 'target_not_offline', '{}'));
  Result := TCEAResult.Ok('{"decision":"allow"}');
end;

function TCEAPolicyModel.EvaluateContext(const ACapabilityId: string;
  const AContext: TCEACapabilityContext): TCEAResult;
var
  Classification: string;
begin
  case AContext.TargetClassification of
    tcSinglePlayerOffline: Classification := 'single_player_offline';
    tcMultiplayerOrOnline: Classification := 'multiplayer_or_online';
  else
    Classification := 'unknown';
  end;
  Result := Evaluate(ACapabilityId, Classification);
end;

end.
