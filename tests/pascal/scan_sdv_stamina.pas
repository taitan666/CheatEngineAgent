program scan_sdv_stamina;

{$mode objfpc}{$H+}

uses
  SysUtils, FPJSON, JSONParser, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_scan_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

var
  TargetPid: Cardinal;
  TargetValue: string;
  ParseCode: Integer;
  Hasher: TCEAWindowsSha256;
  Backend: TCEAWin32ReadOnlyBackend;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Scanner: TCEAScanCapability;
  AttachRequest: TCEAttachRequest;
  ScanRequest: TCEScanRequest;
  Identity: TCEProcessIdentity;
  R: TCEAResult;
  ScopeId, PartialReason, ScanId: string;
  Ranges: TCEScanRangeArray;
  Deadline: QWord;
  Data: TJSONData;

begin
  Assert(ParamCount >= 2, 'pid and value are required');
  Val(ParamStr(1), TargetPid, ParseCode);
  Assert(ParseCode = 0, 'pid is valid');
  TargetValue := ParamStr(2);

  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Scanner := TCEAScanCapability.Create(Backend, Processes,
    512 * 1024 * 1024, 1000, 1);
  try
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:sdv-scan';
    AttachRequest.LeaseId := 'lease:sdv-scan';
    AttachRequest.Pid := TargetPid;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcOk, 'attach');

    // 授权进程级扫描范围（private 内存，返回可读区域 + scope_id）
    R := Scanner.AuthorizeProcessScope(Identity, 'private',
      512 * 1024 * 1024, 1000, 4096, Ranges, ScopeId, PartialReason);
    Assert(R.Code = rcOk, 'authorize process scope: ' + R.StableCode);
    WriteLn('SCOPE range_count=' + IntToStr(Length(Ranges)) +
      ' partial=' + PartialReason);

    FillChar(ScanRequest, SizeOf(ScanRequest), 0);
    ScanRequest.TaskId := AttachRequest.TaskId;
    ScanRequest.LeaseId := AttachRequest.LeaseId;
    ScanRequest.ProcessIdentityId := Identity.Id;
    ScanRequest.ScanKind := 'value';
    ScanRequest.ValueType := 'single';
    ScanRequest.ValueText := TargetValue;
    ScanRequest.ScopeId := ScopeId;
    ScanRequest.ScopePartialReason := PartialReason;
    ScanRequest.Epoch := Identity.Epoch;
    ScanRequest.MaxBytes := 512 * 1024 * 1024;
    ScanRequest.MaxResults := 1000;
    ScanRequest.MaxDurationMs := 30000;
    ScanRequest.MaxRegions := 4096;
    ScanRequest.Ranges := Ranges;
    if Length(Ranges) > 0 then
    begin
      ScanRequest.RangeStart := Ranges[0].StartAddress;
      ScanRequest.RangeSize := Ranges[0].Size;
    end;
    R := Scanner.FirstScan(ScanRequest, Identity);
    Assert(R.Code = rcOk, 'first scan starts: ' + R.StableCode);

    // 从 FirstScan 结果提取 scan_id
    ScanId := '';
    Data := GetJSON(R.DataJson);
    try
      ScanId := TJSONObject(Data).Get('scan_id', '');
    finally
      Data.Free;
    end;
    WriteLn('SCAN_ID=' + ScanId);

    // 等待扫描完成
    Deadline := GetTickCount64 + 30000;
    repeat
      R := Scanner.GetStatus(ScanId, Identity);
      if R.Failed then Break;
      Data := GetJSON(R.DataJson);
      try
        if TJSONObject(Data).Get('state', '') = 'ready' then Break;
      finally
        Data.Free;
      end;
      Sleep(50);
    until GetTickCount64 >= Deadline;

    if R.Failed then
      WriteLn('SCAN_RESULT failed=' + R.StableCode)
    else
      WriteLn('SCAN_RESULT ' + R.DataJson);
  finally
    Scanner.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
  end;
end.
