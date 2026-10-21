unit cea_process_capability;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_runtime_backend_ports;

type
  TCEAProcessIdentityService = class
  private
    FHasher: ICEAHasher;
    FLastSignature: string;
    FEpoch: QWord;
  public
    constructor Create(const AHasher: ICEAHasher);
    function Observe(const AInfo: TCEARuntimeProcessInfo;
      const AClassification: TCETargetClassification;
      out AIdentity: TCEProcessIdentity): TCEAResult;
  end;

  TCEAProcessCapability = class
  private
    FBackend: ICEAReadOnlyRuntimeBackend;
    FIdentities: TCEAProcessIdentityService;
    FCurrent: TCEProcessIdentity;
    FAttached: Boolean;
    FAttachmentSerial: QWord;
  public
    constructor Create(const ABackend: ICEAReadOnlyRuntimeBackend;
      const AIdentities: TCEAProcessIdentityService);
    function ListProcesses: TCEAResult;
    function Attach(const ARequest: TCEAttachRequest;
      const AClassification: TCETargetClassification;
      out AIdentity: TCEProcessIdentity): TCEAResult;
    function Detach(const AIdentity: TCEProcessIdentity): TCEAResult;
    function Current(out AIdentity: TCEProcessIdentity): TCEAResult;
    property AttachmentSerial: QWord read FAttachmentSerial;
  end;

implementation

function LooksLikeSha256(const AValue: string): Boolean;
var
  Index: Integer;
begin
  Result := (Length(AValue) = 71) and (Copy(AValue, 1, 7) = 'sha256:');
  if not Result then
    Exit;
  for Index := 8 to Length(AValue) do
    if not (AValue[Index] in ['0'..'9', 'a'..'f']) then
      Exit(False);
end;

function NormalizePathForIdentity(const AValue: string): string;
begin
  Result := LowerCase(StringReplace(AValue, '/', '\', [rfReplaceAll]));
end;

constructor TCEAProcessIdentityService.Create(const AHasher: ICEAHasher);
begin
  inherited Create;
  FHasher := AHasher;
end;

function TCEAProcessIdentityService.Observe(
  const AInfo: TCEARuntimeProcessInfo;
  const AClassification: TCETargetClassification;
  out AIdentity: TCEProcessIdentity): TCEAResult;
var
  NormalizedPath, PathHash, Signature, IdentityHash: string;
begin
  if FHasher = nil then
    Exit(TCEAResult.Error(rcInternalError, 'identity_hasher_missing', '{}'));
  if (AInfo.Pid = 0) or (AInfo.StartedAt = '') or
     (AInfo.ExecutablePath = '') or
     not LooksLikeSha256(AInfo.ExecutableSha256) or
     not LooksLikeSha256(AInfo.ModuleSetHash) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'process_identity_input_invalid', '{}'));
  if AClassification <> tcSinglePlayerOffline then
    Exit(TCEAResult.Error(rcTargetNotOffline, 'target_not_offline', '{}'));

  NormalizedPath := NormalizePathForIdentity(AInfo.ExecutablePath);
  PathHash := FHasher.HashUtf8(NormalizedPath);
  Signature := IntToStr(AInfo.Pid) + #0 + AInfo.StartedAt + #0 + PathHash +
    #0 + AInfo.ExecutableSha256 + #0 + IntToStr(Ord(AInfo.Architecture)) +
    #0 + AInfo.ModuleSetHash;
  if (FEpoch = 0) or (Signature <> FLastSignature) then
  begin
    Inc(FEpoch);
    FLastSignature := Signature;
  end;
  IdentityHash := FHasher.HashUtf8(Signature);

  AIdentity.Id := 'process-' + Copy(IdentityHash, 8, 32);
  AIdentity.Pid := AInfo.Pid;
  AIdentity.StartedAt := AInfo.StartedAt;
  AIdentity.ExecutablePathHash := PathHash;
  AIdentity.ExecutableSha256 := AInfo.ExecutableSha256;
  AIdentity.Architecture := AInfo.Architecture;
  AIdentity.ModuleSetHash := AInfo.ModuleSetHash;
  AIdentity.Epoch := FEpoch;
  AIdentity.TargetClassification := AClassification;
  Result := TCEAResult.Ok('{"process_identity_id":"' + AIdentity.Id +
    '","epoch":' + IntToStr(AIdentity.Epoch) + '}');
end;

constructor TCEAProcessCapability.Create(
  const ABackend: ICEAReadOnlyRuntimeBackend;
  const AIdentities: TCEAProcessIdentityService);
begin
  inherited Create;
  FBackend := ABackend;
  FIdentities := AIdentities;
end;

function TCEAProcessCapability.ListProcesses: TCEAResult;
begin
  if FBackend = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ce_runtime_backend_missing', '{}'));
  Result := FBackend.ListProcesses;
end;

function TCEAProcessCapability.Attach(const ARequest: TCEAttachRequest;
  const AClassification: TCETargetClassification;
  out AIdentity: TCEProcessIdentity): TCEAResult;
var
  Info: TCEARuntimeProcessInfo;
begin
  if (ARequest.TaskId = '') or (ARequest.LeaseId = '') or
     (ARequest.Pid = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'attach_request_invalid', '{}'));
  if not ARequest.OperatorAttestsAuthorizedDebugging then
    Exit(TCEAResult.Error(rcUnauthorized,
      'operator_attestation_required', '{}'));
  if AClassification <> tcSinglePlayerOffline then
    Exit(TCEAResult.Error(rcTargetNotOffline, 'target_not_offline', '{}'));
  if (FBackend = nil) or (FIdentities = nil) then
    Exit(TCEAResult.Error(rcInternalError,
      'process_capability_dependencies_missing', '{}'));
  Result := FBackend.QueryProcessInfo(ARequest.Pid, Info);
  if Result.Failed then
    Exit;
  if Info.Pid <> ARequest.Pid then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'queried_process_changed', '{}'));
  Result := FIdentities.Observe(Info, AClassification, AIdentity);
  if Result.Failed then
    Exit;
  Result := FBackend.AttachReadOnly(ARequest.Pid);
  if Result.Failed then
    Exit;
  FCurrent := AIdentity;
  FAttached := True;
  Inc(FAttachmentSerial);
  Result := TCEAResult.Ok('{"process_identity_id":"' + AIdentity.Id + '"}');
end;

function TCEAProcessCapability.Detach(
  const AIdentity: TCEProcessIdentity): TCEAResult;
begin
  if not FAttached then
    Exit(TCEAResult.Error(rcConflict, 'process_not_attached', '{}'));
  if (AIdentity.Id <> FCurrent.Id) or (AIdentity.Epoch <> FCurrent.Epoch) then
    Exit(TCEAResult.Error(rcStaleProcessIdentity,
      'detach_target_changed', '{}'));
  Result := FBackend.Detach;
  if not Result.Failed then
  begin
    FAttached := False;
    Inc(FAttachmentSerial);
    FillChar(FCurrent, SizeOf(FCurrent), 0);
  end;
end;

function TCEAProcessCapability.Current(
  out AIdentity: TCEProcessIdentity): TCEAResult;
begin
  if not FAttached then
    Exit(TCEAResult.Error(rcConflict, 'process_not_attached', '{}'));
  AIdentity := FCurrent;
  Result := TCEAResult.Ok('{}');
end;

end.
