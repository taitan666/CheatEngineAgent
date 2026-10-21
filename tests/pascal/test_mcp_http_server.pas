program test_mcp_http_server;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  Classes, SysUtils, Windows, fphttpclient, cea_results, cea_mcp_registry,
  cea_mcp_protocol, cea_mcp_http_server;

type
  TFakeDispatcher = class(TObject, IMCPToolDispatcher)
  public
    function DispatchTool(const AToolName,
      AArgumentsJson: string): TCEAResult;
  end;

function TFakeDispatcher.DispatchTool(const AToolName,
  AArgumentsJson: string): TCEAResult;
begin
  Result := TCEAResult.Ok('{"status":"ready"}');
end;

function Post(const AUrl, AToken, ABody: string;
  out AStatus: Integer): string;
var
  Client: TFPHTTPClient;
  Input, Output: TStringStream;
begin
  Client := TFPHTTPClient.Create(nil);
  Input := TStringStream.Create(ABody);
  Output := TStringStream.Create('');
  try
    Client.AddHeader('Content-Type', 'application/json');
    if AToken <> '' then Client.AddHeader('Authorization', 'Bearer ' + AToken);
    Client.RequestBody := Input;
    try
      Client.Post(AUrl, Output);
      AStatus := Client.ResponseStatusCode;
    except
      on E: EHTTPClient do AStatus := Client.ResponseStatusCode;
    end;
    Result := Output.DataString;
  finally
    Output.Free;
    Input.Free;
    Client.Free;
  end;
end;

var
  Dispatcher: TFakeDispatcher;
  Registry: TMCPToolRegistry;
  Protocol: TMCPProtocol;
  Server: TCEAMCPHttpServer;
  R: TCEAResult;
  Port: Word;
  Status: Integer;
  Response, Token: string;

begin
  Windows.SetEnvironmentVariable('CEA_TEST_MCP_TOKEN',
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
  Token := ResolveMCPToken('CEA_TEST_MCP_TOKEN');
  Assert(Token =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'MCP token can be injected by the launcher environment');
  Windows.SetEnvironmentVariable('CEA_TEST_MCP_TOKEN', nil);
  Token := ResolveMCPToken('CEA_TEST_MCP_TOKEN');
  Assert(Length(Token) = 64, 'missing environment token is generated per run');

  Dispatcher := TFakeDispatcher.Create;
  Registry := TMCPToolRegistry.Create(Dispatcher);
  RegisterDefaultFoundationTools(Registry);
  Protocol := TMCPProtocol.Create(Registry);
  Server := TCEAMCPHttpServer.Create(Protocol, 'test-ephemeral-token');
  try
    R := Server.Start(32479, 5, Port);
    Assert(R.Code = rcOk, 'loopback MCP HTTP server starts');
    Assert(Port >= 32479, 'server reports selected loopback port');
    Response := Post('http://127.0.0.1:' + IntToStr(Port) + '/mcp',
      '', '{"jsonrpc":"2.0","id":1,"method":"tools/list"}', Status);
    Assert(Status = 401, 'missing bearer token is rejected');
    Response := Post('http://127.0.0.1:' + IntToStr(Port) + '/mcp',
      'test-ephemeral-token',
      '{"jsonrpc":"2.0","id":1,"method":"tools/call",' +
      '"params":{"name":"cea.health","arguments":{}}}', Status);
    Assert((Status = 200) and (Pos('ready', Response) > 0),
      'authenticated JSON-RPC reaches MCP protocol');
    Assert(Server.Endpoint = 'http://127.0.0.1:' + IntToStr(Port) + '/mcp',
      'endpoint is loopback only');
    WriteLn('MCP_HTTP_SERVER=PASS');
  finally
    Server.Free;
    Protocol.Free;
    Registry.Free;
    Dispatcher.Free;
  end;
end.
