unit cea_llm_streaming;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_results, cea_llm_provider;

type
  TCEAStreamFormat = (sfOpenAI, sfAnthropic);

  TCEASSECollector = class(TObject, ICEAHttpResponseChunkSink)
  private
    FFormat: TCEAStreamFormat;
    FSink: ICEALLMTextStreamSink;
    FBuffer: string;
    FEventData: string;
    FContent: string;
    FPromptTokens: Int64;
    FCompletionTokens: Int64;
    FFailure: TCEAResult;
    FHasFailure: Boolean;
    function ProcessEvent(const APayload: string): TCEAResult;
    function ProcessLine(const ALine: string): TCEAResult;
  public
    constructor Create(const AFormat: TCEAStreamFormat;
      const ASink: ICEALLMTextStreamSink);
    function OnResponseChunk(const AChunk: string): TCEAResult;
    function FinalResult(const AProviderId, AModelId: string;
      const AMaxTotalTokens: Cardinal): TCEAResult;
  end;

implementation

uses
  SysUtils, FPJSON, JSONParser;

constructor TCEASSECollector.Create(const AFormat: TCEAStreamFormat;
  const ASink: ICEALLMTextStreamSink);
begin
  inherited Create;
  FFormat := AFormat;
  FSink := ASink;
  FFailure := TCEAResult.Ok('{}');
end;

function TCEASSECollector.ProcessEvent(const APayload: string): TCEAResult;
var
  Data, Item, Delta, Usage: TJSONData;
  TextDelta: string;
begin
  if (Trim(APayload) = '') or (Trim(APayload) = '[DONE]') then
    Exit(TCEAResult.Ok('{}'));
  Data := nil;
  try
    try
      Data := GetJSON(APayload);
    except
      Exit(TCEAResult.Error(rcUnknown, 'model_stream_event_invalid', '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcUnknown, 'model_stream_event_invalid', '{}'));
    TextDelta := '';
    if FFormat = sfOpenAI then
    begin
      Item := TJSONObject(Data).Find('choices');
      if (Item <> nil) and (Item.JSONType = jtArray) and
         (TJSONArray(Item).Count > 0) and
         (TJSONArray(Item).Items[0].JSONType = jtObject) then
      begin
        Delta := TJSONObject(TJSONArray(Item).Items[0]).Find('delta');
        if (Delta <> nil) and (Delta.JSONType = jtObject) then
          TextDelta := TJSONObject(Delta).Get('content', '');
      end;
      Usage := TJSONObject(Data).Find('usage');
      if (Usage <> nil) and (Usage.JSONType = jtObject) then
      begin
        FPromptTokens := TJSONObject(Usage).Get('prompt_tokens', FPromptTokens);
        FCompletionTokens := TJSONObject(Usage).Get('completion_tokens',
          FCompletionTokens);
      end;
    end
    else
    begin
      if TJSONObject(Data).Get('type', '') = 'content_block_delta' then
      begin
        Delta := TJSONObject(Data).Find('delta');
        if (Delta <> nil) and (Delta.JSONType = jtObject) then
          TextDelta := TJSONObject(Delta).Get('text', '');
      end;
      Item := TJSONObject(Data).Find('message');
      if (Item <> nil) and (Item.JSONType = jtObject) then
      begin
        Usage := TJSONObject(Item).Find('usage');
        if (Usage <> nil) and (Usage.JSONType = jtObject) then
          FPromptTokens := TJSONObject(Usage).Get('input_tokens', FPromptTokens);
      end;
      Usage := TJSONObject(Data).Find('usage');
      if (Usage <> nil) and (Usage.JSONType = jtObject) then
      begin
        FPromptTokens := TJSONObject(Usage).Get('input_tokens', FPromptTokens);
        FCompletionTokens := TJSONObject(Usage).Get('output_tokens',
          FCompletionTokens);
      end;
    end;
    if TextDelta <> '' then
    begin
      FContent := FContent + TextDelta;
      if FSink <> nil then FSink.OnTextDelta(TextDelta);
    end;
    Result := TCEAResult.Ok('{}');
  finally
    Data.Free;
  end;
end;

function TCEASSECollector.ProcessLine(const ALine: string): TCEAResult;
var
  Line: string;
begin
  Line := ALine;
  if (Line <> '') and (Line[Length(Line)] = #13) then
    Delete(Line, Length(Line), 1);
  if Line = '' then
  begin
    Result := ProcessEvent(FEventData);
    FEventData := '';
    Exit;
  end;
  if Pos('data:', Line) = 1 then
  begin
    Line := Copy(Line, 6, MaxInt);
    if (Line <> '') and (Line[1] = ' ') then Delete(Line, 1, 1);
    if FEventData <> '' then FEventData := FEventData + #10;
    FEventData := FEventData + Line;
  end;
  Result := TCEAResult.Ok('{}');
end;

function TCEASSECollector.OnResponseChunk(const AChunk: string): TCEAResult;
var
  LineEnd: SizeInt;
  Line: string;
begin
  if FHasFailure then Exit(FFailure);
  FBuffer := FBuffer + AChunk;
  repeat
    LineEnd := Pos(#10, FBuffer);
    if LineEnd = 0 then Break;
    Line := Copy(FBuffer, 1, LineEnd - 1);
    Delete(FBuffer, 1, LineEnd);
    Result := ProcessLine(Line);
    if Result.Failed then
    begin
      FFailure := Result;
      FHasFailure := True;
      Exit;
    end;
  until False;
  Result := TCEAResult.Ok('{}');
end;

function TCEASSECollector.FinalResult(const AProviderId, AModelId: string;
  const AMaxTotalTokens: Cardinal): TCEAResult;
var
  Output, Usage: TJSONObject;
  TotalTokens: Int64;
begin
  if FHasFailure then Exit(FFailure);
  if FBuffer <> '' then
  begin
    Result := ProcessLine(FBuffer);
    FBuffer := '';
    if Result.Failed then Exit;
  end;
  if FEventData <> '' then
  begin
    Result := ProcessEvent(FEventData);
    FEventData := '';
    if Result.Failed then Exit;
  end;
  TotalTokens := FPromptTokens + FCompletionTokens;
  if (AMaxTotalTokens > 0) and (TotalTokens > AMaxTotalTokens) then
    Exit(TCEAResult.Error(rcBudgetExceeded,
      'model_total_token_budget_exceeded', '{}'));
  Output := TJSONObject.Create;
  try
    Output.Add('provider_id', AProviderId);
    Output.Add('model_id', AModelId);
    Output.Add('content', FContent);
    Output.Add('authority', 'proposal_only');
    Usage := TJSONObject.Create;
    Usage.Add('prompt_tokens', FPromptTokens);
    Usage.Add('completion_tokens', FCompletionTokens);
    Usage.Add('total_tokens', TotalTokens);
    Output.Add('usage', Usage);
    Result := TCEAResult.Ok(Output.AsJSON);
  finally
    Output.Free;
  end;
end;

end.
