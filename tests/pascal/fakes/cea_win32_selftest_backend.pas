unit cea_win32_selftest_backend;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, Windows, JwaTlHelp32, fpjson, jsonparser, cea_types, cea_results,
  cea_runtime_backend_ports;

type
  TCEAWin32SelfTestBackend = class(TObject, ICEAReadOnlyRuntimeBackend)
  private
    FAllowedPid: Cardinal;
    FHandle: THandle;
    FScanAddress: QWord;
    FScanSize: Cardinal;
  public
    AttachCount: Cardinal;
    ReadCount: Cardinal;
    ReadAttemptCount: Cardinal;
    ListModulesCount: Cardinal;
    FirstScanCount: Cardinal;
    RefineScanCount: Cardinal;
    CancelScanCount: Cardinal;
    DisassembleCount: Cardinal;
    constructor Create(const AAllowedPid: Cardinal);
    destructor Destroy; override;
    procedure ConfigureScanRegion(const AAddress: QWord;
      const AByteCount: Cardinal);
    function ListProcesses: TCEAResult;
    function QueryProcessInfo(const APid: Cardinal;
      out AInfo: TCEARuntimeProcessInfo): TCEAResult;
    function AttachReadOnly(const APid: Cardinal): TCEAResult;
    function Detach: TCEAResult;
    function ListModules(const APid, AMaxResults: Cardinal): TCEAResult;
    function ReadMemory(const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
    function PlanReadableRegions(const ARegionKinds: string;
      const AMaxBytes: QWord; const AMaxRegions: Cardinal): TCEAResult;
    function FirstScan(const ARequestJson: string): TCEAResult;
    function GetScanStatus(const AScanId: string): TCEAResult;
    function RefineScan(const ARequestJson: string): TCEAResult;
    function CancelScan(const AScanId: string): TCEAResult;
    function Disassemble(const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
  end;

implementation

const
  SelfTestExecutableHash =
    'sha256:1111111111111111111111111111111111111111111111111111111111111111';
  SelfTestModuleHash =
    'sha256:2222222222222222222222222222222222222222222222222222222222222222';

function BytesToHex(const ABytes: array of Byte): string;
const
  Digits = '0123456789abcdef';
var
  Index: Integer;
begin
  SetLength(Result, Length(ABytes) * 2);
  for Index := 0 to High(ABytes) do
  begin
    Result[Index * 2 + 1] := Digits[(ABytes[Index] shr 4) + 1];
    Result[Index * 2 + 2] := Digits[(ABytes[Index] and $0F) + 1];
  end;
end;

constructor TCEAWin32SelfTestBackend.Create(const AAllowedPid: Cardinal);
begin
  inherited Create;
  FAllowedPid := AAllowedPid;
end;

destructor TCEAWin32SelfTestBackend.Destroy;
begin
  if FHandle <> 0 then
    CloseHandle(FHandle);
  inherited Destroy;
end;

procedure TCEAWin32SelfTestBackend.ConfigureScanRegion(
  const AAddress: QWord; const AByteCount: Cardinal);
begin
  FScanAddress := AAddress;
  FScanSize := AByteCount;
end;

function TCEAWin32SelfTestBackend.ListProcesses: TCEAResult;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
  Found: Boolean;
begin
  Found := False;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcInternalError,
      'selftest_process_snapshot_failed', '{}'));
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    if Process32First(Snapshot, Entry) then
      repeat
        if Entry.th32ProcessID = FAllowedPid then
        begin
          Found := True;
          Break;
        end;
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  if not Found then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_process_not_found', '{}'));
  Result := TCEAResult.Ok('{"processes":[{"pid":' +
    IntToStr(FAllowedPid) + '}]}');
end;

function TCEAWin32SelfTestBackend.QueryProcessInfo(const APid: Cardinal;
  out AInfo: TCEARuntimeProcessInfo): TCEAResult;
var
  Buffer: array[0..MAX_PATH] of Char;
  CreatedAt, ExitAt, KernelAt, UserAt: TFileTime;
  TempHandle: THandle;
begin
  if (APid = 0) or (APid <> FAllowedPid) or
     (APid <> GetCurrentProcessId) then
    Exit(TCEAResult.Error(rcUnauthorized,
      'selftest_target_not_allowed', '{}'));
  TempHandle := OpenProcess(PROCESS_QUERY_INFORMATION, False, APid);
  if TempHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized,
      'selftest_query_open_failed', '{}'));
  try
    FillChar(CreatedAt, SizeOf(CreatedAt), 0);
    if not GetProcessTimes(TempHandle, CreatedAt, ExitAt, KernelAt, UserAt) then
      Exit(TCEAResult.Error(rcInternalError,
        'selftest_process_time_failed', '{}'));
    FillChar(Buffer, SizeOf(Buffer), 0);
    GetModuleFileName(0, Buffer, Length(Buffer));
    AInfo.Pid := APid;
    AInfo.StartedAt := IntToHex(CreatedAt.dwHighDateTime, 8) +
      IntToHex(CreatedAt.dwLowDateTime, 8);
    AInfo.ExecutablePath := StrPas(Buffer);
    AInfo.ExecutableSha256 := SelfTestExecutableHash;
    {$if defined(CPU64)}
    AInfo.Architecture := caX86_64;
    {$else}
    AInfo.Architecture := caX86;
    {$endif}
    AInfo.ModuleSetHash := SelfTestModuleHash;
    Result := TCEAResult.Ok('{}');
  finally
    CloseHandle(TempHandle);
  end;
end;

function TCEAWin32SelfTestBackend.AttachReadOnly(
  const APid: Cardinal): TCEAResult;
begin
  if (APid <> FAllowedPid) or (APid <> GetCurrentProcessId) then
    Exit(TCEAResult.Error(rcUnauthorized,
      'selftest_target_not_allowed', '{}'));
  if FHandle <> 0 then
    Exit(TCEAResult.Error(rcConflict, 'selftest_already_attached', '{}'));
  FHandle := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ,
    False, APid);
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized,
      'selftest_read_open_failed', '{}'));
  Inc(AttachCount);
  Result := TCEAResult.Ok('{"attached":true}');
end;

function TCEAWin32SelfTestBackend.Detach: TCEAResult;
begin
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'selftest_not_attached', '{}'));
  CloseHandle(FHandle);
  FHandle := 0;
  Result := TCEAResult.Ok('{"detached":true}');
end;

function JsonString(const AValue: UnicodeString): string;
var
  Item: TJSONString;
begin
  Item := TJSONString.Create(UTF8Encode(AValue));
  try
    Result := Item.AsJSON;
  finally
    Item.Free;
  end;
end;

function TCEAWin32SelfTestBackend.ListModules(const APid,
  AMaxResults: Cardinal): TCEAResult;
var
  Snapshot: THandle;
  Entry: TModuleEntry32W;
  Items: string;
  Count: Cardinal;
begin
  Inc(ListModulesCount);
  if (FHandle = 0) or (APid <> FAllowedPid) or (AMaxResults = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_module_request_invalid', '{}'));
  Snapshot := CreateToolhelp32Snapshot(
    TH32CS_SNAPMODULE or TH32CS_SNAPMODULE32, APid);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcInternalError,
      'selftest_module_snapshot_failed', '{}'));
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    Count := 0;
    Items := '';
    if Module32FirstW(Snapshot, Entry) then
      repeat
        if Count > 0 then
          Items := Items + ',';
        Items := Items + '{"name":' + JsonString(Entry.szModule) +
          ',"path":' + JsonString(Entry.szExePath) +
          ',"base_address":"0x' +
          IntToHex(QWord(PtrUInt(Entry.modBaseAddr)), 16) +
          '","size":' + IntToStr(Entry.modBaseSize) + '}';
        Inc(Count);
      until (Count >= AMaxResults) or not Module32NextW(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  Result := TCEAResult.Ok('{"modules":[' + Items +
    '],"returned":' + IntToStr(Count) + '}');
end;

function TCEAWin32SelfTestBackend.ReadMemory(const AAddress: QWord;
  const AByteCount: Cardinal): TCEAResult;
var
  Buffer: array of Byte;
  BytesRead: SIZE_T;
begin
  Inc(ReadAttemptCount);
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'selftest_not_attached', '{}'));
  if (AAddress = 0) or (AByteCount = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_read_invalid', '{}'));
  SetLength(Buffer, AByteCount);
  BytesRead := 0;
  if not Windows.ReadProcessMemory(FHandle, Pointer(PtrUInt(AAddress)),
    @Buffer[0], AByteCount, BytesRead) or (BytesRead <> AByteCount) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'selftest_read_failed', '{}'));
  Inc(ReadCount);
  Result := TCEAResult.Ok('{"address":"0x' + IntToHex(AAddress, 16) +
    '","bytes":"' + BytesToHex(Buffer) + '"}');
end;

function TCEAWin32SelfTestBackend.PlanReadableRegions(
  const ARegionKinds: string; const AMaxBytes: QWord;
  const AMaxRegions: Cardinal): TCEAResult;
begin
  Result := TCEAResult.Error(rcNotImplemented,
    'selftest_process_region_planner_unavailable', '{}');
end;

function TCEAWin32SelfTestBackend.FirstScan(
  const ARequestJson: string): TCEAResult;
var
  Data: TJSONData;
  ValueText: string;
  Expected, Buffer: array of Byte;
  CleanHex: string;
  Index, Offset: Integer;
  BytesRead: SIZE_T;
  MatchAddress: QWord;
begin
  if (FHandle = 0) or (FScanAddress = 0) or (FScanSize = 0) then
    Exit(TCEAResult.Error(rcConflict, 'selftest_scan_not_ready', '{}'));
  try
    Data := GetJSON(ARequestJson);
    try
      ValueText := TJSONObject(Data).Get('value_text', '');
    finally
      Data.Free;
    end;
  except
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_scan_json_invalid', '{}'));
  end;
  CleanHex := StringReplace(StringReplace(ValueText, ' ', '',
    [rfReplaceAll]), '-', '', [rfReplaceAll]);
  if (Length(CleanHex) = 0) or Odd(Length(CleanHex)) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_scan_value_invalid', '{}'));
  SetLength(Expected, Length(CleanHex) div 2);
  try
    for Index := 0 to High(Expected) do
      Expected[Index] := StrToInt('$' + Copy(CleanHex, Index * 2 + 1, 2));
  except
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_scan_value_invalid', '{}'));
  end;
  SetLength(Buffer, FScanSize);
  BytesRead := 0;
  if not Windows.ReadProcessMemory(FHandle, Pointer(PtrUInt(FScanAddress)),
    @Buffer[0], FScanSize, BytesRead) or (BytesRead <> FScanSize) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'selftest_scan_read_failed', '{}'));
  MatchAddress := 0;
  if Length(Expected) <= Length(Buffer) then
    for Offset := 0 to Length(Buffer) - Length(Expected) do
      if CompareByte(Buffer[Offset], Expected[0], Length(Expected)) = 0 then
      begin
        MatchAddress := FScanAddress + QWord(Offset);
        Break;
      end;
  Inc(FirstScanCount);
  if MatchAddress = 0 then
    Result := TCEAResult.Ok('{"scan_id":"selftest-scan-1",' +
      '"match_count":0,"addresses":[]}')
  else
    Result := TCEAResult.Ok('{"scan_id":"selftest-scan-1",' +
      '"match_count":1,"addresses":["' +
      IntToHex(MatchAddress, 16) + '"]}');
end;

function TCEAWin32SelfTestBackend.GetScanStatus(
  const AScanId: string): TCEAResult;
begin
  if AScanId <> 'selftest-scan-1' then
    Exit(TCEAResult.Error(rcConflict, 'selftest_scan_not_active', '{}'));
  Result := TCEAResult.Ok('{"scan_id":"selftest-scan-1",' +
    '"state":"ready","execution":"synchronous","can_refine":true}');
end;

function TCEAWin32SelfTestBackend.RefineScan(
  const ARequestJson: string): TCEAResult;
begin
  if Pos('selftest-scan-1', ARequestJson) = 0 then
    Exit(TCEAResult.Error(rcConflict, 'selftest_scan_not_active', '{}'));
  Inc(RefineScanCount);
  Result := TCEAResult.Ok('{"scan_id":"selftest-scan-1",' +
    '"match_count":1,"addresses":["' +
    IntToHex(FScanAddress, 16) + '"]}');
end;

function TCEAWin32SelfTestBackend.CancelScan(
  const AScanId: string): TCEAResult;
begin
  if AScanId <> 'selftest-scan-1' then
    Exit(TCEAResult.Error(rcConflict, 'selftest_scan_not_active', '{}'));
  Inc(CancelScanCount);
  Result := TCEAResult.Ok('{"cancelled":true}');
end;

function TCEAWin32SelfTestBackend.Disassemble(const AAddress: QWord;
  const AByteCount: Cardinal): TCEAResult;
var
  Buffer: array of Byte;
  BytesRead: SIZE_T;
  Index: Cardinal;
  Items, Mnemonic: string;
begin
  Inc(DisassembleCount);
  if (FHandle = 0) or (AAddress = 0) or (AByteCount = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'selftest_disassembly_invalid', '{}'));
  SetLength(Buffer, AByteCount);
  BytesRead := 0;
  if not Windows.ReadProcessMemory(FHandle, Pointer(PtrUInt(AAddress)),
    @Buffer[0], AByteCount, BytesRead) or (BytesRead <> AByteCount) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'selftest_disassembly_read_failed', '{}'));
  Items := '';
  for Index := 0 to AByteCount - 1 do
  begin
    case Buffer[Index] of
      $90: Mnemonic := 'nop';
      $C3: Mnemonic := 'ret';
    else
      Mnemonic := 'db 0x' + IntToHex(Buffer[Index], 2);
    end;
    if Index > 0 then
      Items := Items + ',';
    Items := Items + '{"address":"0x' +
      IntToHex(AAddress + Index, 16) + '","bytes":"' +
      IntToHex(Buffer[Index], 2) + '","mnemonic":"' +
      Mnemonic + '"}';
  end;
  Result := TCEAResult.Ok('{"decoder":"selftest-minimal",' +
    '"instructions":[' + Items + ']}');
end;

end.
