unit cea_win32_display_enumerator;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Windows, SysUtils, cea_results, cea_ui_layout_types;

type
  // 枚举系统显示器（FR-031 显示器选择）。
  // 使用 EnumDisplayMonitors / GetMonitorInfoW，
  // 为副屏窗口提供稳定显示器标识与工作区几何。
  TCEAWin32DisplayEnumerator = class(TObject, ICEADisplayEnumerator)
  public
    function EnumerateDisplays(
      out ADisplays: TCEADisplayInfoArray): TCEAResult;
  end;

implementation

type
  PMonitorInfoExW = ^TMonitorInfoExW;
  TMonitorInfoExW = record
    cbSize: DWORD;
    rcMonitor: TRect;
    rcWork: TRect;
    dwFlags: DWORD;
    szDevice: array[0..31] of WideChar;
  end;

const
  MONITORINFOF_PRIMARY = 1;

type
  TMonitorEnumProc = function(AMonitor: THandle; ADc: HDC;
    ARect: PRect; AData: LPARAM): BOOL; stdcall;

function EnumDisplayMonitors(ADc: HDC; AClip: PRect;
  AProc: TMonitorEnumProc; AData: LPARAM): BOOL; stdcall;
  external 'user32.dll' name 'EnumDisplayMonitors';
function GetMonitorInfoW(AMonitor: THandle;
  AInfo: PMonitorInfoExW): BOOL; stdcall;
  external 'user32.dll' name 'GetMonitorInfoW';

type
  TCollector = class
  private
    FItems: TCEADisplayInfoArray;
    FSequence: Integer;
  public
    procedure Add(const AMonitor: THandle; const ARect: TRect);
    property Items: TCEADisplayInfoArray read FItems;
  end;

procedure TCollector.Add(const AMonitor: THandle; const ARect: TRect);
var
  Info: TMonitorInfoExW;
  Device: string;
begin
  Info.cbSize := SizeOf(TMonitorInfoExW);
  if not GetMonitorInfoW(AMonitor, @Info) then Exit;
  Device := string(Info.szDevice);
  Inc(FSequence);
  SetLength(FItems, Length(FItems) + 1);
  with FItems[High(FItems)] do
  begin
    // 设备名可用时以设备名为稳定标识，否则退回序号
    if Device <> '' then
      DisplayId := Device
    else
      DisplayId := 'display-' + IntToStr(FSequence);
    Name := Device;
    Left := ARect.Left;
    Top := ARect.Top;
    Width := ARect.Right - ARect.Left;
    Height := ARect.Bottom - ARect.Top;
    IsPrimary := (Info.dwFlags and MONITORINFOF_PRIMARY) <> 0;
  end;
end;

function MonitorEnumCallback(AMonitor: THandle; ADc: HDC;
  ARect: PRect; AData: LPARAM): BOOL; stdcall;
var
  Collector: TCollector;
begin
  Result := True;
  if ARect = nil then Exit;
  Collector := TCollector(AData);
  if Collector = nil then Exit;
  Collector.Add(AMonitor, ARect^);
end;

function TCEAWin32DisplayEnumerator.EnumerateDisplays(
  out ADisplays: TCEADisplayInfoArray): TCEAResult;
var
  Collector: TCollector;
  Ok: BOOL;
  I: Integer;
begin
  SetLength(ADisplays, 0);
  Collector := TCollector.Create;
  try
    Ok := EnumDisplayMonitors(0, nil, @MonitorEnumCallback,
      LPARAM(Collector));
    if not Ok then
      Exit(TCEAResult.Error(rcInternalError, 'display_enumeration_failed', '{}'));
    if Length(Collector.Items) = 0 then
      Exit(TCEAResult.Error(rcUnknown, 'display_none_available', '{}'));
    SetLength(ADisplays, Length(Collector.Items));
    for I := 0 to High(Collector.Items) do
      ADisplays[I] := Collector.Items[I];
    Result := TCEAResult.Ok('{"displays":' +
      IntToStr(Length(ADisplays)) + '}');
  finally
    Collector.Free;
  end;
end;

end.
