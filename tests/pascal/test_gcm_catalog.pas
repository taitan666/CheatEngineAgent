program test_gcm_catalog;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, FPJSON, JSONParser, cea_results, cea_gcm_types,
  cea_gcm_catalog;

var
  TempDir: string;
  DbDir: string;
  Catalog: TCEAGcmCatalog;
  R: TCEAResult;
  Match: TCEAGameMatchResult;
  Entries: TCEACheatTableEntryArray;
  Zh: UnicodeString;

procedure WriteUtf8File(const APath, AContent: string);
var
  Stream: TFileStream;
  Bytes: RawByteString;
begin
  Bytes := AContent;
  Stream := TFileStream.Create(APath, fmCreate);
  try
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    Stream.Free;
  end;
end;

// Decodes the JSON produced by the catalogue and returns the first result's
// zh_name, so the assertion checks the value rather than its wire encoding.
function FirstResultZhName(const AJson: string): string;
var
  Data: TJSONData;
  Obj, First: TJSONObject;
  Arr: TJSONArray;
begin
  Result := '';
  Data := GetJSON(AJson);
  try
    Obj := TJSONObject(Data);
    Arr := Obj.Arrays['results'];
    if (Arr = nil) or (Arr.Count = 0) then
      Exit;
    First := TJSONObject(Arr.Items[0]);
    Result := First.Get('zh_name', '');
  finally
    Data.Free;
  end;
end;

// Same idea for the single-object payload returned by MatchProcessName.
function MatchZhName(const AJson: string): string;
var
  Data: TJSONData;
begin
  Result := '';
  Data := GetJSON(AJson);
  try
    Result := TJSONObject(Data).Get('zh_name', '');
  finally
    Data.Free;
  end;
end;

begin
  TempDir := IncludeTrailingPathDelimiter(GetTempDir) + 'cea-gcm-test-' +
    IntToStr(GetProcessID);
  DbDir := IncludeTrailingPathDelimiter(TempDir) + 'db';
  if not DirectoryExists(DbDir) then
    ForceDirectories(DbDir);

  WriteUtf8File(IncludeTrailingPathDelimiter(DbDir) + 'cheat_table.json',
    '[{"game_name":"Hollow Knight","origin":"Steam",' +
    '"official_url":"https://example.invalid/hk",' +
    '"gcm_url":"https://example.invalid/hk.CT","version":"1.5.78"},' +
    '{"game_name":"Stardew Valley","origin":"Steam",' +
    '"official_url":"https://example.invalid/sdv",' +
    '"gcm_url":"https://example.invalid/sdv.CT","version":"1.6"},' +
    '{"game_name":"","origin":"broken","gcm_url":""}]');
  WriteUtf8File(IncludeTrailingPathDelimiter(DbDir) + 'translations.json',
    '[{"en_US":"Hollow Knight","zh_CN":"空洞骑士","steam_id":367520},' +
    '{"en_US":"Stardew Valley","zh_CN":"星露谷物语","steam_id":413150}]');

  Catalog := TCEAGcmCatalog.Create(TempDir);
  try
    Assert(Catalog.SettingsDirectory = ExcludeTrailingPathDelimiter(TempDir),
      'settings directory kept');
    Assert(not Catalog.Loaded, 'catalog starts unloaded');

    R := Catalog.Load;
    Assert(R.Code = rcOk, 'catalog loads: ' + R.StableCode);
    Assert(Catalog.Loaded, 'catalog reports loaded');
    Assert(Catalog.EntryCount = 2, 'invalid row dropped, two entries kept');
    Assert(Catalog.TranslationCount = 2, 'two translations loaded');

    // Process name matching is deterministic and normalises separators.
    R := Catalog.MatchProcessName('hollow_knight.exe', 40, Match);
    Assert(R.Code = rcOk, 'process match succeeds: ' + R.StableCode);
    Assert(Match.Matched, 'hollow_knight.exe matches a catalogue game');
    Assert(Match.EnName = 'Hollow Knight', 'matched english name');
    Assert(Match.ZhName = '空洞骑士', 'matched chinese name');
    Assert(Match.MatchScore >= 90, 'exact match scores high');
    Assert(Match.HasSteamId and (Match.SteamId = 367520), 'steam id carried');
    Assert(Match.HasEntries, 'matched game carries cheat table entries');
    Assert(Length(Match.Entries) = 1, 'one cheat table entry for hollow knight');
    Assert(Match.Entries[0].Version = '1.5.78', 'entry version preserved');

    // The payload carries the Chinese name as raw UTF-8, so it must decode
    // back to the same value through the generic JSON reader.
    Assert(MatchZhName(R.DataJson) = '空洞骑士',
      'match result carries chinese name');

    // A weak match must stay rejected rather than silently accepted.
    R := Catalog.MatchProcessName('totally-unrelated-tool.exe', 40, Match);
    Assert(R.Code = rcOk, 'non matching process still returns ok');
    Assert(not Match.Matched, 'unrelated process does not match');

    // The score threshold is caller controlled.
    R := Catalog.MatchProcessName('hollow', 100, Match);
    Assert(R.Code = rcOk, 'threshold query ok');
    Assert(not Match.Matched, 'score below threshold is not accepted');

    // Free text search over game names.
    R := Catalog.SearchGames('stardew', 10);
    Assert(R.Code = rcOk, 'search succeeds: ' + R.StableCode);
    Assert(Pos('"count":1', R.DataJson) > 0, 'search finds one game: ' + R.DataJson);
    Assert(FirstResultZhName(R.DataJson) = '星露谷物语',
      'search result carries chinese name');

    R := Catalog.SearchGames('', 10);
    Assert(R.Code = rcInvalidArgument, 'empty search text rejected');
    Assert(R.StableCode = 'gcm_search_text_required', 'empty search stable code');

    // Entry lookup by game name.
    Assert(Catalog.GetEntries('Hollow Knight', Entries), 'entries by game name');
    Assert(Length(Entries) = 1, 'one entry by game name');
    Assert(not Catalog.GetEntries('No Such Game', Entries),
      'unknown game has no entries');

    // Translation lookup.
    Assert(Catalog.TranslateGameName('Stardew Valley', Zh), 'translation found');
    Assert(Zh = '星露谷物语', 'translation text matches');
    Assert(not Catalog.TranslateGameName('No Such Game', Zh),
      'unknown translation');

    R := Catalog.Reload;
    Assert(R.Code = rcOk, 'reload succeeds');

    FreeAndNil(Catalog);
    Catalog := TCEAGcmCatalog.Create(IncludeTrailingPathDelimiter(TempDir) +
      'missing');
    try
      R := Catalog.Load;
      Assert(R.Code = rcUnknown, 'missing catalogue is an error');
      Assert(R.StableCode = 'gcm_cheat_table_unavailable',
        'missing catalogue stable code');
      R := Catalog.MatchProcessName('hollow_knight.exe', 40, Match);
      Assert(R.Code = rcInvalidArgument, 'match requires loaded catalogue');
      Assert(R.StableCode = 'gcm_catalog_not_loaded', 'not loaded stable code');
    finally
      Catalog.Free;
    end;

    WriteLn('GCM_CATALOG=PASS');
  except
    on E: Exception do
    begin
      Catalog.Free;
      WriteLn('GCM_CATALOG=FAIL ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
