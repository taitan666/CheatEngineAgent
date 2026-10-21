program test_win32_memory_regions;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_results, cea_value_scan_types,
  cea_win32_memory_regions;

var
  SystemInfo: TSystemInfo;
  Base: Pointer;
  PageSize: Cardinal;
  OldProtect: DWORD;
  Regions: TCEAMemoryRegionArray;
  Coverage: TCEAScanCoverage;
  R: TCEAResult;
begin
  GetSystemInfo(SystemInfo);
  PageSize := SystemInfo.dwPageSize;
  Base := VirtualAlloc(nil, PageSize * 3, MEM_RESERVE or MEM_COMMIT,
    PAGE_READWRITE);
  Assert(Base <> nil, 'self-test pages allocated');
  try
    PByte(Base)^ := $7A;
    Assert(VirtualProtect(Pointer(PtrUInt(Base) + PageSize), PageSize,
      PAGE_NOACCESS, OldProtect), 'second page made unreadable');
    Assert(VirtualProtect(Pointer(PtrUInt(Base) + PageSize * 2), PageSize,
      PAGE_READWRITE or PAGE_GUARD, OldProtect),
      'third page made guarded');
    R := EnumerateReadableRegions(GetCurrentProcess,
      QWord(PtrUInt(Base)), QWord(PageSize) * 3, 8, Regions, Coverage);
    Assert(R.Code = rcOk, 'region snapshot succeeds');
    Assert(Length(Regions) = 1, 'only first page is readable');
    Assert(Regions[0].StartAddress = QWord(PtrUInt(Base)),
      'readable page has expected address');
    Assert(Regions[0].Size = PageSize, 'readable page has expected size');
    Assert(Coverage.RequestedBytes = QWord(PageSize) * 3,
      'all requested bytes are accounted');
    Assert(Coverage.EligibleBytes = PageSize,
      'only readable page is eligible');
    Assert(Coverage.InspectedBytes = 0,
      'enumerating metadata does not inspect process memory');
    Assert(Coverage.SkippedBytes = QWord(PageSize) * 2,
      'unreadable and guarded pages are skipped');
    Assert(not Coverage.Complete, 'skipped pages make snapshot partial');

    Assert(VirtualProtect(Pointer(PtrUInt(Base) + PageSize * 2), PageSize,
      PAGE_READWRITE, OldProtect), 'third page made readable');
    R := EnumerateReadableRegions(GetCurrentProcess,
      QWord(PtrUInt(Base)), QWord(PageSize) * 3, 1, Regions, Coverage);
    Assert((R.Code = rcOk) and (Length(Regions) = 1),
      'region snapshot obeys the configured region count');
    Assert(Coverage.PartialReason = 'region_limit',
      'additional readable regions report the stable region-limit reason');

    R := EnumerateProcessReadableRegions(GetCurrentProcess, [mrkPrivate],
      PageSize, 32, Regions, Coverage);
    Assert((R.Code = rcOk) and (Length(Regions) > 0),
      'process-level private-region plan returns bounded ranges');
    Assert((Coverage.EligibleBytes <= PageSize) and
      (Coverage.PartialReason = 'byte_limit'),
      'process plan reports byte-limit partial coverage');
    Assert(Regions[0].Kind = mrkPrivate,
      'private-only plan never silently includes image or mapped memory');

    R := EnumerateProcessReadableRegions(GetCurrentProcess, [mrkImage],
      PageSize, 32, Regions, Coverage);
    Assert((R.Code = rcOk) and (Length(Regions) > 0) and
      (Regions[0].Kind = mrkImage),
      'image memory requires and honors an explicit kind selection');

    R := EnumerateProcessReadableRegions(GetCurrentProcess, [],
      PageSize, 32, Regions, Coverage);
    Assert(R.StableCode = 'memory_region_kinds_required',
      'an empty process-level region selection is rejected');

    R := EnumerateReadableRegions(GetCurrentProcess,
      QWord(PtrUInt(Base)), QWord(PageSize) * 3, 0, Regions, Coverage);
    Assert(R.Code = rcInvalidArgument, 'zero region budget is rejected');
    R := EnumerateReadableRegions(GetCurrentProcess,
      High(QWord) - 2, 8, 8, Regions, Coverage);
    Assert(R.Code = rcInvalidArgument, 'wrapping range is rejected');
  finally
    VirtualFree(Base, 0, MEM_RELEASE);
  end;
  WriteLn('WIN32_MEMORY_REGIONS=PASS');
end.
