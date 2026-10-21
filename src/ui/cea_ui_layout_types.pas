unit cea_ui_layout_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

interface

uses
  SysUtils, cea_results;

type
  // 单个组件的布局记忆（FR-024）：顺序、显隐、尺寸
  TCEAUiComponentLayout = record
    ComponentId: string;
    Order: Integer;
    Hidden: Boolean;
    Width: Integer;
    Height: Integer;
    function IsValid: Boolean;
  end;

  TCEAUiComponentLayoutArray = array of TCEAUiComponentLayout;

  // 一个 UI Schema 的布局状态（按 schema id 归档）
  TCEAUiLayoutState = record
    SchemaId: string;
    Components: TCEAUiComponentLayoutArray;
    UpdatedAt: string;
    function IsValid: Boolean;
    function FindComponent(const AComponentId: string;
      out ALayout: TCEAUiComponentLayout): Boolean;
  end;

  // 显示器信息（FR-031 显示器选择）
  TCEADisplayInfo = record
    DisplayId: string;
    Name: string;
    Left: Integer;
    Top: Integer;
    Width: Integer;
    Height: Integer;
    IsPrimary: Boolean;
    function IsValid: Boolean;
  end;

  TCEADisplayInfoArray = array of TCEADisplayInfo;

  // 副屏窗口位置记忆（FR-032 窗口记忆）
  TCEASecondaryWindowPlacement = record
    SchemaId: string;
    DisplayId: string;
    Left: Integer;
    Top: Integer;
    Width: Integer;
    Height: Integer;
    Maximized: Boolean;
    ScalePercent: Integer;
    function IsValid: Boolean;
  end;

  ICEAUiLayoutStore = interface
    function Initialize: TCEAResult;
    function SaveLayout(const ALayout: TCEAUiLayoutState): TCEAResult;
    function LoadLayout(const ASchemaId: string;
      out ALayout: TCEAUiLayoutState): TCEAResult;
    function DeleteLayout(const ASchemaId: string): TCEAResult;
  end;

  ICEAWindowPlacementStore = interface
    function SavePlacement(
      const APlacement: TCEASecondaryWindowPlacement): TCEAResult;
    function LoadPlacement(const ASchemaId: string;
      out APlacement: TCEASecondaryWindowPlacement): TCEAResult;
  end;

  ICEADisplayEnumerator = interface
    function EnumerateDisplays(
      out ADisplays: TCEADisplayInfoArray): TCEAResult;
  end;

function FindDisplay(const ADisplays: TCEADisplayInfoArray;
  const ADisplayId: string; out AInfo: TCEADisplayInfo): Boolean;
function FindPrimaryDisplay(const ADisplays: TCEADisplayInfoArray;
  out AInfo: TCEADisplayInfo): Boolean;
function DisplayContainsPoint(const AInfo: TCEADisplayInfo;
  const ALeft, ATop: Integer): Boolean;
function PlacementIntersectsAnyDisplay(
  const APlacement: TCEASecondaryWindowPlacement;
  const ADisplays: TCEADisplayInfoArray): Boolean;

implementation

function TCEAUiComponentLayout.IsValid: Boolean;
begin
  Result := (ComponentId <> '') and (Order >= 0) and (Width >= 0) and
    (Height >= 0);
end;

function TCEAUiLayoutState.IsValid: Boolean;
begin
  Result := (SchemaId <> '') and (UpdatedAt <> '');
end;

function TCEAUiLayoutState.FindComponent(const AComponentId: string;
  out ALayout: TCEAUiComponentLayout): Boolean;
var
  I: Integer;
begin
  ALayout.ComponentId := '';
  ALayout.Order := 0;
  ALayout.Hidden := False;
  ALayout.Width := 0;
  ALayout.Height := 0;
  for I := 0 to High(Components) do
    if Components[I].ComponentId = AComponentId then
    begin
      ALayout := Components[I];
      Exit(True);
    end;
  Result := False;
end;

function TCEADisplayInfo.IsValid: Boolean;
begin
  Result := (DisplayId <> '') and (Width > 0) and (Height > 0);
end;

function TCEASecondaryWindowPlacement.IsValid: Boolean;
begin
  Result := (SchemaId <> '') and (DisplayId <> '') and (Width > 0) and
    (Height > 0) and (ScalePercent >= 50) and (ScalePercent <= 400);
end;

function FindDisplay(const ADisplays: TCEADisplayInfoArray;
  const ADisplayId: string; out AInfo: TCEADisplayInfo): Boolean;
var
  I: Integer;
begin
  AInfo.DisplayId := '';
  AInfo.Name := '';
  AInfo.Left := 0;
  AInfo.Top := 0;
  AInfo.Width := 0;
  AInfo.Height := 0;
  AInfo.IsPrimary := False;
  if ADisplayId = '' then Exit(False);
  for I := 0 to High(ADisplays) do
    if ADisplays[I].DisplayId = ADisplayId then
    begin
      AInfo := ADisplays[I];
      Exit(True);
    end;
  Result := False;
end;

function FindPrimaryDisplay(const ADisplays: TCEADisplayInfoArray;
  out AInfo: TCEADisplayInfo): Boolean;
var
  I: Integer;
begin
  AInfo.DisplayId := '';
  AInfo.Name := '';
  AInfo.Left := 0;
  AInfo.Top := 0;
  AInfo.Width := 0;
  AInfo.Height := 0;
  AInfo.IsPrimary := False;
  for I := 0 to High(ADisplays) do
    if ADisplays[I].IsPrimary then
    begin
      AInfo := ADisplays[I];
      Exit(True);
    end;
  // 没有标记主屏时退回第一个可用显示器（fail-open 到可用屏，而非无窗口）
  if Length(ADisplays) > 0 then
  begin
    AInfo := ADisplays[0];
    AInfo.IsPrimary := True;
    Exit(True);
  end;
  Result := False;
end;

function DisplayContainsPoint(const AInfo: TCEADisplayInfo;
  const ALeft, ATop: Integer): Boolean;
begin
  Result := (ALeft >= AInfo.Left) and (ALeft < AInfo.Left + AInfo.Width) and
    (ATop >= AInfo.Top) and (ATop < AInfo.Top + AInfo.Height);
end;

function PlacementIntersectsAnyDisplay(
  const APlacement: TCEASecondaryWindowPlacement;
  const ADisplays: TCEADisplayInfoArray): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(ADisplays) do
    if (APlacement.Left < ADisplays[I].Left + ADisplays[I].Width) and
      (ADisplays[I].Left < APlacement.Left + APlacement.Width) and
      (APlacement.Top < ADisplays[I].Top + ADisplays[I].Height) and
      (ADisplays[I].Top < APlacement.Top + APlacement.Height) then
      Exit(True);
  Result := False;
end;

end.
