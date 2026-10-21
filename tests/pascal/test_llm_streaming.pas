program test_llm_streaming;

{$mode objfpc}{$H+}
{$interfaces corba}

uses
  SysUtils, cea_results, cea_llm_provider, cea_llm_streaming;

type
  TTextSink = class(TObject, ICEALLMTextStreamSink)
  public
    Text: string;
    procedure OnTextDelta(const AText: string);
  end;

procedure TTextSink.OnTextDelta(const AText: string);
begin
  Text := Text + AText;
end;

var
  Sink: TTextSink;
  Collector: TCEASSECollector;
  R: TCEAResult;
begin
  Sink := TTextSink.Create;
  Collector := TCEASSECollector.Create(sfOpenAI, Sink);
  try
    Assert(Collector.OnResponseChunk('data: {"choices":[{"delta":{' +
      '"content":"Hel').Code = rcOk, 'fragmented OpenAI SSE starts');
    Assert(Collector.OnResponseChunk('lo"}}]}'#10#10 +
      'data: {"usage":{"prompt_tokens":4,"completion_tokens":2,' +
      '"total_tokens":6}}'#10#10'data: [DONE]'#10#10).Code = rcOk,
      'fragmented OpenAI SSE completes');
    R := Collector.FinalResult('openai-compatible', 'model-a', 100);
    Assert((R.Code = rcOk) and (Sink.Text = 'Hello') and
      (Pos('"content" : "Hello"', R.DataJson) > 0) and
      (Pos('"total_tokens" : 6', R.DataJson) > 0),
      'OpenAI deltas and usage normalize into one proposal');
  finally
    Collector.Free;
    Sink.Free;
  end;

  Sink := TTextSink.Create;
  Collector := TCEASSECollector.Create(sfAnthropic, Sink);
  try
    Assert(Collector.OnResponseChunk(
      'event: message_start'#10'data: {"message":{"usage":{' +
      '"input_tokens":5}}}'#10#10 +
      'event: content_block_delta'#10'data: {"type":"content_block_delta",' +
      '"delta":{"type":"text_delta","text":"World"}}'#10#10 +
      'event: message_delta'#10'data: {"usage":{"output_tokens":3}}'#10#10
      ).Code = rcOk, 'Anthropic SSE events parse');
    R := Collector.FinalResult('anthropic-compatible', 'model-b', 100);
    Assert((R.Code = rcOk) and (Sink.Text = 'World') and
      (Pos('"total_tokens" : 8', R.DataJson) > 0),
      'Anthropic deltas and split usage normalize');
  finally
    Collector.Free;
    Sink.Free;
  end;
  WriteLn('LLM_STREAMING=PASS');
end.
