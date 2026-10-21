unit cea_event_service;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_results, cea_event_types;

type
  // 事件服务配置（FR-070 循环缓存容量 / FR-074 事件前后片段 / FR-077 冷却）
  TCEAEventServiceConfig = record
    PreRollMs: Int64;            // 事件前保留时长
    PostRollMs: Int64;           // 事件后继续录制时长
    SnapshotCapacity: Cardinal;  // 内存快照环形缓存容量
    DefaultCooldownMs: Int64;    // 默认冷却时间
  end;

  // 事件录像证据层（PRD 6.8 / FR-070～FR-080）
  //
  // 职责：维护内存快照环形缓存与事件包，处理本地确定性触发（FR-072）、
  // 事件合并（FR-074）、冷却与按需唤醒 AI（FR-077）。
  // 不负责实际视频编码：录像由 ICEARecordingCapture 平台实现提供。
  TCEAEventService = class
  private
    FConfig: TCEAEventServiceConfig;
    FSnapshots: TCEAFieldSnapshotArray;
    FSnapshotHead: Cardinal;
    FSnapshotCount: Cardinal;
    FRules: TCEAFieldChangeRuleArray;
    FLastTriggerAtMs: array of Int64;
    FEvents: TCEAEventPackageArray;
    FSequence: QWord;       // 快照序列号（统一时间线排序用）
    FEventSequence: QWord;  // 事件 ID 序列（与快照序列独立）
    FSuppressedCount: Cardinal;
    FWakePort: ICEAEventWakePort;
    FRecorder: ICEARecordingCapture;
    FEventStore: ICEAEventStore;
    function FindRule(const AFieldId: string): Integer;
    function NextEventId: string;
    function SnapshotsInWindow(const AStartAtMs, AEndAtMs: Int64): TCEAFieldSnapshotArray;
    function SnapshotsJson(const AItems: TCEAFieldSnapshotArray): string;
    function RuleMatches(const ARule: TCEAFieldChangeRule;
      const APrevious, ACurrent: Double): Boolean;
    procedure AssembleEvent(const ATriggerKind: TCEAEventTriggerKind;
      const ATriggerSource, AProcessIdentityId: string;
      const AEpoch: QWord; const ATriggerAtMs: Int64;
      const AUserTagsJson: string);
    function FindMergeTarget(const ATriggerAtMs: Int64): Integer;
    // 事件包落盘（FR-076/083）；未装配存储时为 no-op
    procedure PersistEvent(const AIndex: Integer);
  public
    constructor Create(const AConfig: TCEAEventServiceConfig);
    procedure SetWakePort(const APort: ICEAEventWakePort);
    procedure SetRecorder(const ARecorder: ICEARecordingCapture);
    // 装配持久化存储；装配后每次事件创建/变更/删除都同步落盘
    procedure SetEventStore(const AStore: ICEAEventStore);

    // 配置字段变化触发规则（FR-072）
    function ConfigureRule(const ARule: TCEAFieldChangeRule): TCEAResult;
    function RuleCount: Integer;

    // 观察字段值：记录快照并按规则评估触发（本地确定性，不调用 AI）
    function ObserveField(const AFieldId, AValueJson: string;
      const AAtMs: Int64; const AProcessIdentityId: string;
      const AEpoch: QWord): TCEAResult;

    // 手动事件标记（FR-071）
    function MarkEvent(const AProcessIdentityId: string; const AEpoch: QWord;
      const AAtMs: Int64; const ATag: string): TCEAResult;

    // 事件包查询（FR-076）
    function GetEvent(const AEventId: string;
      out AEvent: TCEAEventPackage): Boolean;
    function GetEvents: TCEAEventPackageArray;
    function EventCount: Integer;
    function SuppressedCount: Cardinal;
    function SnapshotCount: Cardinal;

    // 隐私：删除事件及其录像引用（FR-083）
    function DeleteEvent(const AEventId: string): TCEAResult;

    // 标记已分析 / 已入队（FR-077）
    function MarkAnalysisState(const AEventId: string;
      const AState: TCEAEventAnalysisState): TCEAResult;

    // 从持久化存储重新载入事件（应用重启后恢复时间线）
    function ReloadFromStore: TCEAResult;
  end;

implementation

function JsonEscape(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      Result := Result + C;
    end;
  end;
end;

constructor TCEAEventService.Create(const AConfig: TCEAEventServiceConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.SnapshotCapacity = 0 then
    FConfig.SnapshotCapacity := 512;
  if FConfig.DefaultCooldownMs < 0 then
    FConfig.DefaultCooldownMs := 0;
  SetLength(FSnapshots, FConfig.SnapshotCapacity);
  FSnapshotHead := 0;
  FSnapshotCount := 0;
  SetLength(FRules, 0);
  SetLength(FEvents, 0);
  FSequence := 0;
  FEventSequence := 0;
  FSuppressedCount := 0;
end;

procedure TCEAEventService.SetWakePort(const APort: ICEAEventWakePort);
begin
  FWakePort := APort;
end;

procedure TCEAEventService.SetRecorder(const ARecorder: ICEARecordingCapture);
begin
  FRecorder := ARecorder;
end;

procedure TCEAEventService.SetEventStore(const AStore: ICEAEventStore);
begin
  FEventStore := AStore;
end;

procedure TCEAEventService.PersistEvent(const AIndex: Integer);
begin
  if (FEventStore = nil) or (AIndex < 0) or (AIndex > High(FEvents)) then
    Exit;
  FEventStore.SaveEvent(FEvents[AIndex]);
end;

function TCEAEventService.ReloadFromStore: TCEAResult;
var
  Loaded: TCEAEventPackageArray;
  I, Prefix: Integer;
  IdText, HexText: string;
  Seq: QWord;
begin
  if FEventStore = nil then
    Exit(TCEAResult.Error(rcInternalError, 'event_store_missing', '{}'));
  try
    Loaded := FEventStore.ListEvents;
  except
    Exit(TCEAResult.Error(rcInternalError, 'event_reload_failed', '{}'));
  end;
  FEvents := Loaded;
  // 事件 ID 形如 event-00000001；重启后必须从已载入的最大序号继续，
  // 否则新事件会复用旧事件 ID 并覆盖历史记录。
  FEventSequence := 0;
  Prefix := Length('event-');
  for I := 0 to High(FEvents) do
  begin
    IdText := FEvents[I].EventId;
    if Copy(IdText, 1, Prefix) <> 'event-' then Continue;
    HexText := Copy(IdText, Prefix + 1, MaxInt);
    if (HexText = '') or (not TryStrToQWord('$' + HexText, Seq)) then Continue;
    if Seq > FEventSequence then FEventSequence := Seq;
  end;
  Result := TCEAResult.Ok('{"count":' + IntToStr(Length(FEvents)) +
    ',"next_sequence":' + IntToStr(FEventSequence) + '}');
end;

function TCEAEventService.FindRule(const AFieldId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FRules) do
    if FRules[I].FieldId = AFieldId then
      Exit(I);
  Result := -1;
end;

function TCEAEventService.NextEventId: string;
begin
  Inc(FEventSequence);
  Result := 'event-' + IntToHex(FEventSequence, 8);
end;

function TCEAEventService.ConfigureRule(
  const ARule: TCEAFieldChangeRule): TCEAResult;
var
  Index: Integer;
begin
  if not ARule.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_rule_invalid', '{}'));
  Index := FindRule(ARule.FieldId);
  if Index < 0 then
  begin
    SetLength(FRules, Length(FRules) + 1);
    SetLength(FLastTriggerAtMs, Length(FRules));
    Index := High(FRules);
    FLastTriggerAtMs[Index] := 0;
  end;
  FRules[Index] := ARule;
  Result := TCEAResult.Ok('{"field_id":"' + JsonEscape(ARule.FieldId) +
    '","condition":"' + ChangeConditionText(ARule.Condition) + '"}');
end;

function TCEAEventService.RuleCount: Integer;
begin
  Result := Length(FRules);
end;

function TCEAEventService.RuleMatches(const ARule: TCEAFieldChangeRule;
  const APrevious, ACurrent: Double): Boolean;
begin
  case ARule.Condition of
    ccAnyChange: Result := APrevious <> ACurrent;
    ccIncrease: Result := ACurrent > APrevious;
    ccDecrease: Result := ACurrent < APrevious;
    ccAboveThreshold: Result := ACurrent > ARule.Threshold;
    ccBelowThreshold: Result := ACurrent < ARule.Threshold;
  else
    Result := False;
  end;
end;

function TCEAEventService.SnapshotsInWindow(const AStartAtMs,
  AEndAtMs: Int64): TCEAFieldSnapshotArray;
var
  I, Index: Integer;
  Count: Integer;
begin
  Result := nil;
  if FSnapshotCount = 0 then Exit;
  Count := 0;
  // 环形缓存按时间顺序遍历：最旧 -> 最新
  for I := 0 to Integer(FSnapshotCount) - 1 do
  begin
    Index := (Integer(FSnapshotHead) - Integer(FSnapshotCount) + I +
      Integer(FConfig.SnapshotCapacity) * 2) mod Integer(FConfig.SnapshotCapacity);
    if (FSnapshots[Index].CapturedAtMs >= AStartAtMs) and
       (FSnapshots[Index].CapturedAtMs <= AEndAtMs) then
    begin
      SetLength(Result, Count + 1);
      Result[Count] := FSnapshots[Index];
      Inc(Count);
    end;
  end;
end;

function TCEAEventService.SnapshotsJson(
  const AItems: TCEAFieldSnapshotArray): string;
var
  I: Integer;
  Part: string;
begin
  Result := '[';
  for I := 0 to High(AItems) do
  begin
    Part := '{"field_id":"' + JsonEscape(AItems[I].FieldId) +
      '","value_json":"' + JsonEscape(AItems[I].ValueJson) +
      '","captured_at_ms":' + IntToStr(AItems[I].CapturedAtMs) +
      ',"sequence":' + IntToStr(AItems[I].Sequence) + '}';
    if I > 0 then Result := Result + ',';
    Result := Result + Part;
  end;
  Result := Result + ']';
end;

function TCEAEventService.FindMergeTarget(const ATriggerAtMs: Int64): Integer;
var
  I: Integer;
begin
  // 事件重叠合并（FR-074）：触发时间仍落在既有事件窗口内则合并，
  // 避免重复保存大量视频
  for I := High(FEvents) downto 0 do
    if (ATriggerAtMs >= FEvents[I].StartAtMs) and
       (ATriggerAtMs <= FEvents[I].EndAtMs) then
      Exit(I);
  Result := -1;
end;

procedure TCEAEventService.AssembleEvent(const ATriggerKind: TCEAEventTriggerKind;
  const ATriggerSource, AProcessIdentityId: string; const AEpoch: QWord;
  const ATriggerAtMs: Int64; const AUserTagsJson: string);
var
  Event: TCEAEventPackage;
  WindowStart, WindowEnd: Int64;
  MergeIndex: Integer;
  Snapshots: TCEAFieldSnapshotArray;
  Segment: TCEARecordingSegment;
  CaptureResult: TCEAResult;
begin
  WindowStart := ATriggerAtMs - FConfig.PreRollMs;
  WindowEnd := ATriggerAtMs + FConfig.PostRollMs;
  MergeIndex := FindMergeTarget(ATriggerAtMs);
  if MergeIndex >= 0 then
  begin
    // 合并：延长窗口，保留原触发来源与创建时间
    if WindowEnd > FEvents[MergeIndex].EndAtMs then
      FEvents[MergeIndex].EndAtMs := WindowEnd;
    if WindowStart < FEvents[MergeIndex].StartAtMs then
      FEvents[MergeIndex].StartAtMs := WindowStart;
    Snapshots := SnapshotsInWindow(FEvents[MergeIndex].StartAtMs,
      FEvents[MergeIndex].EndAtMs);
    FEvents[MergeIndex].FieldSnapshotsJson := SnapshotsJson(Snapshots);
    PersistEvent(MergeIndex);
    Exit;
  end;

  FillChar(Event, SizeOf(Event), 0);
  Event.EventId := NextEventId;
  Event.TriggerKind := ATriggerKind;
  Event.TriggerSource := ATriggerSource;
  Event.StartAtMs := WindowStart;
  Event.EndAtMs := WindowEnd;
  Event.ProcessIdentityId := AProcessIdentityId;
  Event.Epoch := AEpoch;
  Snapshots := SnapshotsInWindow(WindowStart, WindowEnd);
  Event.FieldSnapshotsJson := SnapshotsJson(Snapshots);
  Event.AnalysisState := eaUnanalyzed;
  Event.CreatedAtMs := ATriggerAtMs;
  // 统一时间线：记录采集延迟与时钟误差（FR-075）
  Event.CaptureLatencyMs := 0;
  Event.ClockErrorMs := 0;
  if AUserTagsJson <> '' then
    Event.UserTagsJson := AUserTagsJson
  else
    Event.UserTagsJson := '[]';

  Event.RecordingRefsJson := '[]';
  if FRecorder <> nil then
  begin
    Segment.Id := '';
    CaptureResult := FRecorder.CaptureSegment(WindowStart, WindowEnd, Segment);
    if CaptureResult.Code = rcOk then
      Event.RecordingRefsJson := '[{"segment_id":"' + JsonEscape(Segment.Id) +
        '","storage_ref":"' + JsonEscape(Segment.StorageRef) +
        '","duration_ms":' + IntToStr(Segment.DurationMs) + '}]';
  end;

  SetLength(FEvents, Length(FEvents) + 1);
  FEvents[High(FEvents)] := Event;
  PersistEvent(High(FEvents));
end;

function TCEAEventService.ObserveField(const AFieldId, AValueJson: string;
  const AAtMs: Int64; const AProcessIdentityId: string;
  const AEpoch: QWord): TCEAResult;
var
  Index: Integer;
  Previous: TCEAFieldSnapshot;
  HasPrevious: Boolean;
  I, RuleIndex: Integer;
  PreviousValue, CurrentValue: Double;
  PreviousIsNumber, CurrentIsNumber: Boolean;
  Triggered: Boolean;
begin
  if (Trim(AFieldId) = '') or (AAtMs <= 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_observation_invalid', '{}'));

  HasPrevious := False;
  FillChar(Previous, SizeOf(Previous), 0);
  for I := Integer(FSnapshotCount) - 1 downto 0 do
  begin
    Index := (Integer(FSnapshotHead) - 1 - (Integer(FSnapshotCount) - 1 - I) +
      Integer(FConfig.SnapshotCapacity) * 2) mod Integer(FConfig.SnapshotCapacity);
    if FSnapshots[Index].FieldId = AFieldId then
    begin
      Previous := FSnapshots[Index];
      HasPrevious := True;
      Break;
    end;
  end;

  // 写入环形缓存（最旧被覆盖，FR-070）
  FSnapshots[FSnapshotHead].FieldId := AFieldId;
  FSnapshots[FSnapshotHead].ValueJson := AValueJson;
  FSnapshots[FSnapshotHead].CapturedAtMs := AAtMs;
  Inc(FSequence);
  FSnapshots[FSnapshotHead].Sequence := FSequence;
  FSnapshotHead := (FSnapshotHead + 1) mod FConfig.SnapshotCapacity;
  if FSnapshotCount < FConfig.SnapshotCapacity then
    Inc(FSnapshotCount);

  RuleIndex := FindRule(AFieldId);
  if RuleIndex < 0 then
    Exit(TCEAResult.Ok('{"triggered":false,"reason":"no_rule"}'));

  if not FRules[RuleIndex].Enabled then
    Exit(TCEAResult.Ok('{"triggered":false,"reason":"rule_disabled"}'));

  PreviousIsNumber := HasPrevious and
    TryStrToFloat(Previous.ValueJson, PreviousValue);
  CurrentIsNumber := TryStrToFloat(AValueJson, CurrentValue);
  Triggered := False;
  if PreviousIsNumber and CurrentIsNumber then
    Triggered := RuleMatches(FRules[RuleIndex], PreviousValue, CurrentValue)
  else if (FRules[RuleIndex].Condition = ccAnyChange) and HasPrevious then
    Triggered := Previous.ValueJson <> AValueJson;

  if not Triggered then
    Exit(TCEAResult.Ok('{"triggered":false,"reason":"condition_not_met"}'));

  // 冷却：避免同一变化重复触发模型调用（FR-077）
  if (FRules[RuleIndex].CooldownMs > 0) and
     (FLastTriggerAtMs[RuleIndex] > 0) and
     (AAtMs - FLastTriggerAtMs[RuleIndex] < FRules[RuleIndex].CooldownMs) then
  begin
    Inc(FSuppressedCount);
    Exit(TCEAResult.Ok('{"triggered":false,"reason":"cooldown"}'));
  end;

  FLastTriggerAtMs[RuleIndex] := AAtMs;
  AssembleEvent(etFieldChange, 'rule:' + ChangeConditionText(FRules[RuleIndex].Condition),
    AProcessIdentityId, AEpoch, AAtMs,
    '["field:' + JsonEscape(AFieldId) + '"]');
  Result := TCEAResult.Ok('{"triggered":true,"event_id":"' +
    FEvents[High(FEvents)].EventId + '"}');
end;

function TCEAEventService.MarkEvent(const AProcessIdentityId: string;
  const AEpoch: QWord; const AAtMs: Int64; const ATag: string): TCEAResult;
var
  TagsJson: string;
begin
  if AAtMs <= 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'event_mark_time_required', '{}'));
  if ATag <> '' then
    TagsJson := '["' + JsonEscape(ATag) + '"]'
  else
    TagsJson := '[]';
  AssembleEvent(etUserMark, 'user_mark', AProcessIdentityId, AEpoch, AAtMs,
    TagsJson);
  Result := TCEAResult.Ok('{"event_id":"' + FEvents[High(FEvents)].EventId + '"}');
end;

function TCEAEventService.GetEvent(const AEventId: string;
  out AEvent: TCEAEventPackage): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FEvents) do
    if FEvents[I].EventId = AEventId then
    begin
      AEvent := FEvents[I];
      Exit(True);
    end;
  FillChar(AEvent, SizeOf(AEvent), 0);
  Result := False;
end;

function TCEAEventService.GetEvents: TCEAEventPackageArray;
begin
  Result := FEvents;
end;

function TCEAEventService.EventCount: Integer;
begin
  Result := Length(FEvents);
end;

function TCEAEventService.SuppressedCount: Cardinal;
begin
  Result := FSuppressedCount;
end;

function TCEAEventService.SnapshotCount: Cardinal;
begin
  Result := FSnapshotCount;
end;

function TCEAEventService.DeleteEvent(const AEventId: string): TCEAResult;
var
  I, J: Integer;
begin
  for I := 0 to High(FEvents) do
    if FEvents[I].EventId = AEventId then
    begin
      // 删除后不得留下可恢复的隐私副本（FR-083）：连同录像引用一并移除
      for J := I to High(FEvents) - 1 do
        FEvents[J] := FEvents[J + 1];
      SetLength(FEvents, Length(FEvents) - 1);
      if FEventStore <> nil then
        FEventStore.DeleteEvent(AEventId);
      Exit(TCEAResult.Ok('{"event_id":"' + JsonEscape(AEventId) + '"}'));
    end;
  Result := TCEAResult.Error(rcUnknown, 'event_not_found', '{}');
end;

function TCEAEventService.MarkAnalysisState(const AEventId: string;
  const AState: TCEAEventAnalysisState): TCEAResult;
var
  I: Integer;
  ContextJson: string;
begin
  for I := 0 to High(FEvents) do
    if FEvents[I].EventId = AEventId then
    begin
      FEvents[I].AnalysisState := AState;
      if (AState = eaQueued) and (FWakePort <> nil) then
      begin
        // FR-078：优先提供结构化事件摘要
        ContextJson := '{"event_id":"' + JsonEscape(AEventId) +
          '","trigger_kind":"' + EventTriggerKindText(FEvents[I].TriggerKind) +
          '","duration_ms":' + IntToStr(FEvents[I].DurationMs) +
          ',"field_snapshots":' + FEvents[I].FieldSnapshotsJson + '}';
        FWakePort.Enqueue(AEventId, ContextJson);
      end;
      PersistEvent(I);
      Exit(TCEAResult.Ok('{"event_id":"' + JsonEscape(AEventId) +
        '","analysis_state":"' + EventAnalysisStateText(AState) + '"}'));
    end;
  Result := TCEAResult.Error(rcUnknown, 'event_not_found', '{}');
end;

end.
