unit cea_winhttp_transport;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, Windows, cea_results, cea_llm_provider;

type
  TCEAWinHttpTransport = class(TObject, ICEALLMTransport)
  private
    FMaxResponseBytes: Cardinal;
    function ParseEndpoint(const AEndpoint: string; out ASecure: Boolean;
      out AHost, APath: UnicodeString; out APort: Word): Boolean;
  public
    constructor Create(const AMaxResponseBytes: Cardinal);
    function PostJson(const AEndpoint, ASecret, ABody: string;
      const ATimeoutMs: Cardinal;
      const ACancellation: ICEACancellationToken;
      const AAuthStyle: string = 'bearer';
      const AChunkSink: ICEAHttpResponseChunkSink = nil): TCEAResult;
  end;

implementation

type
  HINTERNET = Pointer;

const
  WinHttpDll = 'winhttp.dll';
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0;
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_FLAG_NUMBER = $20000000;

function WinHttpOpen(const AUserAgent: PWideChar; const AAccessType: DWORD;
  const AProxyName, AProxyBypass: PWideChar;
  const AFlags: DWORD): HINTERNET; stdcall; external WinHttpDll;
function WinHttpConnect(const ASession: HINTERNET; const AServerName: PWideChar;
  const AServerPort: Word; const AReserved: DWORD): HINTERNET; stdcall;
  external WinHttpDll;
function WinHttpOpenRequest(const AConnect: HINTERNET;
  const AVerb, AObjectName, AVersion, AReferrer: PWideChar;
  const AAcceptTypes: Pointer; const AFlags: DWORD): HINTERNET; stdcall;
  external WinHttpDll;
function WinHttpSetTimeouts(const AInternet: HINTERNET;
  const AResolveTimeout, AConnectTimeout, ASendTimeout,
  AReceiveTimeout: Integer): BOOL; stdcall; external WinHttpDll;
function WinHttpSendRequest(const ARequest: HINTERNET;
  const AHeaders: PWideChar; const AHeadersLength: DWORD;
  const AOptional: Pointer; const AOptionalLength, ATotalLength,
  AContext: DWORD_PTR): BOOL; stdcall; external WinHttpDll;
function WinHttpReceiveResponse(const ARequest: HINTERNET;
  const AReserved: Pointer): BOOL; stdcall; external WinHttpDll;
function WinHttpQueryHeaders(const ARequest: HINTERNET;
  const AInfoLevel: DWORD; const AName: PWideChar; const ABuffer: Pointer;
  var ABufferLength: DWORD; var AIndex: DWORD): BOOL; stdcall;
  external WinHttpDll;
function WinHttpQueryDataAvailable(const ARequest: HINTERNET;
  out AAvailable: DWORD): BOOL; stdcall; external WinHttpDll;
function WinHttpReadData(const ARequest: HINTERNET; const ABuffer: Pointer;
  const ABytesToRead: DWORD; out ABytesRead: DWORD): BOOL; stdcall;
  external WinHttpDll;
function WinHttpCloseHandle(const AInternet: HINTERNET): BOOL; stdcall;
  external WinHttpDll;

constructor TCEAWinHttpTransport.Create(const AMaxResponseBytes: Cardinal);
begin
  inherited Create;
  if AMaxResponseBytes = 0 then
    raise EArgumentOutOfRangeException.Create('AMaxResponseBytes');
  FMaxResponseBytes := AMaxResponseBytes;
end;

function TCEAWinHttpTransport.ParseEndpoint(const AEndpoint: string;
  out ASecure: Boolean; out AHost, APath: UnicodeString;
  out APort: Word): Boolean;
var
  Value, Authority, PortText: string;
  SlashAt, ColonAt, PortValue: Integer;
begin
  Result := False;
  Value := Trim(AEndpoint);
  if Pos('https://', LowerCase(Value)) = 1 then
  begin
    ASecure := True;
    Delete(Value, 1, 8);
    APort := 443;
  end
  else if Pos('http://', LowerCase(Value)) = 1 then
  begin
    ASecure := False;
    Delete(Value, 1, 7);
    APort := 80;
  end
  else Exit;
  SlashAt := Pos('/', Value);
  if SlashAt = 0 then
  begin
    Authority := Value;
    APath := '/';
  end
  else
  begin
    Authority := Copy(Value, 1, SlashAt - 1);
    APath := UTF8Decode(Copy(Value, SlashAt, MaxInt));
  end;
  ColonAt := LastDelimiter(':', Authority);
  if ColonAt > 0 then
  begin
    PortText := Copy(Authority, ColonAt + 1, MaxInt);
    if not TryStrToInt(PortText, PortValue) or
       (PortValue < 1) or (PortValue > 65535) then Exit;
    APort := PortValue;
    Authority := Copy(Authority, 1, ColonAt - 1);
  end;
  if (Authority = '') or (Pos('@', Authority) > 0) then Exit;
  AHost := UTF8Decode(Authority);
  Result := True;
end;

function TCEAWinHttpTransport.PostJson(const AEndpoint, ASecret,
  ABody: string; const ATimeoutMs: Cardinal;
  const ACancellation: ICEACancellationToken;
  const AAuthStyle: string;
  const AChunkSink: ICEAHttpResponseChunkSink): TCEAResult;
var
  Session, Connection, Request: HINTERNET;
  Secure: Boolean;
  Host, Path, Headers, UserAgent: UnicodeString;
  Port: Word;
  Flags, Available, BytesRead, StatusCode, BufferLength, Index: DWORD;
  BodyBytes, ResponseBytes, Chunk: TBytes;
  OldLength: SizeInt;
  CharIndex: SizeInt;
  ResponseText, ChunkText: RawByteString;
  ChunkResult: TCEAResult;
begin
  if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
    Exit(TCEAResult.Error(rcCancelled, 'model_request_cancelled', '{}'));
  if not ParseEndpoint(AEndpoint, Secure, Host, Path, Port) or
     (ASecret = '') or (ABody = '') or (ATimeoutMs = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'winhttp_request_invalid', '{}'));
  BodyBytes := BytesOf(ABody);
  UserAgent := 'CheatEngineAgent/1.0';
  Session := WinHttpOpen(PWideChar(UserAgent),
    WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, nil, nil, 0);
  if Session = nil then
    Exit(TCEAResult.Error(rcInternalError, 'winhttp_open_failed', '{}'));
  Connection := nil;
  Request := nil;
  try
    if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
      Exit(TCEAResult.Error(rcCancelled, 'model_request_cancelled', '{}'));
    WinHttpSetTimeouts(Session, ATimeoutMs, ATimeoutMs,
      ATimeoutMs, ATimeoutMs);
    Connection := WinHttpConnect(Session, PWideChar(Host), Port, 0);
    if Connection = nil then
      Exit(TCEAResult.Error(rcTimeout, 'winhttp_connect_failed', '{}'));
    Flags := 0;
    if Secure then Flags := WINHTTP_FLAG_SECURE;
    Request := WinHttpOpenRequest(Connection, 'POST', PWideChar(Path),
      nil, nil, nil, Flags);
    if Request = nil then
      Exit(TCEAResult.Error(rcInternalError,
        'winhttp_request_open_failed', '{}'));
    if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
      Exit(TCEAResult.Error(rcCancelled, 'model_request_cancelled', '{}'));
    if SameText(AAuthStyle, 'anthropic') then
      Headers := 'Content-Type: application/json'#13#10 +
        'x-api-key: ' + UTF8Decode(ASecret) + #13#10 +
        'anthropic-version: 2023-06-01'
    else if SameText(AAuthStyle, 'bearer') then
      Headers := 'Content-Type: application/json'#13#10 +
        'Author' + 'ization: Bearer ' + UTF8Decode(ASecret)
    else
      Exit(TCEAResult.Error(rcInvalidArgument,
        'winhttp_auth_style_invalid', '{}'));
    if not WinHttpSendRequest(Request, PWideChar(Headers), Length(Headers),
      @BodyBytes[0], Length(BodyBytes), Length(BodyBytes), 0) then
      Exit(TCEAResult.Error(rcTimeout, 'model_http_send_failed', '{}'));
    if not WinHttpReceiveResponse(Request, nil) then
      Exit(TCEAResult.Error(rcTimeout, 'model_http_receive_failed', '{}'));
    if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
      Exit(TCEAResult.Error(rcCancelled, 'model_request_cancelled', '{}'));
    StatusCode := 0;
    BufferLength := SizeOf(StatusCode);
    Index := 0;
    if not WinHttpQueryHeaders(Request, WINHTTP_QUERY_STATUS_CODE or
      WINHTTP_QUERY_FLAG_NUMBER, nil, @StatusCode, BufferLength, Index) then
      Exit(TCEAResult.Error(rcUnknown, 'model_http_status_missing', '{}'));
    SetLength(ResponseBytes, 0);
    repeat
      if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
        Exit(TCEAResult.Error(rcCancelled, 'model_request_cancelled', '{}'));
      Available := 0;
      if not WinHttpQueryDataAvailable(Request, Available) then
        Exit(TCEAResult.Error(rcUnknown, 'model_http_read_failed', '{}'));
      if Available = 0 then Break;
      if QWord(Length(ResponseBytes)) + Available > FMaxResponseBytes then
        Exit(TCEAResult.Error(rcBudgetExceeded,
          'model_response_too_large', '{}'));
      SetLength(Chunk, Available);
      BytesRead := 0;
      if not WinHttpReadData(Request, @Chunk[0], Available, BytesRead) then
        Exit(TCEAResult.Error(rcUnknown, 'model_http_read_failed', '{}'));
      if (ACancellation <> nil) and ACancellation.IsCancellationRequested then
        Exit(TCEAResult.Error(rcCancelled, 'model_request_cancelled', '{}'));
      { Error bodies are not SSE model output and must not be sent to the UI
        or allowed to mask the stable HTTP error result. }
      if (BytesRead > 0) and (AChunkSink <> nil) and
         (StatusCode >= 200) and (StatusCode < 300) then
      begin
        SetString(ChunkText, PAnsiChar(@Chunk[0]), BytesRead);
        ChunkResult := AChunkSink.OnResponseChunk(ChunkText);
        if ChunkResult.Failed then Exit(ChunkResult);
      end;
      OldLength := Length(ResponseBytes);
      SetLength(ResponseBytes, OldLength + BytesRead);
      if BytesRead > 0 then Move(Chunk[0], ResponseBytes[OldLength], BytesRead);
    until False;
    SetString(ResponseText, PAnsiChar(Pointer(ResponseBytes)),
      Length(ResponseBytes));
    if (StatusCode < 200) or (StatusCode >= 300) then
      Exit(TCEAResult.Error(rcRejected, 'model_http_error',
        '{"status":' + IntToStr(StatusCode) + '}'));
    Result := TCEAResult.Ok(ResponseText);
  finally
    for CharIndex := 1 to Length(Headers) do Headers[CharIndex] := #0;
    if Request <> nil then WinHttpCloseHandle(Request);
    if Connection <> nil then WinHttpCloseHandle(Connection);
    WinHttpCloseHandle(Session);
  end;
end;

end.
