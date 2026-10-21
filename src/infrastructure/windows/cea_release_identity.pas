unit cea_release_identity;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results;

type
  TCEAWindowsWarningClass = (wwcOther, wwcAntivirus, wwcSmartScreen);

  TCEAReleaseIdentityInfo = record
    Version: string;
    BuildChannel: string;
    Sha256: string;
    SignatureStatus: string;
    ByteCount: Int64;
  end;

  TCEAReleaseIdentity = class
  public
    function ReadCurrent(out AIdentity: TCEAReleaseIdentityInfo): TCEAResult;
  end;

function ClassifyWindowsWarning(
  const AMessage: string): TCEAWindowsWarningClass;

implementation

uses
  Classes, Windows, FPJSON, cea_windows_sha256;

type
  PWinTrustFileInfo = ^TWinTrustFileInfo;
  TWinTrustFileInfo = record
    cbStruct: DWORD;
    pcwszFilePath: PWideChar;
    hFile: THandle;
    pgKnownSubject: PGUID;
  end;

  TWinTrustData = record
    cbStruct: DWORD;
    pPolicyCallbackData: Pointer;
    pSIPClientData: Pointer;
    dwUIChoice: DWORD;
    fdwRevocationChecks: DWORD;
    dwUnionChoice: DWORD;
    pFile: PWinTrustFileInfo;
    dwStateAction: DWORD;
    hWVTStateData: THandle;
    pwszURLReference: PWideChar;
    dwProvFlags: DWORD;
    dwUIContext: DWORD;
    pSignatureSettings: Pointer;
  end;

const
  WTD_UI_NONE = 2;
  WTD_REVOKE_NONE = 0;
  WTD_CHOICE_FILE = 1;
  WTD_STATEACTION_VERIFY = 1;
  WTD_STATEACTION_CLOSE = 2;
  WTD_CACHE_ONLY_URL_RETRIEVAL = $00001000;
  TRUST_E_NOSIGNATURE = $800B0100;
  TRUST_E_SUBJECT_FORM_UNKNOWN = $800B0003;
  TRUST_E_PROVIDER_UNKNOWN = $800B0001;

function WinVerifyTrust(hwnd: HWND; pgActionID: PGUID;
  pWVTData: Pointer): LongInt; stdcall;
  external 'wintrust.dll' name 'WinVerifyTrust';

function SignatureStatusForFile(const APath: string): string;
var
  ActionId: TGUID;
  FileInfo: TWinTrustFileInfo;
  TrustData: TWinTrustData;
  WidePath: UnicodeString;
  Status: LongInt;
begin
  Result := 'unknown';
  WidePath := UTF8Decode(APath);
  ActionId := StringToGUID('{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}');
  FillChar(FileInfo, SizeOf(FileInfo), 0);
  FileInfo.cbStruct := SizeOf(FileInfo);
  FileInfo.pcwszFilePath := PWideChar(WidePath);
  FillChar(TrustData, SizeOf(TrustData), 0);
  TrustData.cbStruct := SizeOf(TrustData);
  TrustData.dwUIChoice := WTD_UI_NONE;
  TrustData.fdwRevocationChecks := WTD_REVOKE_NONE;
  TrustData.dwUnionChoice := WTD_CHOICE_FILE;
  TrustData.pFile := @FileInfo;
  TrustData.dwStateAction := WTD_STATEACTION_VERIFY;
  TrustData.dwProvFlags := WTD_CACHE_ONLY_URL_RETRIEVAL;
  Status := WinVerifyTrust(HWND(-1), @ActionId, @TrustData);
  if Status = 0 then
    Result := 'valid'
  else if (Cardinal(Status) = TRUST_E_NOSIGNATURE) or
          (Cardinal(Status) = TRUST_E_SUBJECT_FORM_UNKNOWN) or
          (Cardinal(Status) = TRUST_E_PROVIDER_UNKNOWN) then
    Result := 'unsigned'
  else
    Result := 'untrusted';
  TrustData.dwStateAction := WTD_STATEACTION_CLOSE;
  WinVerifyTrust(HWND(-1), @ActionId, @TrustData);
end;

function ClassifyWindowsWarning(
  const AMessage: string): TCEAWindowsWarningClass;
var
  Text: string;
begin
  Text := LowerCase(AMessage);
  if (Pos('smartscreen', Text) > 0) or
     (Pos('unrecognized app', Text) > 0) or
     (Pos('protected your pc', Text) > 0) then
    Exit(wwcSmartScreen);
  if (Pos('antivirus', Text) > 0) or (Pos('quarantin', Text) > 0) or
     (Pos('threat', Text) > 0) then
    Exit(wwcAntivirus);
  Result := wwcOther;
end;

function TCEAReleaseIdentity.ReadCurrent(
  out AIdentity: TCEAReleaseIdentityInfo): TCEAResult;
var
  ExecutablePath: string;
  Stream: TFileStream;
  Hasher: TCEAWindowsSha256;
  Projection: TJSONObject;
begin
  FillChar(AIdentity, SizeOf(AIdentity), 0);
  ExecutablePath := ExpandFileName(ParamStr(0));
  if not FileExists(ExecutablePath) then
    Exit(TCEAResult.Error(rcConflict,
      'release_executable_unavailable', '{}'));
  Hasher := TCEAWindowsSha256.Create;
  Stream := nil;
  Projection := nil;
  try
    try
      Stream := TFileStream.Create(ExecutablePath,
        fmOpenRead or fmShareDenyNone);
      AIdentity.ByteCount := Stream.Size;
      FreeAndNil(Stream);
      AIdentity.Version := 'development';
      AIdentity.BuildChannel := 'internal';
      AIdentity.Sha256 := Hasher.HashFile(ExecutablePath);
      AIdentity.SignatureStatus := SignatureStatusForFile(ExecutablePath);
      Projection := TJSONObject.Create;
      Projection.Add('version', AIdentity.Version);
      Projection.Add('build_channel', AIdentity.BuildChannel);
      Projection.Add('sha256', AIdentity.Sha256);
      Projection.Add('signature_status', AIdentity.SignatureStatus);
      Projection.Add('byte_count', AIdentity.ByteCount);
      Result := TCEAResult.Ok(Projection.AsJSON);
    except
      Result := TCEAResult.Error(rcInternalError,
        'release_identity_read_failed', '{}');
    end;
  finally
    Projection.Free;
    Stream.Free;
    Hasher.Free;
  end;
end;

end.
