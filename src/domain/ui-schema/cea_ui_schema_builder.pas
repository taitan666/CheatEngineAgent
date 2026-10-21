unit cea_ui_schema_builder;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results, cea_ui_schema_types, cea_field_model,
  cea_game_state_model;

type
  // UI Schema 生成器：从 Game State Model 自动生成受控组件白名单的 UI Schema
  // （PRD 场景 A「自动生成副屏」的核心逻辑）
  TCEAUiSchemaBuilder = class
  private
    function FieldToComponentKind(const AValueType: string;
      out AKind: TCEAUiComponentKind): Boolean;
    function FieldToAccess(const AAccess: TCEAFieldAccess;
      out AUiAccess: TCEAUiComponentAccess): Boolean;
  public
    // 从字段模型生成默认 UI Schema（单区块，按字段类型映射组件）
    function BuildFromModel(const AModel: TCEAGameStateModel;
      const APageTitle: string; out ASchema: TCEAUiSchema): TCEAResult;
  end;

implementation

function TCEAUiSchemaBuilder.FieldToComponentKind(const AValueType: string;
  out AKind: TCEAUiComponentKind): Boolean;
begin
  Result := True;
  if AValueType = 'bool' then AKind := ucToggle
  else if AValueType = 'enum' then AKind := ucDropdown
  else if AValueType = 'string' then AKind := ucText
  else if (AValueType = 'integer') or (AValueType = 'single') or
          (AValueType = 'dword') or (AValueType = 'word') or
          (AValueType = 'byte') or (AValueType = 'qword') or
          (AValueType = 'double') then AKind := ucValueCard
  else if (AValueType = 'progress') then AKind := ucProgressBar
  else Result := False;
end;

function TCEAUiSchemaBuilder.FieldToAccess(const AAccess: TCEAFieldAccess;
  out AUiAccess: TCEAUiComponentAccess): Boolean;
begin
  Result := True;
  case AAccess of
    faVerifiedWritable: AUiAccess := uaEditable;
    faPendingWrite: AUiAccess := uaReadOnly; // 待验证：暂只读（FR-022 / AC-014）
    faReadOnly: AUiAccess := uaReadOnly;
    faInvalid: AUiAccess := uaReadOnly;       // 失效：降级只读
  end;
end;

function TCEAUiSchemaBuilder.BuildFromModel(const AModel: TCEAGameStateModel;
  const APageTitle: string; out ASchema: TCEAUiSchema): TCEAResult;
var
  Fields: TCEAGameFieldArray;
  I: Integer;
  Kind: TCEAUiComponentKind;
  UiAccess: TCEAUiComponentAccess;
  Fp: TCEAGameVersionFingerprint;
begin
  FillChar(ASchema, SizeOf(ASchema), 0);
  if AModel = nil then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_required', '{}'));
  Fields := AModel.GetFields;
  if Length(Fields) = 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_empty', '{}'));
  Fp := AModel.Fingerprint;
  if not Fp.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'model_fingerprint_invalid', '{}'));

  ASchema.Id := 'ui-' + Fp.GameName;
  if APageTitle <> '' then ASchema.PageTitle := APageTitle
  else ASchema.PageTitle := Fp.GameName;
  SetLength(ASchema.Sections, 1);
  ASchema.Sections[0].Id := 'sec-' + Fp.GameName;
  ASchema.Sections[0].Title := Fp.GameName;
  SetLength(ASchema.Sections[0].Components, Length(Fields));
  for I := 0 to High(Fields) do
  begin
    if not FieldToComponentKind(Fields[I].ValueType, Kind) then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'field_value_type_unsupported',
        '{"field":"' + Fields[I].FieldId + '"}'));
    if not FieldToAccess(Fields[I].Access, UiAccess) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'field_access_invalid', '{}'));
    ASchema.Sections[0].Components[I].Id := 'comp-' + Fields[I].FieldId;
    ASchema.Sections[0].Components[I].Kind := Kind;
    ASchema.Sections[0].Components[I].Title := Fields[I].DisplayName;
    ASchema.Sections[0].Components[I].FieldId := Fields[I].FieldId;
    ASchema.Sections[0].Components[I].Access := UiAccess;
    // Phase 1 简化：暂不解析 ConstraintsJson 到组件 options（后续 1D 渲染时处理）
    ASchema.Sections[0].Components[I].OptionsJson := '';
  end;
  if not ASchema.IsValid then
    Exit(TCEAResult.Error(rcInternalError, 'ui_schema_build_invalid', '{}'));
  Result := TCEAResult.Ok('{}');
end;

end.