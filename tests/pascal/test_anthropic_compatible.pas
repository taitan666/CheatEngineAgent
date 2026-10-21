program test_anthropic_compatible;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, cea_results, cea_llm_provider, cea_anthropic_compatible;

type
  TFakeSecret = class(TObject, ICEASecretValueProvider)
  public
    function ResolveValue(const ASecretRef: string;
      out AValue: string): TCEAResult;
  end;

  TFakeTransport = class(TObject, ICEALLMTransport)
  public
    LastBody, LastAuthStyle: string;
    ResponseJson: string;
    function PostJson(const AEndpoint, ASecret, ABody: string;
      const ATimeoutMs: Cardinal;
      const ACancellation: ICEACancellationToken;
      const AAuthStyle: string = 'bearer';
      const AChunkSink: ICEAHttpResponseChunkSink = nil): TCEAResult;
  end;

  TTextSink = class(TObject, ICEALLMTextStreamSink)
  public
    Text: string;
    procedure OnTextDelta(const AText: string);
  end;

procedure TTextSink.OnTextDelta(const AText: string);
begin
  Text := Text + AText;
end;

function TFakeSecret.ResolveValue(const ASecretRef: string;
  out AValue: string): TCEAResult;
begin
  if ASecretRef <> 'cred:anthropic' then
    Exit(TCEAResult.Error(rcUnauthenticated, 'secret_not_found', '{}'));
  AValue := 'secret-not-returned';
  Result := TCEAResult.Ok('{}');
end;

function TFakeTransport.PostJson(const AEndpoint, ASecret, ABody: string;
  const ATimeoutMs: Cardinal; const ACancellation: ICEACancellationToken;
  const AAuthStyle: string;
  const AChunkSink: ICEAHttpResponseChunkSink): TCEAResult;
begin
  LastBody := ABody;
  LastAuthStyle := AAuthStyle;
  if AChunkSink <> nil then
  begin
    Result := AChunkSink.OnResponseChunk(
      'event: message_start'#10'data: {"message":{"usage":{' +
      '"input_tokens":4}}}'#10#10 +
      'event: content_block_delta'#10'data: {"type":"content_block_delta",' +
      '"delta":{"type":"text_delta","text":"Streamed A"}}'#10#10 +
      'event: message_delta'#10'data: {"usage":{"output_tokens":2}}'#10#10);
    if Result.Failed then Exit;
  end;
  Result := TCEAResult.Ok(ResponseJson);
end;

var
  Config: TCEAProviderConfiguration;
  Request: TCEALLMChatRequest;
  Secret: TFakeSecret;
  Transport: TFakeTransport;
  Provider: TAnthropicCompatibleProvider;
  R: TCEAResult;
  Sink: TTextSink;
begin
  FillChar(Config, SizeOf(Config), 0);
  Config.ProviderId := 'anthropic-compatible';
  Config.Endpoint := 'https://api.deepseek.com/anthropic/v1/messages';
  Config.ModelId := 'deepseek-flash';
  Config.SecretRef := 'cred:anthropic';
  Config.TimeoutMs := 60000;
  Config.MaxPromptBytes := 4096;
  Config.MaxRagBytes := 4096;
  Config.MaxOutputTokens := 1024;
  Config.MaxTotalTokens := 4096;
  Config.Enabled := True;
  FillChar(Request, SizeOf(Request), 0);
  Request.UserPrompt := 'Find evidence.';
  Request.RagContextJson := '{"authority":"none","citations":[]}';
  Request.MaxOutputTokens := 256;
  Request.Temperature := 0.2;
  Secret := TFakeSecret.Create;
  Transport := TFakeTransport.Create;
  Transport.ResponseJson := '{"id":"msg_test","content":[' +
    '{"type":"text","text":"Use evidence only."}],' +
    '"usage":{"input_tokens":40,"output_tokens":12}}';
  Provider := TAnthropicCompatibleProvider.Create(Config, Secret, Transport);
  try
    R := Provider.Chat(Request);
    Assert(R.Code = rcOk, 'Anthropic-compatible chat succeeds');
    Assert(Transport.LastAuthStyle = 'anthropic',
      'Anthropic transport uses x-api-key authentication style');
    Assert((Pos('"system"', Transport.LastBody) > 0) and
      (Pos('"messages"', Transport.LastBody) > 0) and
      (Pos('deepseek-flash', Transport.LastBody) > 0),
      'Anthropic request uses Messages API shape');
    Assert((Pos('Use evidence only.', R.DataJson) > 0) and
      (Pos('"total_tokens" : 52', R.DataJson) > 0),
      'Anthropic response text and usage are normalized');
    Assert(Pos('secret-not-returned', R.DataJson) = 0,
      'provider result never contains the credential');
    Sink := TTextSink.Create;
    try
      Request.StreamSink := Sink;
      R := Provider.Chat(Request);
      Assert((R.Code = rcOk) and (Sink.Text = 'Streamed A') and
        (Pos('"stream" : true', Transport.LastBody) > 0) and
        (Pos('"total_tokens" : 6', R.DataJson) > 0),
        'Anthropic provider enables and normalizes streaming');
      Request.StreamSink := nil;
    finally
      Sink.Free;
    end;
  finally
    Provider.Free;
    Transport.Free;
    Secret.Free;
  end;
  WriteLn('ANTHROPIC_COMPATIBLE=PASS');
end.
