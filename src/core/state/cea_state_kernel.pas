unit cea_state_kernel;

{$mode objfpc}{$H+}

interface

uses
  cea_ports, cea_results;

type
  TCEAStateKernel = class
  private
    FStore: IStateStore;
    FValidator: ISchemaValidator;
  public
    constructor Create(const AStore: IStateStore; const AValidator: ISchemaValidator);
    function Initialize: TCEAResult;
    function RecordEnvelope(const AEnvelopeJson: string): TCEAResult;
  end;

implementation

constructor TCEAStateKernel.Create(const AStore: IStateStore;
  const AValidator: ISchemaValidator);
begin
  inherited Create;
  FStore := AStore;
  FValidator := AValidator;
end;

function TCEAStateKernel.Initialize: TCEAResult;
begin
  if (FStore = nil) or (FValidator = nil) then
    Exit(CEAResult(rcInvalidArgument, 'state store and schema validator are required'));
  Result := FStore.Initialize;
end;

function TCEAStateKernel.RecordEnvelope(const AEnvelopeJson: string): TCEAResult;
begin
  if AEnvelopeJson = '' then
    Exit(CEAResult(rcInvalidArgument, 'envelope JSON is required'));
  if (FStore = nil) or (FValidator = nil) then
    Exit(CEAResult(rcRejected, 'state kernel is not configured'));
  Result := NotImplementedResult('state envelope commit');
end;

end.

