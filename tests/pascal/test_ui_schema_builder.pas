program test_ui_schema_builder;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_ui_schema_types, cea_ui_schema_builder;

var
  Builder: TCEAUiSchemaBuilder;
  Model: TCEAGameStateModel;
  Schema: TCEAUiSchema;
  Field: TCEAGameField;
  R: TCEAResult;
  I: Integer;

begin
  Builder := TCEAUiSchemaBuilder.Create;
  Model := TCEAGameStateModel.Create('Hollow Knight', '1.5',
    'sha256:' + StringOfChar('a', 64), 'sha256:' + StringOfChar('b', 64));
  try
    // 金币：dword 已验证可写 → 数值卡片 + editable
    FillChar(Field, SizeOf(Field), 0);
    Field.FieldId := 'player.geo';
    Field.DisplayName := 'Geo';
    Field.ValueType := 'dword';
    Field.Source := 'win32_memory';
    Field.Confidence := 1.0;
    Field.Access := faVerifiedWritable;
    Field.ValidationStatus := vsVerified;
    Field.LastUpdated := '2026-10-19T20:00:00Z';
    Field.AddressHex := '0x12345678';
    Assert(Model.AddField(Field), 'add geo field');

    // 体力：single 只读 → 数值卡片 + read_only
    FillChar(Field, SizeOf(Field), 0);
    Field.FieldId := 'player.stamina';
    Field.DisplayName := 'Stamina';
    Field.ValueType := 'single';
    Field.Source := 'win32_memory';
    Field.Confidence := 0.9;
    Field.Access := faReadOnly;
    Field.ValidationStatus := vsObserved;
    Field.LastUpdated := '2026-10-19T20:00:00Z';
    Field.AddressHex := '0x12340000';
    Assert(Model.AddField(Field), 'add stamina field');

    // 布尔开关
    FillChar(Field, SizeOf(Field), 0);
    Field.FieldId := 'player.invincible';
    Field.DisplayName := 'Invincible';
    Field.ValueType := 'bool';
    Field.Source := 'win32_memory';
    Field.Confidence := 0.8;
    Field.Access := faPendingWrite;
    Field.ValidationStatus := vsHypothesis;
    Field.LastUpdated := '2026-10-19T20:00:00Z';
    Field.AddressHex := '0x12345000';
    Assert(Model.AddField(Field), 'add boolean field');

    // 构建 UI Schema
    R := Builder.BuildFromModel(Model, '角色概览', Schema);
    Assert(R.Code = rcOk, 'build ok: ' + R.StableCode);
    Assert(Schema.Id = 'ui-Hollow Knight', 'schema id');
    Assert(Schema.PageTitle = '角色概览', 'page title');
    Assert(Length(Schema.Sections) = 1, 'one section');
    Assert(Length(Schema.Sections[0].Components) = 3, 'three components');

    // 校验组件映射
    for I := 0 to High(Schema.Sections[0].Components) do
    begin
      if Schema.Sections[0].Components[I].FieldId = 'player.geo' then
      begin
        Assert(Schema.Sections[0].Components[I].Kind = ucValueCard, 'geo -> value card');
        Assert(Schema.Sections[0].Components[I].Access = uaEditable, 'geo editable');
      end
      else if Schema.Sections[0].Components[I].FieldId = 'player.stamina' then
      begin
        Assert(Schema.Sections[0].Components[I].Kind = ucValueCard, 'stamina -> value card');
        Assert(Schema.Sections[0].Components[I].Access = uaReadOnly, 'stamina read-only');
      end
      else if Schema.Sections[0].Components[I].FieldId = 'player.invincible' then
      begin
        Assert(Schema.Sections[0].Components[I].Kind = ucToggle, 'bool -> toggle');
        Assert(Schema.Sections[0].Components[I].Access = uaReadOnly,
          'pending_write stays read-only (AC-014)');
      end;
    end;

    WriteLn('UI_SCHEMA_BUILDER=PASS');
  finally
    Model.Free;
    Builder.Free;
  end;
end.