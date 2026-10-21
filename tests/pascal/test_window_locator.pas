program test_window_locator;

{$mode objfpc}{$H+}

// Verifies cea_win32_window_locator finds the game window by PID.
//
// A real window is created in this process instead of asserting against some
// ambient desktop window: the locator's whole job is "given a PID, pick that
// process's largest visible window", and only an owned window proves it.

uses
  SysUtils, Windows, fpjson, jsonparser, cea_results, cea_win32_window_locator;

type
  TWndClassExW = record
    cbSize: UINT;
    style: UINT;
    lpfnWndProc: Pointer;
    cbClsExtra: Integer;
    cbWndExtra: Integer;
    hInstance: HINST;
    hIcon: HICON;
    hCursor: HCURSOR;
    hbrBackground: HBRUSH;
    lpszMenuName: PWideChar;
    lpszClassName: PWideChar;
    hIconSm: HICON;
  end;
  PWndClassExW = ^TWndClassExW;

function RegisterClassExW(const AClass: PWndClassExW): ATOM; stdcall;
  external 'user32.dll' name 'RegisterClassExW';
function CreateWindowExW(ADwExStyle: DWORD; AClassName, AWindowName: PWideChar;
  ADwStyle: DWORD; AX, AY, AWidth, AHeight: Integer; AParent: HWND;
  AMenu: HMENU; AInstance: HINST; AParam: Pointer): HWND; stdcall;
  external 'user32.dll' name 'CreateWindowExW';
function DestroyWindow(AWnd: HWND): WINBOOL; stdcall;
  external 'user32.dll' name 'DestroyWindow';

function WndProc(AWnd: HWND; AMsg: UINT; AWParam: WPARAM;
  ALParam: LPARAM): LRESULT; stdcall;
begin
  Result := DefWindowProcW(AWnd, AMsg, AWParam, ALParam);
end;

var
  Failures: Integer = 0;

procedure Check(const AName: string; const AOk: Boolean; const ADetail: string);
begin
  if AOk then
    WriteLn('  ok   ', AName)
  else
  begin
    Inc(Failures);
    WriteLn('  FAIL ', AName, '  ', ADetail);
  end;
end;

var
  Locator: TCEAWin32WindowLocator;
  R: TCEAResult;
  Wnd, SmallWnd: HWND;
  Title: string;
  Data: TJSONObject;
  ClassName: WideString;
  Wc: TWndClassExW;
  Instance: HINST;

begin
  WriteLn('test_window_locator');

  Locator := TCEAWin32WindowLocator.Create;
  try
    R := Locator.FindMainWindow(0, Wnd, Title);
    Check('pid required', (R.Code = rcInvalidArgument) and
      (R.StableCode = 'window_locator_pid_required'), R.StableCode);

    R := Locator.FindMainWindow(High(Cardinal) - 7, Wnd, Title);
    Check('nonexistent pid -> window_not_found',
      (R.Code = rcUnknown) and (R.StableCode = 'window_not_found'),
      R.StableCode);

    // Own window: the locator must return it, with a parseable JSON body.
    Instance := GetModuleHandleW(nil);
    ClassName := WideString('CEAWindowLocatorTestClass');
    FillChar(Wc, SizeOf(Wc), 0);
    Wc.cbSize := SizeOf(Wc);
    Wc.lpfnWndProc := @WndProc;
    Wc.hInstance := Instance;
    Wc.lpszClassName := PWideChar(ClassName);
    RegisterClassExW(@Wc);

    Wnd := CreateWindowExW(0, PWideChar(ClassName),
      PWideChar(WideString('CEA Locator Test Window')), WS_OVERLAPPEDWINDOW,
      100, 100, 320, 200, 0, 0, Instance, nil);
    Check('test window created', Wnd <> 0, 'CreateWindowExW returned 0');
    if Wnd <> 0 then
      ShowWindow(Wnd, SW_SHOW);

    if Wnd <> 0 then
    begin
      R := Locator.FindMainWindow(GetCurrentProcessId, Wnd, Title);
      Check('own window found', R.Code = rcOk, R.StableCode);
      Check('title roundtrips',
        Title = 'CEA Locator Test Window', Title);
      Data := nil;
      try
        Data := TJSONObject(GetJSON(R.DataJson));
        Check('handle is nonzero hex',
          Copy(Data.Get('window_handle', ''), 1, 2) = '0x', R.DataJson);
        Check('candidates counted', Data.Get('candidates', 0) >= 1,
          R.DataJson);
      finally
        Data.Free;
      end;

      // Largest window wins: a second, smaller window must not displace it.
      SmallWnd := CreateWindowExW(0, PWideChar(ClassName),
        PWideChar(WideString('CEA Small Window')), WS_OVERLAPPEDWINDOW,
        200, 200, 80, 60, 0, 0, Instance, nil);
      if SmallWnd <> 0 then
      begin
        R := Locator.FindMainWindow(GetCurrentProcessId, Wnd, Title);
        Check('largest window preferred',
          (R.Code = rcOk) and (Title = 'CEA Locator Test Window'), Title);
        DestroyWindow(SmallWnd);
      end;

      DestroyWindow(Wnd);
    end;
  finally
    Locator.Free;
  end;

  if Failures = 0 then
  begin
    WriteLn('WINDOW_LOCATOR=PASS');
    Halt(0);
  end;
  WriteLn('WINDOW_LOCATOR=FAIL failures=', Failures);
  Halt(1);
end.
