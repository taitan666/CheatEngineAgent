unit cea_scan_capability;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson, jsonparser, cea_types, cea_results,
  cea_runtime_backend_ports, cea_process_capability;

type
  TCEAScanCapability = class
  private
    FBackend: ICEAReadOnlyRuntimeBackend;
    FProcesses: TCEAProcessCapability;
    FMaxBytesPerScan: QWord;
    FMaxResultsPerScan: Cardinal;
    FMaxConcurrentScans: Cardinal;
    FActiveScanId: string;
    FLastCancelledScanId: string;
    FLastScanResultJson: string;
    FActiveAttachmentSerial: QWord;
    FLocalScopeAttachmentSerial: QWord;
    FLocalScopeId: string;
    FLocalScopeIdentityId: string;
    FLocalScopeEpoch: QWord;
    FLocalScopePartialReason: string;
    FLocalRangeStart: QWord;
    FLocalRangeSize: QWord;
    FLocalRanges: TCEScanRangeArray;
    FLocalMaxBytes: QWord;
    FLocalMaxResults: Cardinal;
    function ValidateTarget(const ARequest: TCEScanRequest;
      const AIdentity: TCEProcessIdentity): TCEAResult;
    function RequestJson(const ARequest: TCEScanRequest): string;
    function ScanIdFromResult(const AResult: TCEAResult): string;
    procedure RefreshAttachmentGeneration;
    function EffectiveRanges(const ARequest: TCEScanRequest): TCEScanRangeArray;
    function ValidateRanges(const ARanges: TCEScanRangeArray;
      const AMaxBytes: QWord; const AMaxRanges: Cardinal;
      out ATotalBytes: QWord): TCEAResult;
    function AuthorizeRangesInternal(const AIdentity: TCEProcessIdentity;
      const ARanges: TCEScanRangeArray; const AMaxBytes: QWord;
      const AMaxResults, AMaxRanges: Cardinal;
      out AScopeId: string): TCEAResult;
  public
    constructor Create(const ABackend: ICEAReadOnlyRuntimeBackend;
      const AProcesses: TCEAProcessCapability;
      const AMaxBytesPerScan: QWord;
      const AMaxResultsPerScan, AMaxConcurrentScans: Cardinal);
    function AuthorizeLocalScope(const AIdentity: TCEProcessIdentity;
      const ARangeStart, ARangeSize, AMaxBytes: QWord;
      const AMaxResults: Cardinal; out AScopeId: string): TCEAResult;
    function AuthorizeLocalRanges(const AIdentity: TCEProcessIdentity;
      const ARanges: TCEScanRangeArray; const AMaxBytes: QWord;
      const AMaxResults: Cardinal; out AScopeId: string): TCEAResult;
    function AuthorizeProcessScope(const AIdentity: TCEProcessIdentity;
      const ARegionKinds: string; const AMaxBytes: QWord;
      const AMaxResults, AMaxRegions: Cardinal;
      out ARanges: TCEScanRangeArray; out AScopeId,
      APartialReason: string): TCEAResult;
    function RevokeLocalScope(const AScopeId: string): TCEAResult;
    function FirstScan(const ARequest: TCEScanRequest;
      const AIdentity: TCEProcessIdentity): TCEAResult;
    function RefineScan(const AScanId: string;
      const ARequest: TCEScanRequest;
      const AIdentity: TCEProcessIdentity): TCEAResult;
    function GetStatus(const AScanId: string;
      const AIdentity: TCEProcessIdentity): TCEAResult;
    function CancelScan(const AScanId: string;
      const AIdentity: TCEProcessIdentity): TCEAResult;
  end;

implementation

function TCEAScanCapability.EffectiveRanges(
  const ARequest: TCEScanRequest): TCEScanRangeArray;
begin
  if Length(ARequest.Ranges) > 0 then
    Exit(Copy(ARequest.Ranges, 0, Length(ARequest.Ranges)));
  SetLength(Result, 1);
  Result[0].StartAddress := ARequest.RangeStart;
  Result[0].Size := ARequest.RangeSize;
end;

function TCEAScanCapability.ValidateRanges(const ARanges: TCEScanRangeArray;
  const AMaxBytes: QWord; const AMaxRanges: Cardinal;
  out ATotalBytes: QWord): TCEAResult;
var
  I: Integer;
  RangeLast, PreviousLast: QWord;
begin
  ATotalBytes := 0;
  if (Length(ARanges) = 0) or (Length(ARanges) > AMaxRanges) or
     (AMaxBytes = 0) or (AMaxBytes > FMaxBytesPerScan) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'scan_ranges_invalid', '{}'));
  PreviousLast := 0;
  for I := 0 to High(ARanges) do
  begin
    if (ARanges[I].StartAddress = 0) or (ARanges[I].Size = 0) or
       (ARanges[I].StartAddress > High(QWord) - (ARanges[I].Size - 1)) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'scan_ranges_invalid', '{}'));
    RangeLast := ARanges[I].StartAddress + ARanges[I].Size - 1;
    if (I > 0) and (ARanges[I].StartAddress <= PreviousLast) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'scan_ranges_overlap', '{}'));
    if ATotalBytes > High(QWord) - ARanges[I].Size then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'scan_budget_exceeded', '{}'));
    Inc(ATotalBytes, ARanges[I].Size);
    if ATotalBytes > AMaxBytes then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'scan_budget_exceeded', '{}'));
    PreviousLast := RangeLast;
  end;
  Result := TCEAResult.Ok('{}');
end;

procedure TCEAScanCapability.RefreshAttachmentGeneration;
begin
  if FProcesses = nil then Exit;
  if (FActiveScanId <> '') and
     (FActiveAttachmentSerial <> FProcesses.AttachmentSerial) then
  begin
    FActiveScanId := '';
    FLastCancelledScanId := '';
    FLastScanResultJson := '';
  end;
  if (FLocalScopeId <> '') and
     (FLocalScopeAttachmentSerial <> FProcesses.AttachmentSerial) then
  begin
    FLocalScopeId := '';
    FLocalScopePartialReason := '';
    SetLength(FLocalRanges, 0);
  end;
end;

function JsonQuoted(const AValue: string): string;
var
  JsonString: TJSONString;
begin
  JsonString := TJSONString.Create(AValue);
  try
    Result := JsonString.AsJSON;
  finally
    JsonString.Free;
  end;
end;

function TCEAScanCapability.AuthorizeLocalScope(
  const AIdentity: TCEProcessIdentity;
  const ARangeStart, ARangeSize, AMaxBytes: QWord;
  const AMaxResults: Cardinal; out AScopeId: string): TCEAResult;
var
  Ranges: TCEScanRangeArray;
begin
  SetLength(Ranges, 1);
  Ranges[0].StartAddress := ARangeStart;
  Ranges[0].Size := ARangeSize;
  Result := AuthorizeLocalRanges(AIdentity, Ranges, AMaxBytes,
    AMaxResults, AScopeId);
end;

function TCEAScanCapability.AuthorizeLocalRanges(
  const AIdentity: TCEProcessIdentity; const ARanges: TCEScanRangeArray;
  const AMaxBytes: QWord; const AMaxResults: Cardinal;
  out AScopeId: string): TCEAResult;
begin
  // 显式范围授权：最多 128 个有序不重叠范围（PRD 预算）
  Result := AuthorizeRangesInternal(AIdentity, ARanges, AMaxBytes,
    AMaxResults, 128, AScopeId);
end;

function TCEAScanCapability.AuthorizeRangesInternal(
  const AIdentity: TCEProcessIdentity; const ARanges: TCEScanRangeArray;
  const AMaxBytes: QWord; const AMaxResults, AMaxRanges: Cardinal;
  out AScopeId: string): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
  ScopeGuid: TGUID;
  TotalBytes: QWord;
begin
  AScopeId := '';
  RefreshAttachmentGeneration;
  if FActiveScanId <> '' then
    Exit(TCEAResult.Error(rcScanRunning, 'scan_session_active', '{}'));
  Result := ValidateRanges(ARanges, AMaxBytes, AMaxRanges, TotalBytes);
  if Result.Failed then Exit;
  if (AMaxResults = 0) or (AMaxResults > FMaxResultsPerScan) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'scan_scope_invalid', '{}'));
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then Exit;
  if (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Pid <> CurrentIdentity.Pid) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'scan_scope_target_changed', '{}'));
  if CreateGUID(ScopeGuid) <> 0 then
    Exit(TCEAResult.Error(rcInternalError,
      'scan_scope_id_failed', '{}'));
  FLocalScopeId := 'local-scan-' + GUIDToString(ScopeGuid);
  FLocalScopeAttachmentSerial := FProcesses.AttachmentSerial;
  FLocalScopeIdentityId := AIdentity.Id;
  FLocalScopeEpoch := AIdentity.Epoch;
  FLocalRanges := Copy(ARanges, 0, Length(ARanges));
  FLocalScopePartialReason := '';
  FLocalRangeStart := ARanges[0].StartAddress;
  FLocalRangeSize := TotalBytes;
  FLocalMaxBytes := AMaxBytes;
  FLocalMaxResults := AMaxResults;
  AScopeId := FLocalScopeId;
  Result := TCEAResult.Ok('{"scope_id":' + JsonQuoted(AScopeId) + '}');
end;

function TCEAScanCapability.AuthorizeProcessScope(
  const AIdentity: TCEProcessIdentity; const ARegionKinds: string;
  const AMaxBytes: QWord; const AMaxResults, AMaxRegions: Cardinal;
  out ARanges: TCEScanRangeArray; out AScopeId,
  APartialReason: string): TCEAResult;
var
  Data, Item: TJSONData;
  Items: TJSONArray;
  I: Integer;
  StartText: string;
begin
  SetLength(ARanges, 0);
  AScopeId := '';
  APartialReason := '';
  if (FBackend = nil) or (Trim(ARegionKinds) = '') or
     (AMaxRegions = 0) or (AMaxRegions > 4096) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'process_scan_scope_invalid', '{}'));
  Result := FBackend.PlanReadableRegions(ARegionKinds, AMaxBytes,
    AMaxRegions);
  if Result.Failed then Exit;
  Data := nil;
  try
    try
      Data := GetJSON(Result.DataJson);
      if (Data = nil) or (Data.JSONType <> jtObject) then
        raise EJSON.Create('object required');
      Item := TJSONObject(Data).Find('ranges');
      if (Item = nil) or (Item.JSONType <> jtArray) then
        raise EJSON.Create('ranges required');
      Items := TJSONArray(Item);
      SetLength(ARanges, Items.Count);
      for I := 0 to Items.Count - 1 do
      begin
        if Items.Items[I].JSONType <> jtObject then
          raise EJSON.Create('range object required');
        StartText := TJSONObject(Items.Items[I]).Get('start', '');
        if (Copy(StartText, 1, 2) <> '0x') or
           not TryStrToQWord('$' + Copy(StartText, 3, MaxInt),
             ARanges[I].StartAddress) then
          raise EJSON.Create('range start invalid');
        ARanges[I].Size := QWord(TJSONObject(Items.Items[I]).Get(
          'size', Int64(0)));
      end;
      APartialReason := TJSONObject(Data).Get('partial_reason', '');
    except
      Exit(TCEAResult.Error(rcInternalError,
        'process_scan_plan_invalid', '{}'));
    end;
  finally
    Data.Free;
  end;
  // 进程级自动规划：允许更多 region（现代游戏内存高度碎片化），
  // 与 AMaxRegions（≤4096）一致；显式范围仍受 128 限制。
  Result := AuthorizeRangesInternal(AIdentity, ARanges, AMaxBytes,
    AMaxResults, AMaxRegions, AScopeId);
  if not Result.Failed then
  begin
    FLocalScopePartialReason := APartialReason;
    Result := TCEAResult.Ok('{"scope_id":' + JsonQuoted(AScopeId) +
      ',"range_count":' + IntToStr(Length(ARanges)) +
      ',"partial_reason":' + JsonQuoted(APartialReason) + '}');
  end;
end;

function TCEAScanCapability.RevokeLocalScope(
  const AScopeId: string): TCEAResult;
begin
  RefreshAttachmentGeneration;
  if (AScopeId = '') or (AScopeId <> FLocalScopeId) then
    Exit(TCEAResult.Error(rcConflict,
      'scan_scope_not_active', '{}'));
  if FActiveScanId <> '' then
    Exit(TCEAResult.Error(rcScanRunning,
      'scan_session_active', '{}'));
  FLocalScopeId := '';
  FLocalScopePartialReason := '';
  SetLength(FLocalRanges, 0);
  Result := TCEAResult.Ok('{"scope_revoked":true}');
end;

constructor TCEAScanCapability.Create(
  const ABackend: ICEAReadOnlyRuntimeBackend;
  const AProcesses: TCEAProcessCapability;
  const AMaxBytesPerScan: QWord;
  const AMaxResultsPerScan, AMaxConcurrentScans: Cardinal);
begin
  inherited Create;
  FBackend := ABackend;
  FProcesses := AProcesses;
  FMaxBytesPerScan := AMaxBytesPerScan;
  FMaxResultsPerScan := AMaxResultsPerScan;
  FMaxConcurrentScans := AMaxConcurrentScans;
end;

function TCEAScanCapability.ValidateTarget(const ARequest: TCEScanRequest;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
  Ranges: TCEScanRangeArray;
  TotalBytes: QWord;
  MaxRanges: Cardinal;
  I: Integer;
begin
  RefreshAttachmentGeneration;
  if (FBackend = nil) or (FProcesses = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'scan_dependencies_missing', '{}'));
  if (ARequest.TaskId = '') or (ARequest.ProcessIdentityId = '') or
     (ARequest.LeaseId = '') or (ARequest.ScanKind = '') or
     (ARequest.ValueText = '') or (ARequest.MaxBytes = 0) or
     (ARequest.MaxResults = 0) or (ARequest.Epoch = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'scan_request_invalid', '{}'));
  if (FMaxBytesPerScan = 0) or (FMaxResultsPerScan = 0) or
     (ARequest.MaxBytes > FMaxBytesPerScan) or
     (ARequest.MaxResults > FMaxResultsPerScan) or
     (ARequest.MaxDurationMs > 30000) or
     (ARequest.MaxRegions > 4096) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'scan_budget_exceeded', '{}'));
  Ranges := EffectiveRanges(ARequest);
  MaxRanges := ARequest.MaxRegions;
  if MaxRanges = 0 then MaxRanges := 4096;
  Result := ValidateRanges(Ranges, ARequest.MaxBytes, MaxRanges,
    TotalBytes);
  if Result.Failed then Exit;
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then
    Exit;
  if (ARequest.ProcessIdentityId <> CurrentIdentity.Id) or
     (ARequest.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Pid <> CurrentIdentity.Pid) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'scan_target_changed', '{}'));
  if ARequest.ScanKind = 'value' then
  begin
    if (ARequest.ScopeId = '') or
       (ARequest.ScopeId <> FLocalScopeId) or
       (FLocalScopeIdentityId <> CurrentIdentity.Id) or
       (FLocalScopeEpoch <> CurrentIdentity.Epoch) or
       (Length(Ranges) <> Length(FLocalRanges)) or
       (ARequest.MaxBytes > FLocalMaxBytes) or
       (ARequest.MaxResults > FLocalMaxResults) then
      Exit(TCEAResult.Error(rcApprovalRequired,
        'local_scan_scope_required', '{}'));
    for I := 0 to High(Ranges) do
      if (Ranges[I].StartAddress <> FLocalRanges[I].StartAddress) or
         (Ranges[I].Size <> FLocalRanges[I].Size) then
        Exit(TCEAResult.Error(rcApprovalRequired,
          'local_scan_scope_required', '{}'));
    if ARequest.ValueType = '' then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'scan_value_type_required', '{}'));
  end;
  Result := TCEAResult.Ok('{}');
end;

function TCEAScanCapability.RequestJson(
  const ARequest: TCEScanRequest): string;
var
  MaxDurationMs, MaxRegions: Cardinal;
  Ranges: TCEScanRangeArray;
  I: Integer;
  RangeJson, ScopePartialReason: string;
begin
  MaxDurationMs := ARequest.MaxDurationMs;
  if MaxDurationMs = 0 then MaxDurationMs := 30000;
  MaxRegions := ARequest.MaxRegions;
  if MaxRegions = 0 then MaxRegions := 4096;
  Ranges := EffectiveRanges(ARequest);
  RangeJson := '[';
  for I := 0 to High(Ranges) do
  begin
    if I > 0 then RangeJson := RangeJson + ',';
    RangeJson := RangeJson + '{"start":"0x' +
      IntToHex(Ranges[I].StartAddress, 16) + '","size":' +
      IntToStr(Ranges[I].Size) + '}';
  end;
  RangeJson := RangeJson + ']';
  ScopePartialReason := ARequest.ScopePartialReason;
  if (ARequest.ScanKind = 'value') and
     (ARequest.ScopeId = FLocalScopeId) then
    ScopePartialReason := FLocalScopePartialReason;
  Result := '{"scan_kind":' + JsonQuoted(ARequest.ScanKind) +
    ',"value_type":' + JsonQuoted(ARequest.ValueType) +
    ',"scope_id":' + JsonQuoted(ARequest.ScopeId) +
    ',"scope_partial_reason":' + JsonQuoted(ScopePartialReason) +
    ',"value_text":' + JsonQuoted(ARequest.ValueText) +
    ',"range_start":"0x' + IntToHex(ARequest.RangeStart, 16) + '"' +
    ',"range_size":' + IntToStr(ARequest.RangeSize) +
    ',"ranges":' + RangeJson +
    ',"max_bytes":' + IntToStr(ARequest.MaxBytes) +
    ',"max_results":' + IntToStr(ARequest.MaxResults) +
    ',"max_duration_ms":' + IntToStr(MaxDurationMs) +
    ',"max_regions":' + IntToStr(MaxRegions) + '}';
end;

function TCEAScanCapability.ScanIdFromResult(
  const AResult: TCEAResult): string;
var
  Data: TJSONData;
begin
  Result := '';
  try
    Data := GetJSON(AResult.DataJson);
    try
      if Data.JSONType = jtObject then
        Result := TJSONObject(Data).Get('scan_id', '');
    finally
      Data.Free;
    end;
  except
    Result := '';
  end;
end;

function TCEAScanCapability.FirstScan(const ARequest: TCEScanRequest;
  const AIdentity: TCEProcessIdentity): TCEAResult;
begin
  Result := ValidateTarget(ARequest, AIdentity);
  if Result.Failed then
    Exit;
  if (FMaxConcurrentScans = 0) or (FActiveScanId <> '') then
    Exit(TCEAResult.Error(rcScanRunning,
      'scan_concurrency_exceeded', '{}'));
  Result := FBackend.FirstScan(RequestJson(ARequest));
  if Result.Failed then
    Exit;
  FActiveScanId := ScanIdFromResult(Result);
  if FActiveScanId = '' then
    Result := TCEAResult.Error(rcInternalError,
      'scan_backend_missing_id', '{}')
  else
  begin
    FActiveAttachmentSerial := FProcesses.AttachmentSerial;
    FLastScanResultJson := Result.DataJson;
  end;
end;

function TCEAScanCapability.RefineScan(const AScanId: string;
  const ARequest: TCEScanRequest;
  const AIdentity: TCEProcessIdentity): TCEAResult;
begin
  Result := ValidateTarget(ARequest, AIdentity);
  if Result.Failed then
    Exit;
  if (AScanId = '') or (AScanId <> FActiveScanId) then
    Exit(TCEAResult.Error(rcConflict, 'scan_not_active', '{}'));
  Result := FBackend.RefineScan('{"scan_id":' + JsonQuoted(AScanId) +
    ',"request":' + RequestJson(ARequest) + '}');
  if not Result.Failed then
    FLastScanResultJson := Result.DataJson;
end;

function TCEAScanCapability.GetStatus(const AScanId: string;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
begin
  RefreshAttachmentGeneration;
  if (FProcesses = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'scan_dependencies_missing', '{}'));
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then Exit;
  if (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) or
     (AIdentity.Pid <> CurrentIdentity.Pid) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'scan_target_changed', '{}'));
  if (AScanId = '') or (AScanId <> FActiveScanId) then
    Exit(TCEAResult.Error(rcConflict, 'scan_not_active', '{}'));
  Result := FBackend.GetScanStatus(AScanId);
  if not Result.Failed then
    FLastScanResultJson := Result.DataJson;
end;

function TCEAScanCapability.CancelScan(const AScanId: string;
  const AIdentity: TCEProcessIdentity): TCEAResult;
var
  CurrentIdentity: TCEProcessIdentity;
begin
  RefreshAttachmentGeneration;
  if (FBackend = nil) or (FProcesses = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'scan_dependencies_missing', '{}'));
  Result := FProcesses.Current(CurrentIdentity);
  if Result.Failed then
    Exit;
  if (AIdentity.Id <> CurrentIdentity.Id) or
     (AIdentity.Epoch <> CurrentIdentity.Epoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'scan_target_changed', '{}'));
  if (AScanId = '') or (AScanId <> FActiveScanId) then
  begin
    if (AScanId <> '') and (AScanId = FLastCancelledScanId) then
      Exit(TCEAResult.Ok('{"cancelled":true,"already_cancelled":true}'));
    Exit(TCEAResult.Error(rcConflict, 'scan_not_active', '{}'));
  end;
  Result := FBackend.CancelScan(AScanId);
  if not Result.Failed then
  begin
    FLastCancelledScanId := AScanId;
    FActiveScanId := '';
    FLastScanResultJson := '';
    FLocalScopeId := '';
  end;
end;

end.
