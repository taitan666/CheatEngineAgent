unit cea_win32_effect_backend;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, Windows, cea_results, cea_effect_backend_ports;

type
  TCEAWin32EffectBackend = class(TObject, ICEAMemoryEffectBackend)
  private
    FMaxBytes: Cardinal;
    function DecodeHex(const AHex: string;
      out ABytes: TBytes): Boolean;
    function EncodeHex(const ABytes: array of Byte): string;
  public
    constructor Create(const AMaxBytes: Cardinal);
    function ReadCurrentHex(const APid: Cardinal; const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
    function CompareWriteReadback(const APid: Cardinal;
      const AAddress: QWord; const AExpectedHex,
      AReplacementHex: string): TCEAResult;
  end;

implementation

constructor TCEAWin32EffectBackend.Create(const AMaxBytes: Cardinal);
begin
  inherited Create;
  if AMaxBytes = 0 then
    raise EArgumentOutOfRangeException.Create('AMaxBytes');
  FMaxBytes := AMaxBytes;
end;

function TCEAWin32EffectBackend.DecodeHex(const AHex: string;
  out ABytes: TBytes): Boolean;
var
  I, Parsed: Integer;
begin
  Result := (AHex <> '') and not Odd(Length(AHex));
  if not Result then Exit;
  SetLength(ABytes, Length(AHex) div 2);
  try
    for I := 0 to High(ABytes) do
    begin
      if not TryStrToInt('$' + Copy(AHex, I * 2 + 1, 2), Parsed) or
         (Parsed < 0) or (Parsed > 255) then
        Exit(False);
      ABytes[I] := Byte(Parsed);
    end;
  except
    Exit(False);
  end;
end;

function TCEAWin32EffectBackend.EncodeHex(
  const ABytes: array of Byte): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + LowerCase(IntToHex(ABytes[I], 2));
end;

function TCEAWin32EffectBackend.ReadCurrentHex(const APid: Cardinal;
  const AAddress: QWord; const AByteCount: Cardinal): TCEAResult;
var
  ProcessHandle: THandle;
  CurrentBytes: TBytes;
  BytesRead: SIZE_T;
begin
  if (APid = 0) or (AAddress = 0) or (AByteCount = 0) or
     (AByteCount > FMaxBytes) or
     (AAddress + QWord(AByteCount - 1) < AAddress) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_effect_observation_invalid', '{}'));
  ProcessHandle := Windows.OpenProcess(PROCESS_QUERY_INFORMATION or
    PROCESS_VM_READ, False, APid);
  if ProcessHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized,
      'memory_effect_observation_open_failed', '{}'));
  try
    SetLength(CurrentBytes, AByteCount);
    BytesRead := 0;
    if not Windows.ReadProcessMemory(ProcessHandle,
      Pointer(PtrUInt(AAddress)), @CurrentBytes[0], AByteCount,
      BytesRead) or (BytesRead <> SIZE_T(AByteCount)) then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'memory_effect_observation_read_failed', '{}'));
    Result := TCEAResult.Ok('{"current":"' +
      EncodeHex(CurrentBytes) + '"}');
  finally
    CloseHandle(ProcessHandle);
  end;
end;

function TCEAWin32EffectBackend.CompareWriteReadback(
  const APid: Cardinal; const AAddress: QWord; const AExpectedHex,
  AReplacementHex: string): TCEAResult;
var
  ProcessHandle: THandle;
  Expected, Replacement, BeforeBytes, AfterBytes: TBytes;
  BytesRead, BytesWritten: SIZE_T;
begin
  if (APid = 0) or (AAddress = 0) or
     not DecodeHex(LowerCase(AExpectedHex), Expected) or
     not DecodeHex(LowerCase(AReplacementHex), Replacement) or
     (Length(Expected) <> Length(Replacement)) or
     (Length(Expected) > FMaxBytes) or
     (AAddress + QWord(Length(Expected) - 1) < AAddress) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'memory_effect_request_invalid', '{}'));

  ProcessHandle := Windows.OpenProcess(PROCESS_QUERY_INFORMATION or
    PROCESS_VM_READ or PROCESS_VM_WRITE or PROCESS_VM_OPERATION,
    False, APid);
  if ProcessHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized,
      'memory_effect_open_failed', '{}'));
  try
    SetLength(BeforeBytes, Length(Expected));
    BytesRead := 0;
    if not Windows.ReadProcessMemory(ProcessHandle,
      Pointer(PtrUInt(AAddress)), @BeforeBytes[0], Length(BeforeBytes),
      BytesRead) or (BytesRead <> SIZE_T(Length(BeforeBytes))) then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'memory_effect_precheck_read_failed', '{}'));
    if not CompareMem(@BeforeBytes[0], @Expected[0], Length(Expected)) then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'memory_effect_original_changed', '{"before":"' +
        EncodeHex(BeforeBytes) + '"}'));

    BytesWritten := 0;
    if not Windows.WriteProcessMemory(ProcessHandle,
      Pointer(PtrUInt(AAddress)), @Replacement[0], Length(Replacement),
      BytesWritten) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'memory_effect_write_failed', '{}'));
    if BytesWritten <> SIZE_T(Length(Replacement)) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'memory_effect_partial_write', '{}'));

    SetLength(AfterBytes, Length(Replacement));
    BytesRead := 0;
    if not Windows.ReadProcessMemory(ProcessHandle,
      Pointer(PtrUInt(AAddress)), @AfterBytes[0], Length(AfterBytes),
      BytesRead) or (BytesRead <> SIZE_T(Length(AfterBytes))) then
      Exit(TCEAResult.Error(rcUnknownOutcome,
        'memory_effect_readback_failed', '{}'));
    if not CompareMem(@AfterBytes[0], @Replacement[0],
      Length(Replacement)) then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'memory_effect_readback_mismatch', '{"after":"' +
        EncodeHex(AfterBytes) + '"}'));
    Result := TCEAResult.Ok('{"pid":' + IntToStr(APid) +
      ',"address":"0x' + LowerCase(IntToHex(AAddress, 16)) +
      '","before":"' + EncodeHex(BeforeBytes) +
      '","after":"' + EncodeHex(AfterBytes) +
      '","readback_verified":true}');
  finally
    CloseHandle(ProcessHandle);
  end;
end;

end.
