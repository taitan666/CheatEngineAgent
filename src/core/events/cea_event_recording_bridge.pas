unit cea_event_recording_bridge;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_results, cea_event_types, cea_recording_service;

type
  // 录像捕获与录像缓存之间的桥。
  //
  // 为什么需要这一层：ICEARecordingCapture 只负责「抓出一个片段」，
  // TCEARecordingService 只负责「记住片段、按策略淘汰」。事件服务
  // 只认前者，于是后者永远收不到任何片段——缓存时长、磁盘预算、
  // 保留期限、用户锁定全部形同虚设。桥把两件事接成一条链：
  // 捕获成功 -> 登记进缓存 -> 按策略清理。
  TCEAEventRecordingBridge = class(TObject, ICEARecordingCapture)
  private
    FCapture: ICEARecordingCapture;
    FService: TCEARecordingService;
    FLastCacheError: string;
  public
    constructor Create(const ACapture: ICEARecordingCapture;
      const AService: TCEARecordingService);
    function ProbeSupport(out AReason: string): Boolean;
    function CaptureSegment(const AStartAtMs, AEndAtMs: Int64;
      out ASegment: TCEARecordingSegment): TCEAResult;
    // 最近一次登记失败的原因（成功时为空）
    property LastCacheError: string read FLastCacheError;
  end;

implementation

constructor TCEAEventRecordingBridge.Create(
  const ACapture: ICEARecordingCapture;
  const AService: TCEARecordingService);
begin
  inherited Create;
  FCapture := ACapture;
  FService := AService;
  FLastCacheError := '';
end;

function TCEAEventRecordingBridge.ProbeSupport(out AReason: string): Boolean;
begin
  AReason := '';
  if FCapture = nil then
  begin
    AReason := 'recording_capture_required';
    Exit(False);
  end;
  if FService = nil then
  begin
    AReason := 'recording_service_required';
    Exit(False);
  end;
  Result := FCapture.ProbeSupport(AReason);
end;

function TCEAEventRecordingBridge.CaptureSegment(const AStartAtMs,
  AEndAtMs: Int64; out ASegment: TCEARecordingSegment): TCEAResult;
var
  CacheResult: TCEAResult;
begin
  FLastCacheError := '';
  if FCapture = nil then
    Exit(TCEAResult.Error(rcConflict, 'recording_capture_required', '{}'));
  Result := FCapture.CaptureSegment(AStartAtMs, AEndAtMs, ASegment);
  if Result.Failed then Exit;
  if FService = nil then Exit;

  // 帧已经落盘，此时登记失败不能把捕获翻成失败：否则事件会丢掉
  // 一个真实存在的录像引用，而磁盘上却留着没人管理的帧。
  CacheResult := FService.AddSegment(ASegment);
  if CacheResult.Failed then
    FLastCacheError := CacheResult.StableCode
  else
    // 保留期限与磁盘预算在此按当前时间收口（FR-079）
    FService.EnforceRetention(ASegment.EndedAtMs);
end;

end.
