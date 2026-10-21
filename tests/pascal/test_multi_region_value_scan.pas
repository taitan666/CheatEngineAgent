program test_multi_region_value_scan;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, FPJSON, JSONParser, cea_types, cea_results,
  cea_process_capability, cea_scan_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

function JsonField(const AJson, AName: string): string;
var
  Data: TJSONData;
begin
  Data := GetJSON(AJson);
  try
    Result := TJSONObject(Data).Get(AName, '');
  finally
    Data.Free;
  end;
end;

function WaitReady(const AScanner: TCEAScanCapability;
  const AScanId: string; const AIdentity: TCEProcessIdentity;
  out AResult: TCEAResult): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 10000;
  repeat
    AResult := AScanner.GetStatus(AScanId, AIdentity);
    if AResult.Failed then Exit(False);
    if JsonField(AResult.DataJson, 'state') = 'ready' then Exit(True);
    Sleep(1);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

var
  Backend: TCEAWin32ReadOnlyBackend;
  Hasher: TCEAWindowsSha256;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Scanner: TCEAScanCapability;
  AttachRequest: TCEAttachRequest;
  Identity: TCEProcessIdentity;
  Request: TCEScanRequest;
  ScopeId, ScanId: string;
  ScopePartialReason: string;
  PlannedRanges: TCEScanRangeArray;
  Base: Pointer;
  DisjointBase: Pointer;
  CancelBase: Pointer;
  PageSize: Cardinal;
  SystemInfo: TSystemInfo;
  OldProtect: DWORD;
  R: TCEAResult;
  CancelStarted: QWord;
begin
  GetSystemInfo(SystemInfo);
  PageSize := SystemInfo.dwPageSize;
  Base := VirtualAlloc(nil, PageSize * 3, MEM_RESERVE or MEM_COMMIT,
    PAGE_READWRITE);
  Assert(Base <> nil, 'three-page fixture allocated');
  DisjointBase := VirtualAlloc(nil, PageSize, MEM_RESERVE or MEM_COMMIT,
    PAGE_READWRITE);
  Assert(DisjointBase <> nil, 'disjoint-page fixture allocated');
  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Scanner := TCEAScanCapability.Create(Backend, Processes,
    512 * 1024 * 1024, 10000, 1);
  try
    PCardinal(Base)^ := 767;
    PCardinal(PtrUInt(Base) + PageSize * 2)^ := 767;
    Assert(VirtualProtect(Pointer(PtrUInt(Base) + PageSize), PageSize,
      PAGE_NOACCESS, OldProtect), 'middle page is unreadable');
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:async-multi-region';
    AttachRequest.LeaseId := 'lease:async-multi-region';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    Assert(Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      Identity).Code = rcOk, 'self process attached read-only');

    FillChar(Request, SizeOf(Request), 0);
    Request.TaskId := AttachRequest.TaskId;
    Request.ProcessIdentityId := Identity.Id;
    Request.LeaseId := AttachRequest.LeaseId;
    Request.ScanKind := 'value';
    Request.ValueType := 'dword';
    Request.ValueText := '767';
    Request.RangeStart := QWord(PtrUInt(Base));
    Request.RangeSize := QWord(PageSize) * 3;
    Request.MaxBytes := Request.RangeSize;
    Request.MaxResults := 10000;
    Request.Epoch := Identity.Epoch;
    Assert(Scanner.AuthorizeLocalScope(Identity, Request.RangeStart,
      Request.RangeSize, Request.MaxBytes, Request.MaxResults,
      ScopeId).Code = rcOk, 'multi-region range is locally authorized');
    Request.ScopeId := ScopeId;
    R := Scanner.FirstScan(Request, Identity);
    Assert((R.Code = rcOk) and
      (JsonField(R.DataJson, 'state') = 'running'),
      'production first scan returns immediately in running state');
    ScanId := JsonField(R.DataJson, 'scan_id');
    Assert(ScanId <> '', 'running scan has an opaque id');
    Assert(WaitReady(Scanner, ScanId, Identity, R),
      'background scan reaches ready state');
    Assert((Pos('"match_count":2', R.DataJson) > 0) and
      (Pos('"complete":false', R.DataJson) > 0),
      'two readable regions are scanned and unreadable gap is partial');

    PCardinal(Base)^ := 758;
    Request.ValueText := '758';
    R := Scanner.RefineScan(ScanId, Request, Identity);
    Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
      'first refinement keeps only the changed region');
    PCardinal(Base)^ := 880;
    Request.ValueText := '880';
    R := Scanner.RefineScan(ScanId, Request, Identity);
    Assert((R.Code = rcOk) and (Pos('"match_count":1', R.DataJson) > 0),
      'second refinement preserves the same candidate');
    Assert(Scanner.CancelScan(ScanId, Identity).Code = rcOk,
      'ready scan session can be released');

    PCardinal(Base)^ := 1234;
    PCardinal(DisjointBase)^ := 1234;
    SetLength(Request.Ranges, 2);
    if QWord(PtrUInt(Base)) < QWord(PtrUInt(DisjointBase)) then
    begin
      Request.Ranges[0].StartAddress := QWord(PtrUInt(Base));
      Request.Ranges[1].StartAddress := QWord(PtrUInt(DisjointBase));
    end
    else
    begin
      Request.Ranges[0].StartAddress := QWord(PtrUInt(DisjointBase));
      Request.Ranges[1].StartAddress := QWord(PtrUInt(Base));
    end;
    Request.Ranges[0].Size := PageSize;
    Request.Ranges[1].Size := PageSize;
    Request.RangeStart := Request.Ranges[0].StartAddress;
    Request.RangeSize := QWord(PageSize) * 2;
    Request.MaxBytes := Request.RangeSize;
    Request.ValueText := '1234';
    Assert(Scanner.AuthorizeLocalRanges(Identity, Request.Ranges,
      Request.MaxBytes, Request.MaxResults, ScopeId).Code = rcOk,
      'two disjoint ranges are locally authorized together');
    Request.ScopeId := ScopeId;
    R := Scanner.FirstScan(Request, Identity);
    ScanId := JsonField(R.DataJson, 'scan_id');
    Assert((R.Code = rcOk) and WaitReady(Scanner, ScanId, Identity, R),
      'true multi-range scan reaches ready state');
    Assert((Pos('"match_count":2', R.DataJson) > 0) and
      (Pos('"requested_bytes":8192', R.DataJson) > 0),
      'both disjoint authorized pages are scanned exactly once');
    Assert(Scanner.CancelScan(ScanId, Identity).Code = rcOk,
      'multi-range session can be released');
    Request.Ranges[1].StartAddress := Request.Ranges[0].StartAddress + 1;
    Assert(Scanner.AuthorizeLocalRanges(Identity, Request.Ranges,
      Request.MaxBytes, Request.MaxResults, ScopeId).StableCode =
      'scan_ranges_overlap',
      'overlapping ranges are rejected before a scope is issued');
    SetLength(Request.Ranges, 0);

    R := Scanner.AuthorizeProcessScope(Identity, 'private',
      QWord(PageSize) * 2, Request.MaxResults, 32, PlannedRanges,
      ScopeId, ScopePartialReason);
    Assert((R.Code = rcOk) and (Length(PlannedRanges) > 0) and
      (ScopePartialReason = 'byte_limit'),
      'process-level private selector creates a bounded partial scope');
    Request.Ranges := Copy(PlannedRanges, 0, Length(PlannedRanges));
    Request.RangeStart := PlannedRanges[0].StartAddress;
    Request.RangeSize := QWord(PageSize) * 2;
    Request.MaxBytes := QWord(PageSize) * 2;
    Request.ScopeId := ScopeId;
    Request.ScopePartialReason := ScopePartialReason;
    Request.ValueText := '3735928559';
    R := Scanner.FirstScan(Request, Identity);
    ScanId := JsonField(R.DataJson, 'scan_id');
    Assert((R.Code = rcOk) and WaitReady(Scanner, ScanId, Identity, R),
      'process-planned scan reaches ready state');
    Assert(Pos('"partial_reason":"byte_limit"', R.DataJson) > 0,
      'scope planning truncation survives into final scan coverage');
    Assert(Scanner.CancelScan(ScanId, Identity).Code = rcOk,
      'process-planned scan can be released');
    Request.ScopePartialReason := '';
    SetLength(Request.Ranges, 0);

    CancelBase := VirtualAlloc(nil, 64 * 1024 * 1024,
      MEM_RESERVE or MEM_COMMIT, PAGE_READWRITE);
    Assert(CancelBase <> nil, 'large cancellation fixture allocated');
    try
      Request.ValueText := '3735928559';
      Request.RangeStart := QWord(PtrUInt(CancelBase));
      Request.RangeSize := 64 * 1024 * 1024;
      Request.MaxBytes := Request.RangeSize;
      Assert(Scanner.AuthorizeLocalScope(Identity, Request.RangeStart,
        Request.RangeSize, Request.MaxBytes, Request.MaxResults,
        ScopeId).Code = rcOk, 'large cancellation scope is authorized');
      Request.ScopeId := ScopeId;
      R := Scanner.FirstScan(Request, Identity);
      ScanId := JsonField(R.DataJson, 'scan_id');
      Assert((R.Code = rcOk) and (ScanId <> ''),
        'large background scan starts');
      CancelStarted := GetTickCount64;
      Assert(Scanner.CancelScan(ScanId, Identity).Code = rcOk,
        'in-flight scan accepts cancellation');
      Assert(GetTickCount64 - CancelStarted < 2000,
        'cancellation reaches a scan boundary without UI-scale blocking');
    finally
      VirtualFree(CancelBase, 0, MEM_RELEASE);
    end;
    Assert(Processes.Detach(Identity).Code = rcOk,
      'self process detaches');
  finally
    Scanner.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
    VirtualFree(Base, 0, MEM_RELEASE);
    VirtualFree(DisjointBase, 0, MEM_RELEASE);
  end;
  WriteLn('MULTI_REGION_VALUE_SCAN=PASS');
end.
