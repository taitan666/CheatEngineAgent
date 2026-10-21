unit cea_event_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

interface

uses
  SysUtils, cea_results;

type
  // 事件触发来源（PRD FR-071/072/073/084）
  TCEAEventTriggerKind = (
    etUserMark,       // 用户手动标记（FR-071）
    etFieldChange,    // 内存字段变化触发（FR-072，本地确定性代码）
    etExternalSource, // 外部事件源（FR-073，P1，需 Connector 声明）
    etAiSuggested     // 视觉/AI 候选（FR-084，P2，不得作为写入依据）
  );

  // 事件分析状态（FR-076 analysis_status）
  TCEAEventAnalysisState = (
    eaUnanalyzed, // 已捕获，未排队
    eaQueued,     // 已进入 AI 唤醒队列（FR-077）
    eaAnalyzed,   // 已分析
    eaSuppressed  // 被规则抑制（冷却/合并）
  );

  // 字段变化条件（FR-072）
  TCEAChangeCondition = (
    ccAnyChange,
    ccIncrease,
    ccDecrease,
    ccAboveThreshold,
    ccBelowThreshold
  );

  // 录像片段（FR-070/074/079）
  TCEARecordingSegment = record
    Id: string;
    StartedAtMs: Int64;
    EndedAtMs: Int64;
    FrameCount: Cardinal;
    Locked: Boolean;      // 锁定片段不得被循环缓存覆盖或自动清理
    StorageRef: string;   // 本地存储引用
    SizeBytes: QWord;
    function DurationMs: Int64;
    function IsValid: Boolean;
  end;

  TCEARecordingSegmentArray = array of TCEARecordingSegment;

  // 字段快照（FR-075/076：与录像同一时间基准）
  TCEAFieldSnapshot = record
    FieldId: string;
    ValueJson: string;
    CapturedAtMs: Int64;
    Sequence: QWord;
    function IsValid: Boolean;
  end;

  TCEAFieldSnapshotArray = array of TCEAFieldSnapshot;

  // 事件包（FR-076）
  TCEAEventPackage = record
    EventId: string;
    TriggerKind: TCEAEventTriggerKind;
    TriggerSource: string;         // 触发来源描述
    StartAtMs: Int64;              // 事件时间范围（含前后片段）
    EndAtMs: Int64;
    ProcessIdentityId: string;
    Epoch: QWord;
    FieldSnapshotsJson: string;    // 相关字段快照（JSON 数组）
    RecordingRefsJson: string;     // 录像片段引用（JSON 数组）
    AnalysisState: TCEAEventAnalysisState;
    UserTagsJson: string;
    CreatedAtMs: Int64;
    ClockErrorMs: Int64;           // 时钟误差（FR-075）
    CaptureLatencyMs: Int64;       // 采集延迟（FR-075）
    function IsValid: Boolean;
    function DurationMs: Int64;
  end;

  TCEAEventPackageArray = array of TCEAEventPackage;

  // 字段变化触发规则（FR-072）
  TCEAFieldChangeRule = record
    FieldId: string;
    Condition: TCEAChangeCondition;
    Threshold: Double;
    CooldownMs: Int64;   // 冷却时间，避免重复触发模型调用（FR-077）
    Enabled: Boolean;
    function IsValid: Boolean;
  end;

  TCEAFieldChangeRuleArray = array of TCEAFieldChangeRule;

  // 录像捕获端口（平台实现；FR-070；捕获 API 待 Phase 0/1 原型确定）
  ICEARecordingCapture = interface
    // 探测本机是否具备可用录像捕获能力；不可用时 AReason 说明原因
    function ProbeSupport(out AReason: string): Boolean;
    function CaptureSegment(const AStartAtMs, AEndAtMs: Int64;
      out ASegment: TCEARecordingSegment): TCEAResult;
  end;

  // 单帧图像（未压缩 BGRA/BGR 像素；编码在后续阶段确定）
  TCEAFrameData = record
    Width: Cardinal;
    Height: Cardinal;
    Stride: Cardinal;   // 每行字节数
    Pixels: TBytes;     // 自上而下、每像素 3 字节 BGR
    CapturedAtMs: Int64;
    function IsValid: Boolean;
  end;

  // 帧源端口：录像缓存从帧源取帧，与具体捕获 API 解耦
  ICEAFrameSource = interface
    function ProbeSupport(out AReason: string): Boolean;
    // 抓取一帧；AReason 说明失败原因
    function GrabFrame(out AFrame: TCEAFrameData;
      out AReason: string): Boolean;
  end;

  // 事件存储端口（FR-076/083）
  ICEAEventStore = interface
    function SaveEvent(const AEvent: TCEAEventPackage): TCEAResult;
    function LoadEvent(const AEventId: string;
      out AEvent: TCEAEventPackage): TCEAResult;
    function ListEvents: TCEAEventPackageArray;
    function DeleteEvent(const AEventId: string): TCEAResult;
  end;

  // 按需唤醒 AI 端口（FR-077：规则过滤、事件合并、冷却、任务队列）
  ICEAEventWakePort = interface
    function Enqueue(const AEventId, AContextJson: string): TCEAResult;
    function QueueLength: Integer;
  end;

  function EventTriggerKindText(const AKind: TCEAEventTriggerKind): string;
  function TryParseEventTriggerKind(const AText: string;
    out AKind: TCEAEventTriggerKind): Boolean;
  function EventAnalysisStateText(const AState: TCEAEventAnalysisState): string;
  function TryParseEventAnalysisState(const AText: string;
    out AState: TCEAEventAnalysisState): Boolean;
  function ChangeConditionText(const ACondition: TCEAChangeCondition): string;
  function TryParseChangeCondition(const AText: string;
    out ACondition: TCEAChangeCondition): Boolean;
  // 本地确定性触发来源（FR-072：不要求每次调用 AI）
  function IsLocalDeterministicTrigger(const AKind: TCEAEventTriggerKind): Boolean;
  // 该来源不得作为内存写入依据（FR-084）
  function IsAdvisoryOnlyTrigger(const AKind: TCEAEventTriggerKind): Boolean;

implementation

function EventTriggerKindText(const AKind: TCEAEventTriggerKind): string;
begin
  case AKind of
    etUserMark: Result := 'user_mark';
    etFieldChange: Result := 'field_change';
    etExternalSource: Result := 'external_source';
    etAiSuggested: Result := 'ai_suggested';
  end;
end;

function TryParseEventTriggerKind(const AText: string;
  out AKind: TCEAEventTriggerKind): Boolean;
var
  K: TCEAEventTriggerKind;
begin
  for K := Low(TCEAEventTriggerKind) to High(TCEAEventTriggerKind) do
    if EventTriggerKindText(K) = AText then
    begin
      AKind := K;
      Exit(True);
    end;
  Result := False;
end;

function EventAnalysisStateText(const AState: TCEAEventAnalysisState): string;
begin
  case AState of
    eaUnanalyzed: Result := 'unanalyzed';
    eaQueued: Result := 'queued';
    eaAnalyzed: Result := 'analyzed';
    eaSuppressed: Result := 'suppressed';
  end;
end;

function TryParseEventAnalysisState(const AText: string;
  out AState: TCEAEventAnalysisState): Boolean;
var
  S: TCEAEventAnalysisState;
begin
  for S := Low(TCEAEventAnalysisState) to High(TCEAEventAnalysisState) do
    if EventAnalysisStateText(S) = AText then
    begin
      AState := S;
      Exit(True);
    end;
  Result := False;
end;

function ChangeConditionText(const ACondition: TCEAChangeCondition): string;
begin
  case ACondition of
    ccAnyChange: Result := 'any_change';
    ccIncrease: Result := 'increase';
    ccDecrease: Result := 'decrease';
    ccAboveThreshold: Result := 'above_threshold';
    ccBelowThreshold: Result := 'below_threshold';
  end;
end;

function TryParseChangeCondition(const AText: string;
  out ACondition: TCEAChangeCondition): Boolean;
var
  C: TCEAChangeCondition;
begin
  for C := Low(TCEAChangeCondition) to High(TCEAChangeCondition) do
    if ChangeConditionText(C) = AText then
    begin
      ACondition := C;
      Exit(True);
    end;
  Result := False;
end;

function IsLocalDeterministicTrigger(const AKind: TCEAEventTriggerKind): Boolean;
begin
  Result := AKind in [etUserMark, etFieldChange];
end;

function IsAdvisoryOnlyTrigger(const AKind: TCEAEventTriggerKind): Boolean;
begin
  Result := AKind = etAiSuggested;
end;

function TCEARecordingSegment.DurationMs: Int64;
begin
  if EndedAtMs > StartedAtMs then
    Result := EndedAtMs - StartedAtMs
  else
    Result := 0;
end;

function TCEARecordingSegment.IsValid: Boolean;
begin
  Result := (Id <> '') and (StartedAtMs > 0) and
    (EndedAtMs >= StartedAtMs) and (StorageRef <> '');
end;

function TCEAFieldSnapshot.IsValid: Boolean;
begin
  Result := (FieldId <> '') and (CapturedAtMs > 0);
end;

function TCEAEventPackage.IsValid: Boolean;
begin
  Result := (EventId <> '') and (TriggerSource <> '') and
    (ProcessIdentityId <> '') and (Epoch > 0) and
    (StartAtMs > 0) and (EndAtMs >= StartAtMs) and
    (FieldSnapshotsJson <> '') and (CreatedAtMs > 0);
end;

function TCEAEventPackage.DurationMs: Int64;
begin
  if EndAtMs > StartAtMs then
    Result := EndAtMs - StartAtMs
  else
    Result := 0;
end;

function TCEAFrameData.IsValid: Boolean;
begin
  Result := (Width > 0) and (Height > 0) and (Stride >= Width * 3) and
    (Length(Pixels) >= Int64(Stride) * Int64(Height));
end;

function TCEAFieldChangeRule.IsValid: Boolean;
begin
  Result := (FieldId <> '') and (CooldownMs >= 0) and
    ((Condition in [ccAnyChange, ccIncrease, ccDecrease]) or
     (Threshold <> 0.0));
end;

end.
