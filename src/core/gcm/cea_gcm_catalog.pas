unit cea_gcm_catalog;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  SysUtils, Classes, FPJSON, JSONParser, cea_results, cea_gcm_types;

type
  // Read-only view over the Game-Cheats-Manager data files that already sit
  // in the user profile. Nothing is downloaded and nothing is executed: the
  // catalogue is untrusted observation data, so every lookup is advisory.
  TCEAGcmCatalog = class
  private
    FSettingsDirectory: string;
    FCheatTablePath: string;
    FTranslationsPath: string;
    FEntries: TCEACheatTableEntryArray;
    FTranslations: TCEAGameTranslationArray;
    FLoaded: Boolean;
    function LoadJsonArray(const APath: string; out AArray: TJSONArray;
      out AError: string): Boolean;
    procedure SortEntriesByName;
    function EntriesForNormalizedName(const ANormalizedName: UnicodeString;
      out AEntries: TCEACheatTableEntryArray): Boolean;
    function TranslateUnicode(const AEnName: UnicodeString;
      out AZhName: UnicodeString): Boolean;
  public
    constructor Create(const ASettingsDirectory: string = '');
    destructor Destroy; override;
    function Load: TCEAResult;
    function Reload: TCEAResult;
    function Loaded: Boolean;
    function SettingsDirectory: string;
    function CheatTablePath: string;
    function TranslationsPath: string;
    function EntryCount: Integer;
    function TranslationCount: Integer;
    // Deterministic process name -> game match. AMinScore filters weak
    // matches; a match below the threshold is reported as not matched
    // instead of being silently accepted.
    function MatchProcessName(const AProcessName: string;
      const AMinScore: Integer; out AMatch: TCEAGameMatchResult): TCEAResult;
    // Free text search over game names (English and Chinese), used by the UI.
    function SearchGames(const AText: string;
      const AMaxResults: Cardinal): TCEAResult;
    function TranslateGameName(const AEnName: string;
      out AZhName: UnicodeString): Boolean;
    function GetEntries(const AGameName: string;
      out AEntries: TCEACheatTableEntryArray): Boolean;
  end;

// %APPDATA%\GCM Settings, the directory GCM writes its data files into.
function DefaultGcmSettingsDirectory: string;

implementation

function DefaultGcmSettingsDirectory: string;
var
  AppData: string;
begin
  AppData := GetEnvironmentVariable('APPDATA');
  if AppData = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(AppData) + 'GCM Settings';
end;

function ReadUtf8File(const APath: string; out AContent: RawByteString;
  out AError: string): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  AContent := '';
  AError := '';
  if not FileExists(APath) then
  begin
    AError := 'file_not_found';
    Exit;
  end;
  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(AContent, Stream.Size);
      if Length(AContent) > 0 then
        Stream.ReadBuffer(AContent[1], Length(AContent));
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      AError := 'file_read_failed';
      Exit;
    end;
  end;
  // Mark the bytes as UTF-8 before handing them to the JSON parser. Without
  // this the parser keeps the system code page (GBK on this host) and every
  // Chinese game name comes back as mojibake.
  SetCodePage(AContent, CP_UTF8, False);
  Result := True;
end;

constructor TCEAGcmCatalog.Create(const ASettingsDirectory: string);
begin
  inherited Create;
  if ASettingsDirectory <> '' then
    FSettingsDirectory := ExcludeTrailingPathDelimiter(ASettingsDirectory)
  else
    FSettingsDirectory := DefaultGcmSettingsDirectory;
  if FSettingsDirectory <> '' then
  begin
    FCheatTablePath := IncludeTrailingPathDelimiter(FSettingsDirectory) +
      'db' + PathDelim + 'cheat_table.json';
    FTranslationsPath := IncludeTrailingPathDelimiter(FSettingsDirectory) +
      'db' + PathDelim + 'translations.json';
  end;
  FEntries := nil;
  FTranslations := nil;
  FLoaded := False;
end;

destructor TCEAGcmCatalog.Destroy;
begin
  FEntries := nil;
  FTranslations := nil;
  inherited Destroy;
end;

function TCEAGcmCatalog.SettingsDirectory: string;
begin
  Result := FSettingsDirectory;
end;

function TCEAGcmCatalog.CheatTablePath: string;
begin
  Result := FCheatTablePath;
end;

function TCEAGcmCatalog.TranslationsPath: string;
begin
  Result := FTranslationsPath;
end;

function TCEAGcmCatalog.Loaded: Boolean;
begin
  Result := FLoaded;
end;

function TCEAGcmCatalog.EntryCount: Integer;
begin
  Result := Length(FEntries);
end;

function TCEAGcmCatalog.TranslationCount: Integer;
begin
  Result := Length(FTranslations);
end;

function TCEAGcmCatalog.LoadJsonArray(const APath: string;
  out AArray: TJSONArray; out AError: string): Boolean;
var
  Content: RawByteString;
  Data: TJSONData;
begin
  Result := False;
  AArray := nil;
  AError := '';
  if not ReadUtf8File(APath, Content, AError) then
    Exit;
  try
    Data := GetJSON(Content);
  except
    on E: Exception do
    begin
      AError := 'json_parse_failed';
      Exit;
    end;
  end;
  if not (Data is TJSONArray) then
  begin
    Data.Free;
    AError := 'json_array_required';
    Exit;
  end;
  AArray := TJSONArray(Data);
  Result := True;
end;

procedure TCEAGcmCatalog.SortEntriesByName;
var
  I, J: Integer;
  Temp: TCEACheatTableEntry;
begin
  // Insertion sort keeps the comparison deterministic without pulling in
  // Classes' generic list helpers; catalogues are a few thousand rows.
  for I := 1 to High(FEntries) do
  begin
    Temp := FEntries[I];
    J := I - 1;
    while (J >= 0) and
          (CompareText(string(FEntries[J].GameName), string(Temp.GameName)) > 0) do
    begin
      FEntries[J + 1] := FEntries[J];
      Dec(J);
    end;
    FEntries[J + 1] := Temp;
  end;
end;

function TCEAGcmCatalog.Load: TCEAResult;
var
  TableArray, TransArray: TJSONArray;
  Error: string;
  I: Integer;
  Obj: TJSONObject;
  Entry: TCEACheatTableEntry;
  Translation: TCEAGameTranslation;
  SteamValue: TJSONData;
  LoadedEntries, LoadedTranslations: Integer;
begin
  if FSettingsDirectory = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'gcm_settings_directory_unavailable', '{}'));
  FEntries := nil;
  FTranslations := nil;
  LoadedEntries := 0;
  LoadedTranslations := 0;

  if LoadJsonArray(FCheatTablePath, TableArray, Error) then
  try
    SetLength(FEntries, TableArray.Count);
    for I := 0 to TableArray.Count - 1 do
    begin
      if not (TableArray.Items[I] is TJSONObject) then
        Continue;
      Obj := TJSONObject(TableArray.Items[I]);
      Entry.GameName := Obj.Get('game_name', '');
      Entry.Origin := Obj.Get('origin', '');
      Entry.OfficialUrl := Obj.Get('official_url', '');
      Entry.GcmUrl := Obj.Get('gcm_url', '');
      Entry.Version := Obj.Get('version', '');
      if not Entry.IsValid then
        Continue;
      FEntries[LoadedEntries] := Entry;
      Inc(LoadedEntries);
    end;
  finally
    TableArray.Free;
  end
  else
    Exit(TCEAResult.Error(rcUnknown, 'gcm_cheat_table_unavailable',
      '{"reason":"' + Error + '","path":"' +
      StringReplace(FCheatTablePath, '\', '\\', [rfReplaceAll]) + '"}'));

  SetLength(FEntries, LoadedEntries);
  SortEntriesByName;

  if LoadJsonArray(FTranslationsPath, TransArray, Error) then
  try
    SetLength(FTranslations, TransArray.Count);
    for I := 0 to TransArray.Count - 1 do
    begin
      if not (TransArray.Items[I] is TJSONObject) then
        Continue;
      Obj := TJSONObject(TransArray.Items[I]);
      Translation.EnUs := Obj.Get('en_US', '');
      Translation.ZhCn := Obj.Get('zh_CN', '');
      Translation.SteamId := 0;
      Translation.HasSteamId := False;
      SteamValue := Obj.Find('steam_id');
      if (SteamValue <> nil) and (SteamValue.JSONType = jtNumber) then
      begin
        Translation.SteamId := QWord(SteamValue.AsInt64);
        Translation.HasSteamId := True;
      end;
      if not Translation.IsValid then
        Continue;
      FTranslations[LoadedTranslations] := Translation;
      Inc(LoadedTranslations);
    end;
  finally
    TransArray.Free;
  end
  else
  begin
    // The translation table is optional: without it the catalogue still
    // works, game names simply stay in their original language.
    FTranslations := nil;
    LoadedTranslations := 0;
  end;
  SetLength(FTranslations, LoadedTranslations);

  FLoaded := True;
  Result := TCEAResult.Ok('{"entries":' + IntToStr(Length(FEntries)) +
    ',"translations":' + IntToStr(Length(FTranslations)) + '}');
end;

function TCEAGcmCatalog.Reload: TCEAResult;
begin
  Result := Load;
end;

function TCEAGcmCatalog.EntriesForNormalizedName(
  const ANormalizedName: UnicodeString;
  out AEntries: TCEACheatTableEntryArray): Boolean;
var
  I, Count: Integer;
begin
  AEntries := nil;
  Count := 0;
  SetLength(AEntries, Length(FEntries));
  for I := 0 to High(FEntries) do
    if NormalizeGameName(FEntries[I].GameName) = ANormalizedName then
    begin
      AEntries[Count] := FEntries[I];
      Inc(Count);
    end;
  SetLength(AEntries, Count);
  Result := Count > 0;
end;

function TCEAGcmCatalog.GetEntries(const AGameName: string;
  out AEntries: TCEACheatTableEntryArray): Boolean;
begin
  AEntries := nil;
  if AGameName = '' then
    Exit(False);
  Result := EntriesForNormalizedName(NormalizeGameName(AGameName), AEntries);
end;

function TCEAGcmCatalog.TranslateUnicode(const AEnName: UnicodeString;
  out AZhName: UnicodeString): Boolean;
var
  I: Integer;
  Key: UnicodeString;
begin
  AZhName := '';
  Key := CompactNameKey(AEnName);
  if Key = '' then
    Exit(False);
  for I := 0 to High(FTranslations) do
    if CompactNameKey(FTranslations[I].EnUs) = Key then
    begin
      AZhName := FTranslations[I].ZhCn;
      Exit(True);
    end;
  Result := False;
end;

function TCEAGcmCatalog.TranslateGameName(const AEnName: string;
  out AZhName: UnicodeString): Boolean;
begin
  Result := TranslateUnicode(AEnName, AZhName);
end;

function TCEAGcmCatalog.MatchProcessName(const AProcessName: string;
  const AMinScore: Integer; out AMatch: TCEAGameMatchResult): TCEAResult;
var
  Query: UnicodeString;
  I, Score, BestScore, BestIndex: Integer;
begin
  FillChar(AMatch, SizeOf(AMatch), 0);
  AMatch.Entries := nil;
  if not FLoaded then
    Exit(TCEAResult.Error(rcInvalidArgument, 'gcm_catalog_not_loaded', '{}'));
  Query := NormalizeProcessName(AProcessName);
  if Query = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'gcm_process_name_required', '{}'));

  BestScore := 0;
  BestIndex := -1;
  for I := 0 to High(FEntries) do
  begin
    Score := ScoreNormalizedNameMatch(Query,
      NormalizeGameName(FEntries[I].GameName));
    if Score > BestScore then
    begin
      BestScore := Score;
      BestIndex := I;
    end;
  end;

  if (BestIndex < 0) or (BestScore < AMinScore) then
    Exit(TCEAResult.Ok(Utf8JsonText(
      UTF8String('{"matched":false,"query":"') +
      JsonEscapeUnicode(Query) + UTF8String('","best_score":') +
      UTF8String(IntToStr(BestScore)) + UTF8String('}'))));

  AMatch.Matched := True;
  AMatch.EnName := FEntries[BestIndex].GameName;
  AMatch.MatchScore := BestScore;
  EntriesForNormalizedName(NormalizeGameName(AMatch.EnName), AMatch.Entries);

  AMatch.ZhName := '';
  AMatch.SteamId := 0;
  AMatch.HasSteamId := False;
  TranslateUnicode(AMatch.EnName, AMatch.ZhName);
  for I := 0 to High(FTranslations) do
    if CompactNameKey(FTranslations[I].EnUs) =
       CompactNameKey(AMatch.EnName) then
    begin
      AMatch.SteamId := FTranslations[I].SteamId;
      AMatch.HasSteamId := FTranslations[I].HasSteamId;
      Break;
    end;
  if (AMatch.ZhName = '') and (AMatch.HasSteamId) then
    for I := 0 to High(FTranslations) do
      if FTranslations[I].HasSteamId and
         (FTranslations[I].SteamId = AMatch.SteamId) then
      begin
        AMatch.ZhName := FTranslations[I].ZhCn;
        Break;
      end;

  Result := TCEAResult.Ok(Utf8JsonText(
    UTF8String('{"matched":true,"game_name":"') +
    JsonEscapeUnicode(AMatch.EnName) + UTF8String('","zh_name":"') +
    JsonEscapeUnicode(AMatch.ZhName) + UTF8String('","score":') +
    UTF8String(IntToStr(AMatch.MatchScore)) + UTF8String(',"entries":') +
    UTF8String(IntToStr(Length(AMatch.Entries))) + UTF8String('}')));
end;

function TCEAGcmCatalog.SearchGames(const AText: string;
  const AMaxResults: Cardinal): TCEAResult;
var
  Query, ZhName, Key: UnicodeString;
  Json, ItemJson: UTF8String;
  I, Count, Score, Limit: Integer;
  Seen: TStringList;
begin
  if not FLoaded then
    Exit(TCEAResult.Error(rcInvalidArgument, 'gcm_catalog_not_loaded', '{}'));
  Query := NormalizeGameName(AText);
  if Query = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'gcm_search_text_required', '{}'));
  Limit := AMaxResults;
  if (Limit <= 0) or (Limit > 200) then
    Limit := 20;

  Json := '';
  Count := 0;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    for I := 0 to High(FEntries) do
    begin
      if Count >= Limit then
        Break;
      Score := ScoreNormalizedNameMatch(Query,
        NormalizeGameName(FEntries[I].GameName));
      if Score < 40 then
        Continue;
      Key := CompactNameKey(FEntries[I].GameName);
      if Seen.IndexOf(string(Key)) >= 0 then
        Continue;
      Seen.Add(string(Key));
      ZhName := '';
      TranslateUnicode(FEntries[I].GameName, ZhName);
      // Assembled as UTF8String on purpose: routing the fields through
      // UnicodeString and back would transcode them to the system code page.
      ItemJson := UTF8String('{"game_name":"') +
        JsonEscapeUnicode(FEntries[I].GameName) +
        UTF8String('","zh_name":"') + JsonEscapeUnicode(ZhName) +
        UTF8String('","version":"') +
        JsonEscapeUnicode(FEntries[I].Version) +
        UTF8String('","origin":"') +
        JsonEscapeUnicode(FEntries[I].Origin) +
        UTF8String('","gcm_url":"') +
        JsonEscapeUnicode(FEntries[I].GcmUrl) +
        UTF8String('","score":') + UTF8String(IntToStr(Score)) +
        UTF8String('}');
      if Json <> '' then
        Json := Json + ',';
      Json := Json + ItemJson;
      Inc(Count);
    end;
  finally
    Seen.Free;
  end;
  Result := TCEAResult.Ok(Utf8JsonText(
    UTF8String('{"count":') + UTF8String(IntToStr(Count)) +
    UTF8String(',"results":[') + Json + UTF8String(']}')));
end;

end.
