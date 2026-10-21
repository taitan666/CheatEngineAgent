unit cea_llm_provider;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_results;

type
  TCEAProviderConfiguration = record
    ProviderId: string;
    Endpoint: string;
    ModelId: string;
    SecretRef: string;
    TimeoutMs: Cardinal;
    MaxPromptBytes: Cardinal;
    MaxRagBytes: Cardinal;
    MaxOutputTokens: Cardinal;
    MaxTotalTokens: Cardinal;
    Enabled: Boolean;
  end;

  ICEACancellationToken = interface
    function IsCancellationRequested: Boolean;
  end;

  ICEALLMTextStreamSink = interface
    procedure OnTextDelta(const AText: string);
  end;

  ICEAHttpResponseChunkSink = interface
    function OnResponseChunk(const AChunk: string): TCEAResult;
  end;

  TCEACancellationToken = class(TObject, ICEACancellationToken)
  private
    FCancelled: LongInt;
  public
    procedure Cancel;
    function IsCancellationRequested: Boolean;
  end;

  TCEALLMChatRequest = record
    UserPrompt: string;
    RagContextJson: string;
    MaxOutputTokens: Cardinal;
    Temperature: Double;
    Cancellation: ICEACancellationToken;
    StreamSink: ICEALLMTextStreamSink;
    // 结构化输出（1C 扩展，向后兼容）：
    // ResponseFormat：空=自由文本；'json_object'=JSON 对象模式（OpenAI response_format）
    // OutputJsonSchema：可选 JSON Schema 约束（先记录，供后续工具调用/严格校验用）
    ResponseFormat: string;
    OutputJsonSchema: string;
  end;

  ICEASecretValueProvider = interface
    function ResolveValue(const ASecretRef: string;
      out AValue: string): TCEAResult;
  end;

  ICEALLMTransport = interface
    function PostJson(const AEndpoint, ASecret, ABody: string;
      const ATimeoutMs: Cardinal;
      const ACancellation: ICEACancellationToken;
      const AAuthStyle: string = 'bearer';
      const AChunkSink: ICEAHttpResponseChunkSink = nil): TCEAResult;
  end;

  TCEALLMChatProvider = class(TObject)
  public
    function Chat(const ARequest: TCEALLMChatRequest): TCEAResult;
      virtual; abstract;
  end;

implementation

procedure TCEACancellationToken.Cancel;
begin
  InterlockedExchange(FCancelled, 1);
end;

function TCEACancellationToken.IsCancellationRequested: Boolean;
begin
  Result := InterlockedCompareExchange(FCancelled, 0, 0) <> 0;
end;

end.
