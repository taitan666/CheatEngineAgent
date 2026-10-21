program test_ui_customization_service;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, FPJSON, JSONParser, cea_results, cea_llm_provider,
  cea_field_model, cea_game_state_model, cea_ui_schema_types, cea_gcm_types,
  cea_ui_customization_service;

type
  // Records every prompt and replays a scripted model answer, so the test can
  // assert both what was sent to the model and what survived sanitising.
  TFakeProvider = class(TCEALLMChatProvider)
  public
    Prompts: TStringList;
    Answers: TStringList;
    CallIndex: Integer;
    FailNext: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Chat(const ARequest: TCEALLMChatRequest): TCEAResult; override;
  end;

var
  Failures: Integer = 0;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL ', AMessage);
  end;
end;

constructor TFakeProvider.Create;
begin
  inherited Create;
  Prompts := TStringList.Create;
  Answers := TStringList.Create;
  CallIndex := 0;
end;

destructor TFakeProvider.Destroy;
begin
  Prompts.Free;
  Answers.Free;
  inherited Destroy;
end;

function TFakeProvider.Chat(const ARequest: TCEALLMChatRequest): TCEAResult;
var
  Answer, Envelope: string;
  Obj: TJSONObject;
begin
  Prompts.Add(ARequest.UserPrompt);
  if FailNext then
    Exit(TCEAResult.Error(rcTimeout, 'provider_timeout', '{}'));
  if CallIndex >= Answers.Count then
    Exit(TCEAResult.Error(rcInternalError, 'no_scripted_answer', '{}'));
  Answer := Answers[CallIndex];
  Inc(CallIndex);
  Obj := TJSONObject.Create;
  try
    Obj.Add('provider_id', 'fake');
    Obj.Add('content', Answer);
    Envelope := Obj.AsJSON;
  finally
    Obj.Free;
  end;
  Result := TCEAResult.Ok(Utf8JsonText(UTF8String(Envelope)));
end;

// Builds a schema answer with one component per entry of AComponents, where
// each entry is "componentId|kind|fieldId|access".
function SchemaAnswer(const AComponents: array of string): string;
var
  Root, PageObj, SectionObj, CompObj: TJSONObject;
  Sections, Comps: TJSONArray;
  Parts: TStringArray;
  I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('id', 'ui-custom');
    Root.Add('page_title', 'Custom');
    Sections := TJSONArray.Create;
    Root.Add('sections', Sections);
    SectionObj := TJSONObject.Create;
    Sections.Add(SectionObj);
    SectionObj.Add('id', 'sec-main');
    SectionObj.Add('title', 'Main');
    Comps := TJSONArray.Create;
    SectionObj.Add('components', Comps);
    for I := 0 to High(AComponents) do
    begin
      Parts := AComponents[I].Split('|');
      CompObj := TJSONObject.Create;
      Comps.Add(CompObj);
      CompObj.Add('id', Parts[0]);
      CompObj.Add('kind', Parts[1]);
      CompObj.Add('title', Parts[0]);
      CompObj.Add('field_id', Parts[2]);
      CompObj.Add('access', Parts[3]);
      CompObj.Add('options_json', '');
    end;
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

var
  Model: TCEAGameStateModel;
  Provider: TFakeProvider;
  Service: TCEAUiCustomizationService;
  Proposal, Confirmed, Rejected: TCEAUiSchemaProposal;
  R: TCEAResult;
  Prompt: string;
  ComponentCount: Integer;
  I: Integer;

  procedure AddField(const AId, AName, ATypeName: string;
    const AAccess: TCEAFieldAccess);
  var
    F: TCEAGameField;
  begin
    FillChar(F, SizeOf(F), 0);
    F.FieldId := AId;
    F.DisplayName := AName;
    F.ValueType := ATypeName;
    F.ValueJson := '123';
    F.Source := 'win32_memory';
    F.Confidence := 1.0;
    F.Access := AAccess;
    F.ValidationStatus := vsObserved;
    F.LastUpdated := '2026-10-20T12:00:00Z';
    // The address must never appear in the prompt; the test greps for it.
    F.AddressHex := '7FF612345678';
    Assert(Model.AddField(F), 'add field ' + AId);
  end;

begin
  Model := TCEAGameStateModel.Create('StardewValley', '1.6',
    'sha256:' + StringOfChar('a', 64), 'sha256:' + StringOfChar('b', 64));
  Provider := TFakeProvider.Create;
  Service := TCEAUiCustomizationService.Create(Provider);
  try
    AddField('player.gold', 'Gold', 'dword', faVerifiedWritable);
    AddField('player.stamina', 'Stamina', 'single', faReadOnly);

    // 1. A plain text component plus a verified-writable value card survives.
    Provider.Answers.Add(SchemaAnswer([
      'comp-gold|value_card|player.gold|editable',
      'comp-note|text||read_only']));
    R := Service.ProposeFromInstruction(Model, '把金币放到最上面',
      '2026-10-20T12:10:00Z', Proposal);
    Check(not R.Failed, 'proposal succeeds');
    Check(Proposal.State = upsProposed, 'proposal starts as proposed');
    Check(Proposal.ProposalId = 'uip-1', 'proposal gets a stable id');
    Check(Proposal.Schema.IsValid, 'proposal carries a valid schema');
    Check(Proposal.DroppedComponents = 0, 'nothing is dropped');
    Check(Proposal.DowngradedComponents = 0, 'nothing is downgraded');

    // The prompt carries field metadata but never memory addresses or values.
    Prompt := Provider.Prompts[0];
    Check(Pos('player.gold', Prompt) > 0, 'prompt lists the field id');
    Check(Pos('7FF612345678', Prompt) = 0, 'prompt never carries an address');
    Check(Pos('"value"', Prompt) = 0, 'prompt never carries a memory value');
    Check(Pos('把金币放到最上面', Prompt) > 0, 'prompt carries the instruction');

    // 2. A component bound to an invented field is dropped, not rendered.
    Provider.Answers.Add(SchemaAnswer([
      'comp-ghost|value_card|player.ghost|read_only',
      'comp-gold|value_card|player.gold|editable']));
    R := Service.ProposeFromInstruction(Model, '加一个不存在的字段',
      '2026-10-20T12:11:00Z', Proposal);
    Check(not R.Failed, 'proposal with a ghost field still succeeds');
    Check(Proposal.DroppedComponents = 1, 'the invented field is dropped');
    ComponentCount := 0;
    for I := 0 to High(Proposal.Schema.Sections) do
      Inc(ComponentCount, Length(Proposal.Schema.Sections[I].Components));
    Check(ComponentCount = 1, 'only the real field survives');
    Check(Pos('player.ghost', Proposal.SchemaJson) = 0,
      'the invented field is gone from the stored JSON');

    // 3. Claiming editable on a read-only field is downgraded, not trusted.
    Provider.Answers.Add(SchemaAnswer([
      'comp-stamina|slider|player.stamina|editable']));
    R := Service.ProposeFromInstruction(Model, '把体力做成滑块',
      '2026-10-20T12:12:00Z', Proposal);
    Check(not R.Failed, 'proposal succeeds for a read-only field');
    Check(Proposal.DowngradedComponents = 1, 'editable claim is downgraded');
    Check(Proposal.Schema.Sections[0].Components[0].Access = uaReadOnly,
      'read-only field stays read-only');

    // 4. An unknown component kind is rejected by the whitelist codec.
    Provider.Answers.Add(SchemaAnswer([
      'comp-gold|live_chart|player.gold|read_only']));
    R := Service.ProposeFromInstruction(Model, '加一个图表',
      '2026-10-20T12:13:00Z', Proposal);
    Check(R.Failed, 'unknown component kind is rejected');
    Check(R.StableCode = 'ui_component_kind_not_whitelisted',
      'rejection names the whitelist');

    // 5. A schema whose components were all dropped fails closed.
    Provider.Answers.Add(SchemaAnswer([
      'comp-ghost|value_card|player.ghost|read_only']));
    R := Service.ProposeFromInstruction(Model, '只加一个不存在的字段',
      '2026-10-20T12:14:00Z', Proposal);
    Check(R.Failed, 'an all-dropped proposal fails');
    Check(R.StableCode = 'ui_proposal_no_usable_component',
      'empty result reports no usable component');

    // 6. Provider failure propagates unchanged.
    Provider.FailNext := True;
    R := Service.ProposeFromInstruction(Model, '任意要求',
      '2026-10-20T12:15:00Z', Proposal);
    Check(R.Failed, 'provider failure propagates');
    Check(R.StableCode = 'provider_timeout', 'provider code is preserved');
    Provider.FailNext := False;

    // 7. Empty instruction is refused before any provider call.
    I := Provider.Prompts.Count;
    R := Service.ProposeFromInstruction(Model, '   ',
      '2026-10-20T12:16:00Z', Proposal);
    Check(R.Failed, 'empty instruction is refused');
    Check(R.StableCode = 'ui_instruction_required',
      'empty instruction reports the reason');
    Check(Provider.Prompts.Count = I, 'no provider call for an empty request');

    // 8. Confirm / Reject drive the proposal state machine.
    Provider.Answers.Add(SchemaAnswer([
      'comp-gold|value_card|player.gold|editable']));
    R := Service.ProposeFromInstruction(Model, '金币置顶',
      '2026-10-20T12:17:00Z', Proposal);
    Check(not R.Failed, 'proposal for confirmation succeeds');
    R := Service.Confirm(Proposal, Confirmed);
    Check(not R.Failed, 'confirm succeeds');
    Check(Confirmed.State = upsConfirmed, 'confirmed state is set');
    Check(Proposal.State = upsProposed, 'confirm does not mutate the input');
    R := Service.Reject(Confirmed, Rejected);
    Check(not R.Failed, 'reject succeeds after confirm');
    Check(Rejected.State = upsRejected, 'rejected state is set');
    R := Service.Confirm(Rejected, Confirmed);
    Check(R.Failed, 'a rejected proposal cannot be confirmed');
    Check(R.StableCode = 'ui_proposal_already_rejected',
      'rejection is final');

    // 9. Without a provider the service refuses instead of inventing a schema.
    Service.Free;
    Service := TCEAUiCustomizationService.Create(nil);
    R := Service.ProposeFromInstruction(Model, '任意要求',
      '2026-10-20T12:18:00Z', Proposal);
    Check(R.Failed, 'missing provider fails');
    Check(R.StableCode = 'llm_not_configured', 'missing provider is reported');
  finally
    Service.Free;
    Provider.Free;
    Model.Free;
  end;

  if Failures > 0 then
  begin
    WriteLn('UI_CUSTOMIZATION_SERVICE=FAIL failures=', Failures);
    Halt(1);
  end;
  WriteLn('UI_CUSTOMIZATION_SERVICE=PASS');
end.
