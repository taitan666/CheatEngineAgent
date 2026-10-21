unit cea_discovery_round;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

interface

uses
  SysUtils, cea_results;

type
  // FR-051 (PRD 6.6) 分轮验证：每一轮扫描或修改之前，必须先把「这一轮想干
  // 什么、具体怎么做、预期看到什么」写下来，并且展示给操作者。
  //
  // 为什么这不是形式主义：内存扫描本身永远会返回结果，问题在于结果有没有
  // 意义。没有预期就无从判断「这次变了」到底是找到了字段还是碰巧。把预期
  // 写在前面的唯一作用，是让事后能回答「当时我以为会看到 X，实际看到 Y」。
  //
  // 边界设计：
  //  - 轮次是会话内的计划，不落盘。持久事实在 FR-052 证据表和 FR-046 写入
  //    账本里；这里存的是「意图」，重启后旧意图本来就已失效，存下来反而会
  //    让下一轮误以为还有人没交代。
  //  - 同一时刻只允许一个未收尾的轮次。允许并行规划就等于允许「先扫了再
  //    补理由」，那样预期永远可以事后编。
  //  - MatchedExpectation 必须由操作者显式给出，不从数值推断：我们不知道
  //    「血量 100」对操作者意味着什么，替他判断等于伪造结论。
  TCEADiscoveryRoundKind = (
    drkScan,     // 首次扫描
    drkRefine,   // 缩小结果集
    drkCompare,  // 两次采集对比（不扫描）
    drkWrite     // 写入/验证
  );

  TCEADiscoveryRoundState = (
    drsPlanned,    // 已声明，尚未执行
    drsCompleted,  // 已执行并给出观察结果
    drsAbandoned   // 放弃（记录理由，仍是「试过什么」的证据）
  );

  TCEADiscoveryRound = record
    RoundId: string;          // 稳定标识 "round-XXXXXXXX"
    Sequence: Cardinal;       // 会话内单调递增
    Kind: TCEADiscoveryRoundKind;
    Purpose: string;          // 这一轮想达成什么
    Operation: string;        // 具体操作（扫描类型/值类型/目标字段等）
    ExpectedObservation: string;  // 预期看到什么
    FieldId: string;          // 可选：这一轮针对哪个字段
    State: TCEADiscoveryRoundState;
    ObservedOutcome: string;  // 实际发生了什么（完成时填）
    MatchedExpectation: Boolean;  // 是否与预期一致（操作者判定）
    CreatedAt: string;        // UTC ISO8601
    CompletedAt: string;
    function IsValid: Boolean;
  end;

  TCEADiscoveryRoundArray = array of TCEADiscoveryRound;

  // 轮次服务。没有存储后端：见上面的边界说明。
  TCEADiscoveryRoundService = class(TObject)
  private
    FRounds: array of TCEADiscoveryRound;
    FSequence: Cardinal;
    function IndexOf(const ARoundId: string): Integer;
    function BuildRound(const AKind: TCEADiscoveryRoundKind;
      const APurpose, AOperation, AExpectedObservation, AFieldId,
      ACreatedAt: string): TCEADiscoveryRound;
  public
    // 声明一轮。已有未收尾轮次时拒绝（不能「先扫后补理由」）。
    function PlanRound(const AKind: TCEADiscoveryRoundKind;
      const APurpose, AOperation, AExpectedObservation, AFieldId,
      ACreatedAt: string; out ARound: TCEADiscoveryRound): TCEAResult;
    // 收尾一轮：必须由操作者判定是否与预期一致。
    function CompleteRound(const ARoundId, AObservedOutcome: string;
      const AMatchedExpectation: Boolean; const ACompletedAt: string;
      out ARound: TCEADiscoveryRound): TCEAResult;
    // 放弃一轮：理由必填，否则「放弃」会变成不留痕迹的跳过。
    function AbandonRound(const ARoundId, AReason, ACompletedAt: string;
      out ARound: TCEADiscoveryRound): TCEAResult;
    // 当前未收尾的轮次；没有则返回 False。
    function CurrentRound(out ARound: TCEADiscoveryRound): Boolean;
    function GetRound(const ARoundId: string;
      out ARound: TCEADiscoveryRound): TCEAResult;
    function ListRounds(const ALimit: Cardinal;
      out ARounds: TCEADiscoveryRoundArray): TCEAResult;
    function Count: Cardinal;
    // 结束会话时清空（轮次是会话内的计划）。
    procedure Reset;
  end;

function DiscoveryRoundKindText(const AKind: TCEADiscoveryRoundKind): string;
function TryParseDiscoveryRoundKind(const AText: string;
  out AKind: TCEADiscoveryRoundKind): Boolean;
function DiscoveryRoundStateText(const AState: TCEADiscoveryRoundState): string;
function TryParseDiscoveryRoundState(const AText: string;
  out AState: TCEADiscoveryRoundState): Boolean;

const
  // 三个字段都是给人看的短句，不是文档。上限防止把整篇攻略塞进意图，
  // 也防止模型输出被原样当成「目的」。
  CeaDiscoveryPurposeMaxChars = 400;
  CeaDiscoveryOperationMaxChars = 400;
  CeaDiscoveryExpectedMaxChars = 400;
  CeaDiscoveryOutcomeMaxChars = 800;
  CeaDiscoveryReasonMaxChars = 400;
  CeaDiscoveryRoundDefaultLimit = 50;
  CeaDiscoveryRoundMaxLimit = 500;

implementation

function DiscoveryRoundKindText(const AKind: TCEADiscoveryRoundKind): string;
begin
  case AKind of
    drkScan: Result := 'scan';
    drkRefine: Result := 'refine';
    drkCompare: Result := 'compare';
    drkWrite: Result := 'write';
  end;
end;

function TryParseDiscoveryRoundKind(const AText: string;
  out AKind: TCEADiscoveryRoundKind): Boolean;
var
  K: TCEADiscoveryRoundKind;
begin
  for K := Low(TCEADiscoveryRoundKind) to High(TCEADiscoveryRoundKind) do
    if DiscoveryRoundKindText(K) = AText then
    begin
      AKind := K;
      Exit(True);
    end;
  Result := False;
end;

function DiscoveryRoundStateText(const AState: TCEADiscoveryRoundState): string;
begin
  case AState of
    drsPlanned: Result := 'planned';
    drsCompleted: Result := 'completed';
    drsAbandoned: Result := 'abandoned';
  end;
end;

function TryParseDiscoveryRoundState(const AText: string;
  out AState: TCEADiscoveryRoundState): Boolean;
var
  S: TCEADiscoveryRoundState;
begin
  for S := Low(TCEADiscoveryRoundState) to High(TCEADiscoveryRoundState) do
    if DiscoveryRoundStateText(S) = AText then
    begin
      AState := S;
      Exit(True);
    end;
  Result := False;
end;

function TCEADiscoveryRound.IsValid: Boolean;
begin
  Result := (RoundId <> '') and (Purpose <> '') and (Operation <> '') and
    (ExpectedObservation <> '') and (CreatedAt <> '');
end;

function TCEADiscoveryRoundService.IndexOf(const ARoundId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FRounds) do
    if FRounds[I].RoundId = ARoundId then
      Exit(I);
  Result := -1;
end;

function TCEADiscoveryRoundService.BuildRound(
  const AKind: TCEADiscoveryRoundKind;
  const APurpose, AOperation, AExpectedObservation, AFieldId,
  ACreatedAt: string): TCEADiscoveryRound;
begin
  Result := Default(TCEADiscoveryRound);
  Result.RoundId := 'round-' + IntToHex(FSequence, 8);
  Result.Sequence := FSequence;
  Result.Kind := AKind;
  Result.Purpose := APurpose;
  Result.Operation := AOperation;
  Result.ExpectedObservation := AExpectedObservation;
  Result.FieldId := AFieldId;
  Result.State := drsPlanned;
  Result.CreatedAt := ACreatedAt;
end;

function TCEADiscoveryRoundService.PlanRound(
  const AKind: TCEADiscoveryRoundKind;
  const APurpose, AOperation, AExpectedObservation, AFieldId,
  ACreatedAt: string; out ARound: TCEADiscoveryRound): TCEAResult;
var
  Active: TCEADiscoveryRound;
  Planned: TCEADiscoveryRound;
begin
  ARound := Default(TCEADiscoveryRound);
  if Trim(APurpose) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_purpose_required', '{}'));
  if Trim(AOperation) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_operation_required', '{}'));
  if Trim(AExpectedObservation) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_expected_observation_required', '{}'));
  if Trim(ACreatedAt) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_timestamp_required', '{}'));
  if Length(APurpose) > CeaDiscoveryPurposeMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_purpose_too_long', '{}'));
  if Length(AOperation) > CeaDiscoveryOperationMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_operation_too_long', '{}'));
  if Length(AExpectedObservation) > CeaDiscoveryExpectedMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_expected_observation_too_long', '{}'));
  if CurrentRound(Active) then
    Exit(TCEAResult.Error(rcConflict, 'discovery_round_active',
      '{"active_round_id":"' + Active.RoundId + '"}'));
  Inc(FSequence);
  Planned := BuildRound(AKind, Trim(APurpose), Trim(AOperation),
    Trim(AExpectedObservation), Trim(AFieldId), Trim(ACreatedAt));
  SetLength(FRounds, Length(FRounds) + 1);
  FRounds[High(FRounds)] := Planned;
  ARound := Planned;
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryRoundService.CompleteRound(const ARoundId,
  AObservedOutcome: string; const AMatchedExpectation: Boolean;
  const ACompletedAt: string; out ARound: TCEADiscoveryRound): TCEAResult;
var
  Index: Integer;
begin
  ARound := Default(TCEADiscoveryRound);
  if Trim(ARoundId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_round_id_required', '{}'));
  if Trim(AObservedOutcome) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_outcome_required', '{}'));
  if Length(AObservedOutcome) > CeaDiscoveryOutcomeMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_outcome_too_long', '{}'));
  if Trim(ACompletedAt) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_timestamp_required', '{}'));
  Index := IndexOf(ARoundId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'discovery_round_not_found', '{}'));
  if FRounds[Index].State <> drsPlanned then
    Exit(TCEAResult.Error(rcConflict, 'discovery_round_not_planned', '{}'));
  FRounds[Index].State := drsCompleted;
  FRounds[Index].ObservedOutcome := Trim(AObservedOutcome);
  FRounds[Index].MatchedExpectation := AMatchedExpectation;
  FRounds[Index].CompletedAt := Trim(ACompletedAt);
  ARound := FRounds[Index];
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryRoundService.AbandonRound(const ARoundId, AReason,
  ACompletedAt: string; out ARound: TCEADiscoveryRound): TCEAResult;
var
  Index: Integer;
begin
  ARound := Default(TCEADiscoveryRound);
  if Trim(ARoundId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_round_id_required', '{}'));
  if Trim(AReason) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_abandon_reason_required', '{}'));
  if Length(AReason) > CeaDiscoveryReasonMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_abandon_reason_too_long', '{}'));
  if Trim(ACompletedAt) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_timestamp_required', '{}'));
  Index := IndexOf(ARoundId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'discovery_round_not_found', '{}'));
  if FRounds[Index].State <> drsPlanned then
    Exit(TCEAResult.Error(rcConflict, 'discovery_round_not_planned', '{}'));
  FRounds[Index].State := drsAbandoned;
  FRounds[Index].ObservedOutcome := Trim(AReason);
  FRounds[Index].CompletedAt := Trim(ACompletedAt);
  ARound := FRounds[Index];
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryRoundService.CurrentRound(
  out ARound: TCEADiscoveryRound): Boolean;
var
  I: Integer;
begin
  ARound := Default(TCEADiscoveryRound);
  for I := High(FRounds) downto 0 do
    if FRounds[I].State = drsPlanned then
    begin
      ARound := FRounds[I];
      Exit(True);
    end;
  Result := False;
end;

function TCEADiscoveryRoundService.GetRound(const ARoundId: string;
  out ARound: TCEADiscoveryRound): TCEAResult;
var
  Index: Integer;
begin
  ARound := Default(TCEADiscoveryRound);
  if Trim(ARoundId) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_round_id_required', '{}'));
  Index := IndexOf(ARoundId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'discovery_round_not_found', '{}'));
  ARound := FRounds[Index];
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryRoundService.ListRounds(const ALimit: Cardinal;
  out ARounds: TCEADiscoveryRoundArray): TCEAResult;
var
  Limit, Total, I, Start: Integer;
begin
  SetLength(ARounds, 0);
  Limit := ALimit;
  if Limit <= 0 then
    Limit := CeaDiscoveryRoundDefaultLimit;
  if Limit > CeaDiscoveryRoundMaxLimit then
    Limit := CeaDiscoveryRoundMaxLimit;
  Total := Length(FRounds);
  Start := Total - Limit;
  if Start < 0 then
    Start := 0;
  SetLength(ARounds, Total - Start);
  for I := Start to Total - 1 do
    ARounds[I - Start] := FRounds[I];
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryRoundService.Count: Cardinal;
begin
  Result := Length(FRounds);
end;

procedure TCEADiscoveryRoundService.Reset;
begin
  SetLength(FRounds, 0);
  FSequence := 0;
end;

end.
