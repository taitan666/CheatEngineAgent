program test_ce_scan_capability;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, fpjson, jsonparser, cea_types, cea_results,
  cea_runtime_backend_ports,
  cea_process_capability, cea_scan_capability,
  cea_win32_selftest_backend, cea_test_ports;

const
  Sentinel: array[0..15] of Byte =
    ($41, $47, $45, $4E, $54, $4F, $53, $2D,
     $53, $43, $41, $4E, $2D, $30, $31, $00);

var
  Backend: TCEAWin32SelfTestBackend;
  Hasher: TCEATestHasher;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Scanner: TCEAScanCapability;
  AttachRequest: TCEAttachRequest;
  ScanRequest: TCEScanRequest;
  Identity, StaleIdentity: TCEProcessIdentity;
  R: TCEAResult;
  CallsBefore: Cardinal;
  ScopeId: string;
  StatusData: TJSONData;

begin
  Backend := TCEAWin32SelfTestBackend.Create(GetCurrentProcessId);
  Backend.ConfigureScanRegion(QWord(PtrUInt(@Sentinel[0])), SizeOf(Sentinel));
  Hasher := TCEATestHasher.Create;
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Scanner := TCEAScanCapability.Create(Backend, Processes, 64 * 1024, 16, 1);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:self-scan';
    AttachRequest.LeaseId := 'lease:self-scan';
    AttachRequest.Pid := GetCurrentProcessId;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    Assert(Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      Identity).Code = rcOk, 'authorized self-test attach succeeds');

    FillChar(ScanRequest, SizeOf(ScanRequest), 0);
    ScanRequest.TaskId := AttachRequest.TaskId;
    ScanRequest.ProcessIdentityId := Identity.Id;
    ScanRequest.LeaseId := AttachRequest.LeaseId;
    ScanRequest.ScanKind := 'aob';
    ScanRequest.ValueText := '41 47 45 4E 54 4F 53 2D 53 43 41 4E 2D 30 31 00';
    ScanRequest.RangeStart := QWord(PtrUInt(@Sentinel[0]));
    ScanRequest.RangeSize := SizeOf(Sentinel);
    ScanRequest.MaxBytes := 1024;
    ScanRequest.MaxResults := 4;
    ScanRequest.Epoch := Identity.Epoch;

    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk, 'real self-process exact-byte scan succeeds');
    Assert(Pos(IntToHex(QWord(PtrUInt(@Sentinel[0])), 16),
      UpperCase(R.DataJson)) > 0, 'scan returns the real sentinel address');
    Assert(Backend.FirstScanCount = 1, 'first scan reaches backend once');
    R := Scanner.AuthorizeLocalScope(Identity, ScanRequest.RangeStart,
      ScanRequest.RangeSize, ScanRequest.MaxBytes,
      ScanRequest.MaxResults, ScopeId);
    Assert(R.Code = rcScanRunning,
      'active scan prevents replacement of its local scope');
    R := Scanner.GetStatus('selftest-scan-1', Identity);
    Assert(R.Code = rcOk, 'scan status succeeds');
    StatusData := GetJSON(R.DataJson);
    try
      Assert(TJSONObject(StatusData).Get('state', '') = 'ready',
        'synchronous scan exposes a ready active session for refinement');
    finally
      StatusData.Free;
    end;

    CallsBefore := Backend.FirstScanCount;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcScanRunning, 'concurrency budget blocks a second scan');
    Assert(Backend.FirstScanCount = CallsBefore,
      'blocked concurrent scan never reaches backend');

    R := Scanner.RefineScan('selftest-scan-1', ScanRequest, Identity);
    Assert(R.Code = rcOk, 'refine keeps the matching sentinel candidate');
    Assert(Pos('"match_count":1', R.DataJson) > 0,
      'refine reports one remaining candidate');

    StaleIdentity := Identity;
    Inc(StaleIdentity.Epoch);
    CallsBefore := Backend.RefineScanCount;
    R := Scanner.RefineScan('selftest-scan-1', ScanRequest, StaleIdentity);
    Assert(R.Code = rcStaleProcessIdentity,
      'stale identity cannot refine a scan');
    Assert(Backend.RefineScanCount = CallsBefore,
      'stale refine never reaches backend');

    R := Scanner.CancelScan('selftest-scan-1', Identity);
    Assert(R.Code = rcOk, 'active scan cancels cleanly');
    Assert(Backend.CancelScanCount = 1, 'cancel reaches backend once');
    Assert(Scanner.CancelScan('selftest-scan-1', Identity).Code = rcOk,
      'repeated cancel is idempotent');
    Assert(Backend.CancelScanCount = 1,
      'repeated cancel does not call backend again');
    Assert(Scanner.GetStatus('selftest-scan-1', Identity).Code = rcConflict,
      'cancelled scan is no longer reported active');

    ScanRequest.RangeStart := High(QWord) - 3;
    ScanRequest.RangeSize := 8;
    CallsBefore := Backend.FirstScanCount;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcInvalidArgument,
      'wrapping scan range is rejected');
    Assert(Backend.FirstScanCount = CallsBefore,
      'wrapping scan range never reaches backend');

    ScanRequest.RangeStart := QWord(PtrUInt(@Sentinel[0]));
    ScanRequest.RangeSize := SizeOf(Sentinel);
    ScanRequest.MaxBytes := 64 * 1024 + 1;
    CallsBefore := Backend.FirstScanCount;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcBudgetExceeded, 'scan byte budget is enforced');
    Assert(Backend.FirstScanCount = CallsBefore,
      'over-budget scan never reaches backend');

    ScanRequest.MaxBytes := 1024;
    ScanRequest.MaxDurationMs := 30001;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcBudgetExceeded,
      'scan duration hard limit is enforced');
    ScanRequest.MaxDurationMs := 30000;
    ScanRequest.MaxRegions := 4097;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcBudgetExceeded,
      'scan region hard limit is enforced');
    ScanRequest.MaxRegions := 4096;

    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk, 'new scan starts before process detach');
    Assert(Processes.Detach(Identity).Code = rcOk,
      'process detaches while candidate session exists');
    Assert(Processes.Attach(AttachRequest, tcSinglePlayerOffline,
      Identity).Code = rcOk, 'same process can be reattached');
    ScanRequest.ProcessIdentityId := Identity.Id;
    ScanRequest.Epoch := Identity.Epoch;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk,
      'reattach invalidates old candidate session before new scan');
    Assert(Scanner.CancelScan('selftest-scan-1', Identity).Code = rcOk,
      'reattached scan can be cancelled');

    Assert(Processes.Detach(Identity).Code = rcOk,
      'self-test process detaches cleanly');
    WriteLn('CE_SCAN_CAPABILITY=PASS');
  finally
    Scanner.Free;
    Processes.Free;
    Identities.Free;
    Hasher.Free;
    Backend.Free;
  end;
end.
