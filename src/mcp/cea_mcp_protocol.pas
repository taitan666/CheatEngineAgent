unit cea_mcp_protocol;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, FPJSON, cea_results, cea_mcp_registry;

type
  TMCPProtocol = class
  private
    FRegistry: TMCPToolRegistry;
    function BuildError(const AIdJson: string; const ACode: Integer;
      const AMessage: string): string;
    function BuildInitialize(const AIdJson: string): string;
    function BuildToolList(const AIdJson: string): string;
    function BuildToolCall(const AIdJson: string;
      AParams: TJSONObject): string;
  public
    constructor Create(const ARegistry: TMCPToolRegistry);
    function HandleJsonRpc(const ARequestJson: string): string;
  end;

implementation

uses
  JSONParser;

const
  MCPProtocolVersion = '2025-06-18';
  MCPServerInstructions =
    'Only use this server with explicitly authorized single-player offline ' +
    'targets. Writes, freezes, debug actions, AutoAssembler and Lua require ' +
    'local Cheat Engine UI approval. The client cannot approve its own ' +
    'effects. Kernel/DBK, anti-cheat bypass, concealment, multiplayer ' +
    'targeting, model training and weight mutation are permanently denied.';

constructor TMCPProtocol.Create(const ARegistry: TMCPToolRegistry);
begin
  inherited Create;
  FRegistry := ARegistry;
end;

function TMCPProtocol.BuildError(const AIdJson: string;
  const ACode: Integer; const AMessage: string): string;
var
  Root: TJSONObject;
  ErrorObject: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', '2.0');
    Root.Add('id', GetJSON(AIdJson));
    ErrorObject := TJSONObject.Create;
    ErrorObject.Add('code', ACode);
    ErrorObject.Add('message', AMessage);
    Root.Add('error', ErrorObject);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function TMCPProtocol.BuildInitialize(const AIdJson: string): string;
var
  Root: TJSONObject;
  ResultObject: TJSONObject;
  Capabilities: TJSONObject;
  Tools: TJSONObject;
  ServerInfo: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', '2.0');
    Root.Add('id', GetJSON(AIdJson));
    ResultObject := TJSONObject.Create;
    ResultObject.Add('protocolVersion', MCPProtocolVersion);
    Capabilities := TJSONObject.Create;
    Tools := TJSONObject.Create;
    Tools.Add('listChanged', False);
    Capabilities.Add('tools', Tools);
    ResultObject.Add('capabilities', Capabilities);
    ServerInfo := TJSONObject.Create;
    ServerInfo.Add('name', 'cheat-engine-agent');
    ServerInfo.Add('version', '0.1.0');
    ResultObject.Add('serverInfo', ServerInfo);
    ResultObject.Add('instructions', MCPServerInstructions);
    Root.Add('result', ResultObject);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function TMCPProtocol.BuildToolList(const AIdJson: string): string;
var
  Root: TJSONObject;
  ResultObject: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', '2.0');
    Root.Add('id', GetJSON(AIdJson));
    ResultObject := TJSONObject.Create;
    ResultObject.Add('tools', FRegistry.BuildToolList);
    Root.Add('result', ResultObject);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function TMCPProtocol.BuildToolCall(const AIdJson: string;
  AParams: TJSONObject): string;
var
  Root: TJSONObject;
  ResultObject: TJSONObject;
  Structured: TJSONObject;
  Content: TJSONArray;
  TextItem: TJSONObject;
  Data: TJSONData;
  ToolName: string;
  Arguments: TJSONData;
  CallResult: TCEAResult;
begin
  ToolName := AParams.Get('name', '');
  Arguments := AParams.Find('arguments');
  if (ToolName = '') or (Arguments = nil) then
    Exit(BuildError(AIdJson, -32602, 'Invalid params'));
  CallResult := FRegistry.CallTool(ToolName, Arguments.AsJSON);
  Root := TJSONObject.Create;
  try
    Root.Add('jsonrpc', '2.0');
    Root.Add('id', GetJSON(AIdJson));
    ResultObject := TJSONObject.Create;
    Content := TJSONArray.Create;
    TextItem := TJSONObject.Create;
    TextItem.Add('type', 'text');
    if CallResult.MessageText <> '' then
      TextItem.Add('text', CallResult.MessageText)
    else
      TextItem.Add('text', CallResult.StableCode);
    Content.Add(TextItem);
    ResultObject.Add('content', Content);
    Structured := TJSONObject.Create;
    Structured.Add('stable_code', CallResult.StableCode);
    Structured.Add('is_error', CallResult.Failed);
    try
      Data := GetJSON(Utf8JsonText(CallResult.DataJson));
    except
      Data := TJSONObject.Create;
    end;
    Structured.Add('data', Data);
    if CallResult.ReceiptId <> '' then
      Structured.Add('receipt_id', CallResult.ReceiptId);
    if CallResult.ProofId <> '' then
      Structured.Add('proof_id', CallResult.ProofId);
    ResultObject.Add('structuredContent', Structured);
    ResultObject.Add('isError', CallResult.Failed);
    Root.Add('result', ResultObject);
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

function TMCPProtocol.HandleJsonRpc(const ARequestJson: string): string;
var
  RequestData: TJSONData;
  RequestObject: TJSONObject;
  ParamsData: TJSONData;
  RpcMethod: string;
  IdJson: string;
  I: Integer;
  FieldName: string;
begin
  if Length(ARequestJson) > 1024 * 1024 then
    Exit(BuildError('null', -32600, 'Request too large'));
  RequestData := nil;
  try
    try
      { A JSON-RPC request carrying non-ASCII text arrives tagged with whatever
        code page the caller's string happened to have (936 for a literal built
        in a test, 65001 over HTTP). GetJSON trusts that tag and transcodes the
        already-UTF-8 bytes, which can swallow the byte after a multi-byte
        sequence and turn a valid request into a parse error. Tag it as UTF-8
        first so the bytes are read as what they are. }
      RequestData := GetJSON(Utf8JsonText(ARequestJson));
    except
      Exit(BuildError('null', -32700, 'Parse error'));
    end;
    if RequestData.JSONType <> jtObject then
      Exit(BuildError('null', -32600, 'Invalid Request'));
    RequestObject := TJSONObject(RequestData);
    for I := 0 to RequestObject.Count - 1 do
    begin
      FieldName := RequestObject.Names[I];
      if (FieldName <> 'jsonrpc') and (FieldName <> 'id') and
         (FieldName <> 'method') and (FieldName <> 'params') then
        Exit(BuildError('null', -32600, 'Invalid Request'));
    end;
    if RequestObject.Get('jsonrpc', '') <> '2.0' then
      Exit(BuildError('null', -32600, 'Invalid Request'));
    RpcMethod := RequestObject.Get('method', '');
    if RpcMethod = '' then
      Exit(BuildError('null', -32600, 'Invalid Request'));
    if RequestObject.Find('id') <> nil then
      IdJson := RequestObject.Find('id').AsJSON
    else
      IdJson := 'null';
    ParamsData := RequestObject.Find('params');
    if (ParamsData <> nil) and (ParamsData.JSONType <> jtObject) then
      Exit(BuildError(IdJson, -32602, 'Invalid params'));

    if RpcMethod = 'initialize' then
      Result := BuildInitialize(IdJson)
    else if RpcMethod = 'notifications/initialized' then
      Result := ''
    else if RpcMethod = 'ping' then
      Result := '{"jsonrpc":"2.0","id":' + IdJson + ',"result":{}}'
    else if RpcMethod = 'tools/list' then
      Result := BuildToolList(IdJson)
    else if RpcMethod = 'tools/call' then
    begin
      if ParamsData = nil then
        Result := BuildError(IdJson, -32602, 'Invalid params')
      else
        Result := BuildToolCall(IdJson, TJSONObject(ParamsData));
    end
    else
      Result := BuildError(IdJson, -32601, 'Method not found');
  finally
    RequestData.Free;
  end;
end;

end.
