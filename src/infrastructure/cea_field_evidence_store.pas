unit cea_field_evidence_store;

{$mode objfpc}{$H+}
{$interfaces corba}

{ Persistence for FR-052 field evidence.

  Two classes live here on purpose:

  * TCEAFieldEvidenceStore owns the player-facing table. It is what the UI and
    the MCP tools query, because the reverse-domain store has no notion of a
    field id, a value type or a previous value.
  * TCEAReverseEvidenceStore adapts TCEAReverseRepository to ICEAEvidenceStore
    so the very same observation can also be filed as a reverse-domain
    artifact. It is optional: without it, field evidence still works, it just
    cannot be cited by the candidate/recipe pipeline. }

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, fpjson,
  cea_results, cea_reverse_types, cea_reverse_ports, cea_reverse_repository,
  cea_field_evidence;

type
  TCEAFieldEvidenceStore = class(TObject, ICEAFieldEvidenceStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
    function RowToRecord(const AQuery: TSQLQuery): TCEAFieldEvidence;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function AppendEvidence(const AEvidence: TCEAFieldEvidence): TCEAResult;
    function ListForField(const AFieldId: string; const ALimit: Cardinal;
      out AItems: TCEAFieldEvidenceArray): TCEAResult;
    function Count: Cardinal;
  end;

  TCEAReverseEvidenceStore = class(TObject, ICEAEvidenceStore)
  private
    FRepository: TCEAReverseRepository;
  public
    constructor Create(const ARepository: TCEAReverseRepository);
    function AppendEvidence(const AEvidence: TCEAEvidenceReference): TCEAResult;
    function FindEvidence(const AEvidenceId: string;
      out AEvidence: TCEAEvidenceReference): TCEAResult;
  end;

function EvidenceRecordJson(const AEvidence: TCEAFieldEvidence): string;

implementation

function EvidenceRecordJson(const AEvidence: TCEAFieldEvidence): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('evidence_id', AEvidence.EvidenceId);
    O.Add('field_id', AEvidence.FieldId);
    O.Add('display_name', AEvidence.DisplayName);
    O.Add('kind', EvidenceKindText(AEvidence.Kind));
    O.Add('address', AEvidence.AddressText);
    O.Add('value_type', AEvidence.ValueType);
    O.Add('previous_value', AEvidence.PreviousValueJson);
    O.Add('observed_value', AEvidence.ObservedValueJson);
    O.Add('process_identity_id', AEvidence.ProcessIdentityId);
    O.Add('epoch', AEvidence.Epoch);
    O.Add('executable_sha256', AEvidence.ExecutableSha256);
    O.Add('module_set_hash', AEvidence.ModuleSetHash);
    O.Add('outcome', EvidenceOutcomeText(AEvidence.Outcome));
    O.Add('detail_json', AEvidence.DetailJson);
    O.Add('provenance_uri', AEvidence.ProvenanceUri);
    O.Add('content_hash', AEvidence.ContentHash);
    O.Add('recorded_at', AEvidence.RecordedAt);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

constructor TCEAFieldEvidenceStore.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAFieldEvidenceStore.Destroy;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
  if FConnection.Connected then
    FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEAFieldEvidenceStore.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'field_evidence_database_path_required', '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError,
      'field_evidence_database_open_failed', '{}');
  end;
end;

function TCEAFieldEvidenceStore.Initialize: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then
    Exit;
  try
    if FTransaction.Active then
      FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect('CREATE TABLE IF NOT EXISTS field_evidence (' +
      'sequence INTEGER PRIMARY KEY AUTOINCREMENT,' +
      'evidence_id TEXT NOT NULL UNIQUE,' +
      'field_id TEXT NOT NULL,' +
      'kind TEXT NOT NULL,' +
      'outcome TEXT NOT NULL,' +
      'process_identity_id TEXT NOT NULL,' +
      'epoch INTEGER NOT NULL,' +
      'content_hash TEXT NOT NULL,' +
      'recorded_at TEXT NOT NULL,' +
      'payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect('CREATE INDEX IF NOT EXISTS ' +
      'idx_field_evidence_field ON field_evidence(field_id, sequence DESC)');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    if FTransaction.Active then
      FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError,
      'field_evidence_initialize_failed', '{}');
  end;
end;

function TCEAFieldEvidenceStore.AppendEvidence(
  const AEvidence: TCEAFieldEvidence): TCEAResult;
var
  Q: TSQLQuery;
begin
  if not AEvidence.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'evidence_record_invalid', '{}'));
  Result := EnsureConnected;
  if Result.Failed then
    Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text := 'INSERT INTO field_evidence ' +
      '(evidence_id, field_id, kind, outcome, process_identity_id, epoch, ' +
      'content_hash, recorded_at, payload_json) ' +
      'VALUES (:id, :field, :kind, :outcome, :process, :epoch, :hash, ' +
      ':recorded, :payload)';
    Q.Params.ParamByName('id').AsString := AEvidence.EvidenceId;
    Q.Params.ParamByName('field').AsString := AEvidence.FieldId;
    Q.Params.ParamByName('kind').AsString :=
      EvidenceKindText(AEvidence.Kind);
    Q.Params.ParamByName('outcome').AsString :=
      EvidenceOutcomeText(AEvidence.Outcome);
    Q.Params.ParamByName('process').AsString := AEvidence.ProcessIdentityId;
    Q.Params.ParamByName('epoch').AsLargeInt := AEvidence.Epoch;
    Q.Params.ParamByName('hash').AsString := AEvidence.ContentHash;
    Q.Params.ParamByName('recorded').AsString := AEvidence.RecordedAt;
    Q.Params.ParamByName('payload').AsString :=
      EvidenceRecordJson(AEvidence);
    if FTransaction.Active then
      FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"evidence_id":"' + AEvidence.EvidenceId + '"}');
  except
    if FTransaction.Active then
      FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'evidence_save_failed', '{}');
  end;
  Q.Free;
end;

function TCEAFieldEvidenceStore.RowToRecord(
  const AQuery: TSQLQuery): TCEAFieldEvidence;
var
  Payload: string;
  D: TJSONData;
  O: TJSONObject;
begin
  Result := Default(TCEAFieldEvidence);
  Result.EvidenceId := AQuery.FieldByName('evidence_id').AsString;
  Result.FieldId := AQuery.FieldByName('field_id').AsString;
  Result.Outcome := voUnknown;
  Result.Kind := ekMemoryObservation;
  Result.ContentHash := AQuery.FieldByName('content_hash').AsString;
  Result.RecordedAt := AQuery.FieldByName('recorded_at').AsString;
  Payload := AQuery.FieldByName('payload_json').AsString;
  if Payload = '' then
    Exit;
  D := GetJSON(Payload);
  try
    if D is TJSONObject then
    begin
      O := TJSONObject(D);
      Result.DisplayName := O.Get('display_name', '');
      TryParseEvidenceKind(O.Get('kind', ''), Result.Kind);
      Result.AddressText := O.Get('address', '');
      Result.ValueType := O.Get('value_type', '');
      Result.PreviousValueJson := O.Get('previous_value', '');
      Result.ObservedValueJson := O.Get('observed_value', '');
      Result.ProcessIdentityId := O.Get('process_identity_id', '');
      Result.Epoch := QWord(O.Get('epoch', Int64(0)));
      Result.ExecutableSha256 := O.Get('executable_sha256', '');
      Result.ModuleSetHash := O.Get('module_set_hash', '');
      TryParseEvidenceOutcome(O.Get('outcome', ''), Result.Outcome);
      Result.DetailJson := O.Get('detail_json', '');
      Result.ProvenanceUri := O.Get('provenance_uri', '');
    end;
  finally
    D.Free;
  end;
end;

function TCEAFieldEvidenceStore.ListForField(const AFieldId: string;
  const ALimit: Cardinal; out AItems: TCEAFieldEvidenceArray): TCEAResult;
var
  Q: TSQLQuery;
  Filled: Cardinal;
begin
  SetLength(AItems, 0);
  Result := EnsureConnected;
  if Result.Failed then
    Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then
      FTransaction.Rollback;
    FTransaction.StartTransaction;
    { Newest first: the last observation is the one a player reasons from. }
    if AFieldId = '' then
      Q.SQL.Text := 'SELECT * FROM field_evidence ' +
        'ORDER BY sequence DESC LIMIT :limit'
    else
      Q.SQL.Text := 'SELECT * FROM field_evidence WHERE field_id=:field ' +
        'ORDER BY sequence DESC LIMIT :limit';
    if AFieldId <> '' then
      Q.Params.ParamByName('field').AsString := AFieldId;
    Q.Params.ParamByName('limit').AsInteger := ALimit;
    Q.Open;
    Filled := 0;
    while not Q.EOF and (Filled < ALimit) do
    begin
      SetLength(AItems, Filled + 1);
      AItems[Filled] := RowToRecord(Q);
      Inc(Filled);
      Q.Next;
    end;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"count":' + IntToStr(Filled) + '}');
  except
    if FTransaction.Active then
      FTransaction.Rollback;
    SetLength(AItems, 0);
    Result := TCEAResult.Error(rcInternalError, 'evidence_query_failed', '{}');
  end;
  Q.Free;
end;

function TCEAFieldEvidenceStore.Count: Cardinal;
var
  Q: TSQLQuery;
begin
  Result := 0;
  if EnsureConnected.Failed then
    Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then
      FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT COUNT(*) AS total FROM field_evidence';
    Q.Open;
    if not Q.EOF then
      Result := Q.FieldByName('total').AsInteger;
    Q.Close;
    FTransaction.Commit;
  except
    if FTransaction.Active then
      FTransaction.Rollback;
    Result := 0;
  end;
  Q.Free;
end;

constructor TCEAReverseEvidenceStore.Create(
  const ARepository: TCEAReverseRepository);
begin
  inherited Create;
  FRepository := ARepository;
end;

function TCEAReverseEvidenceStore.AppendEvidence(
  const AEvidence: TCEAEvidenceReference): TCEAResult;
begin
  if FRepository = nil then
    Exit(TCEAResult.Error(rcInternalError, 'reverse_store_required', '{}'));
  Result := FRepository.SaveEvidence(AEvidence);
end;

function TCEAReverseEvidenceStore.FindEvidence(const AEvidenceId: string;
  out AEvidence: TCEAEvidenceReference): TCEAResult;
begin
  if FRepository = nil then
    Exit(TCEAResult.Error(rcInternalError, 'reverse_store_required', '{}'));
  Result := FRepository.LoadEvidence(AEvidenceId, AEvidence);
end;

end.
