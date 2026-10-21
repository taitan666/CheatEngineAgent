program test_scan_512mib_budget;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, FPJSON, JSONParser, cea_types, cea_results,
  cea_process_capability, cea_scan_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

const
  FixtureSize = QWord(512) * 1024 * 1024;
  DeadlineMs = 35000;

function JsonString(const AJson, AName: string): string;
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

function JsonInt(const AJson, AName: string): Int64;
var
  Data: TJSONData;
begin
  Data := GetJSON(AJson);
  try
    Result := TJSONObject(Data).Get(AName, Int64(-1));
  finally
    Data.Free;
  end;
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
  ScopeId, ScanId, State, PartialReason: string;
  Base: Pointer;
  R: TCEAResult;
  StartedAt, Elapsed, ShortStarted, ShortElapsed: QWord;
begin
  Base := VirtualAlloc(nil, FixtureSize, MEM_RESERVE or MEM_COMMIT,
    PAGE_READWRITE);
  if Base = nil then
    raise Exception.Create('Unable to allocate the 512 MiB performance fixture');
  FillChar(Base^, FixtureSize, $A5);

  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Scanner := TCEAScanCapability.Create(Backend, Processes,
    FixtureSize, 10000, 1);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:scan-512mib-budget';
    AttachRequest.LeaseId := 'lease:scan-512mib-budget';
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
    Request.ValueText := '3735928559';
    Request.RangeStart := QWord(PtrUInt(Base));
    Request.RangeSize := FixtureSize;
    Request.MaxBytes := FixtureSize;
    Request.MaxResults := 10000;
    Request.MaxDurationMs := 30000;
    Request.Epoch := Identity.Epoch;
    Assert(Scanner.AuthorizeLocalScope(Identity, Request.RangeStart,
      Request.RangeSize, Request.MaxBytes, Request.MaxResults,
      ScopeId).Code = rcOk, 'exact 512 MiB scope is authorized');
    Request.ScopeId := ScopeId;

    StartedAt := GetTickCount64;
    R := Scanner.FirstScan(Request, Identity);
    Assert(R.Code = rcOk, 'maximum-budget scan starts');
    ScanId := JsonString(R.DataJson, 'scan_id');
    Assert(ScanId <> '', 'maximum-budget scan has an id');
    repeat
      Sleep(10);
      R := Scanner.GetStatus(ScanId, Identity);
      Assert(R.Code = rcOk, 'maximum-budget status remains readable');
      State := JsonString(R.DataJson, 'state');
      Elapsed := GetTickCount64 - StartedAt;
    until (State <> 'running') or (Elapsed > DeadlineMs);

    Assert(State = 'ready', 'scan reaches a terminal ready projection');
    Assert(Elapsed <= DeadlineMs,
      '30-second backend ceiling completes within the 35-second harness allowance');
    Assert(JsonInt(R.DataJson, 'requested_bytes') = Int64(FixtureSize),
      'projection preserves the exact 512 MiB request');
    Assert(JsonInt(R.DataJson, 'inspected_bytes') <= Int64(FixtureSize),
      'scanner never inspects beyond the byte budget');
    PartialReason := JsonString(R.DataJson, 'partial_reason');
    Assert((PartialReason = '') or (PartialReason = 'time_limit'),
      'the only accepted worst-case truncation is the time ceiling');
    WriteLn('SCAN_512MIB_BUDGET=PASS elapsed_ms=', Elapsed,
      ' inspected_bytes=', JsonInt(R.DataJson, 'inspected_bytes'),
      ' partial_reason=', PartialReason);
    Assert(Scanner.CancelScan(ScanId, Identity).Code = rcOk,
      'completed performance session is released');

    Request.MaxDurationMs := 1;
    Assert(Scanner.AuthorizeLocalScope(Identity, Request.RangeStart,
      Request.RangeSize, Request.MaxBytes, Request.MaxResults,
      ScopeId).Code = rcOk, 'same maximum range is reauthorized');
    Request.ScopeId := ScopeId;
    ShortStarted := GetTickCount64;
    R := Scanner.FirstScan(Request, Identity);
    Assert(R.Code = rcOk, 'short-deadline production scan starts');
    ScanId := JsonString(R.DataJson, 'scan_id');
    repeat
      Sleep(1);
      R := Scanner.GetStatus(ScanId, Identity);
      Assert(R.Code = rcOk, 'short-deadline status remains readable');
      State := JsonString(R.DataJson, 'state');
      ShortElapsed := GetTickCount64 - ShortStarted;
    until (State <> 'running') or (ShortElapsed > 2000);
    Assert(State = 'ready', 'short-deadline scan reaches ready projection');
    Assert(JsonString(R.DataJson, 'partial_reason') = 'time_limit',
      'production backend exposes the elapsed-time ceiling');
    Assert(JsonInt(R.DataJson, 'inspected_bytes') < Int64(FixtureSize),
      'time-limited scan stops before the full byte budget');
    Assert(ShortElapsed <= 2000,
      'time-limit checkpoint is observed without UI-scale blocking');
    WriteLn('SCAN_TIME_LIMIT=PASS elapsed_ms=', ShortElapsed,
      ' inspected_bytes=', JsonInt(R.DataJson, 'inspected_bytes'));
    Assert(Scanner.CancelScan(ScanId, Identity).Code = rcOk,
      'time-limited performance session is released');
    Assert(Processes.Detach(Identity).Code = rcOk, 'self process detaches');
  finally
    Scanner.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
    VirtualFree(Base, 0, MEM_RELEASE);
  end;
end.
