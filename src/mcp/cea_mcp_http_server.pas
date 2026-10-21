unit cea_mcp_http_server;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fphttpserver, httpdefs, cea_results, cea_mcp_protocol;

type
  TCEALoopbackHttpServer = class(TFPHttpServer)
  public
    property Address;
  end;

  TCEAMCPHttpServer = class
  private
    FServer: TCEALoopbackHttpServer;
    FProtocol: TMCPProtocol;
    FToken: string;
    FPort: Word;
    FThread: TThread;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  public
    constructor Create(const AProtocol: TMCPProtocol; const AToken: string);
    destructor Destroy; override;
    function Start(const APreferredPort, AAttempts: Word;
      out ASelectedPort: Word): TCEAResult;
    procedure Stop;
    procedure RevokeToken;
    function Endpoint: string;
  end;

function GenerateMCPToken: string;
function ResolveMCPToken(const AEnvironmentVariable: string): string;

implementation

uses
  Windows, fphttpclient;

type
  TCEAServerThread = class(TThread)
  private
    FServer: TCEALoopbackHttpServer;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AServer: TCEALoopbackHttpServer);
    property ErrorText: string read FErrorText;
  end;

const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;

function BCryptGenRandom(const AAlgorithm: THandle; const ABuffer: PByte;
  const ABufferSize, AFlags: Cardinal): LongInt; stdcall;
  external 'bcrypt.dll';

function GenerateMCPToken: string;
const
  Digits = '0123456789abcdef';
var
  Bytes: array[0..31] of Byte;
  I: Integer;
begin
  if BCryptGenRandom(0, @Bytes[0], SizeOf(Bytes),
    BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0 then
    raise Exception.Create('BCryptGenRandom failed');
  SetLength(Result, SizeOf(Bytes) * 2);
  for I := 0 to High(Bytes) do
  begin
    Result[I * 2 + 1] := Digits[(Bytes[I] shr 4) + 1];
    Result[I * 2 + 2] := Digits[(Bytes[I] and $0F) + 1];
  end;
end;

function ResolveMCPToken(const AEnvironmentVariable: string): string;
begin
  if AEnvironmentVariable = '' then
    raise EArgumentException.Create('MCP token environment name required');
  Result := SysUtils.GetEnvironmentVariable(AEnvironmentVariable);
  if Result = '' then
    Exit(GenerateMCPToken);
  if Length(Result) < 32 then
    raise EArgumentException.Create('Injected MCP token is too short');
end;

constructor TCEAServerThread.Create(const AServer: TCEALoopbackHttpServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FServer := AServer;
end;

procedure TCEAServerThread.Execute;
begin
  try
    FServer.Active := True;
  except
    on E: Exception do FErrorText := E.Message;
  end;
end;

constructor TCEAMCPHttpServer.Create(const AProtocol: TMCPProtocol;
  const AToken: string);
begin
  inherited Create;
  if (AProtocol = nil) or (Length(AToken) < 16) then
    raise EArgumentException.Create('MCP protocol and strong token required');
  FProtocol := AProtocol;
  FToken := AToken;
  FServer := TCEALoopbackHttpServer.Create(nil);
  FServer.Address := '127.0.0.1';
  FServer.Threaded := True;
  FServer.QueueSize := 8;
  FServer.OnRequest := @HandleRequest;
end;

destructor TCEAMCPHttpServer.Destroy;
begin
  Stop;
  FServer.Free;
  FToken := StringOfChar(#0, Length(FToken));
  inherited Destroy;
end;

function TCEAMCPHttpServer.Start(const APreferredPort, AAttempts: Word;
  out ASelectedPort: Word): TCEAResult;
var
  Attempt: Word;
begin
  ASelectedPort := 0;
  if (APreferredPort = 0) or (AAttempts = 0) or FServer.Active then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'mcp_http_start_invalid', '{}'));
  for Attempt := 0 to AAttempts - 1 do
  begin
    try
      FServer.Port := APreferredPort + Attempt;
      FThread := TCEAServerThread.Create(FServer);
      FThread.Start;
      Sleep(100);
      if FThread.Finished then
      begin
        FreeAndNil(FThread);
        Continue;
      end;
      FPort := FServer.Port;
      ASelectedPort := FPort;
      Exit(TCEAResult.Ok('{"endpoint":"' + Endpoint + '"}'));
    except
      if FServer.Active then FServer.Active := False;
    end;
  end;
  Result := TCEAResult.Error(rcConflict, 'mcp_loopback_port_unavailable', '{}');
end;

procedure TCEAMCPHttpServer.Stop;
var
  WakeResponse: RawByteString;
begin
  if Assigned(FServer) and FServer.Active then
  begin
    FServer.Active := False;
    try
      WakeResponse := TFPHTTPClient.SimpleGet(
        'http://127.0.0.1:' + IntToStr(FPort) + '/__stop__');
    except
      WakeResponse := '';
    end;
  end;
  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  FPort := 0;
end;

procedure TCEAMCPHttpServer.RevokeToken;
begin
  FToken := StringOfChar(#0, Length(FToken));
  FToken := 'revoked';
end;

function TCEAMCPHttpServer.Endpoint: string;
begin
  if FPort = 0 then Result := ''
  else Result := 'http://127.0.0.1:' + IntToStr(FPort) + '/mcp';
end;

procedure TCEAMCPHttpServer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
begin
  AResponse.ContentType := 'application/json; charset=utf-8';
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  if (ARequest.Authorization <> 'Bearer ' + FToken) then
  begin
    AResponse.Code := 401;
    AResponse.Content := '{"error":"unauthenticated"}';
    Exit;
  end;
  if (ARequest.Method <> 'POST') or (ARequest.PathInfo <> '/mcp') then
  begin
    AResponse.Code := 404;
    AResponse.Content := '{"error":"not_found"}';
    Exit;
  end;
  if ARequest.ContentLength > 1024 * 1024 then
  begin
    AResponse.Code := 413;
    AResponse.Content := '{"error":"request_too_large"}';
    Exit;
  end;
  AResponse.Code := 200;
  AResponse.Content := FProtocol.HandleJsonRpc(ARequest.Content);
end;

end.
