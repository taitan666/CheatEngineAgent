unit cea_save_discovery_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Windows, cea_results, cea_save_discovery_types,
  cea_win32_save_discovery;

type
  TCEASaveDiscoveryService = class
  private
    FScope: TCEADiscoveryScope;
    FHasScope: Boolean;
    FCancelFlag: LongInt;
    FPort: TCEAWin32SaveDiscovery;
    FCandidates: TCEASaveCandidateArray;
    function IsCancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function HasAuthorizedScope: Boolean;
    function AuthorizeDirectory(const ARoot: string;
      const ABudget: TCEADiscoveryBudget;
      out AScope: TCEADiscoveryScope): TCEAResult;
    function Scan(const AScopeId: string;
      out ACandidates: TCEASaveCandidateArray): TCEAResult;
    function SelectCandidate(const AScopeId, ACandidateId: string;
      out ACanonicalPath: string;
      out ACandidate: TCEASaveCandidate): TCEAResult;
    function Cancel(const AScopeId: string): TCEAResult;
    function Revoke(const AScopeId: string): TCEAResult;
  end;

implementation

constructor TCEASaveDiscoveryService.Create;
begin
  inherited Create;
  FPort := TCEAWin32SaveDiscovery.Create;
end;

destructor TCEASaveDiscoveryService.Destroy;
begin
  FPort.Free;
  inherited Destroy;
end;

function TCEASaveDiscoveryService.IsCancelled: Boolean;
begin
  Result := InterlockedCompareExchange(FCancelFlag, 0, 0) <> 0;
end;

function TCEASaveDiscoveryService.HasAuthorizedScope: Boolean;
begin
  Result := FHasScope and not FScope.Revoked;
end;

function TCEASaveDiscoveryService.AuthorizeDirectory(const ARoot: string;
  const ABudget: TCEADiscoveryBudget;
  out AScope: TCEADiscoveryScope): TCEAResult;
var
  Canonical: string;
  NewId: TGUID;
begin
  FillChar(AScope, SizeOf(AScope), 0);
  if (ABudget.MaxFiles < 1) or (ABudget.MaxFiles > 10000) or
     (ABudget.MaxDepth < 0) or (ABudget.MaxDepth > 16) or
     (ABudget.MaxDurationMs < 1) or (ABudget.MaxDurationMs > 60000) then
    Exit(CEAResult(rcInvalidArgument, 'invalid discovery budget'));
  Result := FPort.ValidateRoot(ARoot, Canonical);
  if Result.Failed then Exit;
  CreateGUID(NewId);
  FScope.Id := GUIDToString(NewId);
  FScope.RootPath := Canonical;
  FScope.AuthorizedAt := Now;
  FScope.Budget := ABudget;
  FScope.Revoked := False;
  FHasScope := True;
  InterlockedExchange(FCancelFlag, 0);
  SetLength(FCandidates, 0);
  AScope := FScope;
  Result := TCEAResult.Ok('{}');
end;

function TCEASaveDiscoveryService.Scan(const AScopeId: string;
  out ACandidates: TCEASaveCandidateArray): TCEAResult;
var
  Complete: Boolean;
  Reason, Data: string;
begin
  SetLength(ACandidates, 0);
  if not HasAuthorizedScope or (AScopeId <> FScope.Id) then
    Exit(CEAResult(rcUnauthorized, 'discovery scope is not authorized'));
  if IsCancelled then Exit(CEAResult(rcCancelled, 'discovery cancelled'));
  Result := FPort.Enumerate(FScope, @IsCancelled, ACandidates,
    Complete, Reason);
  if Result.Failed then Exit;
  FCandidates := ACandidates;
  if Complete then Data := 'true' else Data := 'false';
  Result := TCEAResult.Ok('{"complete":' + Data +
    ',"partial_reason":"' + Reason + '","candidate_count":' +
    IntToStr(Length(ACandidates)) + '}');
end;

function TCEASaveDiscoveryService.Cancel(const AScopeId: string): TCEAResult;
begin
  if not HasAuthorizedScope or (AScopeId <> FScope.Id) then
    Exit(CEAResult(rcUnauthorized, 'discovery scope is not authorized'));
  InterlockedExchange(FCancelFlag, 1);
  Result := TCEAResult.Ok('{}');
end;

function TCEASaveDiscoveryService.SelectCandidate(
  const AScopeId, ACandidateId: string;
  out ACanonicalPath: string;
  out ACandidate: TCEASaveCandidate): TCEAResult;
var
  I: Integer;
begin
  ACanonicalPath := '';
  FillChar(ACandidate, SizeOf(ACandidate), 0);
  if not HasAuthorizedScope or (AScopeId <> FScope.Id) then
    Exit(TCEAResult.Error(rcUnauthorized,
      'discovery_scope_not_authorized', '{}'));
  for I := 0 to High(FCandidates) do
    if (FCandidates[I].Id = ACandidateId) and
       (FCandidates[I].ScopeId = AScopeId) then
    begin
      Result := FPort.ValidateCandidate(FScope, FCandidates[I],
        ACanonicalPath);
      if not Result.Failed then ACandidate := FCandidates[I];
      Exit;
    end;
  Result := TCEAResult.Error(rcConflict,
    'save_candidate_not_found', '{}');
end;

function TCEASaveDiscoveryService.Revoke(const AScopeId: string): TCEAResult;
begin
  if not HasAuthorizedScope or (AScopeId <> FScope.Id) then
    Exit(CEAResult(rcUnauthorized, 'discovery scope is not authorized'));
  InterlockedExchange(FCancelFlag, 1);
  FScope.Revoked := True;
  FHasScope := False;
  SetLength(FCandidates, 0);
  Result := TCEAResult.Ok('{}');
end;

end.
