unit cea_ct_catalog;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, DB, SQLDB, SQLite3Conn, cea_results, cea_types,
  cea_ct_model;

type
  TCTCatalog = class
  private
    FDatabasePath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    function EnsureConnected: TCEAResult;
    function ColumnExists(const ATableName, AColumnName: string): Boolean;
  public
    constructor Create(const ADatabasePath: string);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    function ImportArtifact(const ARequest: TCTImportRequest): TCEAResult;
    function ImportParsedArtifact(const AArtifact: TCTArtifact): TCEAResult;
    function SearchText(const AText: string; const AMaxResults: Cardinal): TCEAResult;
    function GetEntry(const AEntryKey: string): TCEAResult;
    function BuildRagContext(const AText: string;
      const AMaxResults: Cardinal): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

type
  TCTSearchHit = record
    Item: TJSONObject;
    Score: Integer;
    MatchType: string;
  end;
  TCTSearchHits = array of TCTSearchHit;

function NormalizedSearchText(const AValue: string): string;
var
  I: Integer;
  LastWasSpace: Boolean;
  C: Char;
begin
  Result := '';
  LastWasSpace := True;
  for I := 1 to Length(Trim(LowerCase(AValue))) do
  begin
    C := Trim(LowerCase(AValue))[I];
    if C in ['a'..'z', '0'..'9', #128..#255] then
    begin
      Result := Result + C;
      LastWasSpace := False;
    end
    else if not LastWasSpace then
    begin
      Result := Result + ' ';
      LastWasSpace := True;
    end;
  end;
  Result := Trim(Result);
end;

function SearchAcronym(const AValue: string): string;
var
  I: Integer;
  TakeNext: Boolean;
begin
  Result := '';
  TakeNext := True;
  for I := 1 to Length(AValue) do
    if AValue[I] = ' ' then
      TakeNext := True
    else if TakeNext then
    begin
      Result := Result + AValue[I];
      TakeNext := False;
    end;
end;

function LightweightPinyin(const AValue: string): string;
const
  Hanzi: array[0..31] of UnicodeString = (
    '无','限','生','命','金','钱','币','信','用','点','经','验','等','级',
    '攻','击','防','御','速','度','时','间','道','具','数','量','血','蓝',
    '体','力','魔','法');
  Pinyin: array[0..31] of string = (
    'wu','xian','sheng','ming','jin','qian','bi','xin','yong','dian',
    'jing','yan','deng','ji','gong','ji','fang','yu','su','du','shi','jian',
    'dao','ju','shu','liang','xue','lan','ti','li','mo','fa');
var
  Text: UnicodeString;
  I, J: Integer;
begin
  Result := '';
  Text := UnicodeString(AValue);
  for I := 1 to Length(Text) do
    for J := 0 to High(Hanzi) do
      if Text[I] = Hanzi[J][1] then
      begin
        if Result <> '' then Result := Result + ' ';
        Result := Result + Pinyin[J];
        Break;
      end;
end;

function CompactText(const AValue: string): string;
begin
  Result := StringReplace(AValue, ' ', '', [rfReplaceAll]);
end;

function TokenSetSimilarity(const ALeft, ARight: string): Integer;
var
  LeftSet, RightSet: TStringList;
  I, Intersection: Integer;
  Token: string;
begin
  Result := 0;
  if (Trim(ALeft) = '') or (Trim(ARight) = '') then Exit;
  LeftSet := TStringList.Create;
  RightSet := TStringList.Create;
  try
    LeftSet.Sorted := True;
    LeftSet.Duplicates := dupIgnore;
    RightSet.Sorted := True;
    RightSet.Duplicates := dupIgnore;
    LeftSet.Delimiter := ' ';
    LeftSet.StrictDelimiter := True;
    LeftSet.DelimitedText := Trim(ALeft);
    RightSet.Delimiter := ' ';
    RightSet.StrictDelimiter := True;
    RightSet.DelimitedText := Trim(ARight);
    Intersection := 0;
    for I := 0 to LeftSet.Count - 1 do
    begin
      Token := LeftSet[I];
      if RightSet.IndexOf(Token) >= 0 then Inc(Intersection);
    end;
    Result := Intersection * 200 div (LeftSet.Count + RightSet.Count);
  finally
    RightSet.Free;
    LeftSet.Free;
  end;
end;

function LevenshteinDistance(const ALeft, ARight: string): Integer;
var
  PreviousRow, CurrentRow: array of Integer;
  I, J, Cost, Candidate: Integer;
begin
  SetLength(PreviousRow, Length(ARight) + 1);
  SetLength(CurrentRow, Length(ARight) + 1);
  for J := 0 to Length(ARight) do PreviousRow[J] := J;
  for I := 1 to Length(ALeft) do
  begin
    CurrentRow[0] := I;
    for J := 1 to Length(ARight) do
    begin
      if ALeft[I] = ARight[J] then Cost := 0 else Cost := 1;
      CurrentRow[J] := PreviousRow[J] + 1;
      Candidate := CurrentRow[J - 1] + 1;
      if Candidate < CurrentRow[J] then CurrentRow[J] := Candidate;
      Candidate := PreviousRow[J - 1] + Cost;
      if Candidate < CurrentRow[J] then CurrentRow[J] := Candidate;
    end;
    PreviousRow := Copy(CurrentRow);
  end;
  Result := PreviousRow[Length(ARight)];
end;

function ScoreSearchField(const AQuery, AField: string;
  out AMatchType: string): Integer;
var
  FieldText, Acronym, PinyinText, PinyinCompact: string;
  Distance, MaximumLength, Similarity, VectorSimilarity: Integer;
begin
  Result := 0;
  AMatchType := '';
  FieldText := NormalizedSearchText(AField);
  if (FieldText = '') or (AQuery = '') then Exit;
  if FieldText = AQuery then
  begin
    AMatchType := 'exact';
    Exit(1000);
  end;
  if Pos(AQuery, FieldText) = 1 then
  begin
    AMatchType := 'prefix';
    Exit(900);
  end;
  if Pos(AQuery, FieldText) > 0 then
  begin
    AMatchType := 'substring';
    Exit(800);
  end;
  Acronym := SearchAcronym(FieldText);
  if (Length(AQuery) >= 2) and (Acronym = AQuery) then
  begin
    AMatchType := 'acronym';
    Exit(760);
  end;
  PinyinText := LightweightPinyin(AField);
  if PinyinText <> '' then
  begin
    PinyinCompact := CompactText(PinyinText);
    if PinyinCompact = CompactText(AQuery) then
    begin
      AMatchType := 'pinyin';
      Exit(740);
    end;
    if SearchAcronym(PinyinText) = CompactText(AQuery) then
    begin
      AMatchType := 'pinyin_initials';
      Exit(720);
    end;
  end;
  VectorSimilarity := TokenSetSimilarity(LightweightPinyin(AQuery),
    PinyinText);
  if VectorSimilarity >= 50 then
  begin
    AMatchType := 'lightweight_vector';
    Exit(400 + VectorSimilarity);
  end;
  if (Length(AQuery) > 128) or (Length(FieldText) > 128) then Exit;
  Distance := LevenshteinDistance(AQuery, FieldText);
  MaximumLength := Length(AQuery);
  if Length(FieldText) > MaximumLength then MaximumLength := Length(FieldText);
  Similarity := 100 - (Distance * 100 div MaximumLength);
  if Similarity >= 65 then
  begin
    AMatchType := 'fuzzy';
    Result := 500 + Similarity;
  end;
end;

function BestSearchScore(const AQuery: string;
  const AFields: array of string; out AMatchType: string): Integer;
var
  I, CandidateScore: Integer;
  CandidateType: string;
begin
  Result := 0;
  AMatchType := '';
  for I := 0 to High(AFields) do
  begin
    CandidateScore := ScoreSearchField(AQuery, AFields[I], CandidateType);
    if CandidateScore > Result then
    begin
      Result := CandidateScore;
      AMatchType := CandidateType;
    end;
  end;
end;

function StringsJson(const AValues: TCTStringArray): string;
var
  Values: TJSONArray;
  I: Integer;
begin
  Values := TJSONArray.Create;
  try
    for I := 0 to High(AValues) do Values.Add(AValues[I]);
    Result := Values.AsJSON;
  finally
    Values.Free;
  end;
end;

constructor TCTCatalog.Create(const ADatabasePath: string);
begin
  inherited Create;
  FDatabasePath := ADatabasePath;
  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.Database := FConnection;
end;

destructor TCTCatalog.Destroy;
begin
  if FTransaction.Active then FTransaction.Rollback;
  if FConnection.Connected then FConnection.Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

function TCTCatalog.EnsureConnected: TCEAResult;
begin
  if FDatabasePath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_database_path_required', '{}'));
  try
    if not FConnection.Connected then
    begin
      FConnection.DatabaseName := FDatabasePath;
      FConnection.Open;
    end;
    Result := TCEAResult.Ok('{}');
  except
    Result := TCEAResult.Error(rcInternalError,
      'ct_database_open_failed', '{}');
  end;
end;

function TCTCatalog.ColumnExists(const ATableName,
  AColumnName: string): Boolean;
var
  Query: TSQLQuery;
begin
  Result := False;
  Query := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'PRAGMA table_info(' + ATableName + ')';
    Query.Open;
    while not Query.EOF do
    begin
      if SameText(Query.FieldByName('name').AsString, AColumnName) then
        Exit(True);
      Query.Next;
    end;
  finally
    Query.Free;
  end;
end;

function TCTCatalog.Initialize: TCEAResult;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  try
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS ct_artifacts (' +
      'artifact_id TEXT PRIMARY KEY, content_hash TEXT NOT NULL UNIQUE, ' +
      'source_uri TEXT NOT NULL, parser_version TEXT NOT NULL, ' +
      'table_version TEXT NOT NULL, game_name TEXT NOT NULL, ' +
      'game_version TEXT NOT NULL, ' +
      'license_spdx TEXT NOT NULL DEFAULT ''NOASSERTION'', ' +
      'license_uri TEXT NOT NULL DEFAULT '''', ' +
      'license_status TEXT NOT NULL DEFAULT ''unknown'')');
    if not ColumnExists('ct_artifacts', 'license_spdx') then
      FConnection.ExecuteDirect('ALTER TABLE ct_artifacts ADD COLUMN ' +
        'license_spdx TEXT NOT NULL DEFAULT ''NOASSERTION''');
    if not ColumnExists('ct_artifacts', 'license_uri') then
      FConnection.ExecuteDirect('ALTER TABLE ct_artifacts ADD COLUMN ' +
        'license_uri TEXT NOT NULL DEFAULT ''''');
    if not ColumnExists('ct_artifacts', 'license_status') then
      FConnection.ExecuteDirect('ALTER TABLE ct_artifacts ADD COLUMN ' +
        'license_status TEXT NOT NULL DEFAULT ''unknown''');
    FConnection.ExecuteDirect(
      'CREATE TABLE IF NOT EXISTS ct_entries (' +
      'entry_key TEXT PRIMARY KEY, artifact_id TEXT NOT NULL ' +
      'REFERENCES ct_artifacts(artifact_id), ordinal_no INTEGER NOT NULL, ' +
      'entry_id TEXT NOT NULL, parent_entry_id TEXT NOT NULL, ' +
      'description TEXT NOT NULL, variable_type TEXT NOT NULL, ' +
      'address_expression TEXT NOT NULL, module_name TEXT NOT NULL, ' +
      'pointer_offsets_json TEXT NOT NULL, aob_patterns_json TEXT NOT NULL, ' +
      'autoassembler_text TEXT NOT NULL, lua_text TEXT NOT NULL, ' +
      'risk_flags TEXT NOT NULL)');
    FConnection.ExecuteDirect(
      'CREATE INDEX IF NOT EXISTS ct_entries_artifact ' +
      'ON ct_entries(artifact_id)');
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"initialized":true}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError,
      'ct_catalog_initialize_failed', '{}');
  end;
end;

function TCTCatalog.ImportArtifact(
  const ARequest: TCTImportRequest): TCEAResult;
begin
  Result := TCEAResult.Error(rcInvalidArgument,
    'ct_parsed_artifact_required',
    '{"source_id":"' + ARequest.SourceId + '"}');
end;

function TCTCatalog.ImportParsedArtifact(
  const AArtifact: TCTArtifact): TCEAResult;
var
  Query, EntryQuery: TSQLQuery;
  ArtifactId, EntryKey: string;
  I: Integer;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  if (AArtifact.ContentHash = '') or (AArtifact.SourceUri = '') or
     (AArtifact.ParserVersion = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_artifact_invalid', '{}'));
  ArtifactId := 'ct-' + Copy(AArtifact.ContentHash, 8, 32);
  Query := TSQLQuery.Create(nil);
  EntryQuery := TSQLQuery.Create(nil);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT artifact_id FROM ct_artifacts ' +
      'WHERE content_hash=:content_hash';
    Query.Params.ParamByName('content_hash').AsString := AArtifact.ContentHash;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if not Query.EOF then
    begin
      ArtifactId := Query.FieldByName('artifact_id').AsString;
      Query.Close;
      FTransaction.Commit;
      Exit(TCEAResult.Ok('{"artifact_id":"' + ArtifactId +
        '","deduplicated":true}'));
    end;
    Query.Close;
    FTransaction.Commit;

    Query.SQL.Text := 'INSERT INTO ct_artifacts ' +
      '(artifact_id, content_hash, source_uri, parser_version, ' +
      'table_version, game_name, game_version, license_spdx, license_uri, ' +
      'license_status) VALUES ' +
      '(:artifact_id, :content_hash, :source_uri, :parser_version, ' +
      ':table_version, :game_name, :game_version, :license_spdx, ' +
      ':license_uri, :license_status)';
    Query.Params.ParamByName('artifact_id').AsString := ArtifactId;
    Query.Params.ParamByName('content_hash').AsString := AArtifact.ContentHash;
    Query.Params.ParamByName('source_uri').AsString := AArtifact.SourceUri;
    Query.Params.ParamByName('parser_version').AsString := AArtifact.ParserVersion;
    Query.Params.ParamByName('table_version').AsString := AArtifact.TableVersion;
    Query.Params.ParamByName('game_name').AsString := AArtifact.GameName;
    Query.Params.ParamByName('game_version').AsString := AArtifact.GameVersion;
    Query.Params.ParamByName('license_spdx').AsString := AArtifact.LicenseSpdx;
    Query.Params.ParamByName('license_uri').AsString := AArtifact.LicenseUri;
    Query.Params.ParamByName('license_status').AsString :=
      AArtifact.LicenseStatus;

    EntryQuery.Database := FConnection;
    EntryQuery.Transaction := FTransaction;
    EntryQuery.SQL.Text := 'INSERT INTO ct_entries ' +
      '(entry_key, artifact_id, ordinal_no, entry_id, parent_entry_id, ' +
      'description, variable_type, address_expression, module_name, ' +
      'pointer_offsets_json, aob_patterns_json, autoassembler_text, ' +
      'lua_text, risk_flags) VALUES (:entry_key, :artifact_id, :ordinal_no, ' +
      ':entry_id, :parent_entry_id, :description, :variable_type, ' +
      ':address_expression, :module_name, :pointer_offsets_json, ' +
      ':aob_patterns_json, :autoassembler_text, :lua_text, :risk_flags)';
    FTransaction.StartTransaction;
    Query.ExecSQL;
    for I := 0 to High(AArtifact.Entries) do
    begin
      EntryKey := ArtifactId + ':' + IntToStr(I);
      EntryQuery.Params.ParamByName('entry_key').AsString := EntryKey;
      EntryQuery.Params.ParamByName('artifact_id').AsString := ArtifactId;
      EntryQuery.Params.ParamByName('ordinal_no').AsInteger := I;
      EntryQuery.Params.ParamByName('entry_id').AsString :=
        AArtifact.Entries[I].EntryId;
      EntryQuery.Params.ParamByName('parent_entry_id').AsString :=
        AArtifact.Entries[I].ParentEntryId;
      EntryQuery.Params.ParamByName('description').AsString :=
        AArtifact.Entries[I].Description;
      EntryQuery.Params.ParamByName('variable_type').AsString :=
        AArtifact.Entries[I].VariableType;
      EntryQuery.Params.ParamByName('address_expression').AsString :=
        AArtifact.Entries[I].AddressExpression;
      EntryQuery.Params.ParamByName('module_name').AsString :=
        AArtifact.Entries[I].ModuleName;
      EntryQuery.Params.ParamByName('pointer_offsets_json').AsString :=
        StringsJson(AArtifact.Entries[I].PointerOffsets);
      EntryQuery.Params.ParamByName('aob_patterns_json').AsString :=
        StringsJson(AArtifact.Entries[I].AobPatterns);
      EntryQuery.Params.ParamByName('autoassembler_text').AsString :=
        AArtifact.Entries[I].AutoAssemblerText;
      EntryQuery.Params.ParamByName('lua_text').AsString :=
        AArtifact.Entries[I].LuaText;
      EntryQuery.Params.ParamByName('risk_flags').AsString :=
        AArtifact.Entries[I].RiskFlags;
      EntryQuery.ExecSQL;
    end;
    FTransaction.Commit;
    Result := TCEAResult.Ok('{"artifact_id":"' + ArtifactId +
      '","entry_count":' + IntToStr(Length(AArtifact.Entries)) + '}');
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcUnknownOutcome, 'ct_import_failed', '{}');
  end;
  EntryQuery.Free;
  Query.Free;
end;

function TCTCatalog.SearchText(const AText: string;
  const AMaxResults: Cardinal): TCEAResult;
var
  Query: TSQLQuery;
  Results: TJSONArray;
  ItemObject: TJSONObject;
  RootObject: TJSONObject;
  Hits: TCTSearchHits;
  QueryText, MatchType: string;
  Limit: Cardinal;
  HitCount, I, J: Integer;
  Swap: TCTSearchHit;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  if Trim(AText) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ct_query_required', '{}'));
  Limit := AMaxResults;
  if Limit = 0 then Limit := 10;
  if Limit > 100 then Limit := 100;
  Query := TSQLQuery.Create(nil);
  Results := TJSONArray.Create;
  SetLength(Hits, 0);
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT a.*, e.* FROM ct_entries e JOIN ct_artifacts a ' +
      'ON a.artifact_id=e.artifact_id ORDER BY a.game_name, e.ordinal_no ' +
      'LIMIT 10000';
    QueryText := NormalizedSearchText(AText);
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    while not Query.EOF do
    begin
      HitCount := BestSearchScore(QueryText, [
        Query.FieldByName('game_name').AsString,
        Query.FieldByName('description').AsString,
        Query.FieldByName('module_name').AsString,
        Query.FieldByName('address_expression').AsString,
        Query.FieldByName('autoassembler_text').AsString], MatchType);
      if HitCount = 0 then
      begin
        Query.Next;
        Continue;
      end;
      ItemObject := TJSONObject.Create;
      ItemObject.Add('entry_key', Query.FieldByName('entry_key').AsString);
      ItemObject.Add('game_name', Query.FieldByName('game_name').AsString);
      ItemObject.Add('game_version', Query.FieldByName('game_version').AsString);
      ItemObject.Add('description', Query.FieldByName('description').AsString);
      ItemObject.Add('module', Query.FieldByName('module_name').AsString);
      ItemObject.Add('address_expression',
        Query.FieldByName('address_expression').AsString);
      ItemObject.Add('pointer_offsets', GetJSON(
        Query.FieldByName('pointer_offsets_json').AsString));
      ItemObject.Add('aob_patterns', GetJSON(
        Query.FieldByName('aob_patterns_json').AsString));
      ItemObject.Add('autoassembler_text',
        Query.FieldByName('autoassembler_text').AsString);
      ItemObject.Add('lua_text', Query.FieldByName('lua_text').AsString);
      ItemObject.Add('risk_flags', Query.FieldByName('risk_flags').AsString);
      ItemObject.Add('source_uri', Query.FieldByName('source_uri').AsString);
      ItemObject.Add('content_hash', Query.FieldByName('content_hash').AsString);
      ItemObject.Add('parser_version', Query.FieldByName('parser_version').AsString);
      ItemObject.Add('license_spdx', Query.FieldByName('license_spdx').AsString);
      ItemObject.Add('license_uri', Query.FieldByName('license_uri').AsString);
      ItemObject.Add('license_status',
        Query.FieldByName('license_status').AsString);
      ItemObject.Add('authority', 'none');
      I := Length(Hits);
      SetLength(Hits, I + 1);
      Hits[I].Item := ItemObject;
      Hits[I].Score := HitCount;
      Hits[I].MatchType := MatchType;
      Query.Next;
    end;
    Query.Close;
    FTransaction.Commit;
    for I := 0 to High(Hits) - 1 do
      for J := I + 1 to High(Hits) do
        if Hits[J].Score > Hits[I].Score then
        begin
          Swap := Hits[I];
          Hits[I] := Hits[J];
          Hits[J] := Swap;
        end;
    HitCount := Length(Hits);
    if HitCount > Integer(Limit) then HitCount := Limit;
    for I := 0 to HitCount - 1 do
    begin
      Hits[I].Item.Add('retrieval_score', Hits[I].Score);
      Hits[I].Item.Add('match_type', Hits[I].MatchType);
      Results.Add(Hits[I].Item);
      Hits[I].Item := nil;
    end;
    RootObject := TJSONObject.Create;
    RootObject.Add('retrieval_method',
      'gcm_style_exact_prefix_substring_acronym_pinyin_lightweight_vector_fuzzy');
    RootObject.Add('pinyin_lexicon_version', 'cheat-terms-zh-v1');
    RootObject.Add('vector_model', 'deterministic_pinyin_token_set_v1');
    RootObject.Add('external_embedding', False);
    RootObject.Add('results', Results);
    Results := nil;
    Result := TCEAResult.Ok(RootObject.AsJSON);
    RootObject.Free;
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ct_search_failed', '{}');
  end;
  for I := 0 to High(Hits) do Hits[I].Item.Free;
  Results.Free;
  Query.Free;
end;

function TCTCatalog.GetEntry(const AEntryKey: string): TCEAResult;
var
  Query: TSQLQuery;
  ItemObject: TJSONObject;
begin
  Result := EnsureConnected;
  if Result.Failed then Exit;
  if Trim(AEntryKey) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ct_entry_key_required', '{}'));
  Query := TSQLQuery.Create(nil);
  ItemObject := nil;
  try
    Query.Database := FConnection;
    Query.Transaction := FTransaction;
    Query.SQL.Text := 'SELECT a.*, e.* FROM ct_entries e ' +
      'JOIN ct_artifacts a ON a.artifact_id=e.artifact_id ' +
      'WHERE e.entry_key=:entry_key LIMIT 1';
    Query.Params.ParamByName('entry_key').AsString := AEntryKey;
    if FTransaction.Active then FTransaction.Rollback;
    FTransaction.StartTransaction;
    Query.Open;
    if Query.EOF then
    begin
      Query.Close;
      FTransaction.Commit;
      Exit(TCEAResult.Error(rcInvalidArgument, 'ct_entry_not_found', '{}'));
    end;
    ItemObject := TJSONObject.Create;
    ItemObject.Add('entry_key', Query.FieldByName('entry_key').AsString);
    ItemObject.Add('game_name', Query.FieldByName('game_name').AsString);
    ItemObject.Add('game_version', Query.FieldByName('game_version').AsString);
    ItemObject.Add('description', Query.FieldByName('description').AsString);
    ItemObject.Add('module', Query.FieldByName('module_name').AsString);
    ItemObject.Add('address_expression',
      Query.FieldByName('address_expression').AsString);
    ItemObject.Add('pointer_offsets', GetJSON(
      Query.FieldByName('pointer_offsets_json').AsString));
    ItemObject.Add('aob_patterns', GetJSON(
      Query.FieldByName('aob_patterns_json').AsString));
    ItemObject.Add('autoassembler_text',
      Query.FieldByName('autoassembler_text').AsString);
    ItemObject.Add('lua_text', Query.FieldByName('lua_text').AsString);
    ItemObject.Add('risk_flags', Query.FieldByName('risk_flags').AsString);
    ItemObject.Add('source_uri', Query.FieldByName('source_uri').AsString);
    ItemObject.Add('content_hash', Query.FieldByName('content_hash').AsString);
    ItemObject.Add('parser_version', Query.FieldByName('parser_version').AsString);
    ItemObject.Add('license_spdx', Query.FieldByName('license_spdx').AsString);
    ItemObject.Add('license_uri', Query.FieldByName('license_uri').AsString);
    ItemObject.Add('license_status',
      Query.FieldByName('license_status').AsString);
    ItemObject.Add('authority', 'none');
    Result := TCEAResult.Ok(ItemObject.AsJSON);
    Query.Close;
    FTransaction.Commit;
  except
    if FTransaction.Active then FTransaction.Rollback;
    Result := TCEAResult.Error(rcInternalError, 'ct_entry_read_failed', '{}');
  end;
  ItemObject.Free;
  Query.Free;
end;

function TCTCatalog.BuildRagContext(const AText: string;
  const AMaxResults: Cardinal): TCEAResult;
var
  SearchResult: TCEAResult;
begin
  SearchResult := SearchText(AText, AMaxResults);
  if SearchResult.Failed then Exit(SearchResult);
  Result := TCEAResult.Ok('{"authority":"none",' +
    '"training_allowed":false,"citations_manifest":' +
    SearchResult.DataJson + '}');
end;

end.
