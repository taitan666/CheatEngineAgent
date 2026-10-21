unit cea_mcp_dispatcher;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_results, cea_mcp_registry;

type
  TMCPFoundationDispatcher = class(TObject, IMCPToolDispatcher)
  public
    { The owner is accepted for symmetry with the runtime dispatchers; this
      foundation dispatcher holds no owned objects, so it may be nil. }
    constructor Create(const AOwner: TObject = nil);
    function DispatchTool(const AToolName,
      AArgumentsJson: string): TCEAResult;
  end;

implementation

constructor TMCPFoundationDispatcher.Create(const AOwner: TObject);
begin
  inherited Create;
end;

function TMCPFoundationDispatcher.DispatchTool(const AToolName,
  AArgumentsJson: string): TCEAResult;
begin
  if AToolName = 'cea.health' then
    Exit(TCEAResult.Ok('{"status":"ready"}'));
  if AToolName = 'cea.get_runtime_state' then
    Exit(TCEAResult.Ok('{"initialized":true,"mcp_enabled":false}'));
  Result := TCEAResult.Error(rcNotImplemented, 'not_implemented',
    '{"tool":"' + AToolName + '"}');
end;

end.
