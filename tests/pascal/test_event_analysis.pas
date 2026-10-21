program test_event_analysis;

{$mode objfpc}{$H+}

// FR-090..FR-094: local event analysis must stay local, must not promote an
// inference trigger into evidence, and must never claim a write is safe.

uses
  SysUtils, cea_results, cea_event_types, cea_event_analysis_service,
  cea_llm_provider;

type
  // Records the prompt it was given so the test can assert what left the
  // process, and answers with a fixed envelope.
  TFakeProvider = class(TCEALLMChatProvider)
  public
    LastPrompt: string;
    LastResponseFormat: string;
    CallCount: Integer;
    Answer: string;
    function Chat(const ARequest: TCEALLMChatRequest): TCEAResult; override;
  end;

function TFakeProvider.Chat(const ARequest: TCEALLMChatRequest): TCEAResult;
begin
  Inc(CallCount);
  LastPrompt := ARequest.UserPrompt;
  LastResponseFormat := ARequest.ResponseFormat;
  Result := TCEAResult.Ok('{"provider_id":"fake","content":' + Answer + '}');
end;

var
  Service: TCEAEventAnalysisService;
  Provider: TFakeProvider;
  Events: TCEAEventPackageArray;
  Event: TCEAEventPackage;
  Analysis: TCEAEventAnalysis;
  Trend: TCEAFieldTrend;
  Grade: TCEAEvidenceGrade;
  Reason, Digest: string;
  Content: UnicodeString;
  Suggestions: TCEAVerificationSuggestionArray;
  R: TCEAResult;
  I: Integer;
  SawCaptureAgain, SawReject, SawAob, SawPointer: Boolean;

function MakeEvent(const AId, ATriggerSource: string;
  const AKind: TCEAEventTriggerKind; const ASnapshots: string;
  const ATags: string): TCEAEventPackage;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.EventId := AId;
  Result.TriggerKind := AKind;
  Result.TriggerSource := ATriggerSource;
  Result.StartAtMs := 1000;
  Result.EndAtMs := 3000;
  Result.ProcessIdentityId := 'process-test';
  Result.Epoch := 1;
  Result.FieldSnapshotsJson := ASnapshots;
  Result.RecordingRefsJson := '[]';
  Result.AnalysisState := eaUnanalyzed;
  Result.UserTagsJson := ATags;
  Result.CreatedAtMs := 2000;
end;

begin
  Service := TCEAEventAnalysisService.Create;
  Provider := TFakeProvider.Create;
  try
    // ---- 1. 摘要必须包含前后值与差值 ----
    Event := MakeEvent('event-00000001', 'field_change', etFieldChange,
      '[{"field_id":"player.gold","value_json":"100","captured_at_ms":1000},' +
      '{"field_id":"player.gold","value_json":"250","captured_at_ms":2000}]',
      '["boss"]');
    SetLength(Events, 1);
    Events[0] := Event;
    R := Service.BuildDigest(Event, Events, Digest);
    Assert(R.Code = rcOk, 'digest: ' + R.StableCode);
    Assert(Pos('"previous":"100"', Digest) > 0, 'digest previous value');
    Assert(Pos('"current":"250"', Digest) > 0, 'digest current value');
    Assert(Pos('"changed":true', Digest) > 0, 'digest changed flag');
    Assert(Pos('"direction":"increase"', Digest) > 0, 'digest direction');
    Assert(Pos('"delta":"150"', Digest) > 0, 'digest delta');
    Assert(Pos('"boss"', Digest) > 0, 'digest keeps tags');
    Assert(Pos('"related_event_count":0', Digest) > 0, 'digest related count');

    // 摘要本身必须是合法 JSON
    R := Service.Analyze(Event, Events, 'player.gold', Analysis);
    Assert(R.Code = rcOk, 'analyze: ' + R.StableCode);

    // ---- 2. 证据分级：推断触发不得升级为证据 ----
    Event := MakeEvent('event-00000002', 'ai_suggested', etAiSuggested,
      '[{"field_id":"player.gold","value_json":"100","captured_at_ms":1000}]',
      '[]');
    SetLength(Events, 1);
    Events[0] := Event;
    R := Service.GradeEvent(Event, Events, Grade, Reason);
    Assert(R.Code = rcOk, 'grade ai: ' + R.StableCode);
    Assert(Grade = egVisualInference, 'ai trigger stays inference');
    Assert(Reason = 'advisory_trigger', 'ai reason, got ' + Reason);
    Assert(IsAdvisoryGrade(Grade), 'advisory grade');
    Assert(not IsWriteJustifyingGrade(Grade), 'inference cannot justify write');

    // 用户标记 -> user_confirmed
    Event := MakeEvent('event-00000003', 'user_mark', etUserMark,
      '[{"field_id":"player.gold","value_json":"100","captured_at_ms":1000}]',
      '[]');
    SetLength(Events, 1);
    Events[0] := Event;
    R := Service.GradeEvent(Event, Events, Grade, Reason);
    Assert(Grade = egUserConfirmed, 'user mark grade');
    Assert(Reason = 'operator_marked', 'user mark reason');
    Assert(IsWriteJustifyingGrade(Grade), 'user confirmation justifies');

    // 字段变化 + 另一事件也观测到同一字段 -> repeated_verification
    Event := MakeEvent('event-00000004', 'field_change', etFieldChange,
      '[{"field_id":"player.gold","value_json":"100","captured_at_ms":1000},' +
      '{"field_id":"player.gold","value_json":"250","captured_at_ms":2000}]',
      '[]');
    SetLength(Events, 2);
    Events[0] := Event;
    Events[1] := MakeEvent('event-00000005', 'field_change', etFieldChange,
      '[{"field_id":"player.gold","value_json":"300","captured_at_ms":3000}]',
      '[]');
    R := Service.GradeEvent(Event, Events, Grade, Reason);
    Assert(Grade = egRepeatedVerification, 'repeated grade');
    Assert(Reason = 'observed_in_every_supplied_event', 'repeated reason');

    // 只观测一次 -> direct_observation
    SetLength(Events, 1);
    Events[0] := Event;
    R := Service.GradeEvent(Event, Events, Grade, Reason);
    Assert(Grade = egDirectObservation, 'single event grade');
    Assert(Reason = 'captured_by_readonly_backend', 'single event reason');

    // ---- 3. 跨事件关联（FR-092）----
    SetLength(Events, 2);
    Events[0] := MakeEvent('event-00000006', 'field_change', etFieldChange,
      '[{"field_id":"player.gold","value_json":"100","captured_at_ms":1000},' +
      '{"field_id":"player.gold","value_json":"250","captured_at_ms":2000}]',
      '[]');
    Events[1] := MakeEvent('event-00000007', 'field_change', etFieldChange,
      '[{"field_id":"player.gold","value_json":"400","captured_at_ms":3000}]',
      '[]');
    R := Service.CorrelateField(Events, 'player.gold', Trend);
    Assert(R.Code = rcOk, 'correlate: ' + R.StableCode);
    Assert(Trend.SampleCount = 3, 'trend samples, got ' +
      IntToStr(Trend.SampleCount));
    Assert(Trend.EventCount = 2, 'trend events');
    Assert(Trend.ChangeCount = 2, 'trend changes');
    Assert(Trend.Numeric, 'trend numeric');
    Assert(Trend.FirstValueJson = '100', 'trend first');
    Assert(Trend.LastValueJson = '400', 'trend last');
    Assert(Trend.MinValue = 100, 'trend min');
    Assert(Trend.MaxValue = 400, 'trend max');
    Assert(Trend.Direction = 'increase', 'trend direction');

    // 未观测过的字段必须报错，而不是返回空趋势
    R := Service.CorrelateField(Events, 'player.unknown', Trend);
    Assert(R.Code = rcUnknown, 'unknown field code');
    Assert(R.StableCode = 'event_field_not_observed', 'unknown field stable code');

    // 恒定值：变化次数为 0
    SetLength(Events, 1);
    Events[0] := MakeEvent('event-00000008', 'field_change', etFieldChange,
      '[{"field_id":"player.maxhp","value_json":"100","captured_at_ms":1000},' +
      '{"field_id":"player.maxhp","value_json":"100","captured_at_ms":2000}]',
      '[]');
    R := Service.CorrelateField(Events, 'player.maxhp', Trend);
    Assert(R.Code = rcOk, 'constant correlate');
    Assert(Trend.ChangeCount = 0, 'constant has no change');
    Assert(Trend.MinValue = Trend.MaxValue, 'constant min=max');

    // ---- 4. 建议必须全部是 advisory 且需审批（FR-093）----
    Suggestions := Service.SuggestVerification(Events[0], Events);
    Assert(Length(Suggestions) > 0, 'suggestions produced');
    SawCaptureAgain := False;
    SawReject := False;
    SawAob := False;
    SawPointer := False;
    for I := 0 to High(Suggestions) do
    begin
      Assert(Suggestions[I].IsValid, 'suggestion valid');
      Assert(Suggestions[I].Advisory, 'suggestion is advisory');
      Assert(Suggestions[I].RequiresApproval, 'suggestion needs approval');
      if Suggestions[I].Kind = 'capture_again' then SawCaptureAgain := True;
      if Suggestions[I].Kind = 'reject_mapping' then SawReject := True;
      if Suggestions[I].Kind = 'aob_uniqueness' then SawAob := True;
      if Suggestions[I].Kind = 'pointer_chain_check' then SawPointer := True;
    end;
    Assert(SawReject, 'constant field suggests reject_mapping');
    Assert(SawAob, 'always suggests aob_uniqueness');
    Assert(SawPointer, 'constant numeric suggests pointer_chain_check');
    Assert(not SawCaptureAgain, 'two samples do not suggest capture_again');

    // 建议 ID 唯一
    if Length(Suggestions) > 1 then
      Assert(Suggestions[0].SuggestionId <> Suggestions[1].SuggestionId,
        'suggestion ids unique');

    // ---- 5. 未授权不得把值送出机器（FR-080）----
    SetLength(Events, 1);
    Events[0] := MakeEvent('event-00000009', 'field_change', etFieldChange,
      '[{"field_id":"player.gold","value_json":"100","captured_at_ms":1000}]',
      '[]');
    R := Service.Analyze(Events[0], Events, 'player.gold', Analysis);
    Assert(R.Code = rcOk, 'analyze for provider');
    Provider.Answer := '"{\"summary\":\"ok\"}"';

    R := Service.AskProvider(Provider, Analysis, False, 512, Content);
    Assert(R.Code = rcApprovalRequired, 'consent required code');
    Assert(R.StableCode = 'cloud_consent_required', 'consent stable code');
    Assert(Pos('local_ui_only', R.DataJson) > 0, 'approval surface');
    Assert(Provider.CallCount = 0, 'provider must not be called without consent');

    // 授权后才外发，且提示词里必须带“不得声称地址可写”的约束
    R := Service.AskProvider(Provider, Analysis, True, 512, Content);
    Assert(R.Code = rcOk, 'provider ok: ' + R.StableCode);
    Assert(Provider.CallCount = 1, 'provider called once');
    Assert(Provider.LastResponseFormat = 'json_object', 'json mode requested');
    Assert(Pos('never claim a memory address is safe to write',
      Provider.LastPrompt) > 0, 'prompt carries write-safety rule');
    Assert(Pos('player.gold', Provider.LastPrompt) > 0, 'prompt carries digest');
    Assert(Content <> '', 'content returned');
    // 未配置 provider 时必须 fail closed
    R := Service.AskProvider(nil, Analysis, True, 512, Content);
    Assert(R.Code = rcConflict, 'nil provider code');
    Assert(R.StableCode = 'llm_not_configured', 'nil provider stable code');

    // ---- 6. 非法输入 ----
    FillChar(Event, SizeOf(Event), 0);
    R := Service.BuildDigest(Event, Events, Digest);
    Assert(R.Code = rcInvalidArgument, 'invalid event code');
    Assert(R.StableCode = 'event_invalid', 'invalid event stable code');

    Event := MakeEvent('event-00000010', 'field_change', etFieldChange,
      'not-json', '[]');
    R := Service.BuildDigest(Event, Events, Digest);
    Assert(R.Code = rcInvalidArgument, 'bad snapshots code');
    Assert(R.StableCode = 'event_snapshots_invalid', 'bad snapshots stable code');

    R := Service.CorrelateField(Events, '', Trend);
    Assert(R.Code = rcInvalidArgument, 'empty field code');
    Assert(R.StableCode = 'event_field_required', 'empty field stable code');

    // 空快照事件仍要能分析，并给出 capture_again
    Event := MakeEvent('event-00000011', 'field_change', etFieldChange, '[]', '[]');
    SetLength(Events, 1);
    Events[0] := Event;
    Suggestions := Service.SuggestVerification(Event, Events);
    Assert(Length(Suggestions) = 1, 'one suggestion for empty event');
    Assert(Suggestions[0].Kind = 'capture_again', 'empty event capture_again');
  finally
    Provider.Free;
    Service.Free;
  end;

  WriteLn('EVENT_ANALYSIS=PASS');
end.
