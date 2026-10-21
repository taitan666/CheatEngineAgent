unit cea_profile_store;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, cea_results, cea_profile_types,
  cea_profile_ports;

type
  TCEAProfileStore = class(TObject, ICEAProfileStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function SaveProfile(const AProfile: TCEAGameProfile): TCEAResult;
    function LoadProfile(const AProfileId: string;
      out AProfile: TCEAGameProfile): TCEAResult;
    function ListProfiles(const AGameName: string;
      out AProfiles: TCEAGameProfileArray): TCEAResult;
    function DeleteProfile(const AProfileId: string): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

function ProfileJson(const A: TCEAGameProfile): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', A.Id);
    O.Add('game_name', A.GameName);
    O.Add('game_version', A.GameVersion);
    O.Add('executable_sha256', A.ExecutableSha256);
    O.Add('module_set_hash', A.ModuleSetHash);
    O.Add('connector_type', A.ConnectorType);
    O.Add('fields_json', A.FieldsJson);
    O.Add('ui_schema_json', A.UiSchemaJson);
    O.Add('evidence_json', A.EvidenceJson);
    O.Add('created_at', A.CreatedAt);
    O.Add('updated_at', A.UpdatedAt);
    O.Add('last_verified_at', A.LastVerifiedAt);
    O.Add('invalidation_reason', A.InvalidationReason);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function ProfileFromJson(const APayload: string; out AProfile: TCEAGameProfile): Boolean;
var
  D: TJSONData;
  O: TJSONObject;
begin
  Result := False;
  D := nil;
  try
    D := GetJSON(APayload);
    if (D = nil) or (D.JSONType <> jtObject) then Exit;
    O := TJSONObject(D);
    AProfile.Id := O.Get('id', '');
    AProfile.GameName := O.Get('game_name', '');
    AProfile.GameVersion := O.Get('game_version', '');
    AProfile.ExecutableSha256 := O.Get('executable_sha256', '');
    AProfile.ModuleSetHash := O.Get('module_set_hash', '');
    AProfile.ConnectorType := O.Get('connector_type', '');
    AProfile.FieldsJson := O.Get('fields_json', '');
    AProfile.UiSchemaJson := O.Get('ui_schema_json', '');
    AProfile.EvidenceJson := O.Get('evidence_json', '');
    AProfile.CreatedAt := O.Get('created_at', '');
    AProfile.UpdatedAt := O.Get('updated_at', '');
    AProfile.LastVerifiedAt := O.Get('last_verified_at', '');
    AProfile.InvalidationReason := O.Get('invalidation_reason', '');
    Result := True;
  finally
    D.Free;
  end;
end;

constructor TCEAProfileStore.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAProfileStore.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEAProfileStore.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_database_path_required', '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'profile_database_open_failed', '{}');
  end;
end;

function TCEAProfileStore.Initialize: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  try
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS game_profiles (' +
      'profile_id TEXT PRIMARY KEY, game_name TEXT NOT NULL, ' +
      'executable_sha256 TEXT NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE INDEX IF NOT EXISTS idx_profiles_game ON game_profiles(game_name)');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'profile_store_initialize_failed', '{}');
  end;
end;

function TCEAProfileStore.SaveProfile(const AProfile: TCEAGameProfile): TCEAResult;
var
  Q: TSQLQuery;
  P: string;
begin
  if not AProfile.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_invalid', '{}'));
  P := ProfileJson(AProfile);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    // upsert：存在则更新
    Q.SQL.Text := 'INSERT OR REPLACE INTO game_profiles ' +
      '(profile_id, game_name, executable_sha256, payload_json) ' +
      'VALUES (:id, :game, :exe, :payload)';
    Q.Params.ParamByName('id').AsString := AProfile.Id;
    Q.Params.ParamByName('game').AsString := AProfile.GameName;
    Q.Params.ParamByName('exe').AsString := AProfile.ExecutableSha256;
    Q.Params.ParamByName('payload').AsString := P;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"profile_id":"' + AProfile.Id + '"}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'profile_save_failed', '{}');
  end;
  Q.Free;
end;

function TCEAProfileStore.LoadProfile(const AProfileId: string;
  out AProfile: TCEAGameProfile): TCEAResult;
var
  Q: TSQLQuery;
begin
  FillChar(AProfile, SizeOf(AProfile), 0);
  if AProfileId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT payload_json FROM game_profiles WHERE profile_id=:id';
    Q.Params.ParamByName('id').AsString := AProfileId;
    Q.Open;
    if Q.EOF then
    begin
      Q.Close;
      FTransaction.Commit;
      Exit(TCEAResult.Error(rcInvalidArgument, 'profile_not_found', '{}'));
    end;
    if not ProfileFromJson(Q.Fields[0].AsString, AProfile) then
    begin
      Q.Close;
      FTransaction.Commit;
      Exit(TCEAResult.Error(rcInternalError, 'profile_payload_invalid', '{}'));
    end;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'profile_load_failed', '{}');
  end;
  Q.Free;
end;

function TCEAProfileStore.ListProfiles(const AGameName: string;
  out AProfiles: TCEAGameProfileArray): TCEAResult;
var
  Q: TSQLQuery;
  P: TCEAGameProfile;
begin
  SetLength(AProfiles, 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    if AGameName <> '' then
    begin
      Q.SQL.Text := 'SELECT payload_json FROM game_profiles ' +
        'WHERE game_name=:game ORDER BY game_name';
      Q.Params.ParamByName('game').AsString := AGameName;
    end
    else
      Q.SQL.Text := 'SELECT payload_json FROM game_profiles ORDER BY game_name';
    Q.Open;
    while not Q.EOF do
    begin
      if ProfileFromJson(Q.Fields[0].AsString, P) then
      begin
        SetLength(AProfiles, Length(AProfiles) + 1);
        AProfiles[High(AProfiles)] := P;
      end;
      Q.Next;
    end;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"count":' + IntToStr(Length(AProfiles)) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'profile_list_failed', '{}');
  end;
  Q.Free;
end;

function TCEAProfileStore.DeleteProfile(const AProfileId: string): TCEAResult;
var
  Q: TSQLQuery;
begin
  if AProfileId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'profile_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'DELETE FROM game_profiles WHERE profile_id=:id';
    Q.Params.ParamByName('id').AsString := AProfileId;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'profile_delete_failed', '{}');
  end;
  Q.Free;
end;

end.
