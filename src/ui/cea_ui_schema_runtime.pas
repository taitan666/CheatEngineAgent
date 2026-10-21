unit cea_ui_schema_runtime;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_ui_schema_types, cea_ui_layout_types;

type
  // 组件绑定结果：组件引用的字段是否在状态模型中解析到
  TCEAUiBindingState = (
    ubsBound,          // 已绑定到有效字段
    ubsFieldMissing,   // 字段在状态模型中不存在
    ubsFieldInvalid,   // 字段存在但记录无效
    ubsNotBound        // 组件本就不绑定字段（静态文本）
  );

  // 字段语义状态：副屏以「颜色 + 形状 + 文字」三重表达（PRD 7.9）
  TCEAUiFieldSemanticState = (
    ufsReadOnly,
    ufsPendingWrite,
    ufsVerifiedWritable,
    ufsInvalid,
    ufsUnknown
  );

  TCEAUiRenderComponent = record
    ComponentId: string;
    Kind: TCEAUiComponentKind;
    Title: string;
    FieldId: string;
    OptionsJson: string;
    Binding: TCEAUiBindingState;
    FieldValueJson: string;
    FieldValueType: string;
    ValidationStatus: TCEAValidationStatus;
    Semantic: TCEAUiFieldSemanticState;
    Editable: Boolean;         // 是否允许渲染可提交编辑控件
    DisabledReason: string;    // 不可编辑的稳定原因码
    function IsValid: Boolean;
  end;

  TCEAUiRenderComponentArray = array of TCEAUiRenderComponent;

  TCEAUiRenderSection = record
    SectionId: string;
    Title: string;
    Components: TCEAUiRenderComponentArray;
    function IsValid: Boolean;
  end;

  TCEAUiRenderSectionArray = array of TCEAUiRenderSection;

  TCEAUiRenderModel = record
    SchemaId: string;
    PageTitle: string;
    Sections: TCEAUiRenderSectionArray;
    ComponentCount: Cardinal;
    EditableCount: Cardinal;
    MissingCount: Cardinal;
    GeneratedAtMs: Int64;
    function IsValid: Boolean;
  end;

  TCEAUiSchemaRuntime = class
  private
    function BindComponent(const AComponent: TCEAUiComponent;
      const AModel: TCEAGameStateModel;
      out ARender: TCEAUiRenderComponent): TCEAResult;
  public
    // UI Schema + 游戏状态模型 -> 可渲染模型（FR-020/021/022，AC-005）
    function Bind(const ASchema: TCEAUiSchema;
      const AModel: TCEAGameStateModel; const AGeneratedAtMs: Int64;
      out ARender: TCEAUiRenderModel): TCEAResult;
    // 应用布局记忆（FR-024）：重排 + 剔除隐藏组件
    function ApplyLayout(const ARender: TCEAUiRenderModel;
      const ALayout: TCEAUiLayoutState;
      out AResult: TCEAUiRenderModel): TCEAResult;
    // 序列化为副屏消费的 JSON
    function RenderToJson(const ARender: TCEAUiRenderModel): string;
  end;

function UiBindingStateText(const AState: TCEAUiBindingState): string;
function TryParseUiBindingState(const AText: string;
  out AState: TCEAUiBindingState): Boolean;
function UiFieldSemanticText(const AState: TCEAUiFieldSemanticState): string;
function TryParseUiFieldSemantic(const AText: string;
  out AState: TCEAUiFieldSemanticState): Boolean;
function SemanticFromFieldAccess(
  const AAccess: TCEAFieldAccess): TCEAUiFieldSemanticState;

implementation

uses
  FPJSON, JSONParser;

function UiBindingStateText(const AState: TCEAUiBindingState): string;
begin
  case AState of
    ubsBound: Result := 'bound';
    ubsFieldMissing: Result := 'field_missing';
    ubsFieldInvalid: Result := 'field_invalid';
    ubsNotBound: Result := 'not_bound';
  end;
end;

function TryParseUiBindingState(const AText: string;
  out AState: TCEAUiBindingState): Boolean;
var
  S: TCEAUiBindingState;
begin
  for S := Low(TCEAUiBindingState) to High(TCEAUiBindingState) do
    if UiBindingStateText(S) = AText then
    begin
      AState := S;
      Exit(True);
    end;
  Result := False;
end;

function UiFieldSemanticText(const AState: TCEAUiFieldSemanticState): string;
begin
  case AState of
    ufsReadOnly: Result := 'read_only';
    ufsPendingWrite: Result := 'pending_write';
    ufsVerifiedWritable: Result := 'verified_writable';
    ufsInvalid: Result := 'invalid';
    ufsUnknown: Result := 'unknown';
  end;
end;

function TryParseUiFieldSemantic(const AText: string;
  out AState: TCEAUiFieldSemanticState): Boolean;
var
  S: TCEAUiFieldSemanticState;
begin
  for S := Low(TCEAUiFieldSemanticState) to High(TCEAUiFieldSemanticState) do
    if UiFieldSemanticText(S) = AText then
    begin
      AState := S;
      Exit(True);
    end;
  Result := False;
end;

function SemanticFromFieldAccess(
  const AAccess: TCEAFieldAccess): TCEAUiFieldSemanticState;
begin
  case AAccess of
    faReadOnly: Result := ufsReadOnly;
    faPendingWrite: Result := ufsPendingWrite;
    faVerifiedWritable: Result := ufsVerifiedWritable;
    faInvalid: Result := ufsInvalid;
  else
    Result := ufsUnknown;
  end;
end;

function TCEAUiRenderComponent.IsValid: Boolean;
begin
  Result := (ComponentId <> '') and (Title <> '');
  if Kind <> ucText then
    Result := Result and (FieldId <> '');
  // 可编辑组件必须绑定到有效字段（防止只读字段被渲染成可提交控件）
  if Editable then
    Result := Result and (Binding = ubsBound) and (DisabledReason = '');
end;

function TCEAUiRenderSection.IsValid: Boolean;
begin
  Result := (SectionId <> '') and (Length(Components) > 0);
end;

function TCEAUiRenderModel.IsValid: Boolean;
begin
  Result := (SchemaId <> '') and (PageTitle <> '') and
    (Length(Sections) > 0);
end;

function TCEAUiSchemaRuntime.BindComponent(const AComponent: TCEAUiComponent;
  const AModel: TCEAGameStateModel;
  out ARender: TCEAUiRenderComponent): TCEAResult;
var
  Field: TCEAGameField;
begin
  ARender.ComponentId := AComponent.Id;
  ARender.Kind := AComponent.Kind;
  ARender.Title := AComponent.Title;
  ARender.FieldId := AComponent.FieldId;
  ARender.OptionsJson := AComponent.OptionsJson;
  ARender.Binding := ubsNotBound;
  ARender.FieldValueJson := '';
  ARender.FieldValueType := '';
  ARender.ValidationStatus := vsObserved;
  ARender.Semantic := ufsUnknown;
  ARender.Editable := False;
  ARender.DisabledReason := '';

  // 可编辑声明本身必须合法：静态文本不可编辑，可编辑组件必须绑定字段
  if AComponent.Access = uaEditable then
  begin
    if AComponent.Kind = ucText then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'text_component_not_editable', '{}'));
    if AComponent.FieldId = '' then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'editable_component_field_required', '{}'));
  end;

  if AComponent.FieldId = '' then
  begin
    Result := TCEAResult.Ok('{}');
    Exit;
  end;

  if not AModel.GetField(AComponent.FieldId, Field) then
  begin
    ARender.Binding := ubsFieldMissing;
    ARender.DisabledReason := 'field_not_in_state_model';
    Result := TCEAResult.Ok('{}');
    Exit;
  end;

  ARender.FieldValueJson := Field.ValueJson;
  ARender.FieldValueType := Field.ValueType;
  ARender.ValidationStatus := Field.ValidationStatus;

  if not Field.IsValid then
  begin
    ARender.Binding := ubsFieldInvalid;
    ARender.Semantic := ufsInvalid;
    ARender.DisabledReason := 'field_record_invalid';
    Result := TCEAResult.Ok('{}');
    Exit;
  end;

  ARender.Binding := ubsBound;
  ARender.Semantic := SemanticFromFieldAccess(Field.Access);

  // 双重门禁（FR-022 / AC-005）：
  // 组件声明 uaEditable 且字段确为 faVerifiedWritable 时才允许渲染编辑控件。
  if AComponent.Access <> uaEditable then
    ARender.DisabledReason := 'component_read_only'
  else if Field.Access <> faVerifiedWritable then
    ARender.DisabledReason := 'field_not_verified_writable'
  else
  begin
    ARender.Editable := True;
    ARender.DisabledReason := '';
  end;

  Result := TCEAResult.Ok('{}');
end;

function TCEAUiSchemaRuntime.Bind(const ASchema: TCEAUiSchema;
  const AModel: TCEAGameStateModel; const AGeneratedAtMs: Int64;
  out ARender: TCEAUiRenderModel): TCEAResult;
var
  I, J: Integer;
  Component: TCEAUiRenderComponent;
  R: TCEAResult;
begin
  ARender.SchemaId := '';
  ARender.PageTitle := '';
  SetLength(ARender.Sections, 0);
  ARender.ComponentCount := 0;
  ARender.EditableCount := 0;
  ARender.MissingCount := 0;
  ARender.GeneratedAtMs := 0;

  if AModel = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_required', '{}'));
  if not ASchema.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_schema_invalid', '{}'));

  ARender.SchemaId := ASchema.Id;
  ARender.PageTitle := ASchema.PageTitle;
  ARender.GeneratedAtMs := AGeneratedAtMs;
  SetLength(ARender.Sections, Length(ASchema.Sections));

  for I := 0 to High(ASchema.Sections) do
  begin
    if not ASchema.Sections[I].IsValid then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ui_section_invalid', '{}'));
    ARender.Sections[I].SectionId := ASchema.Sections[I].Id;
    ARender.Sections[I].Title := ASchema.Sections[I].Title;
    SetLength(ARender.Sections[I].Components,
      Length(ASchema.Sections[I].Components));
    for J := 0 to High(ASchema.Sections[I].Components) do
    begin
      if not ASchema.Sections[I].Components[J].IsValid then
        Exit(TCEAResult.Error(rcInvalidArgument, 'ui_component_invalid', '{}'));
      R := BindComponent(ASchema.Sections[I].Components[J], AModel, Component);
      if R.Failed then Exit(R);
      if not Component.IsValid then
        Exit(TCEAResult.Error(rcInternalError, 'ui_component_binding_invalid',
          '{}'));
      ARender.Sections[I].Components[J] := Component;
      Inc(ARender.ComponentCount);
      if Component.Editable then Inc(ARender.EditableCount);
      if Component.Binding = ubsFieldMissing then Inc(ARender.MissingCount);
    end;
  end;

  if not ARender.IsValid then
    Exit(TCEAResult.Error(rcInternalError, 'ui_render_model_invalid', '{}'));
  Result := TCEAResult.Ok('{}');
end;

function TCEAUiSchemaRuntime.ApplyLayout(const ARender: TCEAUiRenderModel;
  const ALayout: TCEAUiLayoutState; out AResult: TCEAUiRenderModel): TCEAResult;
var
  I, J, K, Best: Integer;
  Consumed, Picked: array of Boolean;
  Section: TCEAUiRenderSection;
  Component: TCEAUiRenderComponent;
begin
  if ALayout.SchemaId <> ARender.SchemaId then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ui_layout_schema_mismatch', '{}'));

  AResult := ARender;
  for I := 0 to High(ARender.Sections) do
  begin
    SetLength(Picked, Length(ARender.Sections[I].Components));
    for J := 0 to High(Picked) do Picked[J] := False;
    SetLength(Consumed, Length(ALayout.Components));
    for J := 0 to High(Consumed) do Consumed[J] := False;

    Section.SectionId := ARender.Sections[I].SectionId;
    Section.Title := ARender.Sections[I].Title;
    SetLength(Section.Components, 0);

    // 先按布局记忆的 Order 升序挑选（选择排序，组件数量小）
    for K := 0 to High(ALayout.Components) do
    begin
      Best := -1;
      for J := 0 to High(ALayout.Components) do
      begin
        if Consumed[J] then Continue;
        if (Best < 0) or
          (ALayout.Components[J].Order < ALayout.Components[Best].Order) then
          Best := J;
      end;
      if Best < 0 then Break;
      Consumed[Best] := True;
      for J := 0 to High(ARender.Sections[I].Components) do
        if (not Picked[J]) and (ARender.Sections[I].Components[J].ComponentId =
          ALayout.Components[Best].ComponentId) then
        begin
          Picked[J] := True;
          if not ALayout.Components[Best].Hidden then
          begin
            SetLength(Section.Components, Length(Section.Components) + 1);
            Section.Components[High(Section.Components)] :=
              ARender.Sections[I].Components[J];
          end;
          Break;
        end;
    end;

    // 布局记忆未覆盖的组件按原顺序追加（不因缺少记忆而消失）
    for J := 0 to High(ARender.Sections[I].Components) do
      if not Picked[J] then
      begin
        SetLength(Section.Components, Length(Section.Components) + 1);
        Section.Components[High(Section.Components)] :=
          ARender.Sections[I].Components[J];
      end;

    AResult.Sections[I] := Section;
  end;

  // 重算计数（隐藏组件被剔除后计数必须一致）
  AResult.ComponentCount := 0;
  AResult.EditableCount := 0;
  AResult.MissingCount := 0;
  for I := 0 to High(AResult.Sections) do
    for J := 0 to High(AResult.Sections[I].Components) do
    begin
      Component := AResult.Sections[I].Components[J];
      Inc(AResult.ComponentCount);
      if Component.Editable then Inc(AResult.EditableCount);
      if Component.Binding = ubsFieldMissing then Inc(AResult.MissingCount);
    end;

  if not AResult.IsValid then
    Exit(TCEAResult.Error(rcInternalError, 'ui_layout_result_invalid', '{}'));
  Result := TCEAResult.Ok('{}');
end;

function TCEAUiSchemaRuntime.RenderToJson(
  const ARender: TCEAUiRenderModel): string;
var
  Root, SectionObj, CompObj: TJSONObject;
  SectionsArr, CompsArr: TJSONArray;
  I, J: Integer;
  C: TCEAUiRenderComponent;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('schema_id', ARender.SchemaId);
    Root.Add('page_title', ARender.PageTitle);
    Root.Add('generated_at_ms', ARender.GeneratedAtMs);
    Root.Add('component_count', ARender.ComponentCount);
    Root.Add('editable_count', ARender.EditableCount);
    Root.Add('missing_count', ARender.MissingCount);
    SectionsArr := TJSONArray.Create;
    Root.Add('sections', SectionsArr);
    for I := 0 to High(ARender.Sections) do
    begin
      SectionObj := TJSONObject.Create;
      SectionsArr.Add(SectionObj);
      SectionObj.Add('section_id', ARender.Sections[I].SectionId);
      SectionObj.Add('title', ARender.Sections[I].Title);
      CompsArr := TJSONArray.Create;
      SectionObj.Add('components', CompsArr);
      for J := 0 to High(ARender.Sections[I].Components) do
      begin
        C := ARender.Sections[I].Components[J];
        CompObj := TJSONObject.Create;
        CompsArr.Add(CompObj);
        CompObj.Add('component_id', C.ComponentId);
        CompObj.Add('kind', UiComponentKindText(C.Kind));
        CompObj.Add('title', C.Title);
        CompObj.Add('field_id', C.FieldId);
        CompObj.Add('options_json', C.OptionsJson);
        CompObj.Add('binding', UiBindingStateText(C.Binding));
        CompObj.Add('field_value_json', C.FieldValueJson);
        CompObj.Add('field_value_type', C.FieldValueType);
        CompObj.Add('validation_status', ValidationStatusText(C.ValidationStatus));
        CompObj.Add('semantic', UiFieldSemanticText(C.Semantic));
        CompObj.Add('editable', C.Editable);
        CompObj.Add('disabled_reason', C.DisabledReason);
      end;
    end;
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

end.
