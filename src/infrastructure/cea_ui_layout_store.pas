unit cea_ui_layout_store;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, cea_results, cea_ui_layout_types;

type
  // 布局记忆与副屏窗口位置记忆的 SQLite 持久化（FR-024 / FR-032）。
  TCEAUiLayoutStore = class(TObject, ICEAUiLayoutStore, ICEAWindowPlacementStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function SaveLayout(const ALayout: TCEAUiLayoutState): TCEAResult;
    function LoadLayout(const ASchemaId: string;
      out ALayout: TCEAUiLayoutState): TCEAResult;
    function DeleteLayout(const ASchemaId: string): TCEAResult;
    function SavePlacement(
      const APlacement: TCEASecondaryWindowPlacement): TCEAResult;
    function LoadPlacement(const ASchemaId: string;
      out APlacement: TCEASecondaryWindowPlacement): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

function LayoutJson(const ALayout: TCEAUiLayoutState): string;
var
  Root, Item: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('schema_id', ALayout.SchemaId);
    Root.Add('updated_at', ALayout.UpdatedAt);
    Arr := TJSONArray.Create;
    Root.Add('components', Arr);
    for I := 0 to High(ALayout.Components) do
    begin
      Item := TJSONObject.Create;
      Arr.Add(Item);
      Item.Add('component_id', ALayout.Components[I].ComponentId);
      Item.Add('order', ALayout.Components[I].Order);
      Item.Add('hidden', ALayout.Components[I].Hidden);
      Item.Add('width', ALayout.Components[I].Width);
      Item.Add('height', ALayout.Components[I].Height);
    end;
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function LayoutFromJson(const APayload: string;
  out ALayout: TCEAUiLayoutState): Boolean;
var
  Data, Item: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Result := False;
  ALayout.SchemaId := '';
  ALayout.UpdatedAt := '';
  SetLength(ALayout.Components, 0);
  Data := nil;
  try
    try
      Data := GetJSON(APayload);
    except
      Exit;
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then Exit;
    Obj := TJSONObject(Data);
    ALayout.SchemaId := Obj.Get('schema_id', '');
    ALayout.UpdatedAt := Obj.Get('updated_at', '');
    Item := Obj.Find('components');
    if (Item <> nil) and (Item.JSONType = jtArray) then
    begin
      Arr := TJSONArray(Item);
      SetLength(ALayout.Components, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        if Arr.Items[I].JSONType <> jtObject then Exit;
        ALayout.Components[I].ComponentId :=
          TJSONObject(Arr.Items[I]).Get('component_id', '');
        ALayout.Components[I].Order :=
          TJSONObject(Arr.Items[I]).Get('order', 0);
        ALayout.Components[I].Hidden :=
          TJSONObject(Arr.Items[I]).Get('hidden', False);
        ALayout.Components[I].Width :=
          TJSONObject(Arr.Items[I]).Get('width', 0);
        ALayout.Components[I].Height :=
          TJSONObject(Arr.Items[I]).Get('height', 0);
      end;
    end;
    Result := ALayout.SchemaId <> '';
  finally
    Data.Free;
  end;
end;

constructor TCEAUiLayoutStore.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAUiLayoutStore.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEAUiLayoutStore.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_layout_database_path_required',
      '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_layout_database_open_failed',
      '{}');
  end;
end;

function TCEAUiLayoutStore.Initialize: TCEAResult;
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
      'CREATE TABLE IF NOT EXISTS ui_layouts (' +
      'schema_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL)';
    Q.ExecSQL;
    Q.SQL.Text :=
      'CREATE TABLE IF NOT EXISTS secondary_window_placements (' +
      'schema_id TEXT PRIMARY KEY, display_id TEXT NOT NULL, ' +
      'left_pos INTEGER NOT NULL, top_pos INTEGER NOT NULL, ' +
      'width INTEGER NOT NULL, height INTEGER NOT NULL, ' +
      'maximized INTEGER NOT NULL, scale_percent INTEGER NOT NULL)';
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ui_layout_initialize_failed',
      '{}');
  end;
  Q.Free;
end;

function TCEAUiLayoutStore.SaveLayout(
  const ALayout: TCEAUiLayoutState): TCEAResult;
var
  Q: TSQLQuery;
begin
  if not ALayout.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_layout_invalid', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text :=
      'INSERT OR REPLACE INTO ui_layouts (schema_id, payload_json) ' +
      'VALUES (:id, :payload)';
    Q.Params.ParamByName('id').AsString := ALayout.SchemaId;
    Q.Params.ParamByName('payload').AsString := LayoutJson(ALayout);
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ui_layout_save_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiLayoutStore.LoadLayout(const ASchemaId: string;
  out ALayout: TCEAUiLayoutState): TCEAResult;
var
  Q: TSQLQuery;
begin
  ALayout.SchemaId := '';
  ALayout.UpdatedAt := '';
  SetLength(ALayout.Components, 0);
  if ASchemaId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_layout_schema_id_required',
      '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text := 'SELECT payload_json FROM ui_layouts WHERE schema_id=:id';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.Open;
    if Q.EOF then
      Exit(TCEAResult.Error(rcUnknown, 'ui_layout_not_found', '{}'));
    if not LayoutFromJson(Q.Fields[0].AsString, ALayout) then
      Exit(TCEAResult.Error(rcInternalError, 'ui_layout_payload_invalid', '{}'));
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'ui_layout_load_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiLayoutStore.DeleteLayout(const ASchemaId: string): TCEAResult;
var
  Q: TSQLQuery;
begin
  if ASchemaId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_layout_schema_id_required',
      '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'DELETE FROM ui_layouts WHERE schema_id=:id';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ui_layout_delete_failed', '{}');
  end;
  Q.Free;
end;

function TCEAUiLayoutStore.SavePlacement(
  const APlacement: TCEASecondaryWindowPlacement): TCEAResult;
var
  Q: TSQLQuery;
begin
  if not APlacement.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'window_placement_invalid', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text :=
      'INSERT OR REPLACE INTO secondary_window_placements ' +
      '(schema_id, display_id, left_pos, top_pos, width, height, maximized, ' +
      'scale_percent) VALUES (:id, :display, :left, :top, :width, :height, ' +
      ':maximized, :scale)';
    Q.Params.ParamByName('id').AsString := APlacement.SchemaId;
    Q.Params.ParamByName('display').AsString := APlacement.DisplayId;
    Q.Params.ParamByName('left').AsInteger := APlacement.Left;
    Q.Params.ParamByName('top').AsInteger := APlacement.Top;
    Q.Params.ParamByName('width').AsInteger := APlacement.Width;
    Q.Params.ParamByName('height').AsInteger := APlacement.Height;
    Q.Params.ParamByName('maximized').AsInteger := Ord(APlacement.Maximized);
    Q.Params.ParamByName('scale').AsInteger := APlacement.ScalePercent;
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'window_placement_save_failed',
      '{}');
  end;
  Q.Free;
end;

function TCEAUiLayoutStore.LoadPlacement(const ASchemaId: string;
  out APlacement: TCEASecondaryWindowPlacement): TCEAResult;
var
  Q: TSQLQuery;
begin
  APlacement.SchemaId := '';
  APlacement.DisplayId := '';
  APlacement.Left := 0;
  APlacement.Top := 0;
  APlacement.Width := 0;
  APlacement.Height := 0;
  APlacement.Maximized := False;
  APlacement.ScalePercent := 0;
  if ASchemaId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'window_placement_schema_required',
      '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text :=
      'SELECT display_id, left_pos, top_pos, width, height, maximized, ' +
      'scale_percent FROM secondary_window_placements WHERE schema_id=:id';
    Q.Params.ParamByName('id').AsString := ASchemaId;
    Q.Open;
    if Q.EOF then
      Exit(TCEAResult.Error(rcUnknown, 'window_placement_not_found', '{}'));
    APlacement.SchemaId := ASchemaId;
    APlacement.DisplayId := Q.Fields[0].AsString;
    APlacement.Left := Q.Fields[1].AsInteger;
    APlacement.Top := Q.Fields[2].AsInteger;
    APlacement.Width := Q.Fields[3].AsInteger;
    APlacement.Height := Q.Fields[4].AsInteger;
    APlacement.Maximized := Q.Fields[5].AsInteger <> 0;
    APlacement.ScalePercent := Q.Fields[6].AsInteger;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'window_placement_load_failed',
      '{}');
  end;
  Q.Free;
end;

end.
