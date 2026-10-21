unit cea_win32_window_locator;

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, cea_results;

type
  // 按进程 ID 定位游戏主窗口（录像帧源的前置条件）。
  //
  // 为什么需要它：ICEAFrameSource 的实现要求一个 HWND，而运行时只知道 PID
  // （进程身份来自 TCEProcessIdentity）。没有这一步，录像层即使写好也接不上。
  //
  // 选择策略：在属于该 PID 的可见顶层窗口中取客户区面积最大的那个。
  // 不能取「第一个」——游戏常见带启动器/覆盖层/工具窗口，第一个往往是
  // 无内容的辅助窗口，抓出来是一片空白，等于录了无用证据。
  TCEAWin32WindowLocator = class
  public
    // 成功体：{"window_handle":"0x...","title":"...","width":N,"height":N}
    function FindMainWindow(const APid: Cardinal;
      out AWindowHandle: HWND; out ATitle: string): TCEAResult;
  end;

implementation

// Local JSON string escaping: window titles are user-visible text and can carry
// quotes, backslashes or non-ASCII characters, so they cannot be concatenated raw.
function EscapeJsonText(const AValue: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(AValue) do
  begin
    Ch := AValue[I];
    case Ch of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if Ch < ' ' then
        Result := Result + '\u' + IntToHex(Ord(Ch), 4)
      else
        Result := Result + Ch;
    end;
  end;
end;

type
  TWindowCandidate = class
  private
    FPid: Cardinal;
    FBestHandle: HWND;
    FBestArea: Int64;
    FBestTitle: string;
    FFoundCount: Integer;
    procedure Consider(const AWnd: HWND);
  public
    constructor Create(const APid: Cardinal);
    property BestHandle: HWND read FBestHandle;
    property BestTitle: string read FBestTitle;
    property FoundCount: Integer read FFoundCount;
  end;

constructor TWindowCandidate.Create(const APid: Cardinal);
begin
  inherited Create;
  FPid := APid;
  FBestHandle := 0;
  FBestArea := 0;
  FBestTitle := '';
  FFoundCount := 0;
end;

procedure TWindowCandidate.Consider(const AWnd: HWND);
var
  OwnerPid: DWORD;
  Rect: TRect;
  TitleLen: Integer;
  Buffer: array[0..511] of WideChar;
  Area: Int64;
  Title: string;
begin
  OwnerPid := 0;
  GetWindowThreadProcessId(AWnd, @OwnerPid);
  if OwnerPid <> FPid then Exit;
  if not IsWindowVisible(AWnd) then Exit;
  if not GetClientRect(AWnd, Rect) then Exit;
  Area := Int64(Rect.Right - Rect.Left) * Int64(Rect.Bottom - Rect.Top);
  if Area <= 0 then Exit;
  Inc(FFoundCount);
  // 面积相同则保留先遇到的（EnumWindows 的 Z 序靠前=更靠顶层）
  if Area <= FBestArea then Exit;
  Title := '';
  TitleLen := GetWindowTextLengthW(AWnd);
  if (TitleLen > 0) and (TitleLen < Length(Buffer)) then
  begin
    FillChar(Buffer, SizeOf(Buffer), 0);
    if GetWindowTextW(AWnd, @Buffer[0], Length(Buffer)) > 0 then
      Title := string(WideString(Buffer));
  end;
  FBestHandle := AWnd;
  FBestArea := Area;
  FBestTitle := Title;
end;

function WindowEnumCallback(AWnd: HWND; AParam: LPARAM): WINBOOL; stdcall;
var
  Candidate: TWindowCandidate;
begin
  Candidate := TWindowCandidate(AParam);
  if Candidate <> nil then
    Candidate.Consider(AWnd);
  Result := True;  // 继续枚举，要比较面积
end;

function TCEAWin32WindowLocator.FindMainWindow(const APid: Cardinal;
  out AWindowHandle: HWND; out ATitle: string): TCEAResult;
var
  Candidate: TWindowCandidate;
  Ok: WINBOOL;
begin
  AWindowHandle := 0;
  ATitle := '';
  if APid = 0 then
    Exit(TCEAResult.Error(rcInvalidArgument, 'window_locator_pid_required', '{}'));
  Candidate := TWindowCandidate.Create(APid);
  try
    Ok := EnumWindows(@WindowEnumCallback, LPARAM(Candidate));
    if (not Ok) and (Candidate.FoundCount = 0) then
      Exit(TCEAResult.Error(rcInternalError, 'window_enumeration_failed', '{}'));
    if Candidate.BestHandle = 0 then
      Exit(TCEAResult.Error(rcUnknown, 'window_not_found',
        '{"pid":' + IntToStr(APid) + '}'));
    AWindowHandle := Candidate.BestHandle;
    ATitle := Candidate.BestTitle;
    Result := TCEAResult.Ok('{"window_handle":"0x' +
      IntToHex(PtrUInt(AWindowHandle), 16) + '","title":"' +
      EscapeJsonText(ATitle) + '","candidates":' +
      IntToStr(Candidate.FoundCount) + '}');
  finally
    Candidate.Free;
  end;
end;

end.
