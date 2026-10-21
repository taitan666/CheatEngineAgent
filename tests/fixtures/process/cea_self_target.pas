program cea_self_target;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, Windows;

const
  PageSize = 4096;

type
  TFixturePluginLoader = class(TThread)
  private
    FPluginPath: string;
    FMarkerPath: string;
    FModule: HMODULE;
  protected
    procedure Execute; override;
  public
    constructor Create(const APluginPath, AMarkerPath: string);
    destructor Destroy; override;
  end;

constructor TFixturePluginLoader.Create(const APluginPath,
  AMarkerPath: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPluginPath := APluginPath;
  FMarkerPath := AMarkerPath;
end;

procedure TFixturePluginLoader.Execute;
var
  WidePath: UnicodeString;
begin
  while (not Terminated) and (not FileExists(FMarkerPath)) do
    Sleep(10);
  if Terminated then Exit;
  WidePath := UTF8Decode(FPluginPath);
  FModule := LoadLibraryW(PWideChar(WidePath));
end;

destructor TFixturePluginLoader.Destroy;
begin
  if FModule <> 0 then
    FreeLibrary(FModule);
  inherited Destroy;
end;

var
  Buffer: PByte;
  Command: string;
  PluginLoader: TFixturePluginLoader;

begin
  PluginLoader := nil;
  if ParamCount = 2 then
  begin
    PluginLoader := TFixturePluginLoader.Create(ParamStr(1), ParamStr(2));
    PluginLoader.Start;
  end;
  GetMem(Buffer, PageSize);
  try
    FillChar(Buffer^, PageSize, $CC);
    Buffer[0] := $90;
    Buffer[1] := $90;
    Buffer[2] := $C3;
    Buffer[3] := $DE;
    Buffer[4] := $AD;
    Buffer[5] := $BE;
    Buffer[6] := $EF;
    WriteLn(Format(
      '{"pid":%d,"address":"0x%x","size":%d,' +
      '"aob":"90 90 C3 DE AD BE EF"}',
      [GetCurrentProcessId, QWord(PtrUInt(Buffer)), PageSize]));
    Flush(Output);
    while not EOF(Input) do
    begin
      ReadLn(Command);
      if Command = 'exit' then
        Break;
    end;
  finally
    FreeMem(Buffer);
    if PluginLoader <> nil then
    begin
      PluginLoader.Terminate;
      PluginLoader.WaitFor;
      PluginLoader.Free;
    end;
  end;
end.
