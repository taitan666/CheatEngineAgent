program test_gcm_description_translator;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, FPJSON, JSONParser, cea_results, cea_llm_provider,
  cea_ct_model, cea_gcm_types, cea_gcm_description_translator;

type
  // Records every prompt and answers with a scripted envelope, so the test can
  // assert both what was sent and how the answer is applied.
  TFakeProvider = class(TCEALLMChatProvider)
  public
    Prompts: TStringList;
    Answers: TStringList;
    CallIndex: Integer;
    FailNext: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Chat(const ARequest: TCEALLMChatRequest): TCEAResult; override;
  end;

var
  Failures: Integer = 0;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL ', AMessage);
  end;
end;

constructor TFakeProvider.Create;
begin
  inherited Create;
  Prompts := TStringList.Create;
  Answers := TStringList.Create;
  CallIndex := 0;
end;

destructor TFakeProvider.Destroy;
begin
  Prompts.Free;
  Answers.Free;
  inherited Destroy;
end;

function TFakeProvider.Chat(const ARequest: TCEALLMChatRequest): TCEAResult;
var
  Answer, Envelope: string;
  Obj: TJSONObject;
begin
  Prompts.Add(ARequest.UserPrompt);
  if FailNext then
    Exit(TCEAResult.Error(rcTimeout, 'provider_timeout', '{}'));
  if CallIndex >= Answers.Count then
    Exit(TCEAResult.Error(rcInternalError, 'no_scripted_answer', '{}'));
  Answer := Answers[CallIndex];
  Inc(CallIndex);
  Obj := TJSONObject.Create;
  try
    Obj.Add('provider_id', 'fake');
    Obj.Add('content', Answer);
    Envelope := Obj.AsJSON;
  finally
    Obj.Free;
  end;
  Result := TCEAResult.Ok(Utf8JsonText(UTF8String(Envelope)));
end;

// Builds the envelope the provider would return for a set of translations.
function AnswerFor(const APairs: array of string): string;
var
  Root, Item: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Arr := TJSONArray.Create;
    I := 0;
    while I + 1 <= High(APairs) do
    begin
      Item := TJSONObject.Create;
      Item.Add('source', APairs[I]);
      Item.Add('target', APairs[I + 1]);
      Arr.Add(Item);
      Inc(I, 2);
    end;
    Root.Add('translations', Arr);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function MakeEntry(const ADescription: string): TCTEntry;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.EntryId := 'e' + IntToStr(Random(100000));
  Result.Description := ADescription;
end;

function MakeArtifact(const ADescriptions: array of string): TCTArtifact;
var
  I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.SourceUri := 'file:///tmp/sample.CT';
  Result.ContentHash := 'sha256:abc';
  SetLength(Result.Entries, Length(ADescriptions));
  for I := 0 to High(ADescriptions) do
    Result.Entries[I] := MakeEntry(ADescriptions[I]);
end;

procedure TestCollectDeduplicates;
var
  Translator: TCEAGcmDescriptionTranslator;
  Artifact: TCTArtifact;
  Texts: TCEADescriptionTranslationArray;
  R: TCEAResult;
begin
  Artifact := MakeArtifact(['Infinite Health', 'Infinite Health', '', '   ',
    'Max Gold']);
  Translator := TCEAGcmDescriptionTranslator.Create(nil);
  try
    R := Translator.CollectDescriptions(Artifact, Texts);
    Check(not R.Failed, 'collect ok');
    // Duplicates and blank descriptions collapse: only two distinct strings.
    Check(Length(Texts) = 2, 'collect keeps 2 distinct, got ' +
      IntToStr(Length(Texts)));
    Check(Texts[0].SourceText = 'Infinite Health', 'first source order');
    Check(Texts[1].SourceText = 'Max Gold', 'second source order');
    Check(not Texts[0].Translated, 'collect marks untranslated');
  finally
    Translator.Free;
  end;
end;

procedure TestTranslateHappyPath;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  try
    Provider.Answers.Add(AnswerFor(['Infinite Health', '无限生命', 'Max Gold',
      '最大金币']));
    Artifact := MakeArtifact(['Infinite Health', 'Max Gold']);
    R := Translator.Translate(Artifact, Batch);
    Check(not R.Failed, 'translate ok: ' + R.StableCode);
    Check(Batch.Count = 2, 'batch count 2');
    Check(Batch.TranslatedCount = 2, 'batch translated 2');
    Check(Batch.RequestCount = 1, 'one provider request');
    Check(Batch.Entries[0].TranslatedText = UnicodeString('无限生命'),
      'first translation applied');
    Check(Batch.Entries[1].TranslatedText = UnicodeString('最大金币'),
      'second translation applied');
    Check(Batch.SourceUri = Artifact.SourceUri, 'source uri carried');
    Check(Batch.ContentHash = Artifact.ContentHash, 'content hash carried');
    // The prompt must carry the English source and must never carry scripts.
    Check(Pos('Infinite Health', Provider.Prompts[0]) > 0,
      'prompt carries source text');
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestTranslateRejectsUnknownSource;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  try
    // The provider invented an entry that was never sent.
    Provider.Answers.Add(AnswerFor(['Infinite Health', '无限生命',
      'Teleport To Boss', '传送到 Boss']));
    Artifact := MakeArtifact(['Infinite Health']);
    R := Translator.Translate(Artifact, Batch);
    Check(R.Failed, 'unknown source fails');
    Check(R.StableCode = 'translation_source_unknown',
      'unknown source code, got ' + R.StableCode);
    Check(Batch.TranslatedCount = 0, 'nothing applied on failure');
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestTranslateRejectsMissingEntry;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  try
    // Only one of the two requested strings came back.
    Provider.Answers.Add(AnswerFor(['Infinite Health', '无限生命']));
    Artifact := MakeArtifact(['Infinite Health', 'Max Gold']);
    R := Translator.Translate(Artifact, Batch);
    Check(R.Failed, 'missing entry fails');
    Check(R.StableCode = 'translation_entry_count_mismatch',
      'count mismatch code, got ' + R.StableCode);
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestTranslatePropagatesProviderFailure;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  try
    Provider.FailNext := True;
    Artifact := MakeArtifact(['Infinite Health']);
    R := Translator.Translate(Artifact, Batch);
    Check(R.Failed, 'provider failure propagates');
    Check(R.Code = rcTimeout, 'provider timeout code preserved');
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestTranslateEmptyTable;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  try
    Artifact := MakeArtifact(['', '   ']);
    R := Translator.Translate(Artifact, Batch);
    Check(not R.Failed, 'empty table is success');
    Check(Batch.Count = 0, 'empty batch');
    Check(Batch.RequestCount = 0, 'no provider call for empty table');
    Check(Provider.Prompts.Count = 0, 'provider never called');
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestTranslateBatchesLargeTable;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
  Descriptions: array of string;
  I: Integer;
begin
  Provider := TFakeProvider.Create;
  // Two entries per request over five distinct strings means three calls.
  Translator := TCEAGcmDescriptionTranslator.Create(Provider, 2);
  try
    SetLength(Descriptions, 5);
    for I := 0 to 4 do
      Descriptions[I] := 'Entry ' + IntToStr(I);
    Provider.Answers.Add(AnswerFor(['Entry 0', '条目 0', 'Entry 1', '条目 1']));
    Provider.Answers.Add(AnswerFor(['Entry 2', '条目 2', 'Entry 3', '条目 3']));
    Provider.Answers.Add(AnswerFor(['Entry 4', '条目 4']));
    Artifact := MakeArtifact(Descriptions);
    R := Translator.Translate(Artifact, Batch);
    Check(not R.Failed, 'batched translate ok: ' + R.StableCode);
    Check(Batch.RequestCount = 3, 'three requests, got ' +
      IntToStr(Batch.RequestCount));
    Check(Batch.TranslatedCount = 5, 'all five translated');
    Check(Batch.Entries[4].TranslatedText = UnicodeString('条目 4'),
      'last batch applied');
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestTranslateRejectsMalformedAnswer;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  try
    Provider.Answers.Add('not json at all');
    Artifact := MakeArtifact(['Infinite Health']);
    R := Translator.Translate(Artifact, Batch);
    Check(R.Failed, 'malformed answer fails');
    Check(R.StableCode = 'translation_response_invalid',
      'malformed code, got ' + R.StableCode);
  finally
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestCancellationStopsBeforeProvider;
var
  Translator: TCEAGcmDescriptionTranslator;
  Provider: TFakeProvider;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  Token: TCEACancellationToken;
  R: TCEAResult;
begin
  Provider := TFakeProvider.Create;
  Translator := TCEAGcmDescriptionTranslator.Create(Provider);
  Token := TCEACancellationToken.Create;
  try
    Token.Cancel;
    Artifact := MakeArtifact(['Infinite Health']);
    R := Translator.Translate(Artifact, Batch, Token);
    Check(R.Failed, 'cancelled translate fails');
    Check(R.Code = rcCancelled, 'cancelled code');
    Check(Provider.Prompts.Count = 0, 'provider not called after cancel');
  finally
    Token.Free;
    Translator.Free;
    Provider.Free;
  end;
end;

procedure TestNoProviderIsRejected;
var
  Translator: TCEAGcmDescriptionTranslator;
  Artifact: TCTArtifact;
  Batch: TCEADescriptionBatch;
  R: TCEAResult;
begin
  Translator := TCEAGcmDescriptionTranslator.Create(nil);
  try
    Artifact := MakeArtifact(['Infinite Health']);
    R := Translator.Translate(Artifact, Batch);
    Check(R.Failed, 'nil provider fails');
    Check(R.StableCode = 'translation_provider_missing',
      'missing provider code, got ' + R.StableCode);
  finally
    Translator.Free;
  end;
end;

// The disclaimer is a Chinese literal compiled into the unit; this guards the
// source-encoding setup, because a wrong code page would ship mojibake to users.
procedure TestDisclaimerLiteralSurvivesCompilation;
begin
  Check(CeaTranslationDisclaimer = UnicodeString('机器翻译，仅供参考'),
    'disclaimer literal decodes as expected');
end;

begin
  Randomize;
  TestCollectDeduplicates;
  TestTranslateHappyPath;
  TestTranslateRejectsUnknownSource;
  TestTranslateRejectsMissingEntry;
  TestTranslatePropagatesProviderFailure;
  TestTranslateEmptyTable;
  TestTranslateBatchesLargeTable;
  TestTranslateRejectsMalformedAnswer;
  TestCancellationStopsBeforeProvider;
  TestNoProviderIsRejected;
  TestDisclaimerLiteralSurvivesCompilation;
  if Failures = 0 then
  begin
    WriteLn('GCM_DESCRIPTION_TRANSLATOR=PASS');
    WriteLn('PASCAL_TEST=PASS');
  end
  else
  begin
    WriteLn('GCM_DESCRIPTION_TRANSLATOR=FAIL failures=', Failures);
    Halt(1);
  end;
end.
