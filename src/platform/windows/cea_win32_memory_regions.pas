unit cea_win32_memory_regions;

{$mode objfpc}{$H+}

interface

uses
  Windows, cea_results, cea_value_scan_types;

type
  TCEAMemoryRegionKind = (mrkPrivate, mrkImage, mrkMapped);
  TCEAMemoryRegionKinds = set of TCEAMemoryRegionKind;

  TCEAMemoryRegion = record
    StartAddress: QWord;
    Size: QWord;
    Protection: DWORD;
    Kind: TCEAMemoryRegionKind;
  end;
  TCEAMemoryRegionArray = array of TCEAMemoryRegion;

function EnumerateReadableRegions(const AProcessHandle: THandle;
  const AStartAddress, ARangeSize: QWord; const AMaxRegions: Cardinal;
  out ARegions: TCEAMemoryRegionArray;
  out ACoverage: TCEAScanCoverage): TCEAResult;
function EnumerateProcessReadableRegions(const AProcessHandle: THandle;
  const AKinds: TCEAMemoryRegionKinds; const AMaxBytes: QWord;
  const AMaxRegions: Cardinal; out ARegions: TCEAMemoryRegionArray;
  out ACoverage: TCEAScanCoverage): TCEAResult;

// 合并相邻且同类的内存区域（首尾相连 + kind 相同），
// 用于减少碎片化进程（如 .NET 托管堆）产生的 region 数量。
function MergeAdjacentRegions(const ARegions: TCEAMemoryRegionArray):
  TCEAMemoryRegionArray;

implementation

uses
  SysUtils;

function ReadablePrivate(const AInfo: TMemoryBasicInformation): Boolean;
var
  BasicProtect: DWORD;
begin
  BasicProtect := AInfo.Protect and $FF;
  Result := (AInfo.State = MEM_COMMIT) and (AInfo._Type = MEM_PRIVATE) and
    ((AInfo.Protect and PAGE_GUARD) = 0) and
    (BasicProtect in [PAGE_READONLY, PAGE_READWRITE, PAGE_WRITECOPY,
      PAGE_EXECUTE_READ, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_WRITECOPY]);
end;

function ReadableRegion(const AInfo: TMemoryBasicInformation): Boolean;
var
  BasicProtect: DWORD;
begin
  BasicProtect := AInfo.Protect and $FF;
  Result := (AInfo.State = MEM_COMMIT) and
    ((AInfo.Protect and PAGE_GUARD) = 0) and
    (BasicProtect in [PAGE_READONLY, PAGE_READWRITE, PAGE_WRITECOPY,
      PAGE_EXECUTE_READ, PAGE_EXECUTE_READWRITE, PAGE_EXECUTE_WRITECOPY]);
end;

function RegionKind(const AInfo: TMemoryBasicInformation;
  out AKind: TCEAMemoryRegionKind): Boolean;
begin
  Result := True;
  case AInfo._Type of
    MEM_PRIVATE: AKind := mrkPrivate;
    MEM_IMAGE: AKind := mrkImage;
    MEM_MAPPED: AKind := mrkMapped;
    else Result := False;
  end;
end;

function EnumerateReadableRegions(const AProcessHandle: THandle;
  const AStartAddress, ARangeSize: QWord; const AMaxRegions: Cardinal;
  out ARegions: TCEAMemoryRegionArray;
  out ACoverage: TCEAScanCoverage): TCEAResult;
var
  Info: TMemoryBasicInformation;
  Cursor, LastAddress, RegionStart, RegionLast, SegmentLast, SegmentSize: QWord;
  Count: Cardinal;
begin
  SetLength(ARegions, 0);
  FillChar(ACoverage, SizeOf(ACoverage), 0);
  if (AProcessHandle = 0) or (AStartAddress = 0) or (ARangeSize = 0) or
    (AMaxRegions = 0) or
    (AStartAddress > High(QWord) - (ARangeSize - 1)) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_region_request_invalid', '{}'));
  ACoverage.RequestedBytes := ARangeSize;
  LastAddress := AStartAddress + ARangeSize - 1;
  Cursor := AStartAddress;
  repeat
    FillChar(Info, SizeOf(Info), 0);
    if VirtualQueryEx(AProcessHandle, Pointer(PtrUInt(Cursor)), Info,
      SizeOf(Info)) <> SizeOf(Info) then
    begin
      ACoverage.SkippedBytes := ACoverage.SkippedBytes +
        (LastAddress - Cursor + 1);
      ACoverage.PartialReason := 'region_query_failed';
      Break;
    end;
    RegionStart := QWord(PtrUInt(Info.BaseAddress));
    if (Info.RegionSize = 0) or (RegionStart > Cursor) or
      (QWord(Info.RegionSize) - 1 > High(QWord) - RegionStart) then
    begin
      ACoverage.SkippedBytes := ACoverage.SkippedBytes +
        (LastAddress - Cursor + 1);
      ACoverage.PartialReason := 'region_metadata_invalid';
      Break;
    end;
    RegionLast := RegionStart + QWord(Info.RegionSize) - 1;
    if RegionLast < Cursor then
    begin
      ACoverage.SkippedBytes := ACoverage.SkippedBytes +
        (LastAddress - Cursor + 1);
      ACoverage.PartialReason := 'region_metadata_invalid';
      Break;
    end;
    if RegionLast > LastAddress then SegmentLast := LastAddress
    else SegmentLast := RegionLast;
    SegmentSize := SegmentLast - Cursor + 1;
    if ReadablePrivate(Info) then
    begin
      Count := Length(ARegions);
      if Count >= AMaxRegions then
      begin
        ACoverage.SkippedBytes := ACoverage.SkippedBytes +
          (LastAddress - Cursor + 1);
        ACoverage.PartialReason := 'region_limit';
        Break;
      end;
      SetLength(ARegions, Count + 1);
      ARegions[Count].StartAddress := Cursor;
      ARegions[Count].Size := SegmentSize;
      ARegions[Count].Protection := Info.Protect;
      ARegions[Count].Kind := mrkPrivate;
      ACoverage.EligibleBytes := ACoverage.EligibleBytes + SegmentSize;
    end
    else
    begin
      ACoverage.SkippedBytes := ACoverage.SkippedBytes + SegmentSize;
      if ACoverage.PartialReason = '' then
        ACoverage.PartialReason := 'region_filtered';
    end;
    if SegmentLast = LastAddress then Break;
    Cursor := SegmentLast + 1;
  until False;
  { Region metadata alone never proves a memory scan was complete. }
  ACoverage.Complete := False;
  if ACoverage.PartialReason = '' then
    ACoverage.PartialReason := 'not_scanned';
  Result := TCEAResult.Ok('{}');
end;

function EnumerateProcessReadableRegions(const AProcessHandle: THandle;
  const AKinds: TCEAMemoryRegionKinds; const AMaxBytes: QWord;
  const AMaxRegions: Cardinal; out ARegions: TCEAMemoryRegionArray;
  out ACoverage: TCEAScanCoverage): TCEAResult;
var
  SystemInfo: TSystemInfo;
  Info: TMemoryBasicInformation;
  Cursor, MaximumAddress, RegionStart, RegionSize, Remaining: QWord;
  Count: Integer;
  Kind: TCEAMemoryRegionKind;
begin
  SetLength(ARegions, 0);
  FillChar(ACoverage, SizeOf(ACoverage), 0);
  if (AProcessHandle = 0) or (AKinds = []) or (AMaxBytes = 0) or
     (AMaxBytes > QWord(512) * 1024 * 1024) or
     (AMaxRegions = 0) or (AMaxRegions > 4096) then
  begin
    if AKinds = [] then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'memory_region_kinds_required', '{}'));
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_region_request_invalid', '{}'));
  end;
  FillChar(SystemInfo, SizeOf(SystemInfo), 0);
  GetNativeSystemInfo(@SystemInfo);
  Cursor := QWord(PtrUInt(SystemInfo.lpMinimumApplicationAddress));
  MaximumAddress := QWord(PtrUInt(SystemInfo.lpMaximumApplicationAddress));
  while Cursor <= MaximumAddress do
  begin
    FillChar(Info, SizeOf(Info), 0);
    if VirtualQueryEx(AProcessHandle, Pointer(PtrUInt(Cursor)), Info,
      SizeOf(Info)) <> SizeOf(Info) then
    begin
      ACoverage.PartialReason := 'region_query_failed';
      Break;
    end;
    RegionStart := QWord(PtrUInt(Info.BaseAddress));
    RegionSize := QWord(Info.RegionSize);
    if (RegionSize = 0) or (RegionStart > Cursor) or
       (RegionStart > High(QWord) - (RegionSize - 1)) then
    begin
      ACoverage.PartialReason := 'region_metadata_invalid';
      Break;
    end;
    if ReadableRegion(Info) and RegionKind(Info, Kind) and
       (Kind in AKinds) then
    begin
      if Length(ARegions) >= AMaxRegions then
      begin
        ACoverage.PartialReason := 'region_limit';
        Break;
      end;
      Remaining := AMaxBytes - ACoverage.EligibleBytes;
      if Remaining = 0 then
      begin
        ACoverage.PartialReason := 'byte_limit';
        Break;
      end;
      if RegionSize > Remaining then RegionSize := Remaining;
      Count := Length(ARegions);
      SetLength(ARegions, Count + 1);
      ARegions[Count].StartAddress := Cursor;
      ARegions[Count].Size := RegionSize;
      ARegions[Count].Protection := Info.Protect;
      ARegions[Count].Kind := Kind;
      Inc(ACoverage.EligibleBytes, RegionSize);
      if RegionSize < QWord(Info.RegionSize) then
      begin
        ACoverage.PartialReason := 'byte_limit';
        Break;
      end;
    end;
    if RegionStart + QWord(Info.RegionSize) - 1 >= MaximumAddress then Break;
    Cursor := RegionStart + QWord(Info.RegionSize);
  end;
  ACoverage.RequestedBytes := ACoverage.EligibleBytes;
  ACoverage.Complete := ACoverage.PartialReason = '';
  Result := TCEAResult.Ok('{}');
end;

function MergeAdjacentRegions(const ARegions: TCEAMemoryRegionArray):
  TCEAMemoryRegionArray;
var
  I: Integer;
  Last: TCEAMemoryRegion;
begin
  SetLength(Result, 0);
  if Length(ARegions) = 0 then Exit;
  Last := ARegions[0];
  for I := 1 to High(ARegions) do
  begin
    // 相邻（首尾相连）且同类 → 合并
    if (ARegions[I].Kind = Last.Kind) and
       (ARegions[I].StartAddress = Last.StartAddress + Last.Size) then
      Last.Size := Last.Size + ARegions[I].Size
    else
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Last;
      Last := ARegions[I];
    end;
  end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Last;
end;

end.
