unit cea_policy_engine;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses cea_ports, cea_results, cea_policy_model;

type
  TCEAInertPolicyEngine = class(TObject, IPolicyEngine)
  public
    function Evaluate(const ACapabilityId, ATargetClassification: string): TCEAResult;
  end;

implementation

function TCEAInertPolicyEngine.Evaluate(const ACapabilityId,
  ATargetClassification: string): TCEAResult;
var
  Policy: TCEAPolicyModel;
begin
  Policy := TCEAPolicyModel.Create;
  try
    Result := Policy.Evaluate(ACapabilityId, ATargetClassification);
  finally
    Policy.Free;
  end;
end;

end.
