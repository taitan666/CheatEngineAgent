program test_discovery_round;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, cea_results, cea_discovery_round;

procedure Fail(const AMessage: string);
begin
  WriteLn('DISCOVERY_ROUND=FAIL ', AMessage);
  Halt(1);
end;

procedure Check(const AValue: Boolean; const AMessage: string);
begin
  if not AValue then Fail(AMessage);
end;

var
  Service: TCEADiscoveryRoundService;
  Round, Got, Active: TCEADiscoveryRound;
  Rounds: TCEADiscoveryRoundArray;
  R: TCEAResult;
  Kind: TCEADiscoveryRoundKind;
  State: TCEADiscoveryRoundState;
  ParsedKind: TCEADiscoveryRoundKind;
  ParsedState: TCEADiscoveryRoundState;
  I: Integer;
  ActiveCount: Integer;

begin
  Service := TCEADiscoveryRoundService.Create;
  try
    { 1. 缺目的/操作/预期/时间戳都必须被拒——预期写不出来就不该开这一轮。 }
    R := Service.PlanRound(drkScan, '', 'dword 扫描 100', '血量变成 90', '', '2026-10-21T00:00:00Z', Round);
    Check((R.Code = rcInvalidArgument) and (R.StableCode = 'discovery_purpose_required'),
      'purpose is required: ' + R.StableCode);
    R := Service.PlanRound(drkScan, '找血量', '  ', '血量变成 90', '', '2026-10-21T00:00:00Z', Round);
    Check(R.StableCode = 'discovery_operation_required', 'operation is required');
    R := Service.PlanRound(drkScan, '找血量', 'dword 扫描 100', '', '', '2026-10-21T00:00:00Z', Round);
    Check(R.StableCode = 'discovery_expected_observation_required',
      'expected observation is required: ' + R.StableCode);
    R := Service.PlanRound(drkScan, '找血量', 'dword 扫描 100', '血量变成 90', '', '', Round);
    Check(R.StableCode = 'discovery_timestamp_required', 'timestamp is required');
    Check(Service.Count = 0, 'rejected plans are not stored');

    { 2. 正常声明一轮。 }
    R := Service.PlanRound(drkScan, '找血量', 'dword 扫描 100',
      '血量变成 90', 'player.hp', '2026-10-21T00:00:00Z', Round);
    Check(R.Code = rcOk, 'plan round: ' + R.StableCode);
    Check(Round.RoundId = 'round-00000001', 'first round id: ' + Round.RoundId);
    Check(Round.Sequence = 1, 'sequence is one-based');
    Check(Round.State = drsPlanned, 'planned state');
    Check(Round.IsValid, 'planned round is valid');
    Check(Round.Kind = drkScan, 'kind roundtrip');
    Check(Round.FieldId = 'player.hp', 'field id kept');
    Check(Service.Count = 1, 'one round stored');

    { 3. 已有未收尾轮次时不能再开——否则预期可以事后补。 }
    R := Service.PlanRound(drkRefine, '缩小范围', 'dword 扫描 90',
      '结果集缩小到个位数', 'player.hp', '2026-10-21T00:00:01Z', Got);
    Check((R.Code = rcConflict) and (R.StableCode = 'discovery_round_active'),
      'a second active round is refused: ' + R.StableCode);
    Check(Pos('"active_round_id":"round-00000001"', R.DataJson) > 0,
      'the conflict names the active round: ' + R.DataJson);
    Check(Service.Count = 1, 'refused plan is not stored');

    { 4. CurrentRound 能找到它。 }
    Check(Service.CurrentRound(Active), 'current round exists');
    Check(Active.RoundId = 'round-00000001', 'current round id');

    { 5. 收尾必须给出观察结果，且一致性由操作者判定。 }
    R := Service.CompleteRound('round-00000001', '', True, '2026-10-21T00:01:00Z', Got);
    Check(R.StableCode = 'discovery_outcome_required', 'outcome is required');
    R := Service.CompleteRound('round-does-not-exist', '看到 90', True,
      '2026-10-21T00:01:00Z', Got);
    Check((R.Code = rcUnknown) and (R.StableCode = 'discovery_round_not_found'),
      'unknown round: ' + R.StableCode);
    R := Service.CompleteRound('round-00000001', '血量从 100 变成 90，剩 3 个候选',
      True, '2026-10-21T00:01:00Z', Got);
    Check(R.Code = rcOk, 'complete round: ' + R.StableCode);
    Check(Got.State = drsCompleted, 'completed state');
    Check(Got.MatchedExpectation, 'operator said it matched');
    Check(Got.CompletedAt = '2026-10-21T00:01:00Z', 'completion time kept');
    Check(Pos('剩 3 个候选', Got.ObservedOutcome) > 0, 'outcome kept verbatim');
    Check(not Service.CurrentRound(Active), 'no active round after completion');

    { 6. 已收尾的轮次不能再收尾（状态机单向）。 }
    R := Service.CompleteRound('round-00000001', '又看了一次', True,
      '2026-10-21T00:02:00Z', Got);
    Check((R.Code = rcConflict) and (R.StableCode = 'discovery_round_not_planned'),
      'completed round cannot be completed again: ' + R.StableCode);

    { 7. 放弃必须有理由，且仍然是「试过什么」的记录。 }
    R := Service.PlanRound(drkCompare, '确认是同一个字段', '连续两次采集对比',
      '两次读到同一个值', 'player.hp', '2026-10-21T00:03:00Z', Round);
    Check(R.Code = rcOk, 'plan second round: ' + R.StableCode);
    Check(Round.RoundId = 'round-00000002', 'sequence continues: ' + Round.RoundId);
    R := Service.AbandonRound('round-00000002', '', '2026-10-21T00:04:00Z', Got);
    Check(R.StableCode = 'discovery_abandon_reason_required', 'reason is required');
    R := Service.AbandonRound('round-00000002', '游戏被关掉了',
      '2026-10-21T00:04:00Z', Got);
    Check(R.Code = rcOk, 'abandon round: ' + R.StableCode);
    Check(Got.State = drsAbandoned, 'abandoned state');
    Check(not Got.MatchedExpectation, 'abandoned round never claims a match');
    Check(Pos('游戏被关掉了', Got.ObservedOutcome) > 0, 'abandon reason kept');
    R := Service.CompleteRound('round-00000002', '其实看到了', True,
      '2026-10-21T00:05:00Z', Got);
    Check(R.StableCode = 'discovery_round_not_planned',
      'abandoned round cannot be completed');

    { 8. 字段长度上限：意图是短句，不是攻略。 }
    R := Service.PlanRound(drkScan, StringOfChar('a', CeaDiscoveryPurposeMaxChars + 1),
      'op', 'exp', '', '2026-10-21T00:06:00Z', Round);
    Check(R.StableCode = 'discovery_purpose_too_long', 'purpose cap enforced');
    R := Service.PlanRound(drkScan, 'p', 'op', 'exp', '', '2026-10-21T00:06:00Z', Round);
    Check(R.Code = rcOk, 'plan third round: ' + R.StableCode);
    R := Service.CompleteRound(Round.RoundId,
      StringOfChar('x', CeaDiscoveryOutcomeMaxChars + 1), True,
      '2026-10-21T00:07:00Z', Got);
    Check(R.StableCode = 'discovery_outcome_too_long', 'outcome cap enforced');
    R := Service.CompleteRound(Round.RoundId, 'ok', False,
      '2026-10-21T00:07:00Z', Got);
    Check(R.Code = rcOk, 'close third round');
    Check(not Got.MatchedExpectation, 'mismatch is representable');

    { 9. 列表按时间顺序返回，limit 取最近若干条。 }
    R := Service.ListRounds(50, Rounds);
    Check(R.Code = rcOk, 'list rounds');
    Check(Length(Rounds) = 3, 'three rounds listed');
    Check(Rounds[0].RoundId = 'round-00000001', 'list is chronological');
    Check(Rounds[2].RoundId = 'round-00000003', 'last round is last');
    R := Service.ListRounds(2, Rounds);
    Check(Length(Rounds) = 2, 'limit honoured');
    Check(Rounds[0].RoundId = 'round-00000002', 'limit keeps the newest tail');
    R := Service.ListRounds(0, Rounds);
    Check(Length(Rounds) = 3, 'zero limit falls back to the default');
    Check(Service.Count = 3, 'count matches');

    { 10. 每种 kind / state 的文本契约都能往返。 }
    for Kind := Low(TCEADiscoveryRoundKind) to High(TCEADiscoveryRoundKind) do
    begin
      Check(TryParseDiscoveryRoundKind(DiscoveryRoundKindText(Kind), ParsedKind),
        'kind roundtrip: ' + DiscoveryRoundKindText(Kind));
      Check(ParsedKind = Kind, 'kind parsed value');
    end;
    for State := Low(TCEADiscoveryRoundState) to High(TCEADiscoveryRoundState) do
    begin
      Check(TryParseDiscoveryRoundState(DiscoveryRoundStateText(State), ParsedState),
        'state roundtrip: ' + DiscoveryRoundStateText(State));
      Check(ParsedState = State, 'state parsed value');
    end;
    Check(not TryParseDiscoveryRoundKind('guessing', ParsedKind), 'unknown kind rejected');
    Check(not TryParseDiscoveryRoundState('done', ParsedState), 'unknown state rejected');

    { 11. Reset 清空并重置序号（轮次是会话内计划）。 }
    Service.Reset;
    Check(Service.Count = 0, 'reset clears rounds');
    R := Service.PlanRound(drkWrite, '写入并重读', '写入 90 后重读',
      '重读得到 90', 'player.hp', '2026-10-21T00:08:00Z', Round);
    Check(R.Code = rcOk, 'plan after reset: ' + R.StableCode);
    Check(Round.RoundId = 'round-00000001', 'sequence restarts after reset');

    { 12. 多个已收尾轮次不会让 CurrentRound 误报。 }
    ActiveCount := 0;
    for I := 0 to Service.Count - 1 do
      if Service.CurrentRound(Active) then
      begin
        Inc(ActiveCount);
        Break;
      end;
    Check(ActiveCount = 1, 'exactly one active round while one is planned');
  finally
    Service.Free;
  end;
  WriteLn('DISCOVERY_ROUND=PASS');
end.
