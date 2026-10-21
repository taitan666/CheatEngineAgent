unit cea_ui_customization_service;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage utf8}

interface

uses
  SysUtils, cea_results, cea_llm_provider, cea_field_model, cea_game_state_model,
  cea_ui_schema_types, cea_ui_schema_codec, cea_gcm_types;

type
  // Lifecycle of a model-authored page proposal (FR-025).
  TCEAUiProposalState = (
    upsProposed,   // authored by the model, waiting for the operator
    upsConfirmed,  // operator accepted it; it may now be stored
    upsRejected    // operator refused it; it must never be stored
  );

  TCEAUiSchemaProposal = record
    ProposalId: string;
    // Verbatim operator instruction, kept so the UI can show what was asked.
    Instruction: UnicodeString;
    Schema: TCEAUiSchema;
    // Canonical JSON of Schema, produced by the codec (not by the model).
    SchemaJson: string;
    // Components the model bound to an unknown field and that were dropped.
    DroppedComponents: Integer;
    // Components the model marked editable on a field that is not verified
    // writable; they were forced back to read-only.
    DowngradedComponents: Integer;
    State: TCEAUiProposalState;
    CreatedAt: string;
    function IsValid: Boolean;
  end;

  // Turns a natural-language request into a page proposal.
  //
  // Safety limits, all enforced locally rather than trusted from the model:
  //  - Only field metadata (id, display name, value type) is sent. Memory
  //    values, addresses and process names never leave the machine.
  //  - The model answer is parsed through TCEAUiSchemaCodec, so any component
  //    kind outside the whitelist is rejected outright.
  //  - A component bound to a field that does not exist is dropped, not
  //    rendered as a placeholder (PRD 7.6 forbids fabricating fields).
  //  - A component claiming uaEditable on a field that is not
  //    faVerifiedWritable is downgraded to uaReadOnly (FR-022 / AC-005).
  //  - The proposal is only a proposal: storing it requires Confirm.
  TCEAUiCustomizationService = class(TObject)
  private
    FProvider: TCEALLMChatProvider;
    FCodec: TCEAUiSchemaCodec;
    FMaxOutputTokens: Cardinal;
    FTemperature: Double;
    FSequence: Integer;
    function BuildPrompt(const AModel: TCEAGameStateModel;
      const AInstruction: string): string;
    function ExtractProviderContent(const AEnvelopeJson: string;
      out AContent: UnicodeString): TCEAResult;
    function Sanitize(const ASchema: TCEAUiSchema;
      const AModel: TCEAGameStateModel; out AClean: TCEAUiSchema;
      out ADropped, ADowngraded: Integer): TCEAResult;
  public
    constructor Create(const AProvider: TCEALLMChatProvider;
      const AMaxOutputTokens: Cardinal = 2048);
    function ProposeFromInstruction(const AModel: TCEAGameStateModel;
      const AInstruction, ACreatedAt: string;
      out AProposal: TCEAUiSchemaProposal): TCEAResult;
    function Confirm(const AProposal: TCEAUiSchemaProposal;
      out AConfirmed: TCEAUiSchemaProposal): TCEAResult;
    function Reject(const AProposal: TCEAUiSchemaProposal;
      out ARejected: TCEAUiSchemaProposal): TCEAResult;
    property Provider: TCEALLMChatProvider read FProvider write FProvider;
  end;

function UiProposalStateText(const AState: TCEAUiProposalState): string;
function TryParseUiProposalState(const AText: string;
  out AState: TCEAUiProposalState): Boolean;

implementation

uses
  Classes, fpjson, jsonparser;

const
  // Hard ceiling on the field inventory handed to the model, so a large save
  // cannot turn one request into an unbounded prompt.
  CeaMaxInventoryFields = 200;

function UiProposalStateText(const AState: TCEAUiProposalState): string;
begin
  case AState of
    upsProposed: Result := 'proposed';
    upsConfirmed: Result := 'confirmed';
    upsRejected: Result := 'rejected';
  end;
end;

function TryParseUiProposalState(const AText: string;
  out AState: TCEAUiProposalState): Boolean;
var
  S: TCEAUiProposalState;
begin
  for S := Low(TCEAUiProposalState) to High(TCEAUiProposalState) do
    if UiProposalStateText(S) = AText then
    begin
      AState := S;
      Exit(True);
    end;
  Result := False;
end;

function TCEAUiSchemaProposal.IsValid: Boolean;
begin
  Result := (ProposalId <> '') and Schema.IsValid;
end;

function CountComponents(const ASchema: TCEAUiSchema): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(ASchema.Sections) do
    Inc(Result, Length(ASchema.Sections[I].Components));
end;

constructor TCEAUiCustomizationService.Create(
  const AProvider: TCEALLMChatProvider; const AMaxOutputTokens: Cardinal);
begin
  inherited Create;
  FProvider := AProvider;
  FCodec := TCEAUiSchemaCodec.Create;
  if AMaxOutputTokens > 0 then FMaxOutputTokens := AMaxOutputTokens
  else FMaxOutputTokens := 2048;
  FTemperature := 0.2;
  FSequence := 0;
end;

function TCEAUiCustomizationService.BuildPrompt(
  const AModel: TCEAGameStateModel; const AInstruction: string): string;
var
  Fields: TCEAGameFieldArray;
  I, Sent: Integer;
  Inventory: UTF8String;
  // Must stay UTF8String: concatenating UTF-8 fragments into a plain `string`
  // makes the compiler transcode them to the local codepage (GBK here) and the
  // instruction reaches the model as mojibake.
  Raw: UTF8String;
begin
  Fields := AModel.GetFields;
  Inventory := '';
  Sent := 0;
  for I := 0 to High(Fields) do
  begin
    if Sent >= CeaMaxInventoryFields then Break;
    if not Fields[I].IsValid then Continue;
    if Sent > 0 then Inventory := Inventory + ',';
    // Only identity and shape are sent: never the current value or address.
    Inventory := Inventory + '{"field_id":"' +
      UTF8String(Fields[I].FieldId) + '","name":"' +
      JsonEscapeUnicode(UnicodeString(UTF8Decode(Fields[I].DisplayName))) +
      '","type":"' + UTF8String(Fields[I].ValueType) +
      '","writable":' + BoolToStr(Fields[I].Access = faVerifiedWritable, True) +
      '}';
    Inc(Sent);
  end;
  Raw := '{"task":"design_secondary_screen_page",' +
    '"rules":["use only the listed component kinds: text, value_card, ' +
    'progress_bar, toggle, slider, dropdown, item_grid, table, search_box, ' +
    'status_notice","every component except text must bind a listed field_id",' +
    '"never invent a field that is not listed",' +
    '"a component may be editable only when its field has writable=true"],' +
    '"output":{"id":"string","page_title":"string","sections":[{"id":"string",' +
    '"title":"string","components":[{"id":"string","kind":"string",' +
    '"title":"string","field_id":"string","access":"read_only|editable",' +
    '"options_json":"string"}]}]},' +
    '"instruction":"' +
    JsonEscapeUnicode(UnicodeString(UTF8Decode(AInstruction))) + '",' +
    '"fields":[' + Inventory + ']}';
  // Keep the UTF-8 bytes while retagging the string, otherwise the provider
  // receives GBK-interpreted text and the model sees mojibake.
  Result := Utf8JsonText(Raw);
end;

function TCEAUiCustomizationService.ExtractProviderContent(
  const AEnvelopeJson: string; out AContent: UnicodeString): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
begin
  AContent := '';
  Data := nil;
  try
    try
      Data := GetJSON(AEnvelopeJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_proposal_envelope_invalid',
        '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_proposal_envelope_invalid',
        '{}'));
    Obj := TJSONObject(Data);
    // UnicodeString overload: a string overload would tag the UTF-8 bytes as
    // the local codepage and break the second parse.
    AContent := Obj.Get('content', UnicodeString(''));
    if Trim(string(AContent)) = '' then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_proposal_content_empty',
        '{}'));
    Result := TCEAResult.Ok('{}');
  finally
    Data.Free;
  end;
end;

function TCEAUiCustomizationService.Sanitize(const ASchema: TCEAUiSchema;
  const AModel: TCEAGameStateModel; out AClean: TCEAUiSchema;
  out ADropped, ADowngraded: Integer): TCEAResult;
var
  I, J, K, Sections: Integer;
  Field: TCEAGameField;
  Keep: TCEAUiComponent;
begin
  FillChar(AClean, SizeOf(AClean), 0);
  ADropped := 0;
  ADowngraded := 0;
  AClean.Id := ASchema.Id;
  AClean.PageTitle := ASchema.PageTitle;
  SetLength(AClean.Sections, 0);
  for I := 0 to High(ASchema.Sections) do
  begin
    SetLength(AClean.Sections, Length(AClean.Sections) + 1);
    Sections := High(AClean.Sections);
    AClean.Sections[Sections].Id := ASchema.Sections[I].Id;
    AClean.Sections[Sections].Title := ASchema.Sections[I].Title;
    SetLength(AClean.Sections[Sections].Components, 0);
    for J := 0 to High(ASchema.Sections[I].Components) do
    begin
      Keep := ASchema.Sections[I].Components[J];
      if Keep.Kind <> ucText then
      begin
        if not AModel.GetField(Keep.FieldId, Field) then
        begin
          // A field the model invented must not reach the screen.
          Inc(ADropped);
          Continue;
        end;
        if Keep.Access = uaEditable then
          if Field.Access <> faVerifiedWritable then
          begin
            Keep.Access := uaReadOnly;
            Inc(ADowngraded);
          end;
      end;
      K := Length(AClean.Sections[Sections].Components);
      SetLength(AClean.Sections[Sections].Components, K + 1);
      AClean.Sections[Sections].Components[K] := Keep;
    end;
    // A section whose components were all dropped would render as an empty
    // frame; remove it instead of shipping a hollow section.
    if Length(AClean.Sections[Sections].Components) = 0 then
      SetLength(AClean.Sections, Length(AClean.Sections) - 1);
  end;
  if Length(AClean.Sections) = 0 then
    Exit(TCEAResult.Error(rcVerificationFailed, 'ui_proposal_no_usable_component',
      '{"dropped":' + IntToStr(ADropped) + '}'));
  if not AClean.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_proposal_invalid', '{}'));
  Result := TCEAResult.Ok('{}');
end;

function TCEAUiCustomizationService.ProposeFromInstruction(
  const AModel: TCEAGameStateModel; const AInstruction, ACreatedAt: string;
  out AProposal: TCEAUiSchemaProposal): TCEAResult;
var
  Request: TCEALLMChatRequest;
  Response: TCEAResult;
  Content: UnicodeString;
  Schema: TCEAUiSchema;
  Clean: TCEAUiSchema;
  Dropped, Downgraded: Integer;
  Json: string;
  Fields: TCEAGameFieldArray;
begin
  FillChar(AProposal, SizeOf(AProposal), 0);
  if FProvider = nil then
    Exit(TCEAResult.Error(rcNotImplemented, 'llm_not_configured', '{}'));
  if AModel = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_required', '{}'));
  if Trim(AInstruction) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_instruction_required', '{}'));
  Fields := AModel.GetFields;
  if Length(Fields) = 0 then
    Exit(TCEAResult.Error(rcConflict, 'model_empty', '{}'));

  FillChar(Request, SizeOf(Request), 0);
  Request.UserPrompt := BuildPrompt(AModel, AInstruction);
  Request.MaxOutputTokens := FMaxOutputTokens;
  Request.Temperature := FTemperature;
  Request.ResponseFormat := 'json_object';
  Response := FProvider.Chat(Request);
  if Response.Failed then Exit(Response);

  Response := ExtractProviderContent(Response.DataJson, Content);
  // A bare `Exit` would drop the error code: always pass the failed result on.
  if Response.Failed then Exit(Response);

  // The model answer goes through the same whitelist codec as any stored
  // schema, so an unknown component kind cannot slip in.
  Response := FCodec.Decode(Utf8JsonText(UTF8Encode(Content)), Schema);
  if Response.Failed then Exit(Response);

  Response := Sanitize(Schema, AModel, Clean, Dropped, Downgraded);
  if Response.Failed then Exit(Response);

  Response := FCodec.Encode(Clean, Json);
  if Response.Failed then Exit(Response);

  Inc(FSequence);
  AProposal.ProposalId := 'uip-' + IntToStr(FSequence);
  AProposal.Instruction := UnicodeString(UTF8Decode(AInstruction));
  AProposal.Schema := Clean;
  AProposal.SchemaJson := Json;
  AProposal.DroppedComponents := Dropped;
  AProposal.DowngradedComponents := Downgraded;
  AProposal.State := upsProposed;
  AProposal.CreatedAt := ACreatedAt;
  Result := TCEAResult.Ok('{"proposal_id":"' + AProposal.ProposalId +
    '","state":"proposed","dropped":' + IntToStr(Dropped) +
    ',"downgraded":' + IntToStr(Downgraded) +
    ',"component_count":' + IntToStr(CountComponents(Clean)) + '}');
end;

function TCEAUiCustomizationService.Confirm(
  const AProposal: TCEAUiSchemaProposal;
  out AConfirmed: TCEAUiSchemaProposal): TCEAResult;
begin
  AConfirmed := AProposal;
  if not AProposal.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_proposal_invalid', '{}'));
  if AProposal.State = upsRejected then
    Exit(TCEAResult.Error(rcConflict, 'ui_proposal_already_rejected', '{}'));
  if AProposal.State = upsConfirmed then
    Exit(TCEAResult.Ok('{"proposal_id":"' + AProposal.ProposalId +
      '","state":"confirmed"}'));
  AConfirmed.State := upsConfirmed;
  Result := TCEAResult.Ok('{"proposal_id":"' + AProposal.ProposalId +
    '","state":"confirmed"}');
end;

function TCEAUiCustomizationService.Reject(
  const AProposal: TCEAUiSchemaProposal;
  out ARejected: TCEAUiSchemaProposal): TCEAResult;
begin
  ARejected := AProposal;
  if not AProposal.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_proposal_invalid', '{}'));
  ARejected.State := upsRejected;
  Result := TCEAResult.Ok('{"proposal_id":"' + AProposal.ProposalId +
    '","state":"rejected"}');
end;

end.
