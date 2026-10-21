program test_event_service;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, Windows, cea_results, cea_event_types, cea_event_service,
  cea_recording_service, cea_win32_recording;

type
  TCEATestRecorder = class(TObject, ICEARecordingCapture)
  private
    FCallCount: Cardinal;
    FProbeReason: string;
  public
    ProbeOk: Boolean;
    function ProbeSupport(out AReason: string): Boolean;
    function CaptureSegment(const AStartAtMs, AEndAtMs: Int64;
      out ASegment: TCEARecordingSegment): TCEAResult;
    property CallCount: Cardinal read FCallCount;
  end;

  TCEATestWakePort = class(TObject, ICEAEventWakePort)
  public
    LastEventId: string;
    LastContextJson: string;
    EnqueueCount: Integer;
    function Enqueue(const AEventId, AContextJson: string): TCEAResult;
    function QueueLength: Integer;
  end;

  TCEATestFrameSource = class(TObject, ICEAFrameSource)
  private
    FWidth: Cardinal;
    FHeight: Cardinal;
    FStride: Cardinal;
    FGrabCount: Cardinal;
  public
    constructor Create(const AWidth, AHeight: Cardinal);
    function ProbeSupport(out AReason: string): Boolean;
    function GrabFrame(out AFrame: TCEAFrameData;
      out AReason: string): Boolean;
    property GrabCount: Cardinal read FGrabCount;
  end;

function TCEATestRecorder.ProbeSupport(out AReason: string): Boolean;
begin
  AReason := FProbeReason;
  Result := ProbeOk;
end;

function TCEATestRecorder.CaptureSegment(const AStartAtMs,
  AEndAtMs: Int64; out ASegment: TCEARecordingSegment): TCEAResult;
begin
  Inc(FCallCount);
  FillChar(ASegment, SizeOf(ASegment), 0);
  ASegment.Id := 'seg-test-' + IntToStr(FCallCount);
  ASegment.StartedAtMs := AStartAtMs;
  ASegment.EndedAtMs := AEndAtMs;
  ASegment.FrameCount := 3;
  ASegment.StorageRef := 'memory://' + ASegment.Id;
  ASegment.SizeBytes := 1024;
  Result := TCEAResult.Ok('{}');
end;

function TCEATestWakePort.Enqueue(const AEventId,
  AContextJson: string): TCEAResult;
begin
  LastEventId := AEventId;
  LastContextJson := AContextJson;
  Inc(EnqueueCount);
  Result := TCEAResult.Ok('{}');
end;

function TCEATestWakePort.QueueLength: Integer;
begin
  Result := EnqueueCount;
end;

constructor TCEATestFrameSource.Create(const AWidth, AHeight: Cardinal);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FStride := AWidth * 3;
end;

function TCEATestFrameSource.ProbeSupport(out AReason: string): Boolean;
begin
  AReason := '';
  Result := True;
end;

function TCEATestFrameSource.GrabFrame(out AFrame: TCEAFrameData;
  out AReason: string): Boolean;
var
  I: Integer;
begin
  Inc(FGrabCount);
  AReason := '';
  AFrame.Width := FWidth;
  AFrame.Height := FHeight;
  AFrame.Stride := FStride;
  SetLength(AFrame.Pixels, Int64(FStride) * Int64(FHeight));
  for I := 0 to High(AFrame.Pixels) do
    AFrame.Pixels[I] := Byte(I mod 256);
  AFrame.CapturedAtMs := GetTickCount64;
  Result := True;
end;

function SegmentOf(const AStartedAtMs, AEndedAtMs: Int64;
  const AId: string; const ASize: QWord): TCEARecordingSegment;
begin
  Result.Id := AId;
  Result.StartedAtMs := AStartedAtMs;
  Result.EndedAtMs := AEndedAtMs;
  Result.FrameCount := 1;
  Result.Locked := False;
  Result.StorageRef := 'memory://' + AId;
  Result.SizeBytes := ASize;
end;

var
  Config: TCEAEventServiceConfig;
  Service: TCEAEventService;
  Rule: TCEAFieldChangeRule;
  Recorder: TCEATestRecorder;
  WakePort: TCEATestWakePort;
  R: TCEAResult;
  Fetched: TCEAEventPackage;
  Policy: TCEARecordingPolicy;
  Cache: TCEARecordingService;
  SegmentFetched: TCEARecordingSegment;
  FrameSource: TCEATestFrameSource;
  Capture: TCEAWin32RecordingCapture;
  CaptureSegmentOut: TCEARecordingSegment;
  StorageDir: string;
  ProbeReason: string;
  IndexPath: string;
  FramePath: string;
begin
  FillChar(Config, SizeOf(Config), 0);
  Config.PreRollMs := 100;
  Config.PostRollMs := 100;
  Config.SnapshotCapacity := 8;
  Config.DefaultCooldownMs := 0;
  Service := TCEAEventService.Create(Config);
  Recorder := TCEATestRecorder.Create;
  WakePort := TCEATestWakePort.Create;
  try
    // 1. 首次观测只记录快照，不触发（无前值可比）
    R := Service.ObserveField('player.geo', '21', 1000, 'process-b50aa21d', 1);
    Assert(R.Code = rcOk, 'first observation: ' + R.StableCode);
    Assert(Pos('"triggered":false', R.DataJson) > 0, 'first obs no trigger');
    Assert(Service.SnapshotCount = 1, 'snapshot recorded');
    Assert(Service.EventCount = 0, 'no event on first observation');

    // 2. 配置规则后，值变化触发本地确定性事件（FR-072）
    FillChar(Rule, SizeOf(Rule), 0);
    Rule.FieldId := 'player.geo';
    Rule.Condition := ccIncrease;
    Rule.Threshold := 0;
    Rule.CooldownMs := 5000;
    Rule.Enabled := True;
    R := Service.ConfigureRule(Rule);
    Assert(R.Code = rcOk, 'configure rule: ' + R.StableCode);
    Assert(Service.RuleCount = 1, 'one rule');

    R := Service.ObserveField('player.geo', '23', 2000, 'process-b50aa21d', 1);
    Assert(Pos('"triggered":true', R.DataJson) > 0,
      'increase triggers locally: ' + R.DataJson);
    Assert(Service.EventCount = 1, 'event created');

    // 3. 事件包内容符合 FR-076
    Assert(Service.GetEvent('event-00000001', Fetched), 'event retrievable');
    Assert(Fetched.TriggerKind = etFieldChange, 'field change trigger');
    Assert(Fetched.ProcessIdentityId = 'process-b50aa21d', 'identity carried');
    Assert(Fetched.Epoch = 1, 'epoch carried');
    Assert(Fetched.StartAtMs = 1900, 'pre-roll window');
    Assert(Fetched.EndAtMs = 2100, 'post-roll window');
    Assert(Fetched.CreatedAtMs = 2000, 'created at trigger time');
    Assert(Pos('"field_id":"player.geo"', Fetched.FieldSnapshotsJson) > 0,
      'field snapshot in event');
    Assert(Pos('field:player.geo', Fetched.UserTagsJson) > 0, 'auto tag');
    Assert(Fetched.AnalysisState = eaUnanalyzed, 'starts unanalyzed');
    Assert(IsLocalDeterministicTrigger(Fetched.TriggerKind),
      'field change is local deterministic (FR-072)');

    // 4. 冷却抑制重复触发，且不重复调用 AI（FR-077）
    R := Service.ObserveField('player.geo', '25', 3000, 'process-b50aa21d', 1);
    Assert(Pos('"reason":"cooldown"', R.DataJson) > 0,
      'cooldown suppresses: ' + R.DataJson);
    Assert(Service.EventCount = 1, 'no duplicate event');
    Assert(Service.SuppressedCount = 1, 'suppression counted');

    // 5. 事件窗口重叠时合并，不重复保存大量视频（FR-074）
    Rule.CooldownMs := 0;
    R := Service.ConfigureRule(Rule);
    Assert(R.Code = rcOk, 'update rule cooldown');
    R := Service.ObserveField('player.geo', '30', 10000, 'process-b50aa21d', 1);
    Assert(Pos('"triggered":true', R.DataJson) > 0, 'trigger at 10000');
    Assert(Service.EventCount = 2, 'second event');
    R := Service.ObserveField('player.geo', '31', 10050, 'process-b50aa21d', 1);
    Assert(Pos('"triggered":true', R.DataJson) > 0, 'overlapping trigger');
    Assert(Service.EventCount = 2, 'overlapping trigger merged (FR-074)');
    Assert(Service.GetEvent('event-00000002', Fetched), 'fetch merged event');
    Assert(Fetched.StartAtMs = 9900, 'merge keeps earlier start');
    Assert(Fetched.EndAtMs = 10150, 'merge extends end window');

    // 6. 手动事件标记（FR-071）
    R := Service.MarkEvent('process-b50aa21d', 1, 20000, 'boss-fight');
    Assert(R.Code = rcOk, 'manual mark: ' + R.StableCode);
    Assert(Service.EventCount = 3, 'manual event created');
    Assert(Service.GetEvent('event-00000003', Fetched), 'fetch manual event');
    Assert(Fetched.TriggerKind = etUserMark, 'user mark kind');
    Assert(Pos('boss-fight', Fetched.UserTagsJson) > 0, 'user tag stored');
    Assert(Fetched.AnalysisState = eaUnanalyzed, 'manual event unanalyzed');

    // 7. 非法手动标记时间被拒
    R := Service.MarkEvent('process-b50aa21d', 1, 0, 'x');
    Assert(R.Code = rcInvalidArgument, 'mark needs time: ' + R.StableCode);

    // 8. 按需唤醒 AI：置 eaQueued 时入队结构化摘要（FR-077/FR-078）
    Service.SetWakePort(WakePort);
    R := Service.MarkAnalysisState('event-00000003', eaQueued);
    Assert(R.Code = rcOk, 'mark queued: ' + R.StableCode);
    Assert(WakePort.EnqueueCount = 1, 'wake port enqueued');
    Assert(WakePort.LastEventId = 'event-00000003', 'queued event id');
    Assert(Pos('"field_snapshots"', WakePort.LastContextJson) > 0,
      'structured summary preferred over raw video (FR-078)');
    Assert(Pos('"trigger_kind":"user_mark"', WakePort.LastContextJson) > 0,
      'trigger kind in summary');

    // 9. 录像捕获接入事件包（FR-070/076）
    Service.SetRecorder(Recorder);
    R := Service.MarkEvent('process-b50aa21d', 1, 30000, 'with-recording');
    Assert(R.Code = rcOk, 'mark with recorder');
    Assert(Recorder.CallCount = 1, 'recorder invoked');
    Assert(Service.GetEvent('event-00000004', Fetched), 'fetch recorded event');
    Assert(Pos('seg-test-1', Fetched.RecordingRefsJson) > 0,
      'recording ref in event package');
    Assert(Pos('memory://seg-test-1', Fetched.RecordingRefsJson) > 0,
      'storage ref carried');

    // 10. 删除事件（FR-083：不得留下可恢复副本）
    R := Service.DeleteEvent('event-00000003');
    Assert(R.Code = rcOk, 'delete event: ' + R.StableCode);
    Assert(Service.EventCount = 3, 'event removed');
    Assert(not Service.GetEvent('event-00000003', Fetched),
      'deleted event not retrievable');
    R := Service.DeleteEvent('event-00000003');
    Assert(R.Code = rcUnknown, 'deleting missing event: ' + R.StableCode);
    Assert(R.StableCode = 'event_not_found', 'not found stable code');

    // 11. 触发来源分类：AI 建议只作参考，不得直接作为写入依据
    Assert(IsAdvisoryOnlyTrigger(etAiSuggested), 'ai suggested advisory');
    Assert(not IsLocalDeterministicTrigger(etAiSuggested),
      'ai suggestion is not a deterministic trigger');

    // 12. 循环录像缓存：超时长淘汰最旧未锁定片段（FR-070）
    FillChar(Policy, SizeOf(Policy), 0);
    Policy.CacheDurationMs := 1000;
    Policy.MaxDiskBytes := 0;
    Policy.RetentionMs := 0;
    Cache := TCEARecordingService.Create(Policy);
    try
      Assert(Cache.CacheDurationMs = 1000, 'cache duration exposed');
      R := Cache.AddSegment(SegmentOf(100, 1100, 'seg-1', 100));
      Assert(R.Code = rcOk, 'add seg-1: ' + R.StableCode);
      R := Cache.AddSegment(SegmentOf(200, 1600, 'seg-2', 100));
      Assert(R.Code = rcOk, 'add seg-2: ' + R.StableCode);
      Assert(Cache.SegmentCount = 2, 'two segments cached');

      // 重复片段被拒
      R := Cache.AddSegment(SegmentOf(100, 1100, 'seg-1', 100));
      Assert(R.Code = rcConflict, 'duplicate segment: ' + R.StableCode);
      Assert(R.StableCode = 'recording_segment_duplicate', 'dup stable code');

      // 新增片段后窗口前移，最旧未锁定片段被淘汰
      R := Cache.AddSegment(SegmentOf(800, 2200, 'seg-3', 100));
      Assert(R.Code = rcOk, 'add seg-3: ' + R.StableCode);
      Assert(Cache.SegmentCount = 2, 'oldest unlocked evicted');
      Assert(not Cache.GetSegment('seg-1', SegmentFetched), 'seg-1 evicted');
      Assert(Cache.GetSegment('seg-2', SegmentFetched), 'seg-2 kept');

      // 锁定片段不被循环缓存覆盖（FR-070/079）
      R := Cache.SetLocked('seg-2', True);
      Assert(R.Code = rcOk, 'lock seg-2: ' + R.StableCode);
      // JSON booleans are lowercase: Pascal-cased True/False breaks parsers.
      Assert(Pos('"locked":true', R.DataJson) > 0,
        'lock result is JSON boolean: ' + R.DataJson);
      R := Cache.SetLocked('seg-missing', True);
      Assert(R.Code = rcUnknown, 'lock missing: ' + R.StableCode);
      R := Cache.AddSegment(SegmentOf(800, 4000, 'seg-4', 100));
      Assert(R.Code = rcOk, 'add seg-4: ' + R.StableCode);
      Assert(Cache.GetSegment('seg-2', SegmentFetched),
        'locked segment survives cache rollover');

      // 保留期限清理：锁定片段永久保留（FR-079）
      Policy.RetentionMs := 1000;
      Cache.Free;
      Cache := TCEARecordingService.Create(Policy);
      R := Cache.AddSegment(SegmentOf(100, 1000, 'keep-locked', 10));
      Assert(R.Code = rcOk, 'add locked candidate');
      Cache.SetLocked('keep-locked', True);
      R := Cache.AddSegment(SegmentOf(200, 2000, 'expire-me', 10));
      Assert(R.Code = rcOk, 'add expiring segment');
      Assert(Cache.EnforceRetention(9000) = 1, 'one expired segment removed');
      Assert(Cache.GetSegment('keep-locked', SegmentFetched),
        'locked segment retained past retention');
      Assert(not Cache.GetSegment('expire-me', SegmentFetched),
        'expired segment removed');

      // 保留期限为 0 表示永久保留，不清理
      Policy.RetentionMs := 0;
      Cache.Free;
      Cache := TCEARecordingService.Create(Policy);
      R := Cache.AddSegment(SegmentOf(100, 1000, 'forever', 10));
      Assert(R.Code = rcOk, 'add forever segment');
      Assert(Cache.EnforceRetention(999999) = 0, 'no retention limit');
    finally
      Cache.Free;
    end;

    // 13. 磁盘预算：不淘汰刚加入的片段（FR-079）
    FillChar(Policy, SizeOf(Policy), 0);
    Policy.CacheDurationMs := 0;
    Policy.MaxDiskBytes := 150;
    Policy.RetentionMs := 0;
    Cache := TCEARecordingService.Create(Policy);
    try
      R := Cache.AddSegment(SegmentOf(100, 200, 'big', 200));
      Assert(R.Code = rcOk, 'add oversize segment: ' + R.StableCode);
      Assert(Cache.SegmentCount = 1, 'newly added segment kept');
      Assert(Cache.TotalSizeBytes = 200, 'size tracked');
    finally
      Cache.Free;
    end;

    // 14. GDI 帧源 + 关键帧捕获落盘（1G 平台原型）
    StorageDir := IncludeTrailingPathDelimiter(GetTempDir) +
      'cea-event-test-' + IntToStr(GetProcessID);
    FrameSource := TCEATestFrameSource.Create(2, 2);
    try
      Capture := TCEAWin32RecordingCapture.Create(FrameSource, StorageDir, 10);
      try
        Assert(Capture.ProbeSupport(ProbeReason), 'capture probe');
        R := Capture.CaptureSegment(1000, 1030, CaptureSegmentOut);
        Assert(R.Code = rcOk, 'capture segment: ' + R.StableCode);
        Assert(CaptureSegmentOut.FrameCount = 4, 'four keyframes captured');
        Assert(CaptureSegmentOut.SizeBytes = 48, 'frame bytes written');
        Assert(FrameSource.GrabCount = 4, 'frame source grabbed 4');
        Assert(Pos('"frames":4', R.DataJson) > 0, 'capture summary');

        IndexPath := CaptureSegmentOut.StorageRef;
        Assert(FileExists(IndexPath), 'index file written: ' + IndexPath);
        FramePath := IncludeTrailingPathDelimiter(StorageDir) +
          CaptureSegmentOut.Id + '-0.bgr';
        Assert(FileExists(FramePath), 'frame file written: ' + FramePath);
        Assert(CaptureSegmentOut.DurationMs = 30, 'segment duration');

        // 时间窗口倒置被拒
        R := Capture.CaptureSegment(2000, 1000, CaptureSegmentOut);
        Assert(R.Code = rcInvalidArgument, 'inverted window rejected: ' +
          R.StableCode);
      finally
        Capture.Free;
      end;
    finally
      FrameSource.Free;
    end;

    WriteLn('EVENT_SERVICE=PASS');
  finally
    Service.Free;
    Recorder.Free;
    WakePort.Free;
  end;
end.
