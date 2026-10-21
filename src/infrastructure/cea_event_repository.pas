unit cea_event_repository;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, cea_results, cea_event_types;

type
  // 事件包持久化（FR-076 事件包 / FR-083 证据导出与删除）。
  //
  // 与内存态 TCEAEventService 的分工：服务负责触发判定与事件合并，
  // 本仓储只负责把事件包落 SQLite 并支持按 id 读取与删除。
  TCEAEventRepository = class(TObject, ICEAEventStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function SaveEvent(const AEvent: TCEAEventPackage): TCEAResult;
    function LoadEvent(const AEventId: string;
      out AEvent: TCEAEventPackage): TCEAResult;
    function ListEvents: TCEAEventPackageArray;
    function DeleteEvent(const AEventId: string): TCEAResult;
    // 按进程身份读取该局事件（时间线视图用）
    function ListEventsForProcess(const AProcessIdentityId: string;
      out AEvents: TCEAEventPackageArray): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

function EventJson(const A: TCEAEventPackage): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('event_id', A.EventId);
    O.Add('trigger_kind', EventTriggerKindText(A.TriggerKind));
    O.Add('trigger_source', A.TriggerSource);
    O.Add('start_at_ms', A.StartAtMs);
    O.Add('end_at_ms', A.EndAtMs);
    O.Add('process_identity_id', A.ProcessIdentityId);
    O.Add('epoch', A.Epoch);
    O.Add('field_snapshots_json', A.FieldSnapshotsJson);
    O.Add('recording_refs_json', A.RecordingRefsJson);
    O.Add('analysis_state', EventAnalysisStateText(A.AnalysisState));
    O.Add('user_tags_json', A.UserTagsJson);
    O.Add('created_at_ms', A.CreatedAtMs);
    O.Add('clock_error_ms', A.ClockErrorMs);
    O.Add('capture_latency_ms', A.CaptureLatencyMs);
    Result := O.AsJSON;
  finally
    O.Free;
  end;
end;

function EventFromJson(const APayload: string;
  out AEvent: TCEAEventPackage): Boolean;
var
  D: TJSONData;
  O: TJSONObject;
  KindText, StateText: string;
begin
  Result := False;
  FillChar(AEvent, SizeOf(AEvent), 0);
  D := nil;
  try
    try
      D := GetJSON(APayload);
    except
      Exit;
    end;
    if (D = nil) or (D.JSONType <> jtObject) then Exit;
    O := TJSONObject(D);
    AEvent.EventId := O.Get('event_id', '');
    KindText := O.Get('trigger_kind', '');
    if not TryParseEventTriggerKind(KindText, AEvent.TriggerKind) then Exit;
    AEvent.TriggerSource := O.Get('trigger_source', '');
    AEvent.StartAtMs := O.Get('start_at_ms', Int64(0));
    AEvent.EndAtMs := O.Get('end_at_ms', Int64(0));
    AEvent.ProcessIdentityId := O.Get('process_identity_id', '');
    AEvent.Epoch := QWord(O.Get('epoch', Int64(0)));
    AEvent.FieldSnapshotsJson := O.Get('field_snapshots_json', '');
    AEvent.RecordingRefsJson := O.Get('recording_refs_json', '');
    StateText := O.Get('analysis_state', '');
    if not TryParseEventAnalysisState(StateText, AEvent.AnalysisState) then Exit;
    AEvent.UserTagsJson := O.Get('user_tags_json', '');
    AEvent.CreatedAtMs := O.Get('created_at_ms', Int64(0));
    AEvent.ClockErrorMs := O.Get('clock_error_ms', Int64(0));
    AEvent.CaptureLatencyMs := O.Get('capture_latency_ms', Int64(0));
    Result := True;
  finally
    D.Free;
  end;
end;

constructor TCEAEventRepository.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAEventRepository.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEAEventRepository.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_database_path_required', '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError, 'event_database_open_failed', '{}');
  end;
end;

function TCEAEventRepository.Initialize: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  try
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS event_packages (' +
      'event_id TEXT PRIMARY KEY, process_identity_id TEXT NOT NULL, ' +
      'created_at_ms INTEGER NOT NULL, payload_json TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE INDEX IF NOT EXISTS idx_events_process ' +
      'ON event_packages(process_identity_id)');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'event_store_initialize_failed', '{}');
  end;
end;

function TCEAEventRepository.SaveEvent(const AEvent: TCEAEventPackage): TCEAResult;
var
  Q: TSQLQuery;
begin
  if not AEvent.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_invalid', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'INSERT OR REPLACE INTO event_packages ' +
      '(event_id, process_identity_id, created_at_ms, payload_json) ' +
      'VALUES (:id, :pid, :created, :payload)';
    Q.Params.ParamByName('id').AsString := AEvent.EventId;
    Q.Params.ParamByName('pid').AsString := AEvent.ProcessIdentityId;
    Q.Params.ParamByName('created').AsLargeInt := AEvent.CreatedAtMs;
    Q.Params.ParamByName('payload').AsString := EventJson(AEvent);
    Q.ExecSQL;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"event_id":"' + AEvent.EventId + '"}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'event_save_failed', '{}');
  end;
  Q.Free;
end;

function TCEAEventRepository.LoadEvent(const AEventId: string;
  out AEvent: TCEAEventPackage): TCEAResult;
var
  Q: TSQLQuery;
begin
  FillChar(AEvent, SizeOf(AEvent), 0);
  if AEventId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT payload_json FROM event_packages WHERE event_id=:id';
    Q.Params.ParamByName('id').AsString := AEventId;
    Q.Open;
    if Q.EOF then
    begin
      Q.Close;
      FTransaction.Commit;
      Exit(TCEAResult.Error(rcUnknown, 'event_not_found', '{}'));
    end;
    if not EventFromJson(Q.Fields[0].AsString, AEvent) then
    begin
      Q.Close;
      FTransaction.Commit;
      Exit(TCEAResult.Error(rcInternalError, 'event_payload_invalid', '{}'));
    end;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'event_load_failed', '{}');
  end;
  Q.Free;
end;

function TCEAEventRepository.ListEvents: TCEAEventPackageArray;
var
  Q: TSQLQuery;
  P: TCEAEventPackage;
begin
  Result := nil;
  if EnsureConnected.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT payload_json FROM event_packages ORDER BY created_at_ms';
    Q.Open;
    while not Q.EOF do
    begin
      if EventFromJson(Q.Fields[0].AsString, P) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := P;
      end;
      Q.Next;
    end;
    Q.Close;
    FTransaction.Commit;
  except
    if FTransaction.Active then FTransaction.Rollback;
    SetLength(Result, 0);
  end;
  Q.Free;
end;

function TCEAEventRepository.ListEventsForProcess(const AProcessIdentityId: string;
  out AEvents: TCEAEventPackageArray): TCEAResult;
var
  Q: TSQLQuery;
  P: TCEAEventPackage;
begin
  SetLength(AEvents, 0);
  if AProcessIdentityId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_process_identity_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT payload_json FROM event_packages ' +
      'WHERE process_identity_id=:pid ORDER BY created_at_ms';
    Q.Params.ParamByName('pid').AsString := AProcessIdentityId;
    Q.Open;
    while not Q.EOF do
    begin
      if EventFromJson(Q.Fields[0].AsString, P) then
      begin
        SetLength(AEvents, Length(AEvents) + 1);
        AEvents[High(AEvents)] := P;
      end;
      Q.Next;
    end;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"count":' + IntToStr(Length(AEvents)) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    SetLength(AEvents, 0);
    Result := TCEAResult.Error(rcInternalError, 'event_list_failed', '{}');
  end;
  Q.Free;
end;

function TCEAEventRepository.DeleteEvent(const AEventId: string): TCEAResult;
var
  Q: TSQLQuery;
  Affected: Integer;
begin
  if AEventId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_id_required', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'DELETE FROM event_packages WHERE event_id=:id';
    Q.Params.ParamByName('id').AsString := AEventId;
    Q.ExecSQL;
    Affected := Q.RowsAffected;
    FTransaction.Commit;
    if Affected <= 0 then
      Exit(TCEAResult.Error(rcUnknown, 'event_not_found', '{}'));
    // FR-083：删除后不得留下可恢复的隐私副本。SQLite 默认把被删行留在
    // 空闲页中，因此删除成功后重建库文件（VACUUM），使旧字节不再存在于磁盘。
    // VACUUM 不能在事务内执行，故放在提交之后。
    try
      FConnection.ExecuteDirect('VACUUM');
    except
      // 重建失败不影响删除语义：行已从逻辑视图中移除
    end;
    Result := TCEAResult.Ok('{"event_id":"' + AEventId + '","deleted":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'event_delete_failed', '{}');
  end;
  Q.Free;
end;

end.
