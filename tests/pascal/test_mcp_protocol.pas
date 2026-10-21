program test_mcp_protocol;

{$mode objfpc}{$H+}

uses
  SysUtils, FPJSON, JSONParser, cea_results, cea_mcp_registry, cea_mcp_dispatcher,
  cea_mcp_protocol;

function ToolIsReadOnly(ARoot: TJSONData; const AToolName: string): Boolean;
var
  Tools: TJSONArray;
  Tool: TJSONObject;
  Annotations: TJSONObject;
  I: Integer;
begin
  Result := False;
  Tools := TJSONArray(ARoot.FindPath('result.tools'));
  for I := 0 to Tools.Count - 1 do
  begin
    Tool := TJSONObject(Tools.Items[I]);
    if Tool.Get('name', '') = AToolName then
    begin
      Annotations := TJSONObject(Tool.Find('annotations'));
      Exit(Annotations.Get('readOnlyHint', False));
    end;
  end;
end;

function ToolSchema(ARoot: TJSONData;
  const AToolName: string): TJSONData;
var
  Tools: TJSONArray;
  I: Integer;
begin
  Result := nil;
  Tools := TJSONArray(ARoot.FindPath('result.tools'));
  for I := 0 to Tools.Count - 1 do
    if TJSONObject(Tools.Items[I]).Get('name', '') = AToolName then
      Exit(TJSONObject(Tools.Items[I]).Find('inputSchema'));
end;

var
  Dispatcher: TMCPFoundationDispatcher;
  Registry: TMCPToolRegistry;
  Protocol: TMCPProtocol;
  Response: string;
  ResponseData: TJSONData;
  Tools: TJSONArray;
  I: Integer;
  ValidationResult: TCEAResult;

begin
  Dispatcher := TMCPFoundationDispatcher.Create(nil);
  Registry := TMCPToolRegistry.Create(Dispatcher);
  Protocol := TMCPProtocol.Create(Registry);
  try
    RegisterDefaultFoundationTools(Registry);
    ValidationResult := Registry.CallTool('cea.health',
      '{"unexpected":true}');
    Assert((ValidationResult.Code = rcInvalidArgument) and
      (ValidationResult.StableCode = 'tool_arguments_schema_invalid'),
      'server rejects undeclared tool arguments before dispatch');
    ValidationResult := Registry.CallTool('cea.attach_process',
      '{"task_id":"task:test"}');
    Assert((ValidationResult.Code = rcInvalidArgument) and
      (ValidationResult.StableCode = 'tool_arguments_schema_invalid'),
      'server rejects missing required tool arguments before dispatch');
    ValidationResult := Registry.CallTool('cea.start_scan',
      '{"task_id":"task:test","process_identity_ref":"process:test",' +
      '"lease_ref":"lease:test","scan_kind":"unknown",' +
      '"value_type":"dword","value":"1","scope_id":"scope:test",' +
      '"epoch":1,"budget":{"max_bytes":1,"max_results":1},' +
      '"ranges":[{"start":"0x1000","size":4}]}');
    Assert((ValidationResult.Code = rcInvalidArgument) and
      (ValidationResult.StableCode = 'tool_arguments_schema_invalid'),
      'server enforces tool argument enums before dispatch');
    ValidationResult := Registry.CallTool('cea.start_scan',
      '{"task_id":"task:test","process_identity_ref":"process:test",' +
      '"lease_ref":"lease:test","scan_kind":"value",' +
      '"value_type":"dword","value":"1","scope_id":"scope:test",' +
      '"epoch":1,"budget":{"max_bytes":536870913,"max_results":1},' +
      '"ranges":[{"start":"0x1000","size":4}]}');
    Assert((ValidationResult.Code = rcInvalidArgument) and
      (ValidationResult.StableCode = 'tool_arguments_schema_invalid'),
      'server enforces numeric tool budgets before dispatch');
    ValidationResult := Registry.CallTool('cea.start_scan',
      '{"task_id":"task:test","process_identity_ref":"process:test",' +
      '"lease_ref":"lease:test","scan_kind":"value",' +
      '"value_type":"dword","value":"1","scope_id":"scope:test",' +
      '"epoch":1,"budget":{"max_bytes":4,"max_results":1},' +
      '"ranges":[{"start":"0x1000","size":4,"extra":true}]}');
    Assert((ValidationResult.Code = rcInvalidArgument) and
      (ValidationResult.StableCode = 'tool_arguments_schema_invalid'),
      'server validates nested array items before dispatch');
    ValidationResult := Registry.CallTool('cea.request_memory_write',
      '{"task_id":"task:test","address":"not-an-address",' +
      '"expected_original_bytes":"GG",' +
      '"replacement_bytes":"00"}');
    Assert((ValidationResult.Code = rcInvalidArgument) and
      (ValidationResult.StableCode = 'tool_arguments_schema_invalid'),
      'server enforces address and byte-string patterns before dispatch');
    Response := Protocol.HandleJsonRpc(
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
      '{"protocolVersion":"2025-06-18","capabilities":{},' +
      '"clientInfo":{"name":"test","version":"1"}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath('result.serverInfo.name').AsString =
        'cheat-engine-agent', 'initialize server info');
      Assert(ResponseData.FindPath('result.protocolVersion').AsString =
        '2025-06-18', 'protocol negotiation');
      Assert(Pos('single-player',
        ResponseData.FindPath('result.instructions').AsString) > 0,
        'server instructions');
    finally
      ResponseData.Free;
    end;

    Response := Protocol.HandleJsonRpc(
      '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}');
    Assert(Pos('cea.health', Response) > 0, 'health tool listed');
    Assert(Pos('cea.request_memory_write', Response) > 0,
      'write request tool listed');
    Assert(Pos('cea.approve', Response) = 0, 'approval tool is absent');
    Assert(Pos('cea.authorize_scan_scope', Response) = 0,
      'MCP cannot create a local scan scope');
    ResponseData := GetJSON(Response);
    try
      Assert(ToolIsReadOnly(ResponseData, 'cea.health'),
        'read-only annotation emitted');
      Assert(ToolSchema(ResponseData, 'cea.start_scan') <> nil,
        'start scan publishes an input schema');
      Assert(not TJSONObject(ToolSchema(ResponseData,
        'cea.start_scan')).Get('additionalProperties', True),
        'scan tool schema rejects unspecified arguments');
      Assert(ToolSchema(ResponseData, 'cea.start_scan').FindPath(
        'properties.scope_id.type').AsString = 'string',
        'scan tool advertises the locally authorized scope id');
      Assert(ToolSchema(ResponseData, 'cea.start_scan').FindPath(
        'properties.ranges.type').AsString = 'array',
        'scan tool advertises explicit ranges');
      Assert(ToolSchema(ResponseData, 'cea.refine_scan').FindPath(
        'properties.scan_id.type').AsString = 'string',
        'refine tool advertises existing session id');
      Assert(ToolSchema(ResponseData, 'cea.cancel_scan').FindPath(
        'properties.scan_id.type').AsString = 'string',
        'cancel tool advertises session id');
      Assert(ToolSchema(ResponseData, 'cea.list_modules') <> nil,
        'module listing is exposed by the MCP registry');
      Assert(ToolSchema(ResponseData, 'cea.attach_process').FindPath(
        'properties.operator_attests_authorized_debugging.type').AsString =
        'boolean', 'attach schema requires the local authorization attestation');
      Assert(ToolSchema(ResponseData, 'cea.request_memory_write').FindPath(
        'properties.expected_original_bytes.pattern').AsString <> '',
        'write proposal schema binds expected bytes');
      Tools := TJSONArray(ResponseData.FindPath('result.tools'));
      Assert(Tools.Count = 95, 'complete MCP registry publishes 95 tools');
      for I := 0 to Tools.Count - 1 do
        Assert(not TJSONObject(TJSONObject(Tools.Items[I]).Find(
          'inputSchema')).Get('additionalProperties', True),
          'every public MCP tool has a closed input schema: ' +
          TJSONObject(Tools.Items[I]).Get('name', ''));
      Assert(Pos('cea.write_field_value', Response) > 0,
        'player-level field write is listed as a proposal');
      Assert(Pos('cea.list_game_fields', Response) > 0,
        'player-level field listing is exposed');
      Assert(Pos('cea.declare_field', Response) > 0,
        'field declaration is exposed as a proposal');
      Assert(Pos('cea.list_published_cheat_files', Response) > 0,
        'published cheat file listing is exposed');
      Assert(Pos('cea.translate_cheat_descriptions', Response) > 0,
        'cheat description translation is exposed as a proposal');
      Assert(Pos('cea.save_ui_page', Response) > 0,
        'multi-page storage is exposed');
      Assert(Pos('cea.restore_ui_schema_version', Response) > 0,
        'UI schema version rollback is exposed');
      Assert(Pos('cea.propose_ui_customization', Response) > 0,
        'natural-language UI customization is exposed as a proposal');
      Assert(ToolSchema(ResponseData, 'cea.restore_ui_schema_version').FindPath(
        'properties.version.type').AsString = 'integer',
        'rollback tool requires an integer version');
      Assert(Pos('cea.declare_pointer_field', Response) > 0,
        'pointer chain declaration is exposed as a proposal');
      Assert(Pos('cea.resolve_field_address', Response) > 0,
        'pointer chain resolution is exposed as a read-only tool');
      Assert(ToolSchema(ResponseData, 'cea.declare_pointer_field').FindPath(
        'properties.offsets_json.type').AsString = 'string',
        'chain declaration carries the offsets as a JSON string');
      Assert(ToolSchema(ResponseData, 'cea.declare_pointer_field').FindPath(
        'required').Count = 5,
        'chain declaration requires field, type, module and offsets');
      Assert(Pos('cea.judge_aob_uniqueness', Response) > 0,
        'AOB uniqueness judging is exposed as a read-only tool');
      Assert(ToolSchema(ResponseData, 'cea.judge_aob_uniqueness').FindPath(
        'properties.scan_id.type').AsString = 'string',
        'AOB uniqueness judging addresses one scan session');
    finally
      ResponseData.Free;
    end;

    Response := Protocol.HandleJsonRpc(
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":' +
      '{"name":"cea.health","arguments":{}}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath(
        'result.structuredContent.data.status').AsString = 'ready',
        'health is ready');
      Assert(not ResponseData.FindPath('result.isError').AsBoolean,
        'health is not an error');
    finally
      ResponseData.Free;
    end;

    Response := Protocol.HandleJsonRpc(
      '{"jsonrpc":"2.0","id":4,"method":"missing","params":{}}');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath('error.code').AsInteger = -32601,
        'unknown method error');
    finally
      ResponseData.Free;
    end;

    Response := Protocol.HandleJsonRpc('[]');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath('error.code').AsInteger = -32600,
        'batch request rejected');
    finally
      ResponseData.Free;
    end;
    Response := Protocol.HandleJsonRpc('{not-json');
    ResponseData := GetJSON(Response);
    try
      Assert(ResponseData.FindPath('error.code').AsInteger = -32700,
        'parse error returned');
    finally
      ResponseData.Free;
    end;

    WriteLn('MCP_PROTOCOL=PASS');
  finally
    Protocol.Free;
    Registry.Free;
    Dispatcher.Free;
  end;
end.
