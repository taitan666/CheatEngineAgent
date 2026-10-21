program test_ui_schema;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, cea_ui_schema_types;

var
  Component: TCEAUiComponent;
  Section: TCEAUiSection;
  Schema: TCEAUiSchema;
  Kind: TCEAUiComponentKind;
  Access: TCEAUiComponentAccess;

begin
  // 组件有效性：文本组件无需字段，其它需字段
  FillChar(Component, SizeOf(Component), 0);
  Assert(not Component.IsValid, 'empty component invalid');
  Component.Id := 'comp-hp';
  Component.Kind := ucValueCard;
  Component.Title := '生命值';
  Component.Access := uaReadOnly;
  Assert(not Component.IsValid, 'value card requires field');
  Component.FieldId := 'player.hp';
  Assert(Component.IsValid, 'value card with field valid');

  // 文本组件无需字段
  FillChar(Component, SizeOf(Component), 0);
  Component.Id := 'comp-title';
  Component.Kind := ucText;
  Component.Title := '角色概览';
  Component.Access := uaReadOnly;
  Assert(Component.IsValid, 'text component needs no field');

  // 枚举往返
  Assert(UiComponentKindText(ucProgressBar) = 'progress_bar');
  Assert(TryParseUiComponentKind('dropdown', Kind));
  Assert(Kind = ucDropdown);
  Assert(not TryParseUiComponentKind('bogus', Kind), 'unknown kind rejected');
  Assert(UiComponentAccessText(uaEditable) = 'editable');
  Assert(TryParseUiComponentAccess('read_only', Access));
  Assert(Access = uaReadOnly);

  // 区块 + Schema 有效性
  FillChar(Component, SizeOf(Component), 0);
  Component.Id := 'comp-geo';
  Component.Kind := ucValueCard;
  Component.Title := 'Geo';
  Component.FieldId := 'player.geo';
  Component.Access := uaEditable;
  Assert(Component.IsValid, 'editable geo card valid');

  FillChar(Section, SizeOf(Section), 0);
  Assert(not Section.IsValid, 'empty section invalid');
  Section.Id := 'sec-overview';
  Section.Title := '角色';
  SetLength(Section.Components, 1);
  Section.Components[0] := Component;
  Assert(Section.IsValid, 'section with component valid');

  FillChar(Schema, SizeOf(Schema), 0);
  Assert(not Schema.IsValid, 'empty schema invalid');
  Schema.Id := 'page-overview';
  Schema.PageTitle := '角色概览';
  SetLength(Schema.Sections, 1);
  Schema.Sections[0] := Section;
  Assert(Schema.IsValid, 'schema with section valid');
  Assert(Schema.Sections[0].Components[0].Access = uaEditable,
    'editable access preserved');

  WriteLn('UI_SCHEMA=PASS');
end.
