unit cea_event_store;

{$mode objfpc}{$H+}

interface

uses
  cea_ports, cea_results;

type
  TCEAEventStore = class
  private
    FStore: IStateStore;
    FValidator: ISchemaValidator;
  public
    constructor Create(const AStore: IStateStore;
      const AValidator: ISchemaValidator);
    function AppendValidated(const ASchemaId,
      APayloadJson: string): TCEAResult;
  end;

implementation

constructor TCEAEventStore.Create(const AStore: IStateStore;
  const AValidator: ISchemaValidator);
begin
  inherited Create;
  FStore := AStore;
  FValidator := AValidator;
end;

function TCEAEventStore.AppendValidated(const ASchemaId,
  APayloadJson: string): TCEAResult;
begin
  if (FStore = nil) or (FValidator = nil) then
    Exit(TCEAResult.Error(rcInternalError, 'state_dependencies_missing', '{}'));
  Result := FValidator.Validate(ASchemaId, APayloadJson);
  if Result.Failed then
    Exit;
  Result := FStore.AppendEvent(APayloadJson);
end;

end.
