unit cea_recording_service;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_results, cea_event_types;

type
  // 循环录像缓存与保留策略（FR-070 / FR-079）
  TCEARecordingPolicy = record
    CacheDurationMs: Int64;   // 滚动缓存时长上限（<=0 表示不限）
    MaxDiskBytes: QWord;      // 最大磁盘空间（0 表示不限）
    RetentionMs: Int64;       // 事件片段保留期限（0 表示永久保留）
    function IsValid: Boolean;
  end;

  // 录像缓存管理（FR-070 循环覆盖 / FR-079 自动清理与用户锁定）
  //
  // 只管理片段元数据与淘汰决策；实际编码由 ICEARecordingCapture 提供。
  // 锁定片段（Locked）不得被循环缓存覆盖，也不得被自动清理。
  TCEARecordingService = class
  private
    FPolicy: TCEARecordingPolicy;
    FSegments: TCEARecordingSegmentArray;
    function FindIndex(const ASegmentId: string): Integer;
    function OldestUnlockedIndex: Integer;
  public
    constructor Create(const APolicy: TCEARecordingPolicy);
    // 记录新片段；超出缓存时长或磁盘预算时淘汰最旧的未锁定片段
    function AddSegment(const ASegment: TCEARecordingSegment): TCEAResult;
    // 锁定/解锁（用户主动保存，FR-070/FR-079）
    function SetLocked(const ASegmentId: string;
      const ALocked: Boolean): TCEAResult;
    // 按保留期限清理过期且未锁定的片段（FR-079）
    function EnforceRetention(const ANowMs: Int64): Cardinal;
    function TotalSizeBytes: QWord;
    function SegmentCount: Integer;
    function GetSegments: TCEARecordingSegmentArray;
    function GetSegment(const ASegmentId: string;
      out ASegment: TCEARecordingSegment): Boolean;
    // 缓存时长上限（毫秒），供事件前后片段窗口裁剪参考
    function CacheDurationMs: Int64;
  end;

implementation

function TCEARecordingPolicy.IsValid: Boolean;
begin
  // MaxDiskBytes 为无符号类型，恒 >= 0，无需比较
  Result := RetentionMs >= 0;
end;

constructor TCEARecordingService.Create(const APolicy: TCEARecordingPolicy);
begin
  inherited Create;
  FPolicy := APolicy;
  SetLength(FSegments, 0);
end;

function TCEARecordingService.FindIndex(const ASegmentId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FSegments) do
    if FSegments[I].Id = ASegmentId then
      Exit(I);
  Result := -1;
end;

function TCEARecordingService.OldestUnlockedIndex: Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FSegments) do
    if not FSegments[I].Locked then
      Exit(I);  // FSegments 按加入顺序（时间递增）排列
end;

function TCEARecordingService.AddSegment(
  const ASegment: TCEARecordingSegment): TCEAResult;
var
  Index: Integer;
  NewestEnd, WindowStart: Int64;
  Evicted: Integer;
begin
  if not ASegment.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'recording_segment_invalid', '{}'));
  Index := FindIndex(ASegment.Id);
  if Index >= 0 then
    Exit(TCEAResult.Error(rcConflict, 'recording_segment_duplicate', '{}'));

  SetLength(FSegments, Length(FSegments) + 1);
  FSegments[High(FSegments)] := ASegment;

  // 循环缓存：超出缓存时长则从最旧的未锁定片段开始淘汰（FR-070）
  if FPolicy.CacheDurationMs > 0 then
  begin
    NewestEnd := FSegments[High(FSegments)].EndedAtMs;
    WindowStart := NewestEnd - FPolicy.CacheDurationMs;
    repeat
      Evicted := -1;
      for Index := 0 to High(FSegments) do
        if (not FSegments[Index].Locked) and
           (FSegments[Index].EndedAtMs < WindowStart) and
           (FSegments[Index].Id <> ASegment.Id) then
        begin
          Evicted := Index;
          Break;
        end;
      if Evicted >= 0 then
      begin
        for Index := Evicted to High(FSegments) - 1 do
          FSegments[Index] := FSegments[Index + 1];
        SetLength(FSegments, Length(FSegments) - 1);
      end;
    until Evicted < 0;
  end;

  // 磁盘预算：超限时淘汰最旧的未锁定片段（FR-079）
  if FPolicy.MaxDiskBytes > 0 then
    while (TotalSizeBytes > FPolicy.MaxDiskBytes) and
          (OldestUnlockedIndex >= 0) do
    begin
      Evicted := OldestUnlockedIndex;
      if FSegments[Evicted].Id = ASegment.Id then
        Break;  // 不淘汰刚加入的片段，即使超预算
      for Index := Evicted to High(FSegments) - 1 do
        FSegments[Index] := FSegments[Index + 1];
      SetLength(FSegments, Length(FSegments) - 1);
    end;

  Result := TCEAResult.Ok('{"segment_id":"' + ASegment.Id +
    '","count":' + IntToStr(Length(FSegments)) + '}');
end;

function TCEARecordingService.SetLocked(const ASegmentId: string;
  const ALocked: Boolean): TCEAResult;
var
  Index: Integer;
  LockedJson: string;
begin
  Index := FindIndex(ASegmentId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'recording_segment_not_found', '{}'));
  FSegments[Index].Locked := ALocked;
  // BoolToStr(X, True) yields Pascal-cased True/False, which is not valid JSON
  // and breaks every downstream GetJSON parser.
  if ALocked then
    LockedJson := 'true'
  else
    LockedJson := 'false';
  Result := TCEAResult.Ok('{"segment_id":"' + ASegmentId + '","locked":' +
    LockedJson + '}');
end;

function TCEARecordingService.EnforceRetention(const ANowMs: Int64): Cardinal;
var
  I: Integer;
  Removed: Cardinal;
  Keep: TCEARecordingSegmentArray;
begin
  Removed := 0;
  if FPolicy.RetentionMs <= 0 then
    Exit(0);
  SetLength(Keep, 0);
  for I := 0 to High(FSegments) do
  begin
    // 锁定片段永久保留；未锁定且超过保留期限的清理
    if FSegments[I].Locked or
       ((ANowMs - FSegments[I].EndedAtMs) <= FPolicy.RetentionMs) then
    begin
      SetLength(Keep, Length(Keep) + 1);
      Keep[High(Keep)] := FSegments[I];
    end
    else
      Inc(Removed);
  end;
  FSegments := Keep;
  Result := Removed;
end;

function TCEARecordingService.TotalSizeBytes: QWord;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FSegments) do
    Inc(Result, FSegments[I].SizeBytes);
end;

function TCEARecordingService.SegmentCount: Integer;
begin
  Result := Length(FSegments);
end;

function TCEARecordingService.GetSegments: TCEARecordingSegmentArray;
begin
  Result := FSegments;
end;

function TCEARecordingService.GetSegment(const ASegmentId: string;
  out ASegment: TCEARecordingSegment): Boolean;
var
  Index: Integer;
begin
  Index := FindIndex(ASegmentId);
  if Index < 0 then
  begin
    FillChar(ASegment, SizeOf(ASegment), 0);
    Exit(False);
  end;
  ASegment := FSegments[Index];
  Result := True;
end;

function TCEARecordingService.CacheDurationMs: Int64;
begin
  Result := FPolicy.CacheDurationMs;
end;

end.
