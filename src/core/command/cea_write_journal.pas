unit cea_write_journal;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DB, SQLDB, SQLite3Conn, cea_results, cea_write_journal_types;

type
  // 写入日志仓储（FR-046 操作历史）。
  //
  // 与治理账本的区别：effects/receipts/proofs 只记录受治理的
  // PlanMemoryWrite 路径；玩家日常写入走命令总线，直接调
  // Win32 CompareWriteReadback，不产生 Effect。这张表补上那段空白。
  TCEAWriteJournal = class(TObject, ICEAWriteJournalStore)
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function AppendWrite(const ARecord: TCEAFieldWriteRecord;
      out ARecordId: string): TCEAResult;
    function ListWrites(const AFieldId: string; const ALimit: Integer;
      out ARecords: TCEAFieldWriteRecordArray): TCEAResult;
    function CountWrites(out ACount: Integer): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

const
  WriteTableSql =
    'CREATE TABLE IF NOT EXISTS field_writes (' +
    'sequence INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'record_id TEXT NOT NULL UNIQUE, ' +
    'field_id TEXT NOT NULL, ' +
    'display_name TEXT NOT NULL, ' +
    'value_type TEXT NOT NULL, ' +
    'original_value TEXT NOT NULL, ' +
    'target_value TEXT NOT NULL, ' +
    'adapter_id TEXT NOT NULL, ' +
    'address_hex TEXT NOT NULL, ' +
    'process_identity_id TEXT NOT NULL, ' +
    'pid INTEGER NOT NULL, ' +
    'epoch INTEGER NOT NULL, ' +
    'outcome TEXT NOT NULL, ' +
    'stable_code TEXT NOT NULL, ' +
    'error_text TEXT NOT NULL, ' +
    'detail_json TEXT NOT NULL, ' +
    'command_sent INTEGER NOT NULL, ' +
    'verified INTEGER NOT NULL, ' +
    'recorded_at TEXT NOT NULL)';

constructor TCEAWriteJournal.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCEAWriteJournal.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCEAWriteJournal.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'write_journal_database_path_required', '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError,
      'write_journal_database_open_failed', '{}');
  end;
end;

function TCEAWriteJournal.Initialize: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  try
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect(WriteTableSql);
    FConnection.ExecuteDirect(
      'CREATE INDEX IF NOT EXISTS idx_writes_field ' +
      'ON field_writes(field_id, sequence DESC)');
    FConnection.ExecuteDirect(
      'CREATE INDEX IF NOT EXISTS idx_writes_recorded ' +
      'ON field_writes(recorded_at)');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError,
      'write_journal_initialize_failed', '{}');
  end;
end;

function TCEAWriteJournal.AppendWrite(const ARecord: TCEAFieldWriteRecord;
  out ARecordId: string): TCEAResult;
var
  Q: TSQLQuery;
begin
  ARecordId := '';
  if not ARecord.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'write_record_invalid', '{}'));
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'INSERT INTO field_writes ' +
      '(record_id, field_id, display_name, value_type, original_value, ' +
      'target_value, adapter_id, address_hex, process_identity_id, pid, ' +
      'epoch, outcome, stable_code, error_text, detail_json, command_sent, ' +
      'verified, recorded_at) VALUES (:rid, :fid, :disp, :vtype, :orig, ' +
      ':target, :adapter, :addr, :ident, :pid, :epoch, :outcome, :stable, ' +
      ':err, :detail, :sent, :verified, :at)';
    Q.Params.ParamByName('rid').AsString := ARecord.RecordId;
    Q.Params.ParamByName('fid').AsString := ARecord.FieldId;
    Q.Params.ParamByName('disp').AsString := ARecord.DisplayName;
    Q.Params.ParamByName('vtype').AsString := ARecord.ValueType;
    Q.Params.ParamByName('orig').AsString := ARecord.OriginalValue;
    Q.Params.ParamByName('target').AsString := ARecord.TargetValue;
    Q.Params.ParamByName('adapter').AsString := ARecord.AdapterId;
    Q.Params.ParamByName('addr').AsString := ARecord.AddressHex;
    Q.Params.ParamByName('ident').AsString := ARecord.ProcessIdentityId;
    Q.Params.ParamByName('pid').AsLargeInt := ARecord.Pid;
    Q.Params.ParamByName('epoch').AsLargeInt := Int64(ARecord.Epoch);
    Q.Params.ParamByName('outcome').AsString := ARecord.Outcome;
    Q.Params.ParamByName('stable').AsString := ARecord.StableCode;
    Q.Params.ParamByName('err').AsString := ARecord.ErrorText;
    Q.Params.ParamByName('detail').AsString := ARecord.DetailJson;
    Q.Params.ParamByName('sent').AsInteger := Ord(ARecord.CommandSent);
    Q.Params.ParamByName('verified').AsInteger := Ord(ARecord.Verified);
    Q.Params.ParamByName('at').AsString := ARecord.RecordedAt;
    Q.ExecSQL;
    FTransaction.Commit;
    ARecordId := ARecord.RecordId;
    Result := TCEAResult.Ok('{"record_id":"' + ARecord.RecordId + '"}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'write_record_save_failed', '{}');
  end;
  Q.Free;
end;

function TCEAWriteJournal.ListWrites(const AFieldId: string;
  const ALimit: Integer; out ARecords: TCEAFieldWriteRecordArray): TCEAResult;
var
  Q: TSQLQuery;
  Limit: Integer;
  Item: TCEAFieldWriteRecord;
begin
  SetLength(ARecords, 0);
  Limit := ALimit;
  if Limit <= 0 then Limit := CeaWriteJournalDefaultLimit;
  if Limit > CeaWriteJournalMaxLimit then Limit := CeaWriteJournalMaxLimit;
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    if AFieldId = '' then
      Q.SQL.Text := 'SELECT * FROM field_writes ' +
        'ORDER BY sequence DESC LIMIT :lim'
    else
      Q.SQL.Text := 'SELECT * FROM field_writes WHERE field_id=:fid ' +
        'ORDER BY sequence DESC LIMIT :lim';
    if AFieldId <> '' then
      Q.Params.ParamByName('fid').AsString := AFieldId;
    Q.Params.ParamByName('lim').AsInteger := Limit;
    Q.Open;
    while not Q.EOF do
    begin
      FillChar(Item, SizeOf(Item), 0);
      Item.Sequence := Q.FieldByName('sequence').AsLargeInt;
      Item.RecordId := Q.FieldByName('record_id').AsString;
      Item.FieldId := Q.FieldByName('field_id').AsString;
      Item.DisplayName := Q.FieldByName('display_name').AsString;
      Item.ValueType := Q.FieldByName('value_type').AsString;
      Item.OriginalValue := Q.FieldByName('original_value').AsString;
      Item.TargetValue := Q.FieldByName('target_value').AsString;
      Item.AdapterId := Q.FieldByName('adapter_id').AsString;
      Item.AddressHex := Q.FieldByName('address_hex').AsString;
      Item.ProcessIdentityId := Q.FieldByName('process_identity_id').AsString;
      Item.Pid := Cardinal(Q.FieldByName('pid').AsLargeInt);
      Item.Epoch := QWord(Q.FieldByName('epoch').AsLargeInt);
      Item.Outcome := Q.FieldByName('outcome').AsString;
      Item.StableCode := Q.FieldByName('stable_code').AsString;
      Item.ErrorText := Q.FieldByName('error_text').AsString;
      Item.DetailJson := Q.FieldByName('detail_json').AsString;
      Item.CommandSent := Q.FieldByName('command_sent').AsInteger <> 0;
      Item.Verified := Q.FieldByName('verified').AsInteger <> 0;
      Item.RecordedAt := Q.FieldByName('recorded_at').AsString;
      SetLength(ARecords, Length(ARecords) + 1);
      ARecords[High(ARecords)] := Item;
      Q.Next;
    end;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"count":' + IntToStr(Length(ARecords)) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError,
      'write_journal_query_failed', '{}');
  end;
  Q.Free;
end;

function TCEAWriteJournal.CountWrites(out ACount: Integer): TCEAResult;
var
  Q: TSQLQuery;
begin
  ACount := 0;
  Result := EnsureConnected;
  if Result.Failed then Exit;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConnection;
    Q.Transaction := FTransaction;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Q.SQL.Text := 'SELECT COUNT(*) AS n FROM field_writes';
    Q.Open;
    if not Q.EOF then
      ACount := Q.FieldByName('n').AsInteger;
    Q.Close;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"count":' + IntToStr(ACount) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError,
      'write_journal_count_failed', '{}');
  end;
  Q.Free;
end;

end.
