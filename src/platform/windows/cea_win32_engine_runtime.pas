unit cea_win32_engine_runtime;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, fpjson, jsonparser, cea_types, cea_results, cea_ports,
  cea_runtime_backend_ports,
  cea_owner_thread_queue, cea_process_capability,
  cea_memory_read_capability, cea_module_capability,
  cea_scan_capability, cea_disassembly_capability;

type
  TCEAEngineRuntime = class(TObject, ICEACommandExecutor)
  private
    FCommandQueue: TCEACommandQueue;
    FIdentities: TCEAProcessIdentityService;
    FProcesses: TCEAProcessCapability;
    FMemory: TCEAMemoryReadCapability;
    FModules: TCEAModuleCapability;
    FScanner: TCEAScanCapability;
    FDisassembly: TCEADisassemblyCapability;
  public
    constructor Create(const ABackend: ICEAReadOnlyRuntimeBackend;
      const AHasher: ICEAHasher);
    destructor Destroy; override;
    function Execute(const ACapabilityId,
      ARequestJson: string): TCEAResult;
    function PumpCommands(const AMaxItems: Cardinal): Cardinal;
    property CommandQueue: TCEACommandQueue read FCommandQueue;
    property Processes: TCEAProcessCapability read FProcesses;
    property Memory: TCEAMemoryReadCapability read FMemory;
    property Modules: TCEAModuleCapability read FModules;
    property Scanner: TCEAScanCapability read FScanner;
    property Disassembly: TCEADisassemblyCapability read FDisassembly;
  end;

function RegisterEngine: TCEAResult; overload;
function RegisterEngine(const ABackend: ICEAReadOnlyRuntimeBackend;
  const AHasher: ICEAHasher): TCEAResult; overload;
procedure UnregisterEngine;
function EngineRegistered: Boolean;

var
  EngineRuntime: TCEAEngineRuntime = nil;

implementation

function TryParseHexAddress(const AText: string; out AValue: QWord): Boolean;
begin
  Result := (Length(AText) > 2) and (Copy(AText, 1, 2) = '0x') and
    TryStrToQWord('$' + Copy(AText, 3, MaxInt), AValue);
end;

constructor TCEAEngineRuntime.Create(
  const ABackend: ICEAReadOnlyRuntimeBackend;
  const AHasher: ICEAHasher);
begin
  inherited Create;
  FCommandQueue := TCEACommandQueue.Create;
  FIdentities := TCEAProcessIdentityService.Create(AHasher);
  FProcesses := TCEAProcessCapability.Create(ABackend, FIdentities);
  FMemory := TCEAMemoryReadCapability.Create(ABackend, FProcesses, 4096);
  FModules := TCEAModuleCapability.Create(ABackend, FProcesses, 256);
  FScanner := TCEAScanCapability.Create(ABackend, FProcesses,
    512 * 1024 * 1024, 10000, 1);
  FDisassembly := TCEADisassemblyCapability.Create(ABackend, FProcesses, 4096);
end;

destructor TCEAEngineRuntime.Destroy;
begin
  FDisassembly.Free;
  FScanner.Free;
  FModules.Free;
  FMemory.Free;
  FProcesses.Free;
  FIdentities.Free;
  FCommandQueue.Free;
  inherited Destroy;
end;

function TCEAEngineRuntime.Execute(const ACapabilityId,
  ARequestJson: string): TCEAResult;
var
  Data, Item: TJSONData;
  Obj, RangeObj: TJSONObject;
  Ranges: TJSONArray;
  AttachRequest: TCEAttachRequest;
  ReadRequest: TCEMemoryReadRequest;
  ScanRequest: TCEScanRequest;
  DisassemblyRequest: TCEDisassembleRequest;
  Identity: TCEProcessIdentity;
  ScanId, AddressText, ValueText: string;
  RangeIndex: Integer;
  TotalRangeBytes: QWord;
begin
  if ACapabilityId = 'runtime_health' then
    Exit(TCEAResult.Ok(
      '{"status":"ready","mode":"read_only","owner_thread":true}'));
  if ACapabilityId = 'process_list' then
    Exit(FProcesses.ListProcesses);

  Data := nil;
  try
    try
      Data := GetJSON(ARequestJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'engine_command_json_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'engine_command_object_required', '{}'));
    Obj := TJSONObject(Data);

    if ACapabilityId = 'process_attach' then
    begin
      FillChar(AttachRequest, SizeOf(AttachRequest), 0);
      AttachRequest.TaskId := Obj.Get('task_id', '');
      AttachRequest.LeaseId := Obj.Get('lease_ref', '');
      AttachRequest.Pid := Obj.Get('pid', 0);
      AttachRequest.OperatorAttestsAuthorizedDebugging := Obj.Get(
        'operator_attests_authorized_debugging', False);
      Exit(FProcesses.Attach(AttachRequest, tcSinglePlayerOffline, Identity));
    end;

    Result := FProcesses.Current(Identity);
    if Result.Failed then
      Exit;

    if ACapabilityId = 'process_detach' then
    begin
      if (Obj.Get('process_identity_ref', '') <> Identity.Id) or
         (QWord(Obj.Get('epoch', Int64(0))) <> Identity.Epoch) then
        Exit(TCEAResult.Error(rcStaleProcessIdentity,
          'detach_target_changed', '{}'));
      Exit(FProcesses.Detach(Identity));
    end;

    if ACapabilityId = 'memory_read' then
    begin
      FillChar(ReadRequest, SizeOf(ReadRequest), 0);
      ReadRequest.TaskId := Obj.Get('task_id', '');
      ReadRequest.ProcessIdentityId := Obj.Get('process_identity_ref', '');
      ReadRequest.LeaseId := Obj.Get('lease_ref', '');
      AddressText := Obj.Get('address', '');
      if not TryParseHexAddress(AddressText, ReadRequest.Address) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'memory_read_address_invalid', '{}'));
      ReadRequest.ByteCount := Obj.Get('byte_count', 0);
      Exit(FMemory.Read(ReadRequest, Identity));
    end;

    if ACapabilityId = 'module_list' then
      Exit(FModules.ListModules(Obj.Get('task_id', ''),
        Obj.Get('lease_ref', ''), Identity, Obj.Get('max_results', 0)));

    if ACapabilityId = 'memory_scan_status' then
      Exit(FScanner.GetStatus(Obj.Get('scan_id', ''), Identity));

    if ACapabilityId = 'disassemble' then
    begin
      FillChar(DisassemblyRequest, SizeOf(DisassemblyRequest), 0);
      DisassemblyRequest.TaskId := Obj.Get('task_id', '');
      DisassemblyRequest.ProcessIdentityId := Obj.Get(
        'process_identity_ref', '');
      DisassemblyRequest.LeaseId := Obj.Get('lease_ref', '');
      AddressText := Obj.Get('address', '');
      if not TryParseHexAddress(AddressText,
        DisassemblyRequest.Address) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'disassembly_address_invalid', '{}'));
      DisassemblyRequest.ByteCount := Obj.Get('byte_count', 0);
      Exit(FDisassembly.Disassemble(DisassemblyRequest, Identity));
    end;

    if (ACapabilityId = 'memory_scan_start') or
       (ACapabilityId = 'memory_scan_refine') then
    begin
      FillChar(ScanRequest, SizeOf(ScanRequest), 0);
      ScanRequest.TaskId := Obj.Get('task_id', '');
      ScanRequest.ProcessIdentityId := Obj.Get('process_identity_ref', '');
      ScanRequest.LeaseId := Obj.Get('lease_ref', '');
      ScanRequest.ScanKind := Obj.Get('scan_kind', '');
      ScanRequest.ValueType := Obj.Get('value_type', '');
      ScanRequest.ScopeId := Obj.Get('scope_id', '');
      if ScanRequest.ScanKind = 'aob' then
        ValueText := Obj.Get('aob_pattern', '')
      else
        ValueText := Obj.Get('value', '');
      ScanRequest.ValueText := ValueText;
      ScanRequest.Epoch := QWord(Obj.Get('epoch', Int64(0)));
      Item := Obj.Find('budget');
      if (Item = nil) or (Item.JSONType <> jtObject) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'scan_budget_invalid', '{}'));
      ScanRequest.MaxBytes := QWord(TJSONObject(Item).Get(
        'max_bytes', Int64(0)));
      ScanRequest.MaxResults := TJSONObject(Item).Get('max_results', 0);
      ScanRequest.MaxDurationMs := TJSONObject(Item).Get(
        'max_duration_ms', 30000);
      ScanRequest.MaxRegions := TJSONObject(Item).Get('max_regions', 4096);
      Item := Obj.Find('ranges');
      if (Item = nil) or (Item.JSONType <> jtArray) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'scan_ranges_invalid', '{}'));
      Ranges := TJSONArray(Item);
      if (Ranges.Count = 0) or (Ranges.Count > 128) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'scan_ranges_invalid', '{}'));
      SetLength(ScanRequest.Ranges, Ranges.Count);
      TotalRangeBytes := 0;
      for RangeIndex := 0 to Ranges.Count - 1 do
      begin
        if Ranges.Items[RangeIndex].JSONType <> jtObject then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'scan_ranges_invalid', '{}'));
        RangeObj := TJSONObject(Ranges.Items[RangeIndex]);
        if not TryParseHexAddress(RangeObj.Get('start', ''),
          ScanRequest.Ranges[RangeIndex].StartAddress) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'scan_range_start_invalid', '{}'));
        ScanRequest.Ranges[RangeIndex].Size := QWord(RangeObj.Get(
          'size', Int64(0)));
        if TotalRangeBytes > High(QWord) -
           ScanRequest.Ranges[RangeIndex].Size then
          Exit(TCEAResult.Error(rcBudgetExceeded,
            'scan_budget_exceeded', '{}'));
        Inc(TotalRangeBytes, ScanRequest.Ranges[RangeIndex].Size);
      end;
      ScanRequest.RangeStart := ScanRequest.Ranges[0].StartAddress;
      ScanRequest.RangeSize := TotalRangeBytes;
      if ACapabilityId = 'memory_scan_start' then
        Exit(FScanner.FirstScan(ScanRequest, Identity));
      ScanId := Obj.Get('scan_id', '');
      Exit(FScanner.RefineScan(ScanId, ScanRequest, Identity));
    end;

    if ACapabilityId = 'memory_scan_cancel' then
      Exit(FScanner.CancelScan(Obj.Get('scan_id', ''), Identity));

    Result := TCEAResult.Error(rcNotImplemented,
      'engine_command_not_implemented',
      '{"capability_id":"' + ACapabilityId + '"}');
  finally
    Data.Free;
  end;
end;

function TCEAEngineRuntime.PumpCommands(const AMaxItems: Cardinal): Cardinal;
var
  DrainResult: TCEAResult;
begin
  Result := 0;
  if AMaxItems = 0 then
    Exit;
  while Result < AMaxItems do
  begin
    DrainResult := FCommandQueue.DrainOne(Self);
    if (DrainResult.Code = rcConflict) and
       (DrainResult.StableCode = 'command_queue_empty') then
      Break;
    if (DrainResult.Code = rcUnauthorized) and
       (DrainResult.StableCode = 'ce_owner_thread_required') then
      Break;
    Inc(Result);
  end;
end;

function RegisterEngine: TCEAResult;
begin
  Result := TCEAResult.Error(rcInternalError,
    'engine_registration_dependencies_required', '{}');
end;

function RegisterEngine(const ABackend: ICEAReadOnlyRuntimeBackend;
  const AHasher: ICEAHasher): TCEAResult;
begin
  if EngineRegistered then
    Exit(TCEAResult.Error(rcConflict, 'engine_already_registered', '{}'));
  if (ABackend = nil) or (AHasher = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'engine_dependencies_required', '{}'));
  try
    EngineRuntime := TCEAEngineRuntime.Create(ABackend, AHasher);
    Result := TCEAResult.Ok('{"registered":true,"mode":"read_only"}');
  except
    on E: Exception do
    begin
      FreeAndNil(EngineRuntime);
      Result := TCEAResult.Error(rcInternalError,
        'engine_registration_failed', '{}');
    end;
  end;
end;

procedure UnregisterEngine;
begin
  FreeAndNil(EngineRuntime);
end;

function EngineRegistered: Boolean;
begin
  Result := EngineRuntime <> nil;
end;

finalization
  UnregisterEngine;

end.
