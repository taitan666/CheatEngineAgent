unit cea_gcm_description_translator;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage utf8}

interface

uses
  SysUtils, cea_results, cea_llm_provider, cea_ct_model, cea_gcm_types;

type
  // One Description string from a cheat table and its machine translation.
  // The English source is always kept verbatim so the UI can show both sides
  // and so a wrong translation can never masquerade as the original text.
  TCEADescriptionTranslation = record
    SourceText: UnicodeString;
    // Empty until a translation succeeded.
    TranslatedText: UnicodeString;
    // True when the provider returned a translation for this exact source.
    Translated: Boolean;
  end;

  TCEADescriptionTranslationArray = array of TCEADescriptionTranslation;

  TCEADescriptionBatch = record
    // Identifier of the cheat table the batch was produced from.
    SourceUri: string;
    // SHA-256 of the table content, so a translation can be tied to the exact
    // file version it was produced from.
    ContentHash: string;
    Entries: TCEADescriptionTranslationArray;
    // Number of provider calls actually made (0 when nothing needed work).
    RequestCount: Integer;
    function Count: Integer;
    function TranslatedCount: Integer;
  end;

  // Translates only the <Description> text of a cheat table.
  //
  // Deliberate scope limits:
  //  - Auto assembler and Lua bodies are never sent to the provider, so a
  //    translation can never leak or rewrite executable content.
  //  - The result is advisory. It is stored next to the English source and is
  //    never used to build a field, address or write command.
  //  - A provider answer that does not cover exactly the requested sources is
  //    rejected as a whole: a missing or invented entry would otherwise shift
  //    translations onto the wrong entries.
  TCEAGcmDescriptionTranslator = class(TObject)
  private
    FProvider: TCEALLMChatProvider;
    FMaxEntriesPerRequest: Integer;
    FMaxOutputTokens: Cardinal;
    FTemperature: Double;
  public
    constructor Create(const AProvider: TCEALLMChatProvider;
      const AMaxEntriesPerRequest: Integer = 40;
      const AMaxOutputTokens: Cardinal = 2048);
    // Distinct, non-empty Description values in table order.
    function CollectDescriptions(const AArtifact: TCTArtifact;
      out ATexts: TCEADescriptionTranslationArray): TCEAResult;
    // Translates every distinct description. ACancellation is polled between
    // batches and passed to the provider.
    function Translate(const AArtifact: TCTArtifact;
      out ABatch: TCEADescriptionBatch;
      const ACancellation: ICEACancellationToken = nil): TCEAResult;
    property MaxEntriesPerRequest: Integer read FMaxEntriesPerRequest;
  end;

const
  // Marker put into the batch so the UI can label the text as machine output.
  CeaTranslationDisclaimer = '机器翻译，仅供参考';

implementation

uses
  Classes, fpjson, jsonparser;

function TCEADescriptionBatch.Count: Integer;
begin
  Result := Length(Entries);
end;
function TCEADescriptionBatch.TranslatedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Entries) do
    if Entries[I].Translated then Inc(Result);
end;

constructor TCEAGcmDescriptionTranslator.Create(
  const AProvider: TCEALLMChatProvider; const AMaxEntriesPerRequest: Integer;
  const AMaxOutputTokens: Cardinal);
begin
  inherited Create;
  FProvider := AProvider;
  if AMaxEntriesPerRequest > 0 then
    FMaxEntriesPerRequest := AMaxEntriesPerRequest
  else
    FMaxEntriesPerRequest := 40;
  FMaxOutputTokens := AMaxOutputTokens;
  FTemperature := 0.1;
end;

function TCEAGcmDescriptionTranslator.CollectDescriptions(
  const AArtifact: TCTArtifact;
  out ATexts: TCEADescriptionTranslationArray): TCEAResult;
var
  I, Count: Integer;
  Text: UnicodeString;
  Seen: TStringList;
  Key: string;
begin
  SetLength(ATexts, 0);
  Count := 0;
  SetLength(ATexts, Length(AArtifact.Entries));
  Seen := TStringList.Create;
  try
    Seen.CaseSensitive := True;
    for I := 0 to High(AArtifact.Entries) do
    begin
      // The parser stores Description as raw UTF-8 bytes in an AnsiString that
      // still carries the default code page tag, so a plain cast would decode
      // them as GBK. UTF8Decode is the only correct conversion here.
      Text := UnicodeString(UTF8Decode(Trim(AArtifact.Entries[I].Description)));
      if Text = '' then Continue;
      Key := string(UTF8Encode(Text));
      if Seen.IndexOf(Key) >= 0 then Continue;
      Seen.Add(Key);
      ATexts[Count].SourceText := Text;
      ATexts[Count].TranslatedText := '';
      ATexts[Count].Translated := False;
      Inc(Count);
    end;
  finally
    Seen.Free;
  end;
  SetLength(ATexts, Count);
  // No descriptions is a legitimate outcome (some tables only carry scripts),
  // but the caller still gets an explicit answer instead of a silent empty OK.
  Result := TCEAResult.Ok('{"description_count":' + IntToStr(Count) + '}');
end;

function BuildTranslationPrompt(const ASources: TCEADescriptionTranslationArray;
  const AFrom, ATo: Integer): UTF8String;
var
  I: Integer;
begin
  Result := 'Translate the following video game cheat table entry descriptions ' +
    'from English to Simplified Chinese.' + LineEnding +
    'Rules: translate only the description text; keep numbers, item names and ' +
    'proper nouns accurate; do not add explanations; do not invent entries.' +
    LineEnding +
    'Answer with a JSON object of the exact shape ' +
    '{"translations":[{"source":"<the original English text, unchanged>",' +
    '"target":"<the Chinese translation>"}]} and include one object for every ' +
    'input string, in the same order.' + LineEnding +
    'Input strings:' + LineEnding;
  for I := AFrom to ATo do
    Result := Result + '"' + JsonEscapeUnicode(ASources[I].SourceText) + '"' +
      LineEnding;
end;

// Applies one provider answer to AEntries. Every returned source must match a
// requested source exactly; a missing or unknown source fails the batch.
//
// Validation and commit are separate passes on purpose: writing each match as
// it arrives would leave the batch half translated when a later entry turns out
// to be invented, and a partially filled batch is worse than no batch at all.
function ApplyTranslations(const AResponseJson: string;
  var AEntries: TCEADescriptionTranslationArray;
  const AFrom, ATo: Integer): TCEAResult;
var
  Root, Item: TJSONData;
  Arr: TJSONArray;
  I, J, Applied, Slot: Integer;
  SourceText, TargetText: UnicodeString;
  Matched: Boolean;
  Pending: array of UnicodeString;
begin
  Root := nil;
  SetLength(Pending, ATo - AFrom + 1);
  for Slot := 0 to High(Pending) do
    Pending[Slot] := '';
  try
    try
      Root := GetJSON(AResponseJson);
    except
      Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
    end;
    if (Root = nil) or (Root.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
    Item := TJSONObject(Root).Find('translations');
    if (Item = nil) or (Item.JSONType <> jtArray) then
      Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
    Arr := TJSONArray(Item);
    Applied := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      if Arr.Items[I].JSONType <> jtObject then
        Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
      SourceText := TJSONObject(Arr.Items[I]).Get('source', UnicodeString(''));
      TargetText := TJSONObject(Arr.Items[I]).Get('target', UnicodeString(''));
      if (SourceText = '') or (TargetText = '') then
        Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
      Matched := False;
      for J := AFrom to ATo do
        if AEntries[J].SourceText = SourceText then
        begin
          if Pending[J - AFrom] <> '' then
            Exit(TCEAResult.Error(rcUnknown,
              'translation_entry_duplicated', '{}'));
          Pending[J - AFrom] := TargetText;
          Inc(Applied);
          Matched := True;
          Break;
        end;
      if not Matched then
        Exit(TCEAResult.Error(rcUnknown, 'translation_source_unknown', '{}'));
    end;
    if Applied <> (ATo - AFrom + 1) then
      Exit(TCEAResult.Error(rcUnknown, 'translation_entry_count_mismatch', '{}'));
    // Everything validated: commit in one pass.
    for J := AFrom to ATo do
    begin
      AEntries[J].TranslatedText := Pending[J - AFrom];
      AEntries[J].Translated := True;
    end;
    Result := TCEAResult.Ok('{"applied":' + IntToStr(Applied) + '}');
  finally
    Root.Free;
  end;
end;

// Chat() returns a proposal envelope ({"provider_id":...,"content":"..."}) and
// the model text is JSON nested inside "content". Extract and hand back the
// inner payload so the caller can parse it once more.
function ExtractProviderContent(const AEnvelopeJson: string): TCEAResult;
var
  Root: TJSONData;
  Content: UnicodeString;
begin
  Root := nil;
  try
    try
      Root := GetJSON(AEnvelopeJson);
    except
      Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
    end;
    if (Root = nil) or (Root.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcUnknown, 'translation_response_invalid', '{}'));
    // Read as UnicodeString so fpjson does the UTF-8 decode; the raw AnsiString
    // path would hand back bytes tagged with the default code page.
    Content := TJSONObject(Root).Get('content', UnicodeString(''));
    if Trim(Content) = '' then
      Exit(TCEAResult.Error(rcUnknown, 'translation_content_empty', '{}'));
    Result := TCEAResult.Ok(Utf8JsonText(UTF8Encode(Content)));
  finally
    Root.Free;
  end;
end;

function TCEAGcmDescriptionTranslator.Translate(const AArtifact: TCTArtifact;
  out ABatch: TCEADescriptionBatch;
  const ACancellation: ICEACancellationToken): TCEAResult;
var
  Collected: TCEADescriptionTranslationArray;
  Index, BatchEnd: Integer;
  Request: TCEALLMChatRequest;
  Prompt: UTF8String;
  Response: TCEAResult;
  ContentJson: string;
begin
  ABatch.SourceUri := AArtifact.SourceUri;
  ABatch.ContentHash := AArtifact.ContentHash;
  ABatch.RequestCount := 0;
  SetLength(ABatch.Entries, 0);
  if FProvider = nil then
    Exit(TCEAResult.Error(rcInternalError,
      'translation_provider_missing', '{}'));
  Result := CollectDescriptions(AArtifact, Collected);
  if Result.Failed then Exit;
  if Length(Collected) = 0 then
  begin
    // Nothing to translate is success, not an error: the caller may simply be
    // looking at a table that only carries scripts.
    Result := TCEAResult.Ok('{"description_count":0,"translated":0}');
    Exit;
  end;
  Index := 0;
  while Index <= High(Collected) do
  begin
    if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
    begin
      ABatch.Entries := Collected;
      Exit(TCEAResult.Error(rcCancelled, 'translation_cancelled', '{}'));
    end;
    BatchEnd := Index + FMaxEntriesPerRequest - 1;
    if BatchEnd > High(Collected) then BatchEnd := High(Collected);
    Prompt := BuildTranslationPrompt(Collected, Index, BatchEnd);
    FillChar(Request, SizeOf(Request), 0);
    Request.UserPrompt := Utf8JsonText(Prompt);
    // The provider requires a well formed, explicitly authority-free context.
    Request.RagContextJson := '{"authority":"none","citations":[]}';
    Request.MaxOutputTokens := FMaxOutputTokens;
    Request.Temperature := FTemperature;
    Request.Cancellation := ACancellation;
    Request.ResponseFormat := 'json_object';
    Response := FProvider.Chat(Request);
    if Response.Failed then
    begin
      ABatch.Entries := Collected;
      Exit(Response);
    end;
    Inc(ABatch.RequestCount);
    // Chat() wraps the model answer in a proposal envelope; the text lives in
    // "content" and must be parsed a second time.
    ContentJson := Response.DataJson;
    Response := ExtractProviderContent(ContentJson);
    if Response.Failed then
    begin
      ABatch.Entries := Collected;
      Exit(Response);
    end;
    Response := ApplyTranslations(Response.DataJson, Collected, Index, BatchEnd);
    if Response.Failed then
    begin
      ABatch.Entries := Collected;
      Exit(Response);
    end;
    Index := BatchEnd + 1;
  end;
  ABatch.Entries := Collected;
  Result := TCEAResult.Ok('{"description_count":' + IntToStr(Length(Collected)) +
    ',"translated":' + IntToStr(ABatch.TranslatedCount) +
    ',"requests":' + IntToStr(ABatch.RequestCount) + '}');
end;

end.
