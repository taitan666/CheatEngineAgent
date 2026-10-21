unit cea_win32_pointer_reader;

{$mode objfpc}{$H+}
{$interfaces corba}

{ Windows implementation of ICEAPointerMemoryReader plus module base lookup.

  The reader opens the target process per read and closes it again: pointer
  chains are resolved rarely (on declaration and on explicit re-resolution), so
  holding a handle open would only widen the window in which a stale handle can
  outlive the process. Read-only access is requested, so this unit can never
  write to the target.

  Module lookup uses a Toolhelp snapshot, the same mechanism the read-only
  backend already uses for `cea.list_modules`, so module base addresses agree
  between the two paths. }

interface

uses
  SysUtils, Windows, JwaTlHelp32, cea_results, cea_pointer_chain;

type
  TCEAWin32PointerReader = class(TObject, ICEAPointerMemoryReader)
  private
    FPid: Cardinal;
    FMaxBytes: Cardinal;
  public
    constructor Create(const APid, AMaxBytes: Cardinal);
    function ReadPointerBytes(const AAddress: QWord;
      const AByteCount: Cardinal; out ABytes: TBytes): TCEAResult;
    { Case-insensitive lookup of a loaded module's base address. }
    function ModuleBaseAddress(const AModuleName: string;
      out ABaseAddress: QWord): TCEAResult;
    property Pid: Cardinal read FPid;
    property MaxBytes: Cardinal read FMaxBytes;
  end;

implementation

constructor TCEAWin32PointerReader.Create(const APid, AMaxBytes: Cardinal);
begin
  inherited Create;
  if (APid = 0) or (AMaxBytes = 0) then
    raise EArgumentOutOfRangeException.Create('pid or max bytes');
  FPid := APid;
  FMaxBytes := AMaxBytes;
end;

function TCEAWin32PointerReader.ReadPointerBytes(const AAddress: QWord;
  const AByteCount: Cardinal; out ABytes: TBytes): TCEAResult;
var
  ProcessHandle: THandle;
  BytesRead: SIZE_T;
begin
  ABytes := nil;
  if (AAddress = 0) or (AByteCount = 0) or (AByteCount > FMaxBytes) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_read_invalid',
      '{"max_bytes":' + IntToStr(FMaxBytes) + '}'));
  if AAddress + QWord(AByteCount - 1) < AAddress then
    Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_read_address_overflow',
      '{}'));
  ProcessHandle := Windows.OpenProcess(PROCESS_QUERY_INFORMATION or
    PROCESS_VM_READ, False, FPid);
  if ProcessHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized, 'pointer_read_open_failed',
      '{"pid":' + IntToStr(FPid) + '}'));
  try
    SetLength(ABytes, AByteCount);
    BytesRead := 0;
    if not Windows.ReadProcessMemory(ProcessHandle,
      Pointer(PtrUInt(AAddress)), @ABytes[0], AByteCount, BytesRead) then
    begin
      ABytes := nil;
      Exit(TCEAResult.Error(rcVerificationFailed, 'pointer_read_failed',
        '{"address":"0x' + IntToHex(AAddress, 16) + '"}'));
    end;
    if BytesRead <> SIZE_T(AByteCount) then
    begin
      { A short read means part of the range is unmapped. Returning the partial
        bytes would let the resolver dereference a pointer assembled from stale
        or missing bytes, so it fails instead. }
      ABytes := nil;
      Exit(TCEAResult.Error(rcVerificationFailed, 'pointer_read_short',
        '{"address":"0x' + IntToHex(AAddress, 16) + '","expected":' +
        IntToStr(AByteCount) + ',"actual":' + IntToStr(BytesRead) + '}'));
    end;
    Result := TCEAResult.Ok('{"address":"0x' + IntToHex(AAddress, 16) +
      '","bytes":' + IntToStr(AByteCount) + '}');
  finally
    CloseHandle(ProcessHandle);
  end;
end;

function TCEAWin32PointerReader.ModuleBaseAddress(const AModuleName: string;
  out ABaseAddress: QWord): TCEAResult;
var
  Snapshot: THandle;
  Entry: TModuleEntry32W;
  Wanted: UnicodeString;
begin
  ABaseAddress := 0;
  if Trim(AModuleName) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'module_name_required', '{}'));
  Snapshot := CreateToolhelp32Snapshot(
    TH32CS_SNAPMODULE or TH32CS_SNAPMODULE32, FPid);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcInternalError, 'module_snapshot_failed',
      '{"pid":' + IntToStr(FPid) + '}'));
  try
    Wanted := UnicodeString(AModuleName);
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    if Module32FirstW(Snapshot, Entry) then
      repeat
        if WideCompareText(UnicodeString(Entry.szModule), Wanted) = 0 then
        begin
          ABaseAddress := QWord(PtrUInt(Entry.modBaseAddr));
          Exit(TCEAResult.Ok('{"module":' +
            '"' + UTF8Encode(UnicodeString(Entry.szModule)) + '"' +
            ',"base_address":"0x' + IntToHex(ABaseAddress, 16) +
            '","size":' + IntToStr(Entry.modBaseSize) + '}'));
        end;
      until not Module32NextW(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  Result := TCEAResult.Error(rcUnknown, 'module_not_loaded',
    '{"module":"' + AModuleName + '","pid":' + IntToStr(FPid) + '}');
end;

end.
