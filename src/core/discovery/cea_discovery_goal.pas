unit cea_discovery_goal;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

interface

uses
  SysUtils, fpjson, jsonparser, cea_results, cea_llm_provider;

type
  { FR-050 (PRD 6.6) goal description: the operator states in their own words
    which field they want to find.

    This unit deliberately does NOT pretend to understand Chinese prose. There
    is no keyword table mapping "gold" or "health" to a value type, because a
    keyword table is not understanding: it silently guesses, and a wrong guess
    here becomes the "expected observation" that FR-051 rounds are measured
    against. So the goal carries three things that are honestly distinct:

      1. Description - the operator's words, verbatim. Never rewritten.
      2. Hints       - value type / behaviour / field id, either declared by the
                       operator or proposed by a model. Hints are advisory.
      3. State       - proposed / accepted / rejected / superseded.

    Safety boundary: a goal is intent, not evidence. Accepting a goal means
    "this is what I am looking for", NOT "this address is correct" and NOT
    "this field is safe to write". It authorises nothing: scans still go
    through FR-051 rounds plus the governance lease, and writes still require
    faVerifiedWritable plus FR-043 confirmation.

    Session-only, like FR-051 rounds: a goal without the evidence gathered for
    it is a dangling intention, and persisting it would let a later session
    mistake an old wish for an outstanding obligation. }
  TCEADiscoveryGoalSource = (
    dgsOperator,  // declared by the operator, no model involved
    dgsModel      // proposed by a model from the operator's description
  );

  TCEADiscoveryGoalState = (
    dgoProposed,    // declared, waiting for the operator to accept or reject
    dgoAccepted,    // the operator is now pursuing this goal
    dgoRejected,    // the operator declined it
    dgoSuperseded   // accepted once, then replaced by a newer accepted goal
  );

  TCEADiscoveryGoal = record
    GoalId: string;           // stable id "goal-XXXXXXXX"
    Sequence: Cardinal;       // session-monotonic
    Description: string;      // operator's words, stored verbatim
    FieldIdHint: string;      // optional; empty means "not named yet"
    ValueTypeHint: string;    // one of the supported value types, or empty
    BehaviorHint: string;     // increase / decrease / constant / unknown
    Rationale: string;        // why a model proposed these hints; empty if operator
    Source: TCEADiscoveryGoalSource;
    State: TCEADiscoveryGoalState;
    // True for every model-sourced goal, including after acceptance: accepting
    // says "I am pursuing this", not "the model was right".
    Advisory: Boolean;
    CreatedAt: string;        // UTC ISO8601
    DecidedAt: string;
    RejectReason: string;
    function IsValid: Boolean;
  end;

  TCEADiscoveryGoalArray = array of TCEADiscoveryGoal;

  TCEADiscoveryGoalService = class(TObject)
  private
    FGoals: array of TCEADiscoveryGoal;
    FSequence: Cardinal;
    function IndexOf(const AGoalId: string): Integer;
    function BuildGoal(const ADescription, AFieldIdHint, AValueTypeHint,
      ABehaviorHint, ARationale, ACreatedAt: string;
      const ASource: TCEADiscoveryGoalSource): TCEADiscoveryGoal;
    procedure SupersedeAccepted(const AExceptGoalId, ADecidedAt: string);
  public
    // Operator's own words. Hints are optional and are whatever the operator
    // typed; nothing is inferred.
    function ProposeFromOperator(const ADescription, AFieldIdHint,
      AValueTypeHint, ABehaviorHint, ACreatedAt: string;
      out AGoal: TCEADiscoveryGoal): TCEAResult;
    // Model interprets the description into hints. The hints are sanitised
    // here, never trusted, and the resulting goal is always advisory.
    function ProposeFromModel(const AProvider: TCEALLMChatProvider;
      const ADescription: string; const AMaxOutputTokens: Cardinal;
      const ACreatedAt: string; out AGoal: TCEADiscoveryGoal): TCEAResult;
    // The operator takes ownership of a goal. Only one goal can be accepted at
    // a time; accepting a new one supersedes the previous accepted goal.
    function Accept(const AGoalId, ADecidedAt: string;
      out AGoal: TCEADiscoveryGoal): TCEAResult;
    function Reject(const AGoalId, AReason, ADecidedAt: string;
      out AGoal: TCEADiscoveryGoal): TCEAResult;
    function CurrentGoal(out AGoal: TCEADiscoveryGoal): Boolean;
    function GetGoal(const AGoalId: string;
      out AGoal: TCEADiscoveryGoal): TCEAResult;
    function ListGoals(const ALimit: Cardinal;
      out AGoals: TCEADiscoveryGoalArray): TCEAResult;
    function Count: Cardinal;
    procedure Reset;
  end;

function DiscoveryGoalSourceText(const ASource: TCEADiscoveryGoalSource): string;
function TryParseDiscoveryGoalSource(const AText: string;
  out ASource: TCEADiscoveryGoalSource): Boolean;
function DiscoveryGoalStateText(const AState: TCEADiscoveryGoalState): string;
function TryParseDiscoveryGoalState(const AText: string;
  out AState: TCEADiscoveryGoalState): Boolean;

// Value types the scan and write layers actually understand. A hint outside
// this set is dropped rather than carried downstream as a fake promise.
function IsSupportedGoalValueType(const AText: string): Boolean;
// Behaviour the operator can claim to have observed. 'unknown' is the honest
// default: most of the time the operator knows the name, not the dynamics.
function IsSupportedGoalBehavior(const AText: string): Boolean;
// Field ids are dotted lower-case identifiers; anything else is dropped so a
// model cannot smuggle punctuation or whitespace into a field id.
function IsWellFormedGoalFieldId(const AText: string): Boolean;

// Pure sanitiser for model output, testable without a provider. Returns
// rcInvalidArgument/discovery_goal_hints_invalid when the payload is not an
// object; unsupported values are dropped to empty rather than rejected, because
// one bad hint should not discard a usable description.
function SanitizeGoalHints(const AHintsJson: string; out AFieldIdHint,
  AValueTypeHint, ABehaviorHint, ARationale: string): TCEAResult;

// JSON has no True/False literals: BoolToStr emits Pascal casing.
function JsonBool(const AValue: Boolean): string;
// Byte-preserving escape, so UTF-8 survives whatever the codepage tag says.
function JsonEscapeText(const AValue: string): string;

const
  CeaDiscoveryGoalDescriptionMaxChars = 800;
  CeaDiscoveryGoalHintMaxChars = 128;
  CeaDiscoveryGoalRationaleMaxChars = 800;
  CeaDiscoveryGoalRejectReasonMaxChars = 400;
  CeaDiscoveryGoalDefaultLimit = 50;
  CeaDiscoveryGoalMaxLimit = 500;

implementation

const
  SupportedValueTypes: array[0..9] of string = (
    'byte', 'word', 'dword', 'qword', 'integer',
    'single', 'double', 'bool', 'enum', 'string');

  SupportedBehaviors: array[0..3] of string = (
    'increase', 'decrease', 'constant', 'unknown');

function DiscoveryGoalSourceText(const ASource: TCEADiscoveryGoalSource): string;
begin
  case ASource of
    dgsOperator: Result := 'operator';
    dgsModel: Result := 'model';
  else
    Result := 'operator';
  end;
end;

function TryParseDiscoveryGoalSource(const AText: string;
  out ASource: TCEADiscoveryGoalSource): Boolean;
var
  I: Integer;
  Text: string;
begin
  Result := False;
  ASource := dgsOperator;
  Text := LowerCase(Trim(AText));
  for I := Ord(Low(TCEADiscoveryGoalSource)) to Ord(High(TCEADiscoveryGoalSource)) do
    if DiscoveryGoalSourceText(TCEADiscoveryGoalSource(I)) = Text then
    begin
      ASource := TCEADiscoveryGoalSource(I);
      Exit(True);
    end;
end;

function DiscoveryGoalStateText(const AState: TCEADiscoveryGoalState): string;
begin
  case AState of
    dgoProposed: Result := 'proposed';
    dgoAccepted: Result := 'accepted';
    dgoRejected: Result := 'rejected';
    dgoSuperseded: Result := 'superseded';
  else
    Result := 'proposed';
  end;
end;

function TryParseDiscoveryGoalState(const AText: string;
  out AState: TCEADiscoveryGoalState): Boolean;
var
  I: Integer;
  Text: string;
begin
  Result := False;
  AState := dgoProposed;
  Text := LowerCase(Trim(AText));
  for I := Ord(Low(TCEADiscoveryGoalState)) to Ord(High(TCEADiscoveryGoalState)) do
    if DiscoveryGoalStateText(TCEADiscoveryGoalState(I)) = Text then
    begin
      AState := TCEADiscoveryGoalState(I);
      Exit(True);
    end;
end;

function IsSupportedGoalValueType(const AText: string): Boolean;
var
  I: Integer;
  Text: string;
begin
  Result := False;
  Text := LowerCase(Trim(AText));
  if Text = '' then Exit;
  for I := Low(SupportedValueTypes) to High(SupportedValueTypes) do
    if SupportedValueTypes[I] = Text then
      Exit(True);
end;

function IsSupportedGoalBehavior(const AText: string): Boolean;
var
  I: Integer;
  Text: string;
begin
  Result := False;
  Text := LowerCase(Trim(AText));
  if Text = '' then Exit;
  for I := Low(SupportedBehaviors) to High(SupportedBehaviors) do
    if SupportedBehaviors[I] = Text then
      Exit(True);
end;

function IsWellFormedGoalFieldId(const AText: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := False;
  if AText = '' then Exit;
  if Length(AText) > CeaDiscoveryGoalHintMaxChars then Exit;
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    if (C >= 'a') and (C <= 'z') then Continue;
    if (C >= '0') and (C <= '9') then Continue;
    if C = '.' then Continue;
    if C = '_' then Continue;
    Exit(False);
  end;
  Result := True;
end;

function SanitizeGoalHints(const AHintsJson: string; out AFieldIdHint,
  AValueTypeHint, ABehaviorHint, ARationale: string): TCEAResult;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Text: string;
begin
  AFieldIdHint := '';
  AValueTypeHint := '';
  ABehaviorHint := 'unknown';
  ARationale := '';
  Data := nil;
  try
    try
      Data := GetJSON(Utf8JsonText(AHintsJson));
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_hints_invalid',
        '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_hints_invalid',
        '{}'));
    Obj := TJSONObject(Data);
    Text := Trim(Obj.Get('field_id_hint', ''));
    if IsWellFormedGoalFieldId(Text) then
      AFieldIdHint := Text;
    Text := LowerCase(Trim(Obj.Get('value_type_hint', '')));
    if IsSupportedGoalValueType(Text) then
      AValueTypeHint := Text;
    Text := LowerCase(Trim(Obj.Get('behavior_hint', '')));
    if IsSupportedGoalBehavior(Text) then
      ABehaviorHint := Text;
    Text := Trim(Obj.Get('rationale', ''));
    if Length(Text) > CeaDiscoveryGoalRationaleMaxChars then
      Text := Copy(Text, 1, CeaDiscoveryGoalRationaleMaxChars);
    ARationale := Text;
    Result := TCEAResult.Ok('{"field_id_hint":"' + JsonEscapeText(AFieldIdHint) +
      '","value_type_hint":"' + JsonEscapeText(AValueTypeHint) +
      '","behavior_hint":"' + JsonEscapeText(ABehaviorHint) + '"}');
  finally
    Data.Free;
  end;
end;

function JsonBool(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

function JsonEscapeText(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      Result := Result + C;
    end;
  end;
end;

function TCEADiscoveryGoal.IsValid: Boolean;
begin
  Result := (GoalId <> '') and (Description <> '') and (CreatedAt <> '');
end;

function TCEADiscoveryGoalService.IndexOf(const AGoalId: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if AGoalId = '' then Exit;
  for I := 0 to High(FGoals) do
    if FGoals[I].GoalId = AGoalId then
      Exit(I);
end;

function TCEADiscoveryGoalService.BuildGoal(const ADescription, AFieldIdHint,
  AValueTypeHint, ABehaviorHint, ARationale, ACreatedAt: string;
  const ASource: TCEADiscoveryGoalSource): TCEADiscoveryGoal;
begin
  Result := Default(TCEADiscoveryGoal);
  Inc(FSequence);
  Result.GoalId := 'goal-' + IntToHex(FSequence, 8);
  Result.Sequence := FSequence;
  Result.Description := ADescription;
  Result.FieldIdHint := AFieldIdHint;
  Result.ValueTypeHint := AValueTypeHint;
  if ABehaviorHint = '' then
    Result.BehaviorHint := 'unknown'
  else
    Result.BehaviorHint := ABehaviorHint;
  Result.Rationale := ARationale;
  Result.Source := ASource;
  Result.State := dgoProposed;
  // Provenance, not a judgement about quality: a model proposed these hints,
  // and that stays true no matter who accepts them afterwards.
  Result.Advisory := ASource = dgsModel;
  Result.CreatedAt := ACreatedAt;
end;

procedure TCEADiscoveryGoalService.SupersedeAccepted(const AExceptGoalId,
  ADecidedAt: string);
var
  I: Integer;
begin
  for I := 0 to High(FGoals) do
    if (FGoals[I].State = dgoAccepted) and (FGoals[I].GoalId <> AExceptGoalId) then
    begin
      FGoals[I].State := dgoSuperseded;
      FGoals[I].DecidedAt := ADecidedAt;
    end;
end;

function TCEADiscoveryGoalService.ProposeFromOperator(const ADescription,
  AFieldIdHint, AValueTypeHint, ABehaviorHint, ACreatedAt: string;
  out AGoal: TCEADiscoveryGoal): TCEAResult;
var
  Description, FieldId, ValueType, Behavior: string;
begin
  AGoal := Default(TCEADiscoveryGoal);
  Description := Trim(ADescription);
  if Description = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_description_required',
      '{}'));
  if Length(Description) > CeaDiscoveryGoalDescriptionMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_description_too_long',
      '{"max_chars":' + IntToStr(CeaDiscoveryGoalDescriptionMaxChars) + '}'));
  if ACreatedAt = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_timestamp_required',
      '{}'));

  // Operator-declared hints are validated, not "corrected": an operator who
  // typed a value type we cannot scan is told so, rather than silently getting
  // a different type.
  FieldId := Trim(AFieldIdHint);
  if (FieldId <> '') and (not IsWellFormedGoalFieldId(FieldId)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_field_id_invalid',
      '{"rule":"lowercase letters, digits, dot and underscore"}'));
  ValueType := LowerCase(Trim(AValueTypeHint));
  if (ValueType <> '') and (not IsSupportedGoalValueType(ValueType)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_value_type_invalid',
      '{}'));
  Behavior := LowerCase(Trim(ABehaviorHint));
  if (Behavior <> '') and (not IsSupportedGoalBehavior(Behavior)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_behavior_invalid',
      '{}'));

  AGoal := BuildGoal(Description, FieldId, ValueType, Behavior, '',
    ACreatedAt, dgsOperator);
  SetLength(FGoals, Length(FGoals) + 1);
  FGoals[High(FGoals)] := AGoal;
  Result := TCEAResult.Ok('{"goal_id":"' + AGoal.GoalId +
    '","state":"' + DiscoveryGoalStateText(AGoal.State) + '"}');
end;

function TCEADiscoveryGoalService.ProposeFromModel(
  const AProvider: TCEALLMChatProvider; const ADescription: string;
  const AMaxOutputTokens: Cardinal; const ACreatedAt: string;
  out AGoal: TCEADiscoveryGoal): TCEAResult;
var
  Description: string;
  Request: TCEALLMChatRequest;
  Prompt: UTF8String;
  Response: TCEAResult;
  Content: UnicodeString;
  Data: TJSONData;
  Obj: TJSONObject;
  FieldId, ValueType, Behavior, Rationale: string;
begin
  AGoal := Default(TCEADiscoveryGoal);
  if AProvider = nil then
    Exit(TCEAResult.Error(rcConflict, 'llm_not_configured', '{}'));
  Description := Trim(ADescription);
  if Description = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_description_required',
      '{}'));
  if Length(Description) > CeaDiscoveryGoalDescriptionMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_description_too_long',
      '{"max_chars":' + IntToStr(CeaDiscoveryGoalDescriptionMaxChars) + '}'));
  if ACreatedAt = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_timestamp_required',
      '{}'));

  // UTF8String throughout: concatenating UTF-8 fragments into a plain `string`
  // transcode them to the local codepage and the model sees mojibake.
  Prompt := '{"task":"interpret_field_goal",' +
    '"rules":["the description is the operator''s own words, do not rewrite it",' +
    '"suggest only a value type from byte, word, dword, qword, integer, ' +
    'single, double, bool, enum, string",' +
    '"suggest only a behaviour from increase, decrease, constant, unknown",' +
    '"never guess a memory address",' +
    '"answer in JSON with keys field_id_hint, value_type_hint, behavior_hint, rationale"],' +
    '"description":"' + JsonEscapeText(Description) + '"}';

  Request := Default(TCEALLMChatRequest);
  Request.UserPrompt := Utf8JsonText(Prompt);
  Request.MaxOutputTokens := AMaxOutputTokens;
  Request.Temperature := 0.1;
  Request.ResponseFormat := 'json_object';
  Response := AProvider.Chat(Request);
  if Response.Failed then
    Exit(Response);

  Content := '';
  Data := nil;
  try
    try
      Data := GetJSON(Utf8JsonText(Response.DataJson));
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_envelope_invalid',
        '{}'));
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_envelope_invalid',
        '{}'));
    Obj := TJSONObject(Data);
    // UnicodeString overload: a string overload would tag the UTF-8 bytes as
    // the local codepage and break the second parse.
    Content := Obj.Get('content', UnicodeString(''));
    if Trim(string(Content)) = '' then
      Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_content_empty',
        '{}'));
  finally
    Data.Free;
  end;

  Response := SanitizeGoalHints(string(Content), FieldId, ValueType, Behavior,
    Rationale);
  if Response.Failed then
    Exit(Response);

  AGoal := BuildGoal(Description, FieldId, ValueType, Behavior, Rationale,
    ACreatedAt, dgsModel);
  SetLength(FGoals, Length(FGoals) + 1);
  FGoals[High(FGoals)] := AGoal;
  Result := TCEAResult.Ok('{"goal_id":"' + AGoal.GoalId +
    '","state":"proposed","source":"model","advisory":true' +
    ',"requires_confirmation":true}');
end;

function TCEADiscoveryGoalService.Accept(const AGoalId, ADecidedAt: string;
  out AGoal: TCEADiscoveryGoal): TCEAResult;
var
  Index: Integer;
begin
  AGoal := Default(TCEADiscoveryGoal);
  if AGoalId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_id_required', '{}'));
  Index := IndexOf(AGoalId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'discovery_goal_not_found', '{}'));
  if FGoals[Index].State = dgoAccepted then
    Exit(TCEAResult.Error(rcConflict, 'discovery_goal_already_accepted',
      '{"goal_id":"' + JsonEscapeText(AGoalId) + '"}'));
  if FGoals[Index].State <> dgoProposed then
    Exit(TCEAResult.Error(rcConflict, 'discovery_goal_not_proposed',
      '{"state":"' + DiscoveryGoalStateText(FGoals[Index].State) + '"}'));

  // One active goal at a time. A second accepted goal is not an error - people
  // do change their minds - but the previous one must stop looking active,
  // otherwise two intentions compete and neither is honest about its status.
  SupersedeAccepted(AGoalId, ADecidedAt);
  FGoals[Index].State := dgoAccepted;
  FGoals[Index].DecidedAt := ADecidedAt;
  AGoal := FGoals[Index];
  Result := TCEAResult.Ok('{"goal_id":"' + AGoal.GoalId +
    '","state":"accepted","advisory":' + JsonBool(AGoal.Advisory) + '}');
end;

function TCEADiscoveryGoalService.Reject(const AGoalId, AReason,
  ADecidedAt: string; out AGoal: TCEADiscoveryGoal): TCEAResult;
var
  Index: Integer;
  Reason: string;
begin
  AGoal := Default(TCEADiscoveryGoal);
  if AGoalId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_id_required', '{}'));
  Reason := Trim(AReason);
  if Reason = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'discovery_goal_reject_reason_required', '{}'));
  if Length(Reason) > CeaDiscoveryGoalRejectReasonMaxChars then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'discovery_goal_reject_reason_too_long',
      '{"max_chars":' + IntToStr(CeaDiscoveryGoalRejectReasonMaxChars) + '}'));
  Index := IndexOf(AGoalId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'discovery_goal_not_found', '{}'));
  // People change their minds after accepting a goal too: "actually this is
  // experience, not health". Rejecting an accepted goal is therefore allowed
  // and simply ends its activity; what is already decided stays decided.
  if FGoals[Index].State = dgoRejected then
    Exit(TCEAResult.Error(rcConflict, 'discovery_goal_already_rejected',
      '{"goal_id":"' + JsonEscapeText(AGoalId) + '"}'));
  if FGoals[Index].State = dgoSuperseded then
    Exit(TCEAResult.Error(rcConflict, 'discovery_goal_not_proposed',
      '{"state":"' + DiscoveryGoalStateText(FGoals[Index].State) + '"}'));

  FGoals[Index].State := dgoRejected;
  FGoals[Index].RejectReason := Reason;
  FGoals[Index].DecidedAt := ADecidedAt;
  AGoal := FGoals[Index];
  Result := TCEAResult.Ok('{"goal_id":"' + AGoal.GoalId +
    '","state":"rejected"}');
end;

function TCEADiscoveryGoalService.CurrentGoal(
  out AGoal: TCEADiscoveryGoal): Boolean;
var
  I: Integer;
begin
  AGoal := Default(TCEADiscoveryGoal);
  Result := False;
  for I := High(FGoals) downto 0 do
    if FGoals[I].State = dgoAccepted then
    begin
      AGoal := FGoals[I];
      Exit(True);
    end;
end;

function TCEADiscoveryGoalService.GetGoal(const AGoalId: string;
  out AGoal: TCEADiscoveryGoal): TCEAResult;
var
  Index: Integer;
begin
  AGoal := Default(TCEADiscoveryGoal);
  if AGoalId = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'discovery_goal_id_required', '{}'));
  Index := IndexOf(AGoalId);
  if Index < 0 then
    Exit(TCEAResult.Error(rcUnknown, 'discovery_goal_not_found', '{}'));
  AGoal := FGoals[Index];
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryGoalService.ListGoals(const ALimit: Cardinal;
  out AGoals: TCEADiscoveryGoalArray): TCEAResult;
var
  Limit, Total, Start, I: Integer;
begin
  SetLength(AGoals, 0);
  Limit := ALimit;
  if Limit <= 0 then
    Limit := CeaDiscoveryGoalDefaultLimit;
  if Limit > CeaDiscoveryGoalMaxLimit then
    Limit := CeaDiscoveryGoalMaxLimit;
  Total := Length(FGoals);
  Start := Total - Limit;
  if Start < 0 then
    Start := 0;
  SetLength(AGoals, Total - Start);
  for I := Start to Total - 1 do
    AGoals[I - Start] := FGoals[I];
  Result := TCEAResult.Ok('{}');
end;

function TCEADiscoveryGoalService.Count: Cardinal;
begin
  Result := Length(FGoals);
end;

procedure TCEADiscoveryGoalService.Reset;
begin
  SetLength(FGoals, 0);
  FSequence := 0;
end;

end.
