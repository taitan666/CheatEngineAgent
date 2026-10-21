unit cea_ui_page_store;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, cea_results, cea_ui_page_types;

type
  // SQLite persistence for secondary-screen pages and their schema version
  // history (FR-026 / FR-033).
  //
  // History is append-only: SavePage always inserts a new row, and a rollback
  // is expressed as "save the old JSON as the next version". Nothing in this
  // store can destroy a version, so an operator can always walk back.
  TCEAUiPageStore = class(TObject, ICEAUiPageStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
    function NextVersion(const ASchemaId: string;
      out AVersion: Integer): TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function SavePage(const APageId, ATitle, ASchemaId, ASchemaJson,
      AUpdatedAt: string; out AVersion: Integer): TCEAResult;
    function ListPages(out APages: TCEAUiPageArray): TCEAResult;
    function GetPage(const APageId: string; out APage: TCEAUiPage;
      out ASchemaJson: string): TCEAResult;
    function SetActivePage(const APageId: string): TCEAResult;
    function GetActivePage(out APage: TCEAUiPage;
      out ASchemaJson: string): TCEAResult;
    function ListVersions(const ASchemaId: string;
      out AVersions: TCEAUiSchemaVersionArray): TCEAResult;
    function LoadVersion(const ASchemaId: string; const AVersion: Integer;
      out ASchemaJson: string): TCEAResult;
  end;

implementation

constructor TCEAUiPageStore.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAUiPageStore.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEAUiPageStore.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_page_database_path_required',
      '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_page_database_open_failed',
      '{}');
  end;
end;

function TCEAUiPageStore.Initialize: TCEAResult;
var
  Q: TSQLQuery;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS ui_schema_versions (' +
      'schema_id TEXT NOT NULL, version INTEGER NOT NULL, ' +
      'created_at TEXT NOT NULL, payload_json TEXT NOT NULL, ' +
      'PRIMARY KEY (schema_id, version))';
    Q.ExecSQL;
    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS ui_pages (' +
      'page_id TEXT PRIMARY KEY, title TEXT NOT NULL, ' +
      'schema_id TEXT NOT NULL, version INTEGER NOT NULL, ' +
      'active INTEGER NOT NULL, updated_at TEXT NOT NULL)';
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ui_page_initialize_failed',
      '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.NextVersion(const ASchemaId: string;
  out AVersion: Integer): TCEAResult;
var
  Q: TSQLQuery;
begin
  AVersion := 0;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text :=
      'SELECT COALESCE(MAX(version), 0) FROM ui_schema_versions ' +
      'WHERE schema_id=:id';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.Open;
    AVersion := Q.Fields[0].AsInteger + 1;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_page_version_query_failed',
      '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.SavePage(const APageId, ATitle, ASchemaId,
  ASchemaJson, AUpdatedAt: string; out AVersion: Integer): TCEAResult;
var
  Q: TSQLQuery;
begin
  AVersion := 0;
  if (Trim(APageId) = '') or (Trim(ATitle) = '') or (Trim(ASchemaId) = '') then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_page_fields_required', '{}'));
  if Trim(ASchemaJson) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_page_schema_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Result := NextVersion(ASchemaId, AVersion);
  if Result.Failed then Exit;

  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text :=
      'INSERT INTO ui_schema_versions ' +
      '(schema_id, version, created_at, payload_json) ' +
      'VALUES (:id, :version, :created, :payload)';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.Params.ParamByName('version').AsInteger := AVersion;
    Q.Params.ParamByName('created').AsString := AUpdatedAt;
    Q.Params.ParamByName('payload').AsString := ASchemaJson;
    Q.ExecSQL;
    // A page switch must not leave two active rows behind.
    Q.SQL.Text := 'UPDATE ui_pages SET active=0 WHERE active<>0';
    Q.ExecSQL;
    Q.SQL.Text :=
      'INSERT OR REPLACE INTO ui_pages ' +
      '(page_id, title, schema_id, version, active, updated_at) ' +
      'VALUES (:page, :title, :schema, :version, 1, :updated)';
    Q.Params.ParamByName('page').AsString := APageId;
    Q.Params.ParamByName('title').AsString := ATitle;
    Q.Params.ParamByName('schema').AsString := ASchemaId;
    Q.Params.ParamByName('version').AsInteger := AVersion;
    Q.Params.ParamByName('updated').AsString := AUpdatedAt;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"page_id":"' + APageId +
      '","schema_id":"' + ASchemaId +
      '","version":' + IntToStr(AVersion) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ui_page_save_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.ListPages(out APages: TCEAUiPageArray): TCEAResult;
var
  Q: TSQLQuery;
  N: Integer;
begin
  SetLength(APages, 0);
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text :=
      'SELECT page_id, title, schema_id, version, active, updated_at ' +
      'FROM ui_pages ORDER BY page_id';
    Q.Open;
    N := 0;
    SetLength(APages, 16);
    while not Q.EOF do
    begin
      if N >= Length(APages) then SetLength(APages, N * 2);
      APages[N].PageId := Q.Fields[0].AsString;
      APages[N].Title := Q.Fields[1].AsString;
      APages[N].SchemaId := Q.Fields[2].AsString;
      APages[N].Version := Q.Fields[3].AsInteger;
      APages[N].Active := Q.Fields[4].AsInteger <> 0;
      APages[N].UpdatedAt := Q.Fields[5].AsString;
      Inc(N);
      Q.Next;
    end;
    SetLength(APages, N);
    Result := TCEAResult.Ok('{"count":' + IntToStr(N) + '}');
  except
    SetLength(APages, 0);
    Result := TCEAResult.Error(rcInternalError, 'ui_page_list_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.GetPage(const APageId: string; out APage: TCEAUiPage;
  out ASchemaJson: string): TCEAResult;
var
  Q: TSQLQuery;
begin
  APage.PageId := '';
  APage.Title := '';
  APage.SchemaId := '';
  APage.Version := 0;
  APage.Active := False;
  APage.UpdatedAt := '';
  ASchemaJson := '';
  if Trim(APageId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_page_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text :=
      'SELECT page_id, title, schema_id, version, active, updated_at ' +
      'FROM ui_pages WHERE page_id=:page';
    Q.Params.ParamByName('page').AsString := APageId;
    Q.Open;
    if Q.EOF then
      Exit(TCEAResult.Error(rcUnknown, 'ui_page_not_found', '{}'));
    APage.PageId := Q.Fields[0].AsString;
    APage.Title := Q.Fields[1].AsString;
    APage.SchemaId := Q.Fields[2].AsString;
    APage.Version := Q.Fields[3].AsInteger;
    APage.Active := Q.Fields[4].AsInteger <> 0;
    APage.UpdatedAt := Q.Fields[5].AsString;
    Q.Close;
    Result := LoadVersion(APage.SchemaId, APage.Version, ASchemaJson);
    if Result.Failed then Exit;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_page_load_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.SetActivePage(const APageId: string): TCEAResult;
var
  Q: TSQLQuery;
begin
  if Trim(APageId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_page_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT COUNT(*) FROM ui_pages WHERE page_id=:page';
    Q.Params.ParamByName('page').AsString := APageId;
    Q.Open;
    if Q.Fields[0].AsInteger = 0 then
    begin
      FTransaction.Rollback;
      Exit(TCEAResult.Error(rcUnknown, 'ui_page_not_found', '{}'));
    end;
    Q.Close;
    Q.SQL.Text := 'UPDATE ui_pages SET active=0 WHERE active<>0';
    Q.ExecSQL;
    Q.SQL.Text := 'UPDATE ui_pages SET active=1 WHERE page_id=:page';
    Q.Params.ParamByName('page').AsString := APageId;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"active_page":"' + APageId + '"}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ui_page_activate_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.GetActivePage(out APage: TCEAUiPage;
  out ASchemaJson: string): TCEAResult;
var
  Q: TSQLQuery;
  PageId: string;
begin
  APage.PageId := '';
  APage.Title := '';
  APage.SchemaId := '';
  APage.Version := 0;
  APage.Active := False;
  APage.UpdatedAt := '';
  ASchemaJson := '';
  Result := EnsureConnected;
  if Result.Failed then Exit;
  PageId := '';
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text := 'SELECT page_id FROM ui_pages WHERE active<>0';
    Q.Open;
    if not Q.EOF then PageId := Q.Fields[0].AsString;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_page_active_failed', '{}');
  end;
  Q.Free;
  if Result.Failed then Exit;
  if PageId = '' then
    Exit(TCEAResult.Error(rcUnknown, 'ui_page_none_active', '{}'));
  Result := GetPage(PageId, APage, ASchemaJson);
end;

function TCEAUiPageStore.ListVersions(const ASchemaId: string;
  out AVersions: TCEAUiSchemaVersionArray): TCEAResult;
var
  Q: TSQLQuery;
  N: Integer;
begin
  SetLength(AVersions, 0);
  if Trim(ASchemaId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text :=
      'SELECT version, created_at FROM ui_schema_versions ' +
      'WHERE schema_id=:id ORDER BY version DESC';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.Open;
    N := 0;
    SetLength(AVersions, 16);
    while not Q.EOF do
    begin
      if N >= Length(AVersions) then SetLength(AVersions, N * 2);
      AVersions[N].SchemaId := ASchemaId;
      AVersions[N].Version := Q.Fields[0].AsInteger;
      AVersions[N].CreatedAt := Q.Fields[1].AsString;
      Inc(N);
      Q.Next;
    end;
    SetLength(AVersions, N);
    Result := TCEAResult.Ok('{"count":' + IntToStr(N) + '}');
  except
    SetLength(AVersions, 0);
    Result := TCEAResult.Error(rcInternalError, 'ui_page_versions_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiPageStore.LoadVersion(const ASchemaId: string;
  const AVersion: Integer; out ASchemaJson: string): TCEAResult;
var
  Q: TSQLQuery;
begin
  ASchemaJson := '';
  if (Trim(ASchemaId) = '') or (AVersion <= 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_version_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text :=
      'SELECT payload_json FROM ui_schema_versions ' +
      'WHERE schema_id=:id AND version=:version';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.Params.ParamByName('version').AsInteger := AVersion;
    Q.Open;
    if Q.EOF then
      Exit(TCEAResult.Error(rcUnknown, 'ui_schema_version_not_found', '{}'));
    ASchemaJson := Q.Fields[0].AsString;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_page_version_load_failed',
      '{}');
  end;
  Q.Free;
end;

end.
