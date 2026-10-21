unit cea_event_analysis_service;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

// PRD 6.9 - AI event analysis and evidence linking (FR-090..FR-094).
//
// This unit is deliberately narrow: it turns an already captured event package
// into an analysis context, a grade, a cross-event trend and a list of
// verification suggestions. It never scans, never writes, and never decides
// that a field is writable. Everything it produces is advisory input for the
// operator, which is what FR-091 and FR-093 require.
//
// Layering note: this is a core unit, so it depends on contracts and on the
// event types only. The provider call is a separate entry point so that the
// local digest path stays usable with no model configured.

interface

uses
  SysUtils, cea_results, cea_event_types, cea_llm_provider;

type
  // Evidence grade (FR-091). The order matters: the first three come from the
  // read-only backend or from the operator, the last two are inference and may
  // never justify a memory write on their own.
  TCEAEvidenceGrade = (
    egDirectObservation,    // captured by the read-only backend
    egRepeatedVerification, // same field observed consistently across events
    egUserConfirmed,        // operator stated it explicitly
    egAiHypothesis,         // model or external connector proposed it
    egVisualInference       // visual/vision candidate (FR-084)
  );

  // One field inside a single event (FR-090 digest, FR-092 comparison).
  TCEAFieldDelta = record
    FieldId: string;
    PreviousValueJson: string;
    CurrentValueJson: string;
    Changed: Boolean;
    Direction: string;   // increase / decrease / same / unknown
    DeltaText: string;   // numeric difference, empty when not numeric
    function IsValid: Boolean;
  end;

  TCEAFieldDeltaArray = array of TCEAFieldDelta;

  TCEAStringArray = array of string;

  // One field across several events (FR-092).
  TCEAFieldTrend = record
    FieldId: string;
    SampleCount: Integer;
    ChangeCount: Integer;
    EventCount: Integer;
    FirstValueJson: string;
    LastValueJson: string;
    Numeric: Boolean;
    MinValue: Double;
    MaxValue: Double;
    Direction: string;
    function IsValid: Boolean;
  end;

  // A next step the operator may choose to run (FR-093). Advisory only: the
  // service cannot execute it, and running it still goes through the normal
  // lease/approval path.
  TCEAVerificationSuggestion = record
    SuggestionId: string;
    Kind: string;          // capture_again / compare_events / aob_uniqueness /
                           // pointer_chain_check / confirm_mapping / reject_mapping
    FieldId: string;
    Text: string;
    Advisory: Boolean;
    RequiresApproval: Boolean;
    function IsValid: Boolean;
  end;

  TCEAVerificationSuggestionArray = array of TCEAVerificationSuggestion;

  TCEAEventAnalysis = record
    EventId: string;
    DigestJson: string;
    Grade: TCEAEvidenceGrade;
    GradeReason: string;
    Deltas: TCEAFieldDeltaArray;
    Trend: TCEAFieldTrend;
    HasTrend: Boolean;
    Suggestions: TCEAVerificationSuggestionArray;
    CloudUsed: Boolean;
    function IsValid: Boolean;
  end;

  TCEAEventAnalysisService = class
  private
    FSequence: Cardinal;
    function NextSuggestionId: string;
  public
    constructor Create;

    // FR-090: structured, short analysis context. Local only.
    function BuildDigest(const AEvent: TCEAEventPackage;
      const AEvents: TCEAEventPackageArray; out ADigestJson: string): TCEAResult;

    // FR-091: grade the event from its trigger and from how often the same
    // field has been observed elsewhere.
    function GradeEvent(const AEvent: TCEAEventPackage;
      const AEvents: TCEAEventPackageArray;
      out AGrade: TCEAEvidenceGrade; out AReason: string): TCEAResult;

    // FR-092: compare one field across every supplied event.
    function CorrelateField(const AEvents: TCEAEventPackageArray;
      const AFieldId: string; out ATrend: TCEAFieldTrend): TCEAResult;

    // FR-093: deterministic suggestions derived from the data, never from a
    // model. Advisory and approval-gated by construction.
    function SuggestVerification(const AEvent: TCEAEventPackage;
      const AEvents: TCEAEventPackageArray): TCEAVerificationSuggestionArray;

    // Local-only end-to-end analysis: digest + grade + trend + suggestions.
    function Analyze(const AEvent: TCEAEventPackage;
      const AEvents: TCEAEventPackageArray;
      const AFieldId: string; out AAnalysis: TCEAEventAnalysis): TCEAResult;

    // FR-080/FR-093: hand the digest to a model. Captured values leave the
    // machine only when the caller passes explicit consent; otherwise the call
    // fails closed with cloud_consent_required.
    function AskProvider(const AProvider: TCEALLMChatProvider;
      const AAnalysis: TCEAEventAnalysis;
      const AConsentToSendValues: Boolean;
      const AMaxOutputTokens: Cardinal;
      out AContent: UnicodeString): TCEAResult;
  end;

function EvidenceGradeText(const AGrade: TCEAEvidenceGrade): string;
function TryParseEvidenceGrade(const AText: string;
  out AGrade: TCEAEvidenceGrade): Boolean;
// Only these grades may support a mapping or a write decision; inference grades
// stay advisory (FR-084/FR-091).
function IsWriteJustifyingGrade(const AGrade: TCEAEvidenceGrade): Boolean;
function IsAdvisoryGrade(const AGrade: TCEAEvidenceGrade): Boolean;
// Byte-preserving JSON string escape. Works on UTF-8 bytes whatever the
// codepage tag, so Chinese field names and values survive.
function JsonEscapeBytes(const AValue: RawByteString): UTF8String;
// Retag UTF-8 bytes without transcoding them (see the fpjson note in
// docs/delivery/phase0-notes.md).
function Utf8Text(const AValue: RawByteString): string;

implementation

uses
  fpjson, jsonparser;

const
  // Hard ceilings so one event cannot produce an unbounded prompt.
  CeaMaxDigestSnapshots = 200;
  CeaMaxTrendSamples = 64;
  CeaMaxSuggestedFields = 10;

function JsonEscapeBytes(const AValue: RawByteString): UTF8String;
var
  I: Integer;
  C: Byte;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := Byte(AValue[I]);
    case C of
      34: Result := Result + '\"';
      92: Result := Result + '\\';
      8: Result := Result + '\b';
      9: Result := Result + '\t';
      10: Result := Result + '\n';
      12: Result := Result + '\f';
      13: Result := Result + '\r';
    else
      if C < 32 then
        Result := Result + '\u' + IntToHex(C, 4)
      else
        Result := Result + AnsiChar(C);
    end;
  end;
end;

function Utf8Text(const AValue: RawByteString): string;
var
  Tmp: RawByteString;
begin
  Tmp := AValue;
  SetCodePage(Tmp, CP_UTF8, False);
  Result := Tmp;
end;

{ JSON has no True/False literals: BoolToStr(Value, True) emits Pascal casing
  and makes the payload unparseable downstream. }
function JsonBool(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

function EvidenceGradeText(const AGrade: TCEAEvidenceGrade): string;
begin
  case AGrade of
    egDirectObservation: Result := 'direct_observation';
    egRepeatedVerification: Result := 'repeated_verification';
    egUserConfirmed: Result := 'user_confirmed';
    egAiHypothesis: Result := 'ai_hypothesis';
    egVisualInference: Result := 'visual_inference';
  end;
end;

function TryParseEvidenceGrade(const AText: string;
  out AGrade: TCEAEvidenceGrade): Boolean;
var
  G: TCEAEvidenceGrade;
begin
  for G := Low(TCEAEvidenceGrade) to High(TCEAEvidenceGrade) do
    if EvidenceGradeText(G) = AText then
    begin
      AGrade := G;
      Exit(True);
    end;
  Result := False;
end;

function IsWriteJustifyingGrade(const AGrade: TCEAEvidenceGrade): Boolean;
begin
  // A justifying grade still does not authorize a write on its own: the field
  // must also be faVerifiedWritable, which only a read-back comparison grants.
  Result := AGrade in [egDirectObservation, egRepeatedVerification,
    egUserConfirmed];
end;

function IsAdvisoryGrade(const AGrade: TCEAEvidenceGrade): Boolean;
begin
  Result := AGrade in [egAiHypothesis, egVisualInference];
end;

function TCEAFieldDelta.IsValid: Boolean;
begin
  Result := FieldId <> '';
end;

function TCEAFieldTrend.IsValid: Boolean;
begin
  Result := (FieldId <> '') and (SampleCount > 0);
end;

function TCEAVerificationSuggestion.IsValid: Boolean;
begin
  Result := (SuggestionId <> '') and (Kind <> '') and (Text <> '');
end;

function TCEAEventAnalysis.IsValid: Boolean;
begin
  Result := (EventId <> '') and (DigestJson <> '');
end;

function TryNumeric(const AValueJson: string; out ANumber: Double): Boolean;
var
  Text: string;
begin
  Text := Trim(AValueJson);
  if Text = '' then
    Exit(False);
  Result := TryStrToFloat(Text, ANumber);
end;

function DirectionOf(const APrevious, ACurrent: Double;
  const AHasPrevious, AHasCurrent: Boolean): string;
begin
  if not (AHasPrevious and AHasCurrent) then
    Exit('unknown');
  if ACurrent > APrevious then
    Result := 'increase'
  else if ACurrent < APrevious then
    Result := 'decrease'
  else
    Result := 'same';
end;

function ParseSnapshots(const AJson: string;
  out AItems: TCEAFieldSnapshotArray): Boolean;
var
  Data: TJSONData;
  Arr: TJSONArray;
  Obj: TJSONObject;
  I, Count: Integer;
begin
  Result := False;
  AItems := nil;
  if Trim(AJson) = '' then
    Exit;
  Data := nil;
  try
    try
      Data := GetJSON(AJson);
    except
      Exit;
    end;
    if (Data = nil) or (Data.JSONType <> jtArray) then
      Exit;
    Arr := TJSONArray(Data);
    SetLength(AItems, Arr.Count);
    Count := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      if Arr.Items[I].JSONType <> jtObject then
        Continue;
      Obj := TJSONObject(Arr.Items[I]);
      AItems[Count].FieldId := Obj.Get('field_id', '');
      AItems[Count].ValueJson := Obj.Get('value_json', '');
      AItems[Count].CapturedAtMs := Obj.Get('captured_at_ms', Int64(0));
      AItems[Count].Sequence := Obj.Get('sequence', Int64(0));
      Inc(Count);
    end;
    SetLength(AItems, Count);
    Result := True;
  finally
    Data.Free;
  end;
end;

// Returns the distinct field ids present in the snapshots, in first-seen order.
function CollectFieldIds(const ASnapshots: TCEAFieldSnapshotArray): TCEAStringArray;
var
  I, J: Integer;
begin
  Result := nil;
  for I := 0 to High(ASnapshots) do
  begin
    if ASnapshots[I].FieldId = '' then
      Continue;
    J := 0;
    while (J <= High(Result)) and (Result[J] <> ASnapshots[I].FieldId) do
      Inc(J);
    if J > High(Result) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := ASnapshots[I].FieldId;
    end;
  end;
end;

constructor TCEAEventAnalysisService.Create;
begin
  inherited Create;
  FSequence := 0;
end;

function TCEAEventAnalysisService.NextSuggestionId: string;
begin
  Inc(FSequence);
  Result := 'suggest-' + IntToHex(FSequence, 6);
end;

function TCEAEventAnalysisService.BuildDigest(const AEvent: TCEAEventPackage;
  const AEvents: TCEAEventPackageArray; out ADigestJson: string): TCEAResult;
var
  Snapshots: TCEAFieldSnapshotArray;
  Deltas: TCEAFieldDeltaArray;
  FieldIds: TCEAStringArray;
  I, J, Sent: Integer;
  PreviousValue, CurrentValue: Double;
  HasPrevious, HasCurrent: Boolean;
  SnapPart, DeltaPart, FieldPart, RelatedPart, TagsPart: UTF8String;
  RelatedCount: Integer;
begin
  ADigestJson := '';
  if not AEvent.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_invalid', '{}'));
  if not ParseSnapshots(AEvent.FieldSnapshotsJson, Snapshots) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_snapshots_invalid', '{}'));

  // Per-field before/after pair inside this event's window. Snapshots are
  // stored in capture order, so the first and last entry per field are the
  // pair the operator cares about.
  FieldIds := CollectFieldIds(Snapshots);
  SetLength(Deltas, Length(FieldIds));
  for I := 0 to High(FieldIds) do
  begin
    Deltas[I].FieldId := FieldIds[I];
    Deltas[I].PreviousValueJson := '';
    Deltas[I].CurrentValueJson := '';
    for J := 0 to High(Snapshots) do
    begin
      if Snapshots[J].FieldId <> FieldIds[I] then
        Continue;
      if Deltas[I].PreviousValueJson = '' then
        Deltas[I].PreviousValueJson := Snapshots[J].ValueJson;
      Deltas[I].CurrentValueJson := Snapshots[J].ValueJson;
    end;
    HasPrevious := TryNumeric(Deltas[I].PreviousValueJson, PreviousValue);
    HasCurrent := TryNumeric(Deltas[I].CurrentValueJson, CurrentValue);
    Deltas[I].Changed := Deltas[I].PreviousValueJson <>
      Deltas[I].CurrentValueJson;
    Deltas[I].Direction := DirectionOf(PreviousValue, CurrentValue,
      HasPrevious, HasCurrent);
    if HasPrevious and HasCurrent then
      Deltas[I].DeltaText := FloatToStr(CurrentValue - PreviousValue)
    else
      Deltas[I].DeltaText := '';
  end;

  TagsPart := UTF8String(AEvent.UserTagsJson);
  if Trim(string(TagsPart)) = '' then
    TagsPart := '[]';

  SnapPart := '[';
  Sent := 0;
  for I := 0 to High(Snapshots) do
  begin
    if Sent >= CeaMaxDigestSnapshots then
      Break;
    if Sent > 0 then
      SnapPart := SnapPart + ',';
    SnapPart := SnapPart + '{"field_id":"' +
      JsonEscapeBytes(UTF8String(Snapshots[I].FieldId)) +
      '","value_json":"' +
      JsonEscapeBytes(UTF8String(Snapshots[I].ValueJson)) +
      '","captured_at_ms":' + UTF8String(IntToStr(Snapshots[I].CapturedAtMs)) +
      '}';
    Inc(Sent);
  end;
  SnapPart := SnapPart + ']';

  DeltaPart := '[';
  for I := 0 to High(Deltas) do
  begin
    if I > 0 then
      DeltaPart := DeltaPart + ',';
    DeltaPart := DeltaPart + '{"field_id":"' +
      JsonEscapeBytes(UTF8String(Deltas[I].FieldId)) +
      '","previous":"' +
      JsonEscapeBytes(UTF8String(Deltas[I].PreviousValueJson)) +
      '","current":"' +
      JsonEscapeBytes(UTF8String(Deltas[I].CurrentValueJson)) +
      '","changed":' + UTF8String(JsonBool(Deltas[I].Changed)) +
      ',"direction":"' + UTF8String(Deltas[I].Direction) +
      '","delta":"' + JsonEscapeBytes(UTF8String(Deltas[I].DeltaText)) + '"}';
  end;
  DeltaPart := DeltaPart + ']';

  FieldPart := '[';
  for I := 0 to High(FieldIds) do
  begin
    if I > 0 then
      FieldPart := FieldPart + ',';
    FieldPart := FieldPart + '"' + JsonEscapeBytes(UTF8String(FieldIds[I])) + '"';
  end;
  FieldPart := FieldPart + ']';

  RelatedPart := '[';
  RelatedCount := 0;
  for I := 0 to High(AEvents) do
  begin
    if AEvents[I].EventId = AEvent.EventId then
      Continue;
    if RelatedCount > 0 then
      RelatedPart := RelatedPart + ',';
    RelatedPart := RelatedPart + '{"event_id":"' +
      JsonEscapeBytes(UTF8String(AEvents[I].EventId)) + '","trigger_kind":"' +
      UTF8String(EventTriggerKindText(AEvents[I].TriggerKind)) +
      '","start_at_ms":' + UTF8String(IntToStr(AEvents[I].StartAtMs)) +
      ',"end_at_ms":' + UTF8String(IntToStr(AEvents[I].EndAtMs)) + '}';
    Inc(RelatedCount);
  end;
  RelatedPart := RelatedPart + ']';

  ADigestJson := Utf8Text('{"event_id":"' +
    JsonEscapeBytes(UTF8String(AEvent.EventId)) + '","trigger_kind":"' +
    UTF8String(EventTriggerKindText(AEvent.TriggerKind)) +
    '","trigger_source":"' +
    JsonEscapeBytes(UTF8String(AEvent.TriggerSource)) +
    '","window":{"start_at_ms":' + UTF8String(IntToStr(AEvent.StartAtMs)) +
    ',"end_at_ms":' + UTF8String(IntToStr(AEvent.EndAtMs)) +
    ',"duration_ms":' + UTF8String(IntToStr(AEvent.DurationMs)) + '}' +
    ',"tags":' + TagsPart +
    ',"fields":' + FieldPart +
    ',"snapshots":' + SnapPart +
    ',"deltas":' + DeltaPart +
    ',"related_events":' + RelatedPart +
    ',"related_event_count":' + UTF8String(IntToStr(RelatedCount)) +
    ',"note":"values are local captures; inference is not evidence"}');
  Result := TCEAResult.Ok(ADigestJson);
end;

function TCEAEventAnalysisService.GradeEvent(const AEvent: TCEAEventPackage;
  const AEvents: TCEAEventPackageArray;
  out AGrade: TCEAEvidenceGrade; out AReason: string): TCEAResult;
var
  Snapshots, Other: TCEAFieldSnapshotArray;
  I, J, K, Observed, Confirmed: Integer;
  SeenElsewhere: Boolean;
begin
  AGrade := egAiHypothesis;
  AReason := '';
  if not AEvent.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_invalid', '{}'));

  // Advisory triggers never grade above inference (FR-084).
  if IsAdvisoryOnlyTrigger(AEvent.TriggerKind) then
  begin
    if AEvent.TriggerKind = etAiSuggested then
      AGrade := egVisualInference
    else
      AGrade := egAiHypothesis;
    AReason := 'advisory_trigger';
    Exit(TCEAResult.Ok('{"grade":"' + EvidenceGradeText(AGrade) +
      '","reason":"' + AReason + '"}'));
  end;

  if AEvent.TriggerKind = etUserMark then
  begin
    AGrade := egUserConfirmed;
    AReason := 'operator_marked';
    Exit(TCEAResult.Ok('{"grade":"' + EvidenceGradeText(AGrade) +
      '","reason":"' + AReason + '"}'));
  end;

  // etFieldChange / etExternalSource: a local capture is a direct observation.
  // It is promoted to repeated_verification only when another event observed
  // the same field id at all - this is corroboration of the observation, not
  // proof that the address is correct.
  AGrade := egDirectObservation;
  AReason := 'captured_by_readonly_backend';
  if ParseSnapshots(AEvent.FieldSnapshotsJson, Snapshots) then
  begin
    Observed := 0;
    Confirmed := 0;
    for I := 0 to High(Snapshots) do
    begin
      if Snapshots[I].FieldId = '' then
        Continue;
      Inc(Observed);
      SeenElsewhere := False;
      for J := 0 to High(AEvents) do
      begin
        if AEvents[J].EventId = AEvent.EventId then
          Continue;
        if not ParseSnapshots(AEvents[J].FieldSnapshotsJson, Other) then
          Continue;
        for K := 0 to High(Other) do
          if Other[K].FieldId = Snapshots[I].FieldId then
          begin
            SeenElsewhere := True;
            Break;
          end;
        if SeenElsewhere then
          Break;
      end;
      if SeenElsewhere then
        Inc(Confirmed);
    end;
    if (Observed > 0) and (Confirmed = Observed) then
    begin
      AGrade := egRepeatedVerification;
      AReason := 'observed_in_every_supplied_event';
    end
    else if Confirmed > 0 then
      AReason := 'observed_in_some_other_event';
  end;
  Result := TCEAResult.Ok('{"grade":"' + EvidenceGradeText(AGrade) +
    '","reason":"' + AReason + '"}');
end;

function TCEAEventAnalysisService.CorrelateField(
  const AEvents: TCEAEventPackageArray; const AFieldId: string;
  out ATrend: TCEAFieldTrend): TCEAResult;
var
  I, J, Samples, Changes, EventCount, NumberCount: Integer;
  Snapshots: TCEAFieldSnapshotArray;
  PreviousValue, CurrentValue: Double;
  HasPrevious, HasPrior: Boolean;
begin
  FillChar(ATrend, SizeOf(ATrend), 0);
  if Trim(AFieldId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_field_required', '{}'));

  ATrend.FieldId := AFieldId;
  ATrend.Direction := 'unknown';
  Samples := 0;
  Changes := 0;
  EventCount := 0;
  NumberCount := 0;
  HasPrevious := False;
  HasPrior := False;
  PreviousValue := 0;
  CurrentValue := 0;
  for I := 0 to High(AEvents) do
  begin
    if not ParseSnapshots(AEvents[I].FieldSnapshotsJson, Snapshots) then
      Continue;
    if Length(Snapshots) = 0 then
      Continue;
    Inc(EventCount);
    for J := 0 to High(Snapshots) do
    begin
      if Snapshots[J].FieldId <> AFieldId then
        Continue;
      if Samples >= CeaMaxTrendSamples then
        Break;
      if not HasPrior then
      begin
        ATrend.FirstValueJson := Snapshots[J].ValueJson;
        ATrend.MinValue := 0;
        ATrend.MaxValue := 0;
      end
      else if ATrend.LastValueJson <> Snapshots[J].ValueJson then
        Inc(Changes);
      ATrend.LastValueJson := Snapshots[J].ValueJson;
      HasPrior := True;

      if TryNumeric(Snapshots[J].ValueJson, CurrentValue) then
      begin
        if NumberCount = 0 then
        begin
          ATrend.MinValue := CurrentValue;
          ATrend.MaxValue := CurrentValue;
        end
        else
        begin
          if CurrentValue < ATrend.MinValue then
            ATrend.MinValue := CurrentValue;
          if CurrentValue > ATrend.MaxValue then
            ATrend.MaxValue := CurrentValue;
        end;
        Inc(NumberCount);
        if HasPrevious then
          ATrend.Direction := DirectionOf(PreviousValue, CurrentValue, True, True);
        PreviousValue := CurrentValue;
        HasPrevious := True;
      end
      else
        HasPrevious := False;
      Inc(Samples);
    end;
  end;

  ATrend.SampleCount := Samples;
  ATrend.ChangeCount := Changes;
  ATrend.EventCount := EventCount;
  ATrend.Numeric := (NumberCount > 0) and (NumberCount = Samples);
  if not ATrend.IsValid then
    Exit(TCEAResult.Error(rcUnknown, 'event_field_not_observed', '{}'));
  Result := TCEAResult.Ok('{"field_id":"' +
    JsonEscapeBytes(UTF8String(AFieldId)) +
    '","samples":' + IntToStr(Samples) +
    ',"changes":' + IntToStr(Changes) +
    ',"events":' + IntToStr(EventCount) +
    ',"numeric":' + JsonBool(ATrend.Numeric) +
    ',"direction":"' + ATrend.Direction + '"}');
end;

function TCEAEventAnalysisService.SuggestVerification(
  const AEvent: TCEAEventPackage;
  const AEvents: TCEAEventPackageArray): TCEAVerificationSuggestionArray;
var
  Snapshots: TCEAFieldSnapshotArray;
  Trend: TCEAFieldTrend;
  Suggestion: TCEAVerificationSuggestion;
  FieldIds: TCEAStringArray;
  I: Integer;
  Grade: TCEAEvidenceGrade;
  Reason: string;

  procedure Add(const AKind, AFieldId, AText: string);
  begin
    Suggestion.SuggestionId := NextSuggestionId;
    Suggestion.Kind := AKind;
    Suggestion.FieldId := AFieldId;
    Suggestion.Text := AText;
    // FR-093: every suggestion is advisory and needs the normal approval path.
    Suggestion.Advisory := True;
    Suggestion.RequiresApproval := True;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Suggestion;
  end;

begin
  Result := nil;
  GradeEvent(AEvent, AEvents, Grade, Reason);

  if IsAdvisoryGrade(Grade) then
    Add('user_confirm', '',
      'Event came from an inference trigger; confirm it by hand before it is ' +
      'used as context.');

  if not ParseSnapshots(AEvent.FieldSnapshotsJson, Snapshots) then
  begin
    Add('capture_again', '',
      'No field snapshot in this event window; capture the field again so the ' +
      'change can be attributed.');
    Exit;
  end;
  if Length(Snapshots) = 0 then
  begin
    Add('capture_again', '',
      'Event window contains no field snapshots; capture the field again.');
    Exit;
  end;

  FieldIds := CollectFieldIds(Snapshots);
  for I := 0 to High(FieldIds) do
  begin
    if I >= CeaMaxSuggestedFields then
      Break;
    if CorrelateField(AEvents, FieldIds[I], Trend).Failed then
    begin
      Add('capture_again', FieldIds[I],
        'Field was captured once only; capture it again after a known in-game ' +
        'change to confirm it tracks the value.');
      Continue;
    end;
    if Trend.EventCount < 2 then
      Add('compare_events', FieldIds[I],
        'Field appears in one event only; record a second event with the same ' +
        'field to compare.');
    if (Trend.SampleCount > 1) and (Trend.ChangeCount = 0) then
      Add('reject_mapping', FieldIds[I],
        'Field never changed across the observed events; the mapping may ' +
        'point at a constant rather than the displayed value.');
    if Trend.Numeric and (Trend.MinValue = Trend.MaxValue) and
       (Trend.SampleCount > 1) then
      Add('pointer_chain_check', FieldIds[I],
        'Numeric field is constant across samples; verify the address with a ' +
        'pointer chain before trusting it after a restart.');
    Add('aob_uniqueness', FieldIds[I],
      'Before using this field as a write anchor, scan for a unique byte ' +
      'pattern around it; an ambiguous signature must not be written.');
  end;

  if Length(Result) = 0 then
    Add('confirm_mapping', '',
      'Evidence looks consistent; ask the operator to confirm the mapping ' +
      'before the field is used for anything but display.');
end;

function TCEAEventAnalysisService.Analyze(const AEvent: TCEAEventPackage;
  const AEvents: TCEAEventPackageArray; const AFieldId: string;
  out AAnalysis: TCEAEventAnalysis): TCEAResult;
var
  Digest: string;
  Grade: TCEAEvidenceGrade;
  Reason: string;
begin
  FillChar(AAnalysis, SizeOf(AAnalysis), 0);
  Result := BuildDigest(AEvent, AEvents, Digest);
  if Result.Failed then
    Exit;
  AAnalysis.EventId := AEvent.EventId;
  AAnalysis.DigestJson := Digest;
  Result := GradeEvent(AEvent, AEvents, Grade, Reason);
  if Result.Failed then
    Exit;
  AAnalysis.Grade := Grade;
  AAnalysis.GradeReason := Reason;
  if Trim(AFieldId) <> '' then
    AAnalysis.HasTrend := not CorrelateField(AEvents, AFieldId,
      AAnalysis.Trend).Failed;
  AAnalysis.Suggestions := SuggestVerification(AEvent, AEvents);
  AAnalysis.CloudUsed := False;
  Result := TCEAResult.Ok('{"event_id":"' +
    JsonEscapeBytes(UTF8String(AAnalysis.EventId)) +
    '","grade":"' + EvidenceGradeText(AAnalysis.Grade) +
    '","grade_reason":"' + AAnalysis.GradeReason +
    '","digest":' + AAnalysis.DigestJson +
    ',"has_trend":' + JsonBool(AAnalysis.HasTrend) +
    ',"suggestion_count":' + IntToStr(Length(AAnalysis.Suggestions)) + '}');
end;

function TCEAEventAnalysisService.AskProvider(
  const AProvider: TCEALLMChatProvider;
  const AAnalysis: TCEAEventAnalysis;
  const AConsentToSendValues: Boolean;
  const AMaxOutputTokens: Cardinal;
  out AContent: UnicodeString): TCEAResult;
var
  Request: TCEALLMChatRequest;
  Prompt: UTF8String;
  Response: TCEAResult;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  AContent := '';
  if AProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));
  if not AAnalysis.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_analysis_invalid', '{}'));
  // FR-080: the digest carries captured memory values, so sending it needs
  // explicit consent on every call rather than a stored preference.
  if not AConsentToSendValues then
    Exit(TCEAResult.Error(rcApprovalRequired, 'cloud_consent_required',
      '{"approval_surface":"local_ui_only"}'));

  // UTF8String throughout: a plain `string` would transcode the fragments to
  // the local codepage and the model would receive mojibake.
  Prompt := '{"task":"analyze_game_event",' +
    '"rules":["separate observed facts from inference",' +
    '"never claim a memory address is safe to write",' +
    '"propose only next observations, not scans or writes",' +
    '"answer in JSON with keys summary, facts, inferences, next_steps"],' +
    '"event":' + UTF8String(AAnalysis.DigestJson) + '}';

  FillChar(Request, SizeOf(Request), 0);
  Request.UserPrompt := Utf8Text(Prompt);
  Request.MaxOutputTokens := AMaxOutputTokens;
  Request.Temperature := 0.2;
  Request.ResponseFormat := 'json_object';
  Response := AProvider.Chat(Request);
  if Response.Failed then
    Exit(Response);

  Data := nil;
  try
    try
      Data := GetJSON(Response.DataJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'event_analysis_envelope_invalid',
        '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'event_analysis_envelope_invalid', '{}'));
    Obj := TJSONObject(Data);
    // UnicodeString overload: a string overload would retag the UTF-8 bytes as
    // the local codepage and break the second parse.
    AContent := Obj.Get('content', UnicodeString(''));
    if Trim(string(AContent)) = '' then
      Exit(TCEAResult.Error(rcInvalidArgument, 'event_analysis_content_empty',
        '{}'));
  finally
    Data.Free;
  end;
  Result := TCEAResult.Ok(Utf8Text('{"event_id":"' +
    JsonEscapeBytes(UTF8String(AAnalysis.EventId)) +
    '","content":"' + JsonEscapeBytes(UTF8String(AContent)) +
    '","cloud_used":true}'));
end;

end.
