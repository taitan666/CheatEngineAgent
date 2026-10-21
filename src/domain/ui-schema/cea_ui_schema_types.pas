unit cea_ui_schema_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils;

type
  // 受控组件白名单（PRD 6.3 FR-021）：
  // 文本、数值卡片、进度条、开关、滑块、下拉、物品格、表格、搜索框、状态提示
  TCEAUiComponentKind = (
    ucText,          // 文本
    ucValueCard,     // 数值卡片
    ucProgressBar,   // 进度条
    ucToggle,        // 开关（布尔）
    ucSlider,        // 滑块
    ucDropdown,      // 下拉（枚举）
    ucItemGrid,      // 物品格
    ucTable,         // 表格
    ucSearchBox,     // 搜索框
    ucStatusNotice   // 状态提示
  );

  // 组件读写能力：只读组件不得渲染可提交编辑控件（FR-022 / AC-005）
  TCEAUiComponentAccess = (
    uaReadOnly,       // 只读展示
    uaEditable        // 可编辑（字段已验证可写）
  );

  TCEAUiComponent = record
    Id: string;              // 组件稳定标识
    Kind: TCEAUiComponentKind;
    Title: string;           // 显示名
    FieldId: string;         // 绑定的字段（可空，如静态文本）
    Access: TCEAUiComponentAccess;
    OptionsJson: string;     // 组件特定选项（如进度条范围、下拉候选项）
    function IsValid: Boolean;
  end;

  TCEAUiComponentArray = array of TCEAUiComponent;

  // 页面区块：一组组件（如「角色概览」「装备栏」）
  TCEAUiSection = record
    Id: string;
    Title: string;
    Components: TCEAUiComponentArray;
    function IsValid: Boolean;
  end;

  TCEAUiSectionArray = array of TCEAUiSection;

  // UI Schema：一个副屏页面的布局描述（受控 JSON，非任意 HTML/JS）
  TCEAUiSchema = record
    Id: string;
    PageTitle: string;
    Sections: TCEAUiSectionArray;
    function IsValid: Boolean;
  end;

  function UiComponentKindText(const AKind: TCEAUiComponentKind): string;
  function TryParseUiComponentKind(const AText: string;
    out AKind: TCEAUiComponentKind): Boolean;
  function UiComponentAccessText(const AAccess: TCEAUiComponentAccess): string;
  function TryParseUiComponentAccess(const AText: string;
    out AAccess: TCEAUiComponentAccess): Boolean;

implementation

function UiComponentKindText(const AKind: TCEAUiComponentKind): string;
begin
  case AKind of
    ucText: Result := 'text';
    ucValueCard: Result := 'value_card';
    ucProgressBar: Result := 'progress_bar';
    ucToggle: Result := 'toggle';
    ucSlider: Result := 'slider';
    ucDropdown: Result := 'dropdown';
    ucItemGrid: Result := 'item_grid';
    ucTable: Result := 'table';
    ucSearchBox: Result := 'search_box';
    ucStatusNotice: Result := 'status_notice';
  end;
end;

function TryParseUiComponentKind(const AText: string;
  out AKind: TCEAUiComponentKind): Boolean;
var
  K: TCEAUiComponentKind;
begin
  for K := Low(TCEAUiComponentKind) to High(TCEAUiComponentKind) do
    if UiComponentKindText(K) = AText then
    begin
      AKind := K;
      Exit(True);
    end;
  Result := False;
end;

function UiComponentAccessText(const AAccess: TCEAUiComponentAccess): string;
begin
  case AAccess of
    uaReadOnly: Result := 'read_only';
    uaEditable: Result := 'editable';
  end;
end;

function TryParseUiComponentAccess(const AText: string;
  out AAccess: TCEAUiComponentAccess): Boolean;
var
  A: TCEAUiComponentAccess;
begin
  for A := Low(TCEAUiComponentAccess) to High(TCEAUiComponentAccess) do
    if UiComponentAccessText(A) = AText then
    begin
      AAccess := A;
      Exit(True);
    end;
  Result := False;
end;

function TCEAUiComponent.IsValid: Boolean;
begin
  Result := (Id <> '') and (Title <> '');
  // 非文本组件必须绑定字段
  if Kind <> ucText then
    Result := Result and (FieldId <> '');
end;

function TCEAUiSection.IsValid: Boolean;
begin
  Result := (Id <> '') and (Length(Components) > 0);
end;

function TCEAUiSchema.IsValid: Boolean;
begin
  Result := (Id <> '') and (Length(Sections) > 0);
end;

end.
