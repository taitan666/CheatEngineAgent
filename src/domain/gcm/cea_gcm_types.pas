unit cea_gcm_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage utf8}

interface

uses
  SysUtils;

type
  // One row of the GCM cheat table catalogue (cheat_table.json).
  // Text fields are UnicodeString on purpose: the source JSON is UTF-8 and
  // some units in this project do not declare {$codepage utf8}, so keeping
  // the text in UTF-16 avoids the lossy AnsiString round trip.
  TCEACheatTableEntry = record
    GameName: UnicodeString;
    Origin: UnicodeString;
    OfficialUrl: UnicodeString;
    GcmUrl: UnicodeString;
    Version: UnicodeString;
    function IsValid: Boolean;
  end;

  TCEACheatTableEntryArray = array of TCEACheatTableEntry;

  // One row of the GCM game name translation table (translations.json).
  TCEAGameTranslation = record
    EnUs: UnicodeString;
    ZhCn: UnicodeString;
    SteamId: QWord;
    HasSteamId: Boolean;
    function IsValid: Boolean;
    function DisplayName: UnicodeString;
  end;

  TCEAGameTranslationArray = array of TCEAGameTranslation;

  // Result of matching a running process against the local GCM catalogue.
  // MatchScore is a deterministic similarity score; the caller decides the
  // acceptance threshold, so a weak match stays visible instead of being
  // silently dropped.
  TCEAGameMatchResult = record
    Matched: Boolean;
    EnName: UnicodeString;
    ZhName: UnicodeString;
    SteamId: QWord;
    HasSteamId: Boolean;
    MatchScore: Integer;
    Entries: TCEACheatTableEntryArray;
    function HasEntries: Boolean;
  end;

// Deterministic process name normalisation: drops the ".exe" suffix, lowers
// ASCII letters and turns separators into single spaces so that
// "Hollow_Knight.exe" and "hollow knight" compare equal. Everything is done
// on UTF-16 code units, so the result never depends on the host code page.
function NormalizeProcessName(const AValue: UnicodeString): UnicodeString;

// Same normalisation used for game names, plus removal of a trailing
// parenthesised decoration such as " (v1.2)".
function NormalizeGameName(const AValue: UnicodeString): UnicodeString;

// Compact form used for equality checks: every non alphanumeric character
// removed. "Hollow Knight" and "hollowknight" collapse to the same key.
function CompactNameKey(const AValue: UnicodeString): UnicodeString;

// Similarity score in [0..100] between two names; 100 means identical after
// normalisation. Used for process name to game name matching.
function ScoreNormalizedNameMatch(const AQuery, ACandidate: UnicodeString): Integer;

// Escapes a Unicode string into JSON string content: quote, backslash and
// control characters use the short escapes, every other code point is passed
// through as raw UTF-8.
//
// \uXXXX escapes are avoided deliberately. FPC 3.2.2's fpjson decoder
// (UnescapeJSONUnicode) corrupts any \uXXXX value above U+007F: the escape is
// rebuilt through a non-UTF-8 AnsiString, so "\u661f" comes back as two "?"
// bytes and "\u661f\u9732" comes back as valid UTF-8 followed by a "?". A
// payload produced with \uXXXX therefore cannot be read back by GetJSON, which
// every internal consumer of TCEAResult.DataJson uses. Emitting raw UTF-8
// keeps the payload round-trippable, and it matches what JsonEscapeText in
// cea_application_runtime.pas already does.
function JsonEscapeUnicode(const AValue: UnicodeString): UTF8String;

// Labels bytes that are already UTF-8 as UTF-8 without re-encoding them.
// Assigning a UTF8String straight into the project's AnsiString would transcode
// it to the system code page (GBK on this machine) and destroy the payload, so
// every JSON body built here must pass through this helper before it becomes a
// TCEAResult.DataJson value.
function Utf8JsonText(const AValue: UTF8String): string;

implementation

function AsciiLower(const AValue: UnicodeString): UnicodeString;
var
  I: Integer;
  W: WideChar;
begin
  SetLength(Result, Length(AValue));
  for I := 1 to Length(AValue) do
  begin
    W := AValue[I];
    if (W >= 'A') and (W <= 'Z') then
      W := WideChar(Ord(W) + 32);
    Result[I] := W;
  end;
end;

function IsAsciiAlnum(const W: WideChar): Boolean;
begin
  Result := ((W >= 'a') and (W <= 'z')) or ((W >= '0') and (W <= '9'));
end;

function IsNameChar(const W: WideChar): Boolean;
begin
  // Non-ASCII characters are kept verbatim: they are part of the name and
  // lower-casing them is not needed for a deterministic comparison.
  Result := IsAsciiAlnum(W) or (Ord(W) >= 128);
end;

function NormalizeProcessName(const AValue: UnicodeString): UnicodeString;
var
  I: Integer;
  W: WideChar;
  S: UnicodeString;
  LastWasSpace: Boolean;
begin
  S := AValue;
  // Trim without relying on the AnsiString Trim overloads.
  while (Length(S) > 0) and (S[1] <= ' ') do
    Delete(S, 1, 1);
  while (Length(S) > 0) and (S[Length(S)] <= ' ') do
    Delete(S, Length(S), 1);
  S := AsciiLower(S);
  if (Length(S) > 4) and
     (Copy(S, Length(S) - 3, 4) = UnicodeString('.exe')) then
  begin
    S := Copy(S, 1, Length(S) - 4);
    while (Length(S) > 0) and (S[Length(S)] <= ' ') do
      Delete(S, Length(S), 1);
  end;
  Result := '';
  LastWasSpace := True;
  for I := 1 to Length(S) do
  begin
    W := S[I];
    if IsNameChar(W) then
    begin
      Result := Result + W;
      LastWasSpace := False;
    end
    else if not LastWasSpace then
    begin
      Result := Result + ' ';
      LastWasSpace := True;
    end;
  end;
  while (Length(Result) > 0) and (Result[Length(Result)] = ' ') do
    Delete(Result, Length(Result), 1);
end;

function NormalizeGameName(const AValue: UnicodeString): UnicodeString;
var
  S: UnicodeString;
  P: Integer;
begin
  S := AValue;
  P := Pos(UnicodeString('('), S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  Result := NormalizeProcessName(S);
end;

function CompactNameKey(const AValue: UnicodeString): UnicodeString;
var
  I: Integer;
  S: UnicodeString;
begin
  S := AsciiLower(AValue);
  Result := '';
  for I := 1 to Length(S) do
    if IsNameChar(S[I]) then
      Result := Result + S[I];
end;

function ScoreNormalizedNameMatch(const AQuery, ACandidate: UnicodeString): Integer;
var
  Q, C, Token: UnicodeString;
  I, Matched, Total: Integer;
begin
  if (AQuery = '') or (ACandidate = '') then
    Exit(0);
  if AQuery = ACandidate then
    Exit(100);
  Q := CompactNameKey(AQuery);
  C := CompactNameKey(ACandidate);
  if (Q <> '') and (Q = C) then
    Exit(95);
  // Prefix / containment on the compact key handles "hollowknight" versus
  // "hollow knight definitive edition" style differences.
  if (Length(Q) >= 4) and (Length(C) >= 4) then
  begin
    if Copy(C, 1, Length(Q)) = Q then
      Exit(80);
    if Pos(Q, C) > 0 then
      Exit(70);
  end;
  // Token overlap: every query token that appears in the candidate counts.
  Matched := 0;
  Total := 0;
  Token := '';
  for I := 1 to Length(AQuery) + 1 do
  begin
    if (I > Length(AQuery)) or (AQuery[I] = ' ') then
    begin
      if Token <> '' then
      begin
        Inc(Total);
        if Pos(UnicodeString(' ') + Token + UnicodeString(' '),
             UnicodeString(' ') + ACandidate + UnicodeString(' ')) > 0 then
          Inc(Matched);
        Token := '';
      end;
    end
    else
      Token := Token + AQuery[I];
  end;
  if (Total = 0) or (Matched = 0) then
    Exit(0);
  Result := 40 + (Matched * 40) div Total;
  if Result > 90 then
    Result := 90;
end;

function JsonEscapeUnicode(const AValue: UnicodeString): UTF8String;
var
  I: Integer;
  W: WideChar;
  Code: Cardinal;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    W := AValue[I];
    case W of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      Code := Ord(W);
      if Code < 32 then
        Result := Result + '\u' + LowerCase(IntToHex(Code, 4))
      else
        // Raw UTF-8, not \uXXXX: see the note on the interface declaration.
        Result := Result + UTF8Encode(W);
    end;
  end;
end;

function Utf8JsonText(const AValue: UTF8String): string;
var
  Tmp: RawByteString;
begin
  Tmp := AValue;
  SetCodePage(Tmp, CP_UTF8, False);
  Result := Tmp;
end;

function TCEACheatTableEntry.IsValid: Boolean;
begin
  Result := (GameName <> '') and (GcmUrl <> '');
end;

function TCEAGameTranslation.IsValid: Boolean;
begin
  Result := (EnUs <> '') and (ZhCn <> '');
end;

function TCEAGameTranslation.DisplayName: UnicodeString;
begin
  if ZhCn <> '' then
    Result := ZhCn
  else
    Result := EnUs;
end;

function TCEAGameMatchResult.HasEntries: Boolean;
begin
  Result := Length(Entries) > 0;
end;

end.
