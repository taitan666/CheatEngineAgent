program test_openai_compatible;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, cea_results, cea_llm_provider, cea_openai_compatible;

type
  TFakeSecret = class(TObject, ICEASecretValueProvider)
  public
    ResolveCount: Cardinal;
    function ResolveValue(const ASecretRef: string;
      out AValue: string): TCEAResult;
  end;

  TFakeTransport = class(TObject, ICEALLMTransport)
  public
    LastEndpoint, LastSecret, LastBody: string;
    CallCount: Cardinal;
    ResponseJson: string;
    FailureCode: TCEAResultCode;
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
  Inc(ResolveCount);
  if ASecretRef <> 'cred:test' then
    Exit(TCEAResult.Error(rcUnauthenticated, 'secret_not_found', '{}'));
  AValue := 'test-secret-never-return';
  Result := TCEAResult.Ok('{"resolved":true}');
end;

function TFakeTransport.PostJson(const AEndpoint, ASecret, ABody: string;
  const ATimeoutMs: Cardinal;
  const ACancellation: ICEACancellationToken;
  const AAuthStyle: string;
  const AChunkSink: ICEAHttpResponseChunkSink): TCEAResult;
begin
  Inc(CallCount);
  LastEndpoint := AEndpoint;
  LastSecret := ASecret;
  LastBody := ABody;
  if AChunkSink <> nil then
  begin
    Result := AChunkSink.OnResponseChunk(
      'data: {"choices":[{"delta":{"content":"Streamed"}}]}'#10#10 +
      'data: {"usage":{"prompt_tokens":2,"completion_tokens":1,' +
      '"total_tokens":3}}'#10#10'data: [DONE]'#10#10);
    if Result.Failed then Exit;
  end;
  if FailureCode <> rcOk then
    Exit(TCEAResult.Error(FailureCode, 'fake_transport_failure', '{}'));
  if ResponseJson = '' then
    ResponseJson := '{"choices":[{"message":{' +
      '"content":"Use the cited AOB as a hypothesis only."}}],' +
      '"usage":{"prompt_tokens":120,"completion_tokens":20,' +
      '"total_tokens":140}}';
  Result := TCEAResult.Ok(ResponseJson);
end;

var
  Config: TCEAProviderConfiguration;
  Request: TCEALLMChatRequest;
  Secret: TFakeSecret;
  Transport: TFakeTransport;
  Provider: TOpenAICompatibleProvider;
  Cancellation: TCEACancellationToken;
  R: TCEAResult;
  Sink: TTextSink;

begin
  FillChar(Config, SizeOf(Config), 0);
  Config.ProviderId := 'local-test';
  Config.Endpoint := 'https://example.invalid/v1/chat/completions';
  Config.ModelId := 'test-model';
  Config.SecretRef := 'cred:test';
  Config.TimeoutMs := 1000;
  Config.MaxPromptBytes := 1024;
  Config.MaxRagBytes := 4096;
  Config.MaxOutputTokens := 512;
  Config.MaxTotalTokens := 1024;
  Config.Enabled := True;
  Secret := TFakeSecret.Create;
  Transport := TFakeTransport.Create;
  Provider := TOpenAICompatibleProvider.Create(Config, Secret, Transport);
  try
    FillChar(Request, SizeOf(Request), 0);
    Request.UserPrompt := 'Find the score address.';
    Request.RagContextJson := '{"authority":"none","citations":[]}';
    Request.MaxOutputTokens := 256;
    R := Provider.Chat(Request);
    Assert(R.Code = rcOk, 'OpenAI-compatible chat succeeds');
    Assert(Pos('hypothesis only', R.DataJson) > 0,
      'assistant content is normalized');
    Assert(Pos('test-secret-never-return', R.DataJson) = 0,
      'secret never appears in provider result');
    Assert(Transport.LastSecret = 'test-secret-never-return',
      'secret is passed only to transport');
    Assert((Pos('test-model', Transport.LastBody) > 0) and
      (Pos('authority', Transport.LastBody) > 0),
      'model and RAG context are included');
    Assert((Pos('never train', LowerCase(Transport.LastBody)) > 0) and
      (Pos('cannot approve', LowerCase(Transport.LastBody)) > 0),
      'system constraints are always injected');
    Assert((Pos('"prompt_tokens" : 120', R.DataJson) > 0) and
      (Pos('"total_tokens" : 140', R.DataJson) > 0),
      'actual provider token usage is preserved');

    Sink := TTextSink.Create;
    try
      Request.StreamSink := Sink;
      R := Provider.Chat(Request);
      Assert((R.Code = rcOk) and (Sink.Text = 'Streamed') and
        (Pos('"stream" : true', Transport.LastBody) > 0) and
        (Pos('"content" : "Streamed"', R.DataJson) > 0),
        'OpenAI provider enables and normalizes streaming');
      Request.StreamSink := nil;
    finally
      Sink.Free;
    end;

    Request.UserPrompt := StringOfChar('x', 1025);
    Assert(Provider.Chat(Request).Code = rcBudgetExceeded,
      'prompt byte budget is enforced before transport');
    Assert(Transport.CallCount = 2,
      'over-budget prompt never reaches transport');
    Request.UserPrompt := 'Find the score address.';
    Request.MaxOutputTokens := 513;
    Assert(Provider.Chat(Request).Code = rcBudgetExceeded,
      'requested output token budget is capped');
    Assert(Transport.CallCount = 2,
      'over-budget output never reaches transport');

    Request.MaxOutputTokens := 256;
    Cancellation := TCEACancellationToken.Create;
    Request.Cancellation := Cancellation;
    Cancellation.Cancel;
    Assert(Provider.Chat(Request).Code = rcCancelled,
      'pre-cancelled request exits before secret resolution');
    Assert((Secret.ResolveCount = 2) and (Transport.CallCount = 2),
      'cancelled request touches neither secret nor transport');
    Request.Cancellation := nil;

    Transport.ResponseJson := '{"choices":[{"message":{' +
      '"content":"oversized"}}],"usage":{"prompt_tokens":900,' +
      '"completion_tokens":200,"total_tokens":1100}}';
    Assert(Provider.Chat(Request).Code = rcBudgetExceeded,
      'actual total token overrun rejects the model result');

    Transport.FailureCode := rcTimeout;
    Transport.CallCount := 0;
    Assert(Provider.Chat(Request).Code = rcTimeout,
      'transport timeout is returned unchanged');
    Assert(Transport.CallCount = 1,
      'timeout is never retried by the provider');
    Transport.FailureCode := rcCancelled;
    Transport.CallCount := 0;
    Assert(Provider.Chat(Request).Code = rcCancelled,
      'transport cancellation is returned unchanged');
    Assert(Transport.CallCount = 1,
      'cancellation is never retried by the provider');
    Transport.FailureCode := rcOk;
    Config.Enabled := False;
    Provider.Free;
    Provider := TOpenAICompatibleProvider.Create(Config, Secret, Transport);
    Assert(Provider.Chat(Request).Code = rcRejected,
      'disabled provider cannot invoke transport');
    WriteLn('OPENAI_COMPATIBLE=PASS');
  finally
    Provider.Free;
    Transport.Free;
    Secret.Free;
  end;
end.
