program verify_sdv_attach;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_types, cea_results, cea_runtime_backend_ports,
  cea_process_capability, cea_module_capability,
  cea_windows_sha256, cea_win32_readonly_backend;

var
  TargetPid: Cardinal;
  ParseCode: Integer;
  Hasher: TCEAWindowsSha256;
  Backend: TCEAWin32ReadOnlyBackend;
  Identities: TCEAProcessIdentityService;
  Processes: TCEAProcessCapability;
  Modules: TCEAModuleCapability;
  AttachRequest: TCEAttachRequest;
  Identity: TCEProcessIdentity;
  Info: TCEARuntimeProcessInfo;
  R: TCEAResult;

begin
  Assert(ParamCount = 1, 'pid is required');
  Val(ParamStr(1), TargetPid, ParseCode);
  Assert(ParseCode = 0, 'pid is valid');

  Hasher := TCEAWindowsSha256.Create;
  Backend := TCEAWin32ReadOnlyBackend.Create(Hasher);
  Identities := TCEAProcessIdentityService.Create(Hasher);
  Processes := TCEAProcessCapability.Create(Backend, Identities);
  Modules := TCEAModuleCapability.Create(Backend, Processes, 32);
  try
    // 1. 查询进程信息（不附加）
    R := Backend.QueryProcessInfo(TargetPid, Info);
    Assert(R.Code = rcOk, 'query process info');
    WriteLn('PROCESS_INFO executable=' + Info.ExecutablePath);
    WriteLn('PROCESS_INFO arch=' + IntToStr(Ord(Info.Architecture)));
    WriteLn('PROCESS_INFO sha256=' + Info.ExecutableSha256);

    // 2. 只读附加
    FillChar(AttachRequest, SizeOf(AttachRequest), 0);
    AttachRequest.TaskId := 'task:sdv-verify';
    AttachRequest.LeaseId := 'lease:sdv-verify';
    AttachRequest.Pid := TargetPid;
    AttachRequest.OperatorAttestsAuthorizedDebugging := True;
    R := Processes.Attach(AttachRequest, tcSinglePlayerOffline, Identity);
    Assert(R.Code = rcOk, 'attach read-only');
    WriteLn('ATTACH_OK identity_id=' + Identity.Id);
    WriteLn('ATTACH_OK epoch=' + IntToStr(Identity.Epoch));
    WriteLn('ATTACH_OK classification=' +
      IntToStr(Ord(Identity.TargetClassification)));

    // 3. 列出模块（确认能枚举 .NET 模块）
    R := Modules.ListModules(AttachRequest.TaskId, AttachRequest.LeaseId,
      Identity, 32);
    Assert(R.Code = rcOk, 'list modules');
    WriteLn('MODULES_OK count_json=' + R.DataJson);

    WriteLn('VERIFY_SDV_ATTACH=PASS');
  finally
    Modules.Free;
    Processes.Free;
    Identities.Free;
    Backend.Free;
    Hasher.Free;
  end;
end.
