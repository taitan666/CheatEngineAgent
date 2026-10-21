unit cea_windows_sha256;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, Windows, cea_ports;

type
  TCEAWindowsSha256 = class(TObject, ICEAHasher)
  public
    function HashUtf8(const AValue: string): string;
    function HashFile(const APath: string): string;
  end;

implementation

type
  TNTStatus = LongInt;

const
  BCryptDll = 'bcrypt.dll';
  Sha256ByteCount = 32;

function BCryptOpenAlgorithmProvider(out AAlgorithm: THandle;
  const AAlgorithmId, AImplementation: PWideChar;
  const AFlags: Cardinal): TNTStatus; stdcall; external BCryptDll;
function BCryptCloseAlgorithmProvider(const AAlgorithm: THandle;
  const AFlags: Cardinal): TNTStatus; stdcall; external BCryptDll;
function BCryptHash(const AAlgorithm: THandle; const ASecret: PByte;
  const ASecretSize: Cardinal; const AInput: PByte;
  const AInputSize: Cardinal; const AOutput: PByte;
  const AOutputSize: Cardinal): TNTStatus; stdcall; external BCryptDll;

function DigestToHex(const ADigest: array of Byte): string;
const
  Digits = '0123456789abcdef';
var
  Index: Integer;
begin
  SetLength(Result, Length(ADigest) * 2);
  for Index := 0 to High(ADigest) do
  begin
    Result[Index * 2 + 1] := Digits[(ADigest[Index] shr 4) + 1];
    Result[Index * 2 + 2] := Digits[(ADigest[Index] and $0F) + 1];
  end;
end;

function TCEAWindowsSha256.HashUtf8(const AValue: string): string;
var
  Algorithm: THandle;
  AlgorithmName: UnicodeString;
  Digest: array[0..Sha256ByteCount - 1] of Byte;
  InputPointer: PByte;
  Status: TNTStatus;
begin
  if QWord(Length(AValue)) > High(Cardinal) then
    raise ERangeError.Create('SHA-256 input exceeds Windows CNG limit');
  Algorithm := 0;
  AlgorithmName := 'SHA256';
  Status := BCryptOpenAlgorithmProvider(Algorithm,
    PWideChar(AlgorithmName), nil, 0);
  if Status < 0 then
    raise Exception.CreateFmt('BCryptOpenAlgorithmProvider failed: 0x%.8x',
      [Cardinal(Status)]);
  try
    if Length(AValue) = 0 then
      InputPointer := nil
    else
      InputPointer := PByte(Pointer(AValue));
    Status := BCryptHash(Algorithm, nil, 0, InputPointer,
      Length(AValue), @Digest[0], SizeOf(Digest));
    if Status < 0 then
      raise Exception.CreateFmt('BCryptHash failed: 0x%.8x',
        [Cardinal(Status)]);
  finally
    BCryptCloseAlgorithmProvider(Algorithm, 0);
  end;
  Result := 'sha256:' + DigestToHex(Digest);
end;

function TCEAWindowsSha256.HashFile(const APath: string): string;
var
  Stream: TFileStream;
  Bytes: TBytes;
  Value: RawByteString;
begin
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if Stream.Size > High(Cardinal) then
      raise ERangeError.Create('SHA-256 file exceeds Windows CNG input limit');
    SetLength(Bytes, Stream.Size);
    if Length(Bytes) > 0 then
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  SetLength(Value, Length(Bytes));
  if Length(Bytes) > 0 then
    Move(Bytes[0], Value[1], Length(Bytes));
  Result := HashUtf8(Value);
end;

end.
