unit cea_mcp_registry;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, FPJSON, cea_results;

type
  IMCPToolDispatcher = interface
    function DispatchTool(const AToolName, AArgumentsJson: string): TCEAResult;
  end;

  TMCPToolDefinition = record
    Name: string;
    Description: string;
    InputSchemaJson: string;
    ReadOnlyHint: Boolean;
    DestructiveHint: Boolean;
    IdempotentHint: Boolean;
    CapabilityId: string;
  end;

  TMCPToolRegistry = class
  private
    FDispatcher: IMCPToolDispatcher;
    FTools: array of TMCPToolDefinition;
    function FindToolIndex(const AName: string): Integer;
  public
    constructor Create(const ADispatcher: IMCPToolDispatcher);
    procedure RegisterTool(const AName, ADescription, AInputSchemaJson: string;
      const AReadOnlyHint, ADestructiveHint, AIdempotentHint: Boolean;
      const ACapabilityId: string);
    function BuildToolList: TJSONArray;
    function CallTool(const AName, AArgumentsJson: string): TCEAResult;
  end;

procedure RegisterDefaultFoundationTools(ARegistry: TMCPToolRegistry);

implementation

uses
  JSONParser, cea_schema_validator;

constructor TMCPToolRegistry.Create(const ADispatcher: IMCPToolDispatcher);
begin
  inherited Create;
  FDispatcher := ADispatcher;
end;

function TMCPToolRegistry.FindToolIndex(const AName: string): Integer;
begin
  for Result := 0 to High(FTools) do
    if FTools[Result].Name = AName then
      Exit;
  Result := -1;
end;

procedure TMCPToolRegistry.RegisterTool(const AName, ADescription,
  AInputSchemaJson: string; const AReadOnlyHint, ADestructiveHint,
  AIdempotentHint: Boolean; const ACapabilityId: string);
var
  Index: Integer;
begin
  if (AName = '') or (FindToolIndex(AName) >= 0) then
    raise EArgumentException.Create('MCP tool name is empty or duplicated');
  Index := Length(FTools);
  SetLength(FTools, Index + 1);
  FTools[Index].Name := AName;
  FTools[Index].Description := ADescription;
  FTools[Index].InputSchemaJson := AInputSchemaJson;
  FTools[Index].ReadOnlyHint := AReadOnlyHint;
  FTools[Index].DestructiveHint := ADestructiveHint;
  FTools[Index].IdempotentHint := AIdempotentHint;
  FTools[Index].CapabilityId := ACapabilityId;
end;

function TMCPToolRegistry.BuildToolList: TJSONArray;
var
  I: Integer;
  ToolObject: TJSONObject;
  Annotations: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(FTools) do
  begin
    ToolObject := TJSONObject.Create;
    ToolObject.Add('name', FTools[I].Name);
    ToolObject.Add('description', FTools[I].Description);
    ToolObject.Add('inputSchema', GetJSON(FTools[I].InputSchemaJson));
    Annotations := TJSONObject.Create;
    Annotations.Add('readOnlyHint', FTools[I].ReadOnlyHint);
    Annotations.Add('destructiveHint', FTools[I].DestructiveHint);
    Annotations.Add('idempotentHint', FTools[I].IdempotentHint);
    ToolObject.Add('annotations', Annotations);
    Result.Add(ToolObject);
  end;
end;

function TMCPToolRegistry.CallTool(const AName,
  AArgumentsJson: string): TCEAResult;
var
  Index: Integer;
  Arguments: TJSONData;
  SchemaResult: TCEAResult;
begin
  Index := FindToolIndex(AName);
  if Index < 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'tool_not_found',
      '{"tool":"' + AName + '"}'));
  Arguments := nil;
  try
    try
      { Same code page trap as the JSON-RPC envelope: arguments carrying
        non-ASCII text must be tagged as UTF-8 before GetJSON transcodes them. }
      Arguments := GetJSON(Utf8JsonText(AArgumentsJson));
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'tool_arguments_invalid', '{}'));
    end;
    if Arguments.JSONType <> jtObject then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'tool_arguments_object_required', '{}'));
  finally
    Arguments.Free;
  end;
  SchemaResult := ValidateInlineJsonSchema(FTools[Index].InputSchemaJson,
    AArgumentsJson);
  if SchemaResult.Failed then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'tool_arguments_schema_invalid', SchemaResult.DataJson));
  if FDispatcher = nil then
    Exit(TCEAResult.Error(rcInternalError, 'tool_dispatcher_missing', '{}'));
  Result := FDispatcher.DispatchTool(AName, AArgumentsJson);
end;

procedure RegisterDefaultFoundationTools(ARegistry: TMCPToolRegistry);
const
  EmptySchema = '{"type":"object","properties":{},"additionalProperties":false}';
  AttachSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256},' +
    '"lease_ref":{"type":"string","minLength":1,"maxLength":256},' +
    '"pid":{"type":"integer","minimum":1},' +
    '"operator_attests_authorized_debugging":{"type":"boolean"}},' +
    '"required":["task_id","lease_ref","pid",' +
      '"operator_attests_authorized_debugging"],' +
    '"additionalProperties":false}';
  DetachSchema = '{"type":"object","properties":{' +
    '"process_identity_ref":{"type":"string","minLength":1},' +
    '"epoch":{"type":"integer","minimum":1}},' +
    '"required":["process_identity_ref","epoch"],' +
    '"additionalProperties":false}';
  MemoryReadSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256},' +
    '"process_identity_ref":{"type":"string","minLength":1},' +
    '"lease_ref":{"type":"string","minLength":1,"maxLength":256},' +
    '"address":{"type":"string","pattern":"^0x[0-9a-fA-F]+$"},' +
    '"byte_count":{"type":"integer","minimum":1,"maximum":4096}},' +
    '"required":["task_id","process_identity_ref","lease_ref",' +
      '"address","byte_count"],"additionalProperties":false}';
  ModuleListSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256},' +
    '"lease_ref":{"type":"string","minLength":1,"maxLength":256},' +
    '"max_results":{"type":"integer","minimum":1,"maximum":4096}},' +
    '"required":["task_id","lease_ref","max_results"],' +
    '"additionalProperties":false}';
  DisassembleSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256},' +
    '"process_identity_ref":{"type":"string","minLength":1},' +
    '"lease_ref":{"type":"string","minLength":1,"maxLength":256},' +
    '"address":{"type":"string","pattern":"^0x[0-9a-fA-F]+$"},' +
    '"byte_count":{"type":"integer","minimum":1,"maximum":64}},' +
    '"required":["task_id","process_identity_ref","lease_ref",' +
      '"address","byte_count"],"additionalProperties":false}';
  SearchSchema = '{"type":"object","properties":{' +
    '"query":{"type":"string","minLength":1,"maxLength":512},' +
    '"max_results":{"type":"integer","minimum":1,"maximum":100}},' +
    '"required":["query"],"additionalProperties":false}';
  CTEntrySchema = '{"type":"object","properties":{' +
    '"entry_key":{"type":"string","minLength":1,"maxLength":256}},' +
    '"required":["entry_key"],"additionalProperties":false}';
  SaveEditSchema = '{"type":"object","properties":{' +
    '"field_path":{"type":"string","minLength":1,"maxLength":512},' +
    '"expected_json":{"type":"string","minLength":1,"maxLength":65536},' +
    '"new_json":{"type":"string","minLength":1,"maxLength":65536}},' +
    '"required":["field_path","expected_json","new_json"],' +
    '"additionalProperties":false}';
  TaskSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256}},' +
    '"required":["task_id"],"additionalProperties":false}';
  EffectSchema = '{"type":"object","properties":{' +
    '"effect_id":{"type":"string","minLength":1,"maxLength":256}},' +
    '"required":["effect_id"],"additionalProperties":false}';
  MemoryWriteSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256},' +
    '"address":{"type":"string","pattern":"^0x[0-9a-fA-F]+$"},' +
    '"expected_original_bytes":{"type":"string","minLength":2,' +
      '"maxLength":8192,"pattern":"^([0-9a-fA-F]{2})+$"},' +
    '"replacement_bytes":{"type":"string","minLength":2,' +
      '"maxLength":8192,"pattern":"^([0-9a-fA-F]{2})+$"}},' +
    '"required":["task_id","address","expected_original_bytes",' +
      '"replacement_bytes"],"additionalProperties":false}';
  FreezeSchema = '{"type":"object","properties":{' +
    '"task_id":{"type":"string","minLength":1,"maxLength":256},' +
    '"address":{"type":"string","pattern":"^0x[0-9a-fA-F]+$"},' +
    '"expected_original_bytes":{"type":"string","minLength":2,' +
      '"maxLength":8192,"pattern":"^([0-9a-fA-F]{2})+$"},' +
    '"replacement_bytes":{"type":"string","minLength":2,' +
      '"maxLength":8192,"pattern":"^([0-9a-fA-F]{2})+$"},' +
    '"interval_ms":{"type":"integer","minimum":100,"maximum":60000},' +
    '"max_writes":{"type":"integer","minimum":1,"maximum":10000},' +
    '"duration_seconds":{"type":"integer","minimum":1,"maximum":3600}},' +
    '"required":["task_id","address","expected_original_bytes",' +
      '"replacement_bytes","interval_ms","max_writes",' +
      '"duration_seconds"],"additionalProperties":false}';
  ScanProperties =
    '"task_id":{"type":"string"},' +
    '"process_identity_ref":{"type":"string"},' +
    '"lease_ref":{"type":"string"},' +
    '"scan_kind":{"type":"string","enum":["aob","value"]},' +
    '"value_type":{"type":"string","enum":' +
      '["byte","word","dword","qword","single","double"]},' +
    '"value":{"type":"string"},' +
    '"aob_pattern":{"type":"string"},' +
    '"scope_id":{"type":"string",' +
      '"description":"Created only by local operator authorization"},' +
    '"epoch":{"type":"integer","minimum":1},' +
    '"budget":{"type":"object","properties":{' +
      '"max_bytes":{"type":"integer","minimum":1,"maximum":536870912},' +
      '"max_results":{"type":"integer","minimum":1,"maximum":10000},' +
      '"max_duration_ms":{"type":"integer","minimum":1,"maximum":30000},' +
      '"max_regions":{"type":"integer","minimum":1,"maximum":4096}},' +
      '"required":["max_bytes","max_results"],' +
      '"additionalProperties":false},' +
    '"ranges":{"type":"array","minItems":1,"maxItems":128,' +
      '"items":{"type":"object","properties":{' +
        '"start":{"type":"string","pattern":"^0x[0-9a-fA-F]+$"},' +
        '"size":{"type":"integer","minimum":1}},' +
        '"required":["start","size"],"additionalProperties":false}}';
  ScanRequired =
    '"task_id","process_identity_ref","lease_ref",' +
    '"scan_kind","epoch","budget","ranges"';
  ScanStartSchema = '{"type":"object","properties":{' +
    ScanProperties + '},"required":[' + ScanRequired +
    '],"additionalProperties":false}';
  ScanRefineSchema = '{"type":"object","properties":{' +
    '"scan_id":{"type":"string"},' + ScanProperties +
    '},"required":["scan_id",' + ScanRequired +
    '],"additionalProperties":false}';
  ScanSessionSchema = '{"type":"object","properties":{' +
    '"scan_id":{"type":"string"}},"required":["scan_id"],' +
    '"additionalProperties":false}';
  { Phase 1 player-level tools (PRD 6.1-6.8). Field writes are never executed
    from MCP: they answer rcApprovalRequired so the operator stays the only
    approval surface (same contract as cea.request_memory_write). }
  GameSessionSchema = '{"type":"object","properties":{' +
    '"game_name":{"type":"string","minLength":1,"maxLength":256},' +
    '"game_version":{"type":"string","maxLength":128}},' +
    '"required":["game_name"],"additionalProperties":false}';
  FieldDeclareSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"display_name":{"type":"string","minLength":1,"maxLength":128},' +
    '"value_type":{"type":"string","enum":' +
      '["byte","word","dword","qword","single","double"]},' +
    '"address":{"type":"string","pattern":"^0x[0-9a-fA-F]+$"}},' +
    '"required":["field_id","display_name","value_type","address"],' +
    '"additionalProperties":false}';
  FieldIdSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["field_id"],"additionalProperties":false}';
  GameProfileSchema = '{"type":"object","properties":{' +
    '"game_name":{"type":"string","minLength":1,"maxLength":256}},' +
    '"required":["game_name"],"additionalProperties":false}';
  FieldChainDeclareSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"display_name":{"type":"string","minLength":1,"maxLength":128},' +
    '"value_type":{"type":"string","enum":' +
      '["byte","word","dword","qword","single","double"]},' +
    '"module_name":{"type":"string","minLength":1,"maxLength":128},' +
    '"offsets_json":{"type":"string","minLength":2,"maxLength":512},' +
    '"address_width_bits":{"type":"integer","enum":[32,64]}},' +
    '"required":["field_id","display_name","value_type","module_name",' +
      '"offsets_json"],"additionalProperties":false}';
  FieldWriteSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"target_value":{"type":"string","minLength":1,"maxLength":64},' +
    '"expected_current_value":{"type":"string","minLength":1,' +
      '"maxLength":64}},' +
    '"required":["field_id","target_value","expected_current_value"],' +
    '"additionalProperties":false}';
  EventTagSchema = '{"type":"object","properties":{' +
    '"tag":{"type":"string","maxLength":256}},' +
    '"additionalProperties":false}';
  PageTitleSchema = '{"type":"object","properties":{' +
    '"page_title":{"type":"string","maxLength":128}},' +
    '"additionalProperties":false}';
  GameTextSchema = '{"type":"object","properties":{' +
    '"text":{"type":"string","minLength":1,"maxLength":256}},' +
    '"required":["text"],"additionalProperties":false}';
  FieldMappingIdSchema = '{"type":"object","properties":{' +
    '"mapping_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["mapping_id"],"additionalProperties":false}';
  EventIdSchema = '{"type":"object","properties":{' +
    '"event_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["event_id"],"additionalProperties":false}';
  { PRD 6.9 事件分析（FR-090~094）。field_id 可选：只做证据分级与建议时不必给。 }
  EventAnalysisSchema = '{"type":"object","properties":{' +
    '"event_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"field_id":{"type":"string","maxLength":128}},' +
    '"required":["event_id"],"additionalProperties":false}';
  { 外发模型必须显式同意，故 consent 是必填布尔。 }
  EventAnalysisCloudSchema = '{"type":"object","properties":{' +
    '"event_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"field_id":{"type":"string","maxLength":128},' +
    '"consent_to_send_values":{"type":"boolean"}},' +
    '"required":["event_id","consent_to_send_values"],' +
    '"additionalProperties":false}';
  PathSchema = '{"type":"object","properties":{' +
    '"path":{"type":"string","minLength":1,"maxLength":512}},' +
    '"required":["path"],"additionalProperties":false}';
  { FR-046 操作历史查询：field_id 为空表示查全部，limit 可省略。 }
  WriteHistorySchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","maxLength":128},' +
    '"limit":{"type":"integer","minimum":1,"maximum":500}},' +
    '"additionalProperties":false}';
  { FR-071/FR-074/FR-079 事件录像：抓帧参数都可省略，省略即用本地默认
    （500ms 一帧 / 5 分钟滚动缓存 / 512MiB 磁盘上限 / 永久保留）。 }
  RecordingStartSchema = '{"type":"object","properties":{' +
    '"storage_directory":{"type":"string","maxLength":512},' +
    '"frame_interval_ms":{"type":"integer","minimum":50,"maximum":10000},' +
    '"cache_duration_ms":{"type":"integer","minimum":0},' +
    '"max_disk_bytes":{"type":"integer","minimum":0},' +
    '"retention_ms":{"type":"integer","minimum":0}},' +
    '"additionalProperties":false}';
  SegmentLockSchema = '{"type":"object","properties":{' +
    '"segment_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"locked":{"type":"boolean"}},' +
    '"required":["segment_id","locked"],"additionalProperties":false}';
  { FR-052 证据查询：field_id 为空表示查全部。 }
  FieldEvidenceSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","maxLength":128},' +
    '"limit":{"type":"integer","minimum":1,"maximum":500}},' +
    '"additionalProperties":false}';
  FieldConfirmationSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["field_id"],"additionalProperties":false}';
  { FR-042/FR-045 命令预览：与写入同形（field_id / target_value /
    expected_current_value），但只读实时值并比对，不改任何状态。 }
  FieldPreviewSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"target_value":{"type":"string","minLength":1,"maxLength":64},' +
    '"expected_current_value":{"type":"string","minLength":1,"maxLength":64}},' +
    '"required":["field_id","target_value","expected_current_value"],' +
    '"additionalProperties":false}';
  { FR-041 输入校验：把字段可接受的范围/枚举声明成约束。空串表示清除约束。 }
  FieldConstraintsSchema = '{"type":"object","properties":{' +
    '"field_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"constraints_json":{"type":"string","maxLength":4096}},' +
    '"required":["field_id","constraints_json"],' +
    '"additionalProperties":false}';
  { FR-040/FR-054 写入隔离：授予写入要写明理由，理由会进账本。 }
  WriteAccessEnableSchema = '{"type":"object","properties":{' +
    '"reason":{"type":"string","minLength":1,"maxLength":400}},' +
    '"required":["reason"],"additionalProperties":false}';
  { FR-051 分轮验证：目的/操作/预期三项必填，缺一项就不该开这一轮。 }
  DiscoveryPlanSchema = '{"type":"object","properties":{' +
    '"kind":{"type":"string","enum":["scan","refine","compare","write"]},' +
    '"purpose":{"type":"string","minLength":1,"maxLength":400},' +
    '"operation":{"type":"string","minLength":1,"maxLength":400},' +
    '"expected_observation":{"type":"string","minLength":1,"maxLength":400},' +
    '"field_id":{"type":"string","maxLength":128}},' +
    '"required":["kind","purpose","operation","expected_observation"],' +
    '"additionalProperties":false}';
  DiscoveryCompleteSchema = '{"type":"object","properties":{' +
    '"round_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"observed_outcome":{"type":"string","minLength":1,"maxLength":800},' +
    '"matched_expectation":{"type":"boolean"}},' +
    '"required":["round_id","observed_outcome","matched_expectation"],' +
    '"additionalProperties":false}';
  DiscoveryAbandonSchema = '{"type":"object","properties":{' +
    '"round_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"reason":{"type":"string","minLength":1,"maxLength":400}},' +
    '"required":["round_id","reason"],"additionalProperties":false}';
  DiscoveryListSchema = '{"type":"object","properties":{' +
    '"limit":{"type":"integer","minimum":1,"maximum":500}},' +
    '"additionalProperties":false}';
  { FR-050 目标描述：描述是操作者原话，hint 是可选补充。
    hint 只能从已知取值里选，猜出来的 hint 会被丢弃。 }
  DiscoveryGoalProposeSchema = '{"type":"object","properties":{' +
    '"description":{"type":"string","minLength":1,"maxLength":800},' +
    '"field_id_hint":{"type":"string","maxLength":128},' +
    '"value_type_hint":{"type":"string",' +
    '"enum":["byte","word","dword","qword","integer","single","double",' +
    '"bool","enum","string"]},' +
    '"behavior_hint":{"type":"string",' +
    '"enum":["increase","decrease","constant","unknown"]}},' +
    '"required":["description"],"additionalProperties":false}';
  DiscoveryGoalModelSchema = '{"type":"object","properties":{' +
    '"description":{"type":"string","minLength":1,"maxLength":800},' +
    '"max_output_tokens":{"type":"integer","minimum":1,"maximum":4096}},' +
    '"required":["description"],"additionalProperties":false}';
  DiscoveryGoalIdSchema = '{"type":"object","properties":{' +
    '"goal_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["goal_id"],"additionalProperties":false}';
  DiscoveryGoalRejectSchema = '{"type":"object","properties":{' +
    '"goal_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"reason":{"type":"string","minLength":1,"maxLength":400}},' +
    '"required":["goal_id","reason"],"additionalProperties":false}';
  DiscoveryGoalListSchema = '{"type":"object","properties":{' +
    '"limit":{"type":"integer","minimum":1,"maximum":500}},' +
    '"additionalProperties":false}';
  { 1D 增强：多页面 / 版本回退 / 自然语言定制（FR-025/026/033）。
    页面存的是 schema JSON，不是数值快照，因此回退只换布局、不回写游戏。 }
  UiPageSchema = '{"type":"object","properties":{' +
    '"page_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"title":{"type":"string","minLength":1,"maxLength":128},' +
    '"schema_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"schema_json":{"type":"string","minLength":2,"maxLength":65536}},' +
    '"required":["page_id","title","schema_id","schema_json"],' +
    '"additionalProperties":false}';
  UiPageIdSchema = '{"type":"object","properties":{' +
    '"page_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["page_id"],"additionalProperties":false}';
  UiSchemaIdSchema = '{"type":"object","properties":{' +
    '"schema_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["schema_id"],"additionalProperties":false}';
  UiRestoreSchema = '{"type":"object","properties":{' +
    '"schema_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"version":{"type":"integer","minimum":1}},' +
    '"required":["schema_id","version"],"additionalProperties":false}';
  UiInstructionSchema = '{"type":"object","properties":{' +
    '"instruction":{"type":"string","minLength":1,"maxLength":1024}},' +
    '"required":["instruction"],"additionalProperties":false}';
  UiProposalSchema = '{"type":"object","properties":{' +
    '"proposal_id":{"type":"string","minLength":1,"maxLength":128},' +
    '"page_id":{"type":"string","maxLength":128},' +
    '"title":{"type":"string","maxLength":128}},' +
    '"required":["proposal_id"],"additionalProperties":false}';
  UiProposalIdSchema = '{"type":"object","properties":{' +
    '"proposal_id":{"type":"string","minLength":1,"maxLength":128}},' +
    '"required":["proposal_id"],"additionalProperties":false}';
begin
  ARegistry.RegisterTool('cea.health', 'Return local AgentOS and MCP health',
    EmptySchema, True, False, True, 'runtime_health');
  ARegistry.RegisterTool('cea.get_runtime_state', 'Return bounded runtime state',
    EmptySchema, True, False, True, 'runtime_state');
  ARegistry.RegisterTool('cea.list_processes', 'List admissible local processes',
    EmptySchema, True, False, True, 'process_list');
  ARegistry.RegisterTool('cea.attach_process', 'Attach to an authorized offline process',
    AttachSchema, True, False, False, 'process_attach');
  ARegistry.RegisterTool('cea.detach_process', 'Detach the current process',
    DetachSchema, True, False, True, 'process_detach');
  ARegistry.RegisterTool('cea.read_memory', 'Read bounded target memory',
    MemoryReadSchema, True, False, True, 'memory_read');
  ARegistry.RegisterTool('cea.list_modules', 'List bounded target modules',
    ModuleListSchema, True, False, True, 'module_list');
  ARegistry.RegisterTool('cea.start_scan', 'Start a bounded memory scan',
    ScanStartSchema, True, False, False, 'memory_scan');
  ARegistry.RegisterTool('cea.refine_scan', 'Refine an existing scan',
    ScanRefineSchema, True, False, False, 'memory_scan');
  ARegistry.RegisterTool('cea.get_scan_status', 'Read scan progress',
    ScanSessionSchema, True, False, True, 'memory_scan');
  ARegistry.RegisterTool('cea.cancel_scan', 'Cancel an existing scan',
    ScanSessionSchema, False, False, True, 'memory_scan');
  { 唯一性判定是只读的：它只读扫描会话的 match_count，不改变目标，
    因此 MCP 可以直接问「这条签名能不能当写入锚点」。发起扫描仍走
    cea.start_scan（租约与本地授权在网关侧校验）。 }
  ARegistry.RegisterTool('cea.judge_aob_uniqueness',
    'Judge whether an AOB scan has exactly one match and may anchor a write',
    ScanSessionSchema, True, False, True, 'memory_scan');
  ARegistry.RegisterTool('cea.disassemble', 'Disassemble a bounded range',
    DisassembleSchema, True, False, True, 'disassemble');
  ARegistry.RegisterTool('cea.import_ct', 'Import CT as untrusted RAG evidence',
    EmptySchema, False, False, True, 'ct_import');
  ARegistry.RegisterTool('cea.search_ct', 'Search indexed CT evidence',
    SearchSchema, True, False, True, 'ct_search');
  ARegistry.RegisterTool('cea.get_ct_entry', 'Get one indexed CT entry',
    CTEntrySchema, True, False, True, 'ct_search');
  ARegistry.RegisterTool('cea.inspect_save',
    'Recheck the locally selected save and return metadata only',
    EmptySchema, True, False, True, 'save_read');
  ARegistry.RegisterTool('cea.get_save_snapshot',
    'Return revalidated metadata for the locally selected save',
    EmptySchema, True, False, True, 'save_read');
  ARegistry.RegisterTool('cea.propose_save_edit',
    'Validate a field-level proposal without writing save bytes',
    SaveEditSchema, True, False, False, 'save_proposal');
  ARegistry.RegisterTool('cea.request_save_backup',
    'Plan a backup of the locally selected save; local approval required',
    TaskSchema, False, False, True, 'save_backup');
  ARegistry.RegisterTool('cea.get_save_effect',
    'Read a save Effect status without exposing file content or path',
    EffectSchema, True, False, True, 'save_effect_status');
  ARegistry.RegisterTool('cea.build_rag_context', 'Build provenance-bound CT context',
    SearchSchema, True, False, True, 'ct_rag');
  ARegistry.RegisterTool('cea.request_memory_write', 'Request a locally approved write',
    MemoryWriteSchema, False, True, False, 'memory_write');
  ARegistry.RegisterTool('cea.request_freeze', 'Request a locally approved freeze',
    FreezeSchema, False, True, False, 'memory_freeze');
  ARegistry.RegisterTool('cea.request_debug_action', 'Request a locally approved debug action',
    EmptySchema, False, True, False, 'debug_state_change');
  ARegistry.RegisterTool('cea.request_script_execution', 'Request approved AA or Lua execution',
    EmptySchema, False, True, False, 'script_execution');
  ARegistry.RegisterTool('cea.get_effect_status', 'Read an Effect status',
    EffectSchema, True, False, True, 'effect_status');
  ARegistry.RegisterTool('cea.emergency_stop', 'Stop new effects and revoke leases',
    EmptySchema, False, True, True, 'emergency_stop');
  { Phase 1 player-level tools. Reads are safe; every mutating player action
    (declare/confirm/write) still requires the local operator UI, so MCP only
    ever proposes and reports back rcApprovalRequired. }
  ARegistry.RegisterTool('cea.start_game_session',
    'Start a player-level session bound to the attached process identity',
    GameSessionSchema, False, False, False, 'game_session');
  ARegistry.RegisterTool('cea.end_game_session',
    'End the current player-level session and drop its fields',
    EmptySchema, False, True, True, 'game_session');
  ARegistry.RegisterTool('cea.list_game_fields',
    'List semantic fields known for the current game session',
    EmptySchema, True, False, True, 'field_read');
  { Game Profile (FR-055 / FR-061 / FR-062). Saving is a read of the current
    session plus a write into the profile store, so it stays operator-only; a
    restore mutates the live Game State Model, which is exactly what FR-094
    says must be confirmed locally first. Both therefore report
    rcApprovalRequired instead of executing. }
  ARegistry.RegisterTool('cea.save_game_profile',
    'Request saving the current field set as a Game Profile; local approval required',
    EmptySchema, False, False, False, 'profile_write');
  ARegistry.RegisterTool('cea.restore_game_profile',
    'Request restoring a Game Profile into the live model; local approval required',
    GameProfileSchema, False, False, False, 'profile_write');
  ARegistry.RegisterTool('cea.capture_field_value',
    'Reread one field from target memory and update its observed value',
    FieldIdSchema, True, False, True, 'field_read');
  ARegistry.RegisterTool('cea.declare_field',
    'Propose a user-declared field; local confirmation still required',
    FieldDeclareSchema, False, False, False, 'field_proposal');
  ARegistry.RegisterTool('cea.declare_pointer_field',
    'Propose a module+offsets pointer chain field; local confirmation still required',
    FieldChainDeclareSchema, False, False, False, 'field_proposal');
  ARegistry.RegisterTool('cea.resolve_field_address',
    'Re-resolve one field pointer chain against the current target (read-only)',
    FieldIdSchema, True, False, True, 'field_read');
  ARegistry.RegisterTool('cea.list_field_mappings',
    'List field mapping proposals and their confirmation state',
    EmptySchema, True, False, True, 'field_read');
  ARegistry.RegisterTool('cea.set_field_constraints',
    'Declare the accepted range/allowed values for a field; local confirmation still required',
    FieldConstraintsSchema, False, False, True, 'field_constraints');
  ARegistry.RegisterTool('cea.propose_ai_field_mapping',
    'Propose an AI field mapping; never writable until a human confirms it',
    FieldDeclareSchema, False, False, False, 'field_proposal');
  ARegistry.RegisterTool('cea.confirm_field_mapping',
    'Confirm a pending field mapping; local approval required',
    FieldMappingIdSchema, False, False, True, 'field_proposal');
  ARegistry.RegisterTool('cea.reject_field_mapping',
    'Reject a pending field mapping',
    FieldMappingIdSchema, False, False, True, 'field_proposal');
  ARegistry.RegisterTool('cea.confirm_field_writable',
    'Request the write-reread-verify promotion of one field; local approval required',
    FieldWriteSchema, False, True, False, 'field_write');
  ARegistry.RegisterTool('cea.write_field_value',
    'Request a governed semantic field write; local approval required',
    FieldWriteSchema, False, True, False, 'field_write');
  { FR-040/FR-054 写入隔离。授予写入会话级开关、撤销它、以及声明「这个字段
    我想要写」这三件事都是操作者的意图表达，MCP 只能申请、不能代做；只有
    查询当前授予状态是纯读取。即使授予已开，真正的写入仍要过
    verified_writable 门禁。 }
  ARegistry.RegisterTool('cea.enable_write_access',
    'Request a session-scoped write grant for the current target; '
    + 'local approval required',
    WriteAccessEnableSchema, False, True, False, 'write_access');
  ARegistry.RegisterTool('cea.disable_write_access',
    'Request revocation of the session write grant',
    EmptySchema, False, True, True, 'write_access');
  ARegistry.RegisterTool('cea.get_write_access',
    'Show whether writes are enabled for this session and for which target',
    EmptySchema, True, False, True, 'write_access_read');
  ARegistry.RegisterTool('cea.request_field_write',
    'Request one field to be marked as intended for writing; '
    + 'local approval required',
    FieldIdSchema, False, False, True, 'field_write');
  { FR-042/FR-045 命令预览：只读实时值、比对原值、不改任何状态，因此可以直接
    由 MCP 执行；真正的写入仍走 cea.write_field_value 的本地审批路径。 }
  ARegistry.RegisterTool('cea.preview_field_write',
    'Preview a field write (live original value, conflict check, adapter) '
    + 'without writing anything',
    FieldPreviewSchema, True, False, True, 'field_preview');
  ARegistry.RegisterTool('cea.build_ui_render_json',
    'Build the secondary-screen render model for the current session',
    PageTitleSchema, True, False, True, 'ui_render');
  ARegistry.RegisterTool('cea.enumerate_displays',
    'Enumerate local displays for secondary-screen placement',
    EmptySchema, True, False, True, 'display_read');
  ARegistry.RegisterTool('cea.mark_event',
    'Mark an operator event on the unified timeline',
    EventTagSchema, False, False, False, 'event_mark');
  ARegistry.RegisterTool('cea.list_events',
    'List recorded events for the current session',
    EmptySchema, True, False, True, 'event_read');
  ARegistry.RegisterTool('cea.delete_event',
    'Delete one recorded event and its evidence payload',
    EventIdSchema, False, True, True, 'event_delete');
  { PRD 6.9 事件分析与证据关联（FR-090~094）。前两个只读推导在本机完成，
    MCP 可以直接问；最后一个会把事件里的实际数值外发给模型，必须本地审批。 }
  ARegistry.RegisterTool('cea.analyze_event',
    'Grade one event''s evidence and digest its changes locally',
    EventAnalysisSchema, True, False, True, 'event_analysis');
  ARegistry.RegisterTool('cea.get_field_trend',
    'Correlate one field''s value changes across recorded events',
    FieldIdSchema, True, False, True, 'event_analysis');
  { FR-046 操作历史：只读查询。写入本身仍只能由本地操作者发起，
    所以这里没有、也不能有对应的写工具。 }
  ARegistry.RegisterTool('cea.list_field_write_history',
    'List durable field-write audit records (time, field, before/after, '
    + 'adapter, outcome, error)',
    WriteHistorySchema, True, False, True, 'write_history');
  { FR-071/074/077/079 事件录像与唤醒队列。开启/停止录像会驱动真实抓帧并写盘，
    锁定片段会改变保留策略，因此这三类必须本地审批；查询片段与查看待办队列
    是只读的，MCP 可以直接执行。 }
  ARegistry.RegisterTool('cea.start_event_recording',
    'Start capturing the game window around events; local approval required',
    RecordingStartSchema, False, False, False, 'event_recording');
  ARegistry.RegisterTool('cea.stop_event_recording',
    'Stop the event recording capture; local approval required',
    EmptySchema, False, False, False, 'event_recording');
  ARegistry.RegisterTool('cea.list_recording_segments',
    'List cached recording segments with size, duration and lock state',
    EmptySchema, True, False, True, 'event_recording_read');
  ARegistry.RegisterTool('cea.lock_recording_segment',
    'Lock or unlock one recording segment so retention cannot evict it; '
    + 'local approval required', SegmentLockSchema, False, False, True,
    'event_recording');
  ARegistry.RegisterTool('cea.queue_event_for_analysis',
    'Queue one event for on-demand analysis; the queue never calls a model',
    EventIdSchema, False, False, True, 'event_wake');
  ARegistry.RegisterTool('cea.peek_analysis_queue',
    'Peek at the pending analysis queue without consuming it',
    EmptySchema, True, False, True, 'event_wake_read');
  ARegistry.RegisterTool('cea.analyze_event_with_model',
    'Ask the model to interpret one event; sends values off-device, '
    + 'local approval required', EventAnalysisCloudSchema, False, False, True,
    'event_analysis_cloud');
  { FR-052 证据记录：查询是只读的；新增证据必须来自真实采集或真实验证，
     MCP 不能凭空造一条证据，所以没有「写证据」工具，只有查询与本地确认。 }
  ARegistry.RegisterTool('cea.list_field_evidence',
    'List durable evidence records for a field (address, value type, observed '
    + 'change, process version, verification outcome)',
    FieldEvidenceSchema, True, False, True, 'field_evidence_read');
  ARegistry.RegisterTool('cea.record_field_confirmation',
    'Record that the operator declared this field''s meaning; local approval '
    + 'required', FieldConfirmationSchema, False, False, True,
    'field_evidence');
  { FR-051 分轮验证：规划与收尾都是操作者的动作，MCP 只能读计划、
    不能替操作者声明「我预期看到 X」——那等于伪造验收标准。 }
  ARegistry.RegisterTool('cea.plan_discovery_round',
    'Declare purpose, operation and expected observation before a scan or '
    + 'write; local approval required', DiscoveryPlanSchema, False, False,
    False, 'discovery_round');
  ARegistry.RegisterTool('cea.complete_discovery_round',
    'Record what actually happened in a planned round and whether it matched '
    + 'the expectation; local approval required', DiscoveryCompleteSchema,
    False, False, True, 'discovery_round');
  ARegistry.RegisterTool('cea.abandon_discovery_round',
    'Abandon a planned round with a reason; local approval required',
    DiscoveryAbandonSchema, False, False, True, 'discovery_round');
  ARegistry.RegisterTool('cea.list_discovery_rounds',
    'List the discovery rounds planned in this session',
    DiscoveryListSchema, True, False, True, 'discovery_round_read');
  ARegistry.RegisterTool('cea.get_current_discovery_round',
    'Show the round that is currently planned but not yet completed',
    EmptySchema, True, False, True, 'discovery_round_read');
  { FR-050 目标描述：描述是操作者的意图。MCP 可以读，但不能替操作者
    声明意图、更不能替操作者接受目标——接受目标意味着「我要找这个」，
    那只能由人来说。 }
  ARegistry.RegisterTool('cea.propose_discovery_goal',
    'Record the operator''s own words describing the field they want to find; '
    + 'local approval required', DiscoveryGoalProposeSchema, False, False,
    False, 'discovery_goal');
  ARegistry.RegisterTool('cea.propose_discovery_goal_with_model',
    'Ask the configured model to interpret a goal description into hints; '
    + 'local approval required', DiscoveryGoalModelSchema, False, False,
    True, 'discovery_goal_model');
  ARegistry.RegisterTool('cea.accept_discovery_goal',
    'Accept one proposed goal as the active one; local approval required',
    DiscoveryGoalIdSchema, False, False, True, 'discovery_goal');
  ARegistry.RegisterTool('cea.reject_discovery_goal',
    'Reject a proposed goal with a reason; local approval required',
    DiscoveryGoalRejectSchema, False, False, True, 'discovery_goal');
  ARegistry.RegisterTool('cea.list_discovery_goals',
    'List the field-discovery goals proposed in this session',
    DiscoveryGoalListSchema, True, False, True, 'discovery_goal_read');
  ARegistry.RegisterTool('cea.get_current_discovery_goal',
    'Show the goal that the operator currently accepted',
    EmptySchema, True, False, True, 'discovery_goal_read');
  ARegistry.RegisterTool('cea.match_gcm_game',
    'Match a process name against the local GCM game catalog',
    GameTextSchema, True, False, True, 'gcm_catalog');
  ARegistry.RegisterTool('cea.search_gcm_games',
    'Search the local GCM game catalog by name',
    GameTextSchema, True, False, True, 'gcm_catalog');
  ARegistry.RegisterTool('cea.scan_gcm_cheat_files',
    'List cheat tables already downloaded by GCM on this machine',
    EmptySchema, True, False, True, 'gcm_library');
  ARegistry.RegisterTool('cea.list_published_cheat_files',
    'List cheat tables published into the local immutable library',
    EmptySchema, True, False, True, 'gcm_library');
  ARegistry.RegisterTool('cea.import_cheat_file',
    'Request import of one local cheat table; local approval required',
    PathSchema, False, False, False, 'cheat_file_import');
  ARegistry.RegisterTool('cea.publish_cheat_file',
    'Request publication of one local cheat table; local approval required',
    PathSchema, False, True, False, 'cheat_file_publish');
  ARegistry.RegisterTool('cea.translate_cheat_descriptions',
    'Request machine translation of CT descriptions; sends text off-device, '
    + 'local approval required', PathSchema, False, False, False,
    'cheat_file_translate');
  { 1D 增强：多页面 / 版本回退 / 自然语言定制（FR-025/026/033）。
    存储、切页、回退都是本地文件级操作，MCP 可以执行；但自然语言定制会让
    模型改写页面结构，因此提案只能创建，确认/拒绝必须由本地操作者完成。 }
  ARegistry.RegisterTool('cea.save_ui_page',
    'Store a whitelisted UI schema as a new page version',
    UiPageSchema, False, False, False, 'ui_page_store');
  ARegistry.RegisterTool('cea.list_ui_pages',
    'List stored secondary-screen pages',
    EmptySchema, True, False, True, 'ui_page_read');
  ARegistry.RegisterTool('cea.get_ui_page',
    'Read one stored page with its schema JSON',
    UiPageIdSchema, True, False, True, 'ui_page_read');
  ARegistry.RegisterTool('cea.set_active_ui_page',
    'Mark one stored page as the active page',
    UiPageIdSchema, False, False, True, 'ui_page_store');
  ARegistry.RegisterTool('cea.get_active_ui_page',
    'Read the currently active page',
    EmptySchema, True, False, True, 'ui_page_read');
  ARegistry.RegisterTool('cea.list_ui_schema_versions',
    'List the append-only version history of one UI schema',
    UiSchemaIdSchema, True, False, True, 'ui_page_read');
  ARegistry.RegisterTool('cea.restore_ui_schema_version',
    'Restore an older UI schema version as the newest version',
    UiRestoreSchema, False, False, False, 'ui_page_store');
  ARegistry.RegisterTool('cea.set_secondary_screen_page',
    'Point the secondary screen at one stored page',
    UiPageIdSchema, False, False, True, 'ui_page_store');
  ARegistry.RegisterTool('cea.propose_ui_customization',
    'Ask the model for a page proposal; the proposal is never stored unconfirmed',
    UiInstructionSchema, False, False, False, 'ui_customization');
  ARegistry.RegisterTool('cea.confirm_ui_customization',
    'Store a model page proposal; local approval required',
    UiProposalSchema, False, False, True, 'ui_customization');
  ARegistry.RegisterTool('cea.reject_ui_customization',
    'Discard a model page proposal',
    UiProposalIdSchema, False, True, True, 'ui_customization');
end;

end.
