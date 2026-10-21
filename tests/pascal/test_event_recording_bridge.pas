program test_event_recording_bridge;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, cea_results, cea_event_types, cea_recording_service,
  cea_event_recording_bridge;

type
  // 可控的捕获替身：能决定捕获成功/失败，也能记录被调用的时间窗口
  TFakeCapture = class(TObject, ICEARecordingCapture)
  private
    FFail: Boolean;
    FProbeReason: string;
    FProbeOk: Boolean;
    FLastStartAtMs: Int64;
    FLastEndAtMs: Int64;
    FCallCount: Cardinal;
  public
    constructor Create;
    function ProbeSupport(out AReason: string): Boolean;
    function CaptureSegment(const AStartAtMs, AEndAtMs: Int64;
      out ASegment: TCEARecordingSegment): TCEAResult;
    property Fail: Boolean read FFail write FFail;
    property ProbeOk: Boolean read FProbeOk write FProbeOk;
    property ProbeReason: string read FProbeReason write FProbeReason;
    property CallCount: Cardinal read FCallCount;
    property LastStartAtMs: Int64 read FLastStartAtMs;
    property LastEndAtMs: Int64 read FLastEndAtMs;
  end;

constructor TFakeCapture.Create;
begin
  inherited Create;
  FFail := False;
  FProbeOk := True;
  FProbeReason := '';
  FCallCount := 0;
end;

function TFakeCapture.ProbeSupport(out AReason: string): Boolean;
begin
  AReason := FProbeReason;
  Result := FProbeOk;
end;

function TFakeCapture.CaptureSegment(const AStartAtMs, AEndAtMs: Int64;
  out ASegment: TCEARecordingSegment): TCEAResult;
begin
  Inc(FCallCount);
  FLastStartAtMs := AStartAtMs;
  FLastEndAtMs := AEndAtMs;
  FillChar(ASegment, SizeOf(ASegment), 0);
  if FFail then
    Exit(TCEAResult.Error(rcInternalError, 'recording_capture_unavailable', '{}'));
  ASegment.Id := 'seg-' + IntToHex(FCallCount, 8);
  ASegment.StartedAtMs := AStartAtMs;
  ASegment.EndedAtMs := AEndAtMs;
  ASegment.FrameCount := 2;
  ASegment.Locked := False;
  ASegment.StorageRef := 'memory://' + ASegment.Id;
  ASegment.SizeBytes := 512;
  Result := TCEAResult.Ok('{}');
end;

var
  Capture: TFakeCapture;
  Policy: TCEARecordingPolicy;
  Cache: TCEARecordingService;
  Bridge: TCEAEventRecordingBridge;
  R: TCEAResult;
  Segment: TCEARecordingSegment;
  ProbeReason: string;
begin
  Capture := TFakeCapture.Create;
  FillChar(Policy, SizeOf(Policy), 0);
  Policy.CacheDurationMs := 60000;
  Policy.MaxDiskBytes := 1024 * 1024;
  Policy.RetentionMs := 0;
  Cache := TCEARecordingService.Create(Policy);
  Bridge := TCEAEventRecordingBridge.Create(Capture, Cache);
  try
    // 1. 探测透传给内部捕获器（桥不自己判断能力）
    Assert(Bridge.ProbeSupport(ProbeReason), 'probe ok');
    Assert(ProbeReason = '', 'probe reason empty');
    Capture.ProbeOk := False;
    Capture.ProbeReason := 'window_minimized';
    Assert(not Bridge.ProbeSupport(ProbeReason), 'probe failure forwarded');
    Assert(ProbeReason = 'window_minimized', 'probe reason forwarded');
    Capture.ProbeOk := True;

    // 2. 捕获成功后片段必须登记进缓存：否则缓存策略形同虚设
    R := Bridge.CaptureSegment(1000, 3000, Segment);
    Assert(R.Code = rcOk, 'capture ok: ' + R.StableCode);
    Assert(Segment.Id = 'seg-00000001', 'segment id: ' + Segment.Id);
    Assert(Cache.SegmentCount = 1, 'segment registered in cache');
    // 注意：不能写成 GetSegment(Segment.Id, Segment)。out 形参在入口就被清零，
    // 于是 Segment.Id 在求值时已经是空串，查询必然失败。
    Assert(Cache.GetSegment('seg-00000001', Segment), 'cache holds segment');
    Assert(Segment.StartedAtMs = 1000, 'start time kept');
    Assert(Segment.EndedAtMs = 3000, 'end time kept');
    Assert(Bridge.LastCacheError = '', 'no cache error on success');

    // 3. 捕获失败不得污染缓存
    Capture.Fail := True;
    R := Bridge.CaptureSegment(4000, 5000, Segment);
    Assert(R.Code <> rcOk, 'capture failure surfaces');
    Assert(R.StableCode = 'recording_capture_unavailable',
      'capture failure code: ' + R.StableCode);
    Assert(Cache.SegmentCount = 1, 'failed capture adds nothing to cache');
    Capture.Fail := False;

    // 4. 多段捕获按顺序进入缓存，时间窗口原样传递
    R := Bridge.CaptureSegment(5000, 7000, Segment);
    Assert(R.Code = rcOk, 'second capture: ' + R.StableCode);
    Assert(Cache.SegmentCount = 2, 'two segments cached');
    Assert(Capture.LastStartAtMs = 5000, 'window start forwarded');
    Assert(Capture.LastEndAtMs = 7000, 'window end forwarded');

    // 5. 用户锁定后缓存清理不得删掉该片段（FR-070/079）
    R := Cache.SetLocked('seg-00000001', True);
    Assert(R.Code = rcOk, 'lock first segment: ' + R.StableCode);
    Assert(Pos('"locked":true', R.DataJson) > 0, 'lock json boolean');

    // 6. 缓存满后桥仍继续登记，最旧未锁定片段被淘汰
    FillChar(Policy, SizeOf(Policy), 0);
    Policy.CacheDurationMs := 1;      // 立刻超窗
    Policy.MaxDiskBytes := 0;
    Policy.RetentionMs := 0;
    Cache.Free;
    Cache := TCEARecordingService.Create(Policy);
    Bridge.Free;
    Bridge := TCEAEventRecordingBridge.Create(Capture, Cache);
    R := Bridge.CaptureSegment(10000, 11000, Segment);
    Assert(R.Code = rcOk, 'capture under tight window: ' + R.StableCode);
    Assert(Cache.SegmentCount = 1, 'first segment cached');
    R := Bridge.CaptureSegment(12000, 13000, Segment);
    Assert(R.Code = rcOk, 'capture again: ' + R.StableCode);
    Assert(Cache.SegmentCount = 1,
      'old unlocked segment evicted, count=' + IntToStr(Cache.SegmentCount));
    Assert(not Cache.GetSegment('seg-00000001', Segment), 'oldest evicted');

    // 7. 捕获器缺失时明确拒绝，而不是静默成功
    Bridge.Free;
    Bridge := TCEAEventRecordingBridge.Create(nil, Cache);
    Assert(not Bridge.ProbeSupport(ProbeReason), 'nil capture probe fails');
    Assert(ProbeReason = 'recording_capture_required',
      'nil capture reason: ' + ProbeReason);
    R := Bridge.CaptureSegment(14000, 15000, Segment);
    Assert(R.Code = rcConflict, 'nil capture rejected');
    Assert(R.StableCode = 'recording_capture_required',
      'nil capture code: ' + R.StableCode);

    WriteLn('EVENT_RECORDING_BRIDGE=PASS');
  finally
    Bridge.Free;
    Cache.Free;
    Capture.Free;
  end;
end.
