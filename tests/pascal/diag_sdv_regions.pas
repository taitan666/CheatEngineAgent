program diag_sdv_regions;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, FPJSON, JSONParser,
  cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_scan_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

var
  TargetPid: Cardinal;
  ParseCode: Integer;
  Hasher: TCEAWindowsSha256;
  Backend: TCEAWin32ReadOnlyBackend;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Scanner: TCEAScanCapability;
  AttachRequest: TCEAttachRequest;
  Identity: TCEProcessIdentity;
  R: TCEAResult;
  Ranges: TCEScanRangeArray;
  ScopeId, PartialReason: string;

begin
  Assert(ParamCount = 1, 'pid is required');
  Val(ParamStr(1), TargetPid, ParseCode);
  Assert(ParseCode = 0, 'pid is valid');

  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Scanner := TCEAScanCapability.Create(Backend, Processes,
    512 * 1024 * 1024, 1000, 1);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:diag';
    AttachRequest.LeaseId := 'lease:diag';
    AttachRequest.Pid := TargetPid;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcOk, 'attach');

    // 直接调用 PlanReadableRegions 看结果
    R := Backend.PlanReadableRegions('private', 512 * 1024 * 1024, 4096);
    WriteLn('PLAN_RESULT code=' + R.StableCode);
    WriteLn('PLAN_RESULT data_len=' + IntToStr(Length(R.DataJson)));

    // 调用 AuthorizeProcessScope 看结果
    R := Scanner.AuthorizeProcessScope(Identity, 'private',
      512 * 1024 * 1024, 1000, 4096, Ranges, ScopeId, PartialReason);
    WriteLn('AUTH_SCOPE code=' + R.StableCode);
    WriteLn('AUTH_SCOPE range_count=' + IntToStr(Length(Ranges)));
    WriteLn('AUTH_SCOPE scope_id=' + ScopeId);
    WriteLn('AUTH_SCOPE partial=' + PartialReason);
  finally
    Scanner.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
  end;
end.
