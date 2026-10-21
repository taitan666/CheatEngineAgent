unit cea_secret_store;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_ports, cea_results, cea_llm_provider;

type
  TCEASecretStore = class(TObject, ISecretStore, ICEASecretValueProvider)
  public
    function SaveValue(const ASecretRef, AValue: string): TCEAResult;
    function DeleteValue(const ASecretRef: string): TCEAResult;
    function ResolveSecret(const ASecretRef: string): TCEAResult;
    function ResolveValue(const ASecretRef: string;
      out AValue: string): TCEAResult;
  end;

implementation

uses
  SysUtils, Windows;

type
  PCredentialW = ^TCredentialW;
  TCredentialW = record
    Flags: DWORD;
    CredentialType: DWORD;
    TargetName: PWideChar;
    Comment: PWideChar;
    LastWritten: TFileTime;
    CredentialBlobSize: DWORD;
    CredentialBlob: PByte;
    Persist: DWORD;
    AttributeCount: DWORD;
    Attributes: Pointer;
    TargetAlias: PWideChar;
    UserName: PWideChar;
  end;

const
  CRED_TYPE_GENERIC = 1;
  CRED_PERSIST_LOCAL_MACHINE = 2;
  ERROR_NOT_FOUND_CODE = 1168;

function CredReadW(const TargetName: PWideChar; const CredentialType,
  Flags: DWORD; out Credential: PCredentialW): BOOL; stdcall;
  external 'advapi32.dll';
function CredWriteW(const Credential: PCredentialW;
  const Flags: DWORD): BOOL; stdcall; external 'advapi32.dll';
function CredDeleteW(const TargetName: PWideChar; const CredentialType,
  Flags: DWORD): BOOL; stdcall; external 'advapi32.dll';
procedure CredFree(const Buffer: Pointer); stdcall; external 'advapi32.dll';

function TCEASecretStore.SaveValue(const ASecretRef,
  AValue: string): TCEAResult;
var
  Credential: TCredentialW;
  Target, UserName: UnicodeString;
  Raw: RawByteString;
begin
  if (Trim(ASecretRef) = '') or (AValue = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'credential_manager_secret_invalid', '{}'));
  Raw := UTF8Encode(UTF8Decode(AValue));
  if Length(Raw) > 2560 then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'credential_manager_secret_too_large', '{}'));
  Target := UTF8Decode(ASecretRef);
  UserName := 'CheatEngineAgent';
  FillChar(Credential, SizeOf(Credential), 0);
  Credential.CredentialType := CRED_TYPE_GENERIC;
  Credential.TargetName := PWideChar(Target);
  Credential.CredentialBlobSize := Length(Raw);
  Credential.CredentialBlob := PByte(PAnsiChar(Raw));
  Credential.Persist := CRED_PERSIST_LOCAL_MACHINE;
  Credential.UserName := PWideChar(UserName);
  if CredWriteW(@Credential, 0) then
    Result := TCEAResult.Ok(
      '{"saved":true,"destination":"windows_credential_manager"}')
  else
    Result := TCEAResult.Error(rcUnknownOutcome,
      'credential_manager_secret_save_failed', '{}');
  Raw := StringOfChar(#0, Length(Raw));
end;

function TCEASecretStore.DeleteValue(
  const ASecretRef: string): TCEAResult;
var
  Target: UnicodeString;
begin
  if Trim(ASecretRef) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'secret_ref_required', '{}'));
  Target := UTF8Decode(ASecretRef);
  if CredDeleteW(PWideChar(Target), CRED_TYPE_GENERIC, 0) or
     (GetLastError = ERROR_NOT_FOUND_CODE) then
    Result := TCEAResult.Ok('{"deleted":true}')
  else
    Result := TCEAResult.Error(rcUnknownOutcome,
      'credential_manager_secret_delete_failed', '{}');
end;

function TCEASecretStore.ResolveValue(const ASecretRef: string;
  out AValue: string): TCEAResult;
var
  Credential: PCredentialW;
  Target: UnicodeString;
  Raw: RawByteString;
  WideValue: UnicodeString;
  I: Integer;
  LooksWide: Boolean;
begin
  AValue := '';
  if Trim(ASecretRef) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'secret_ref_required', '{}'));
  Target := UTF8Decode(ASecretRef);
  Credential := nil;
  if not CredReadW(PWideChar(Target), CRED_TYPE_GENERIC, 0, Credential) then
    Exit(TCEAResult.Error(rcUnauthenticated,
      'credential_manager_secret_not_found', '{}'));
  try
    if (Credential = nil) or (Credential^.CredentialBlobSize = 0) then
      Exit(TCEAResult.Error(rcUnauthenticated,
        'credential_manager_secret_empty', '{}'));
    LooksWide := (Credential^.CredentialBlobSize mod 2 = 0);
    if LooksWide then
      for I := 1 to (Credential^.CredentialBlobSize div 2) - 1 do
        if Credential^.CredentialBlob[I * 2 - 1] <> 0 then
        begin
          LooksWide := False;
          Break;
        end;
    if LooksWide then
    begin
      SetString(WideValue, PWideChar(Credential^.CredentialBlob),
        Credential^.CredentialBlobSize div 2);
      AValue := UTF8Encode(WideValue);
    end
    else
    begin
      SetString(Raw, PAnsiChar(Credential^.CredentialBlob),
        Credential^.CredentialBlobSize);
      AValue := Raw;
    end;
    Result := TCEAResult.Ok('{"resolved":true,"source":"windows_credential_manager"}');
  finally
    CredFree(Credential);
  end;
end;

function TCEASecretStore.ResolveSecret(
  const ASecretRef: string): TCEAResult;
var
  Value: string;
begin
  Result := ResolveValue(ASecretRef, Value);
  Value := StringOfChar(#0, Length(Value));
  Value := '';
end;

end.
