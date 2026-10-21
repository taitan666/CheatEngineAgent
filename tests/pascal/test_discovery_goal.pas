program test_discovery_goal;

{$mode objfpc}{$H+}
{$codepage utf8}

// FR-050: the operator describes the field they want in their own words.
// The goal is intent, never evidence: accepting one must not authorise a scan,
// a write, or even a claim that a model's hints were right.

uses
  SysUtils, fpjson, jsonparser, cea_results, cea_llm_provider, cea_discovery_goal;

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
  // The real providers answer with a content STRING that itself holds JSON.
  // StringToJSONString escapes but does not quote, so the quotes are added here.
  Result := TCEAResult.Ok('{"provider_id":"fake","content":"' +
    StringToJSONString(Answer) + '"}');
end;

var
  Service: TCEADiscoveryGoalService;
  Provider: TFakeProvider;
  Goal, Got: TCEADiscoveryGoal;
  Goals: TCEADiscoveryGoalArray;
  R: TCEAResult;
  FieldId, ValueType, Behavior, Rationale: string;
  FirstGoalId, NewestGoalId: string;

function BytesHex(const AValue: RawByteString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AValue) do
    Result := Result + IntToHex(Byte(AValue[I]), 2);
end;

begin
  Service := TCEADiscoveryGoalService.Create;
  Provider := TFakeProvider.Create;
  try
    // ---- an operator goal needs their words, not a value type -------------
    R := Service.ProposeFromOperator('', '', '', '', '2026-10-21T00:00:00Z', Goal);
    Assert(R.Failed, 'empty description is rejected');
    Assert(R.StableCode = 'discovery_goal_description_required',
      'empty description code: ' + R.StableCode);

    // Whitespace is not a description either.
    R := Service.ProposeFromOperator('   ', '', '', '', '2026-10-21T00:00:00Z', Goal);
    Assert(R.Failed, 'whitespace-only description is rejected');

    R := Service.ProposeFromOperator('找金币', '', '', '', '', Goal);
    Assert(R.Failed, 'missing timestamp is rejected');
    Assert(R.StableCode = 'discovery_goal_timestamp_required',
      'timestamp code: ' + R.StableCode);

    // ---- operator hints are validated, never silently corrected -----------
    R := Service.ProposeFromOperator('找金币', 'player.gold', 'dword', 'increase',
      '2026-10-21T00:00:00Z', Goal);
    Assert(not R.Failed, 'operator goal accepted: ' + R.StableCode);
    Assert(Goal.IsValid, 'operator goal is valid');
    Assert(Goal.Source = dgsOperator, 'source is operator');
    Assert(not Goal.Advisory, 'operator goal is not advisory');
    Assert(Goal.State = dgoProposed, 'operator goal starts proposed');
    // The operator's words are stored verbatim: bytes must match the literal.
    Assert(BytesHex(Goal.Description) = 'E689BEE98791E5B881',
      'description stored verbatim: ' + BytesHex(Goal.Description));
    Assert(Goal.FieldIdHint = 'player.gold', 'field hint kept');
    Assert(Goal.ValueTypeHint = 'dword', 'value type kept');
    Assert(Goal.BehaviorHint = 'increase', 'behaviour kept');
    Assert(Pos('"state":"proposed"', R.DataJson) > 0, 'proposal state: ' + R.DataJson);
    FirstGoalId := Goal.GoalId;

    R := Service.ProposeFromOperator('找血量', 'Player.Health', '', '',
      '2026-10-21T00:00:01Z', Goal);
    Assert(R.Failed, 'uppercase field id rejected');
    Assert(R.StableCode = 'discovery_goal_field_id_invalid',
      'field id code: ' + R.StableCode);

    R := Service.ProposeFromOperator('找血量', 'player.health', 'float', '',
      '2026-10-21T00:00:01Z', Goal);
    Assert(R.Failed, 'unsupported value type rejected');
    Assert(R.StableCode = 'discovery_goal_value_type_invalid',
      'value type code: ' + R.StableCode);

    R := Service.ProposeFromOperator('找血量', 'player.health', 'dword', 'oscillating',
      '2026-10-21T00:00:01Z', Goal);
    Assert(R.Failed, 'unsupported behaviour rejected');
    Assert(R.StableCode = 'discovery_goal_behavior_invalid',
      'behaviour code: ' + R.StableCode);

    // Over-long description: an essay is not a goal.
    R := Service.ProposeFromOperator(
      StringOfChar('x', CeaDiscoveryGoalDescriptionMaxChars + 1), '', '', '',
      '2026-10-21T00:00:02Z', Goal);
    Assert(R.Failed, 'over-long description rejected');
    Assert(R.StableCode = 'discovery_goal_description_too_long',
      'too long code: ' + R.StableCode);

    // ---- accepting is not agreeing that the hints were right --------------
    R := Service.Accept('', '2026-10-21T00:01:00Z', Goal);
    Assert(R.Failed, 'empty goal id rejected');
    Assert(R.StableCode = 'discovery_goal_id_required', 'id code: ' + R.StableCode);

    R := Service.Accept('goal-does-not-exist', '2026-10-21T00:01:00Z', Goal);
    Assert(R.Failed, 'unknown goal rejected');
    Assert(R.StableCode = 'discovery_goal_not_found', 'not found code: ' + R.StableCode);

    Assert(not Service.CurrentGoal(Got), 'nothing accepted yet');
    R := Service.Accept(FirstGoalId, '2026-10-21T00:01:00Z', Goal);
    Assert(not R.Failed, 'accept works: ' + R.StableCode);
    Assert(Goal.State = dgoAccepted, 'goal accepted');
    Assert(Goal.DecidedAt = '2026-10-21T00:01:00Z', 'decision timestamp kept');
    Assert(Service.CurrentGoal(Got), 'a current goal exists');
    Assert(Got.GoalId = FirstGoalId, 'current goal is the accepted one');

    R := Service.Accept(FirstGoalId, '2026-10-21T00:02:00Z', Goal);
    Assert(R.Failed, 'accepting twice rejected');
    Assert(R.StableCode = 'discovery_goal_already_accepted',
      'already accepted code: ' + R.StableCode);

    // ---- one active goal: a second acceptance supersedes the first --------
    R := Service.ProposeFromOperator('找蓝量', 'player.mana', 'dword', 'decrease',
      '2026-10-21T00:03:00Z', Goal);
    Assert(not R.Failed, 'second goal proposed: ' + R.StableCode);
    R := Service.Accept(Goal.GoalId, '2026-10-21T00:04:00Z', Got);
    Assert(not R.Failed, 'second goal accepted: ' + R.StableCode);
    R := Service.GetGoal(FirstGoalId, Goal);
    Assert(not R.Failed, 'first goal still readable: ' + R.StableCode);
    Assert(Goal.State = dgoSuperseded, 'first goal superseded, got ' +
      DiscoveryGoalStateText(Goal.State));
    Assert(Goal.DecidedAt = '2026-10-21T00:04:00Z',
      'supersede timestamp is the moment of replacement');

    // ---- rejection needs a reason ----------------------------------------
    R := Service.ProposeFromOperator('找经验值', '', '', '',
      '2026-10-21T00:05:00Z', Goal);
    Assert(not R.Failed, 'third goal proposed: ' + R.StableCode);
    R := Service.Reject(Goal.GoalId, '', '2026-10-21T00:06:00Z', Got);
    Assert(R.Failed, 'rejection without a reason is rejected');
    Assert(R.StableCode = 'discovery_goal_reject_reason_required',
      'reason code: ' + R.StableCode);
    R := Service.Reject(Goal.GoalId, '这个词太笼统，先确定是经验还是等级',
      '2026-10-21T00:06:00Z', Got);
    Assert(not R.Failed, 'rejection with reason works: ' + R.StableCode);
    Assert(Got.State = dgoRejected, 'goal rejected');
    Assert(BytesHex(Got.RejectReason) = 'E8BF99E4B8AAE8AF8DE5A4AAE7ACBCE7BB9FEFBC8CE58588E7A1AEE5AE9AE698AFE7BB8FE9AA8CE8BF98E698AFE7AD89E7BAA7',
      'reject reason stored verbatim: ' + BytesHex(Got.RejectReason));

    // A rejected goal cannot be accepted later; re-proposing is the way back,
    // because the operator's intent may have changed.
    R := Service.Accept(Got.GoalId, '2026-10-21T00:07:00Z', Goal);
    Assert(R.Failed, 'rejected goal cannot be accepted');
    Assert(R.StableCode = 'discovery_goal_not_proposed',
      'not proposed code: ' + R.StableCode);

    // ---- model-sourced goals stay advisory forever ------------------------
    Provider.Answer := '{"field_id_hint":"player.gold","value_type_hint":"dword",' +
      '"behavior_hint":"increase","rationale":"gold usually rises when picked up"}';
    R := Service.ProposeFromModel(nil, '找金币', 512, '2026-10-21T00:08:00Z', Goal);
    Assert(R.Failed, 'nil provider rejected');
    Assert(R.StableCode = 'llm_not_configured', 'provider code: ' + R.StableCode);

    R := Service.ProposeFromModel(Provider, '', 512, '2026-10-21T00:08:00Z', Goal);
    Assert(R.Failed, 'model path also requires a description');
    Assert(Provider.CallCount = 0, 'no call without a description');

    R := Service.ProposeFromModel(Provider, '找金币', 512, '2026-10-21T00:08:00Z', Goal);
    Assert(not R.Failed, 'model goal proposed: ' + R.StableCode);    Assert(Provider.CallCount = 1, 'model was called once');
    Assert(Provider.LastResponseFormat = 'json_object',
      'model must answer as JSON, got ' + Provider.LastResponseFormat);
    // The operator's words go out verbatim and are never rewritten by hints.
    Assert(BytesHex(Goal.Description) = 'E689BEE98791E5B881',
      'model path keeps the description verbatim: ' + BytesHex(Goal.Description));
    Assert(Goal.Source = dgsModel, 'source is model');
    Assert(Goal.Advisory, 'model goal is advisory');
    Assert(Goal.FieldIdHint = 'player.gold', 'model field hint kept');
    Assert(Goal.ValueTypeHint = 'dword', 'model value type kept');
    Assert(Goal.Rationale <> '', 'rationale kept for review');

    // Accepting a model goal takes ownership of the intent, not of the claim.
    R := Service.Accept(Goal.GoalId, '2026-10-21T00:09:00Z', Got);
    Assert(not R.Failed, 'model goal can be accepted: ' + R.StableCode);
    Assert(Got.Advisory, 'accepted model goal is still advisory');
    Assert(Got.State = dgoAccepted, 'model goal accepted');

    // ---- model hints are sanitised, not trusted --------------------------
    Provider.Answer := '{"field_id_hint":"Player Health","value_type_hint":"float",' +
      '"behavior_hint":"oscillating","rationale":"guess"}';
    R := Service.ProposeFromModel(Provider, '找血量', 512, '2026-10-21T00:10:00Z', Goal);
    Assert(not R.Failed, 'goal with bad hints still usable: ' + R.StableCode);
    Assert(Goal.FieldIdHint = '', 'malformed field id dropped');
    Assert(Goal.ValueTypeHint = '', 'unsupported value type dropped');
    Assert(Goal.BehaviorHint = 'unknown', 'unsupported behaviour falls back to unknown');
    Assert(Goal.Description <> '', 'description survives bad hints');
    NewestGoalId := Goal.GoalId;

    // A payload that is not an object is an error, not a goal with no hints.
    Provider.Answer := '[1,2,3]';
    R := Service.ProposeFromModel(Provider, '找血量', 512, '2026-10-21T00:11:00Z', Goal);
    Assert(R.Failed, 'non-object hints rejected');
    Assert(R.StableCode = 'discovery_goal_hints_invalid',
      'hints code: ' + R.StableCode);

    // ---- the pure sanitiser is testable without a provider ----------------
    R := SanitizeGoalHints('{"field_id_hint":"player.hp","value_type_hint":"DWORD",' +
      '"behavior_hint":"decrease"}', FieldId, ValueType, Behavior, Rationale);
    Assert(not R.Failed, 'sanitiser ok: ' + R.StableCode);
    Assert(FieldId = 'player.hp', 'sanitiser field id');
    Assert(ValueType = 'dword', 'sanitiser lowercases the value type');
    Assert(Behavior = 'decrease', 'sanitiser behaviour');
    Assert(Rationale = '', 'absent rationale is empty, not invented');

    R := SanitizeGoalHints('not json', FieldId, ValueType, Behavior, Rationale);
    Assert(R.Failed, 'sanitiser rejects non-JSON');
    Assert(R.StableCode = 'discovery_goal_hints_invalid',
      'sanitiser code: ' + R.StableCode);

    // ---- list, filter and limits -----------------------------------------
    // The failed proposal above reset Goal to its default, so the newest id has
    // to be remembered before that point rather than read back from Goal.
    R := Service.ListGoals(0, Goals);
    Assert(not R.Failed, 'list ok: ' + R.StableCode);
    Assert(Service.Count = 5, 'five goals exist, got ' + IntToStr(Service.Count));
    Assert(Length(Goals) = 5, 'default limit covers all five');
    Assert(Goals[Length(Goals) - 1].GoalId = NewestGoalId,
      'list is chronological, newest last');

    R := Service.ListGoals(2, Goals);
    Assert(Length(Goals) = 2, 'limit honoured');
    Assert(Goals[0].Sequence < Goals[1].Sequence, 'last two in order');

    R := Service.ListGoals(CeaDiscoveryGoalMaxLimit + 100, Goals);
    Assert(Length(Goals) = 5, 'limit clamps down to what exists');

    // ---- text contracts round-trip ---------------------------------------
    Assert(DiscoveryGoalSourceText(dgsModel) = 'model', 'source text');
    Assert(TryParseDiscoveryGoalSource('OPERATOR', Got.Source) and
      (Got.Source = dgsOperator), 'source parse is case-insensitive');
    Assert(not TryParseDiscoveryGoalSource('robot', Got.Source),
      'unknown source rejected');
    Assert(DiscoveryGoalStateText(dgoSuperseded) = 'superseded', 'state text');
    Assert(TryParseDiscoveryGoalState('rejected', Got.State) and
      (Got.State = dgoRejected), 'state parse');
    Assert(not TryParseDiscoveryGoalState('', Got.State), 'empty state rejected');

    Assert(IsSupportedGoalValueType('qword'), 'qword supported');
    Assert(not IsSupportedGoalValueType(''), 'empty value type is not a value type');
    Assert(IsSupportedGoalBehavior('unknown'), 'unknown behaviour supported');
    Assert(not IsSupportedGoalBehavior('spikes'), 'unknown word rejected');
    Assert(IsWellFormedGoalFieldId('a1.b_2'), 'dotted id allowed');
    Assert(not IsWellFormedGoalFieldId('a b'), 'space rejected');
    Assert(not IsWellFormedGoalFieldId('a-b'), 'hyphen rejected');

    // ---- reset clears the session ----------------------------------------
    Service.Reset;
    Assert(Service.Count = 0, 'reset clears goals');
    Assert(not Service.CurrentGoal(Got), 'reset clears the active goal');
    R := Service.ProposeFromOperator('找金币', '', '', '',
      '2026-10-21T00:12:00Z', Goal);
    Assert(not R.Failed, 'usable after reset: ' + R.StableCode);
    Assert(Goal.Sequence = 1, 'sequence restarts after reset, got ' +
      IntToStr(Goal.Sequence));

    WriteLn('DISCOVERY_GOAL=PASS');
  finally
    Provider.Free;
    Service.Free;
  end;
end.
