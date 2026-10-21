unit cea_ct_draft_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_types, cea_results, cea_ports, cea_reverse_types,
  cea_ct_draft_types, cea_ct_draft_ports;

type
  TCEACTDraftService = class
  private
    FResolver: ICEACTDraftSourceResolver;
    FRepository: ICEACTDraftRepository;
    FHasher: ICEAHasher;
    FClock: ICEAClock;
    function FieldFailure(const ACode: TCEAResultCode;
      const APointer: string): TCEAResult;
    function BuildDraft(const AProposal: TCEACTDraftProposal;
      const AParentId: string; const ARevision: Cardinal;
      out ADraft: TCEACTDraft): TCEAResult;
  public
    constructor Create(const AResolver: ICEACTDraftSourceResolver;
      const ARepository: ICEACTDraftRepository; const AHasher: ICEAHasher;
      const AClock: ICEAClock);
    function Propose(const AProposal: TCEACTDraftProposal;
      out ADraft: TCEACTDraft): TCEAResult;
    function Revalidate(const ADraftId: string;
      out ADraft: TCEACTDraft): TCEAResult;
    function Abandon(const ADraftId: string;
      out ADraft: TCEACTDraft): TCEAResult;
  end;

implementation

uses
  Classes, FPJSON, JSONParser, cea_ct_draft_canonical;

constructor TCEACTDraftService.Create(const AResolver: ICEACTDraftSourceResolver;
  const ARepository: ICEACTDraftRepository; const AHasher: ICEAHasher;
  const AClock: ICEAClock);
begin
  inherited Create;
  FResolver := AResolver; FRepository := ARepository;
  FHasher := AHasher; FClock := AClock;
end;

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(StringReplace(S, '\', '\\', [rfReplaceAll]),
    '"', '\"', [rfReplaceAll]);
end;

function TCEACTDraftService.FieldFailure(const ACode: TCEAResultCode;
  const APointer: string): TCEAResult;
begin
  Result := TCEAResult.Error(ACode, ResultCodeToStableCode(ACode),
    '{"pointer":"' + JsonEscape(APointer) + '"}');
end;

function ParseStrings(const AJson: string;
  out AValues: TCEACTDraftStringArray): Boolean;
var D:TJSONData; A:TJSONArray; I:Integer;
begin
  SetLength(AValues,0); D:=nil;
  try D:=GetJSON(AJson); if D.JSONType<>jtArray then Exit(False);
    A:=TJSONArray(D); SetLength(AValues,A.Count);
    for I:=0 to A.Count-1 do begin if A.Items[I].JSONType<>jtString then Exit(False); AValues[I]:=A.Strings[I]; end;
    Result:=True;
  except Result:=False; end;
  D.Free;
end;

function SortedIdsJson(const AEvidence: array of TCEAEvidenceReference): string;
var L:TStringList; A:TJSONArray; I:Integer;
begin
  L:=TStringList.Create; A:=TJSONArray.Create;
  try L.Sorted:=True; L.Duplicates:=dupIgnore;
    for I:=0 to High(AEvidence) do L.Add(AEvidence[I].Id);
    for I:=0 to L.Count-1 do A.Add(L[I]); Result:=A.AsJSON;
  finally A.Free; L.Free; end;
end;

function SortedProofIdsJson(const AProofs: array of TCEAProof): string;
var L:TStringList; A:TJSONArray; I:Integer;
begin
  L:=TStringList.Create; A:=TJSONArray.Create;
  try L.Sorted:=True; L.Duplicates:=dupIgnore;
    for I:=0 to High(AProofs) do L.Add(AProofs[I].Id);
    for I:=0 to L.Count-1 do A.Add(L[I]); Result:=A.AsJSON;
  finally A.Free; L.Free; end;
end;

function SourceHashesJson(const B:TCEACTDraftSourceBundle):string;
var Keys:TStringList; I,P:Integer; O:TJSONObject; Key,Value:string;
begin
  Keys:=TStringList.Create; O:=TJSONObject.Create;
  try Keys.Sorted:=True; Keys.Duplicates:=dupIgnore; Keys.NameValueSeparator:='=';
    for I:=0 to High(B.Evidence) do Keys.Values[B.Evidence[I].Id]:=B.Evidence[I].ContentHash;
    for I:=0 to High(B.Proofs) do Keys.Values[B.Proofs[I].Id]:=B.Proofs[I].VerificationHash;
    for I:=0 to Keys.Count-1 do begin P:=Pos('=',Keys[I]); Key:=Copy(Keys[I],1,P-1); Value:=Copy(Keys[I],P+1,MaxInt); O.Add(Key,Value); end;
    Result:=O.AsJSON;
  finally O.Free; Keys.Free; end;
end;

function FindCandidate(const B:TCEACTDraftSourceBundle; const AId:string;
  out C:TCEACandidateLocation):Boolean;
var I:Integer;
begin
  for I:=0 to High(B.Candidates) do if B.Candidates[I].Id=AId then begin C:=B.Candidates[I]; Exit(True); end;
  FillChar(C,SizeOf(C),0); Result:=False;
end;

function SemanticKey(const E:TCEACTDraftEntry):string;
var I:Integer;
begin
  Result:=CTDraftEntryKindText(E.Kind)+'|'+LowerCase(E.ModuleName)+'|'+LowerCase(E.AddressText)+'|'+CTDraftValueTypeId(E.ValueType);
  for I:=0 to High(E.PointerOffsets) do Result:=Result+'|'+LowerCase(E.PointerOffsets[I]);
end;

function HexFitsQWord(const AValue: string): Boolean;
var I: Integer;
begin
  Result := (Length(AValue) > 2) and
    (Copy(AValue, 1, 2) = '0x') and (Length(AValue) <= 18);
  if not Result then Exit;
  for I := 3 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

function TCEACTDraftService.BuildDraft(const AProposal:TCEACTDraftProposal;
  const AParentId:string; const ARevision:Cardinal; out ADraft:TCEACTDraft):TCEAResult;
var B:TCEACTDraftSourceBundle; C:TCEACandidateLocation; E:TCEACTDraftEntry;
  I,J,CurrentGroup:Integer; Values:TCEACTDraftStringArray; Keys:TStringList;
  Findings:TJSONArray; Finding:TJSONObject; Canonical,Key:string;
begin
  FillChar(ADraft,SizeOf(ADraft),0);
  if (FResolver=nil) or (FRepository=nil) or (FHasher=nil) or (FClock=nil) then
    Exit(TCEAResult.Error(rcInternalError,'ct_draft_service_dependency_missing','{}'));
  if Length(AProposal.Entries)>CECTDraftMaxEntries then Exit(FieldFailure(rcCTDraftBudgetExceeded,'/entries'));
  if Length(AProposal.Entries)=0 then Exit(TCEAResult.Error(rcInvalidArgument,'ct_draft_proposal_invalid','{}'));
  for I:=0 to High(AProposal.Entries) do begin
    if Length(AProposal.Entries[I].Description)>CECTDraftMaxDescriptionBytes then Exit(FieldFailure(rcCTDraftBudgetExceeded,'/entries/'+IntToStr(I)+'/description'));
    if not IsCTDraftXml10Text(AProposal.Entries[I].Description) then Exit(FieldFailure(rcCTDraftXmlCharacterInvalid,'/entries/'+IntToStr(I)+'/description'));
  end;
  Result:=FResolver.Resolve(AProposal,B); if Result.Failed then Exit;
  ADraft.ParentDraftId:=AParentId; ADraft.Revision:=ARevision; ADraft.SchemaVersion:='1.0'; ADraft.State:=dsValidated;
  ADraft.GameName:=AProposal.GameName; ADraft.GameVersion:=AProposal.GameVersion;
  ADraft.TargetExecutableSha256:=B.TargetExecutableSha256; ADraft.ModuleSetHash:=B.ModuleSetHash;
  ADraft.CompatibilityHash:=B.Recipe.CompatibilityHash; ADraft.RecipeId:=B.Recipe.Id;
  ADraft.VerificationRunId:=B.Verification.Id; ADraft.EvidenceIdsJson:=SortedIdsJson(B.Evidence);
  ADraft.ProofIdsJson:=SortedProofIdsJson(B.Proofs); ADraft.SourceHashesJson:=SourceHashesJson(B);
  ADraft.GeneratorVersion:='ct-draft-v1'; ADraft.FindingsJson:='[]'; ADraft.FailureModesJson:='[]';
  ADraft.CreatedAt:=FClock.UtcNowIso8601; ADraft.UpdatedAt:=ADraft.CreatedAt;
  SetLength(ADraft.Entries,Length(AProposal.Entries)); CurrentGroup:=-1;
  Keys:=TStringList.Create; Findings:=TJSONArray.Create;
  try Keys.Sorted:=True; Keys.Duplicates:=dupError;
    for I:=0 to High(AProposal.Entries) do begin
      FillChar(E,SizeOf(E),0); E.Ordinal:=I; E.ParentOrdinal:=CurrentGroup;
      E.Kind:=AProposal.Entries[I].RequestedKind; E.Description:=AProposal.Entries[I].Description;
      E.ValueType:=AProposal.Entries[I].RequestedValueType;
      if E.Kind=deGroup then begin E.ParentOrdinal:=-1; CurrentGroup:=I; ADraft.Entries[I]:=E; Continue; end;
      if not FindCandidate(B,AProposal.Entries[I].CandidateId,C) then Exit(FieldFailure(rcCTDraftSourceMissing,'/entries/'+IntToStr(I)+'/candidate_id'));
      if not (((E.Kind=deAbsoluteAddress) and (C.Kind=ckAbsoluteAddress)) or ((E.Kind=deModuleOffset) and (C.Kind=ckModuleOffset)) or ((E.Kind=dePointerChain) and (C.Kind=ckPointerChain))) then Exit(FieldFailure(rcCTDraftEntryKindUnsupported,'/entries/'+IntToStr(I)+'/kind'));
      if E.ValueType=dvNone then Exit(FieldFailure(rcCTDraftValueTypeUnsupported,'/entries/'+IntToStr(I)+'/value_type'));
      E.AddressText:=LowerCase(C.AddressText); E.AddressWidthBits:=C.AddressWidthBits; E.ModuleName:=NormalizeCTDraftModuleName(C.ModuleName);
      if not HexFitsQWord(E.AddressText) then
        Exit(FieldFailure(rcCTDraftBudgetExceeded,
          '/entries/'+IntToStr(I)+'/address'));
      E.CandidateId:=C.Id; E.EvidenceIdsJson:=AProposal.Entries[I].EvidenceIdsJson; E.VerificationOutcome:=voPass; E.CompatibilityHash:=C.CompatibilityHash;
      E.AobEvidenceJson:=C.AobEvidenceJson; if E.AobEvidenceJson='' then E.AobEvidenceJson:='[]';
      if E.Kind=deAbsoluteAddress then begin
        Include(E.RiskFlags,drNonPortable);
        Finding:=TJSONObject.Create;
        Finding.Add('code','absolute_address_non_portable');
        Finding.Add('pointer','/entries/'+IntToStr(I)+'/address');
        Finding.Add('severity','warning');
        Findings.Add(Finding);
      end;
      if E.AobEvidenceJson<>'[]' then Include(E.RiskFlags,drAobEvidenceOnly);
      if E.Kind=dePointerChain then begin
        if not ParseStrings(C.PointerOffsetsJson,Values) then Exit(FieldFailure(rcCTDraftSourceUnverified,'/entries/'+IntToStr(I)+'/pointer_offsets'));
        if Length(Values)>CECTDraftMaxPointerDepth then Exit(FieldFailure(rcCTDraftBudgetExceeded,'/entries/'+IntToStr(I)+'/pointer_offsets'));
        for J := 0 to High(Values) do begin
          if (Length(Values[J]) > CECTDraftMaxOffsetText) or
             not HexFitsQWord(Values[J]) then
            Exit(FieldFailure(rcCTDraftBudgetExceeded,
              '/entries/'+IntToStr(I)+'/pointer_offsets/'+IntToStr(J)));
        end;
        E.PointerOffsets:=Values;
      end;
      if E.ValueType=dvByteArray then begin
        if C.ObservedByteLength=0 then Exit(FieldFailure(rcCTDraftValueTypeUnsupported,'/entries/'+IntToStr(I)+'/value_type'));
        E.ByteArrayLength:=C.ObservedByteLength;
      end;
      if not E.IsValid then Exit(TCEAResult.Error(rcInvalidArgument,'ct_draft_entry_invalid','{"pointer":"/entries/'+IntToStr(I)+'"}'));
      Key:=SemanticKey(E); if Keys.IndexOf(Key)>=0 then Exit(TCEAResult.Error(rcConflict,'ct_draft_duplicate_entry','{"pointer":"/entries/'+IntToStr(I)+'"}'));
      Keys.Add(Key); ADraft.Entries[I]:=E;
    end;
    ADraft.FindingsJson:=Findings.AsJSON;
  finally Findings.Free; Keys.Free; end;
  Canonical:=BuildCTDraftCanonicalJson(ADraft); ADraft.ContentHash:=FHasher.HashUtf8(Canonical);
  ADraft.Id:='ctdraft:'+Copy(ADraft.ContentHash,8,32)+':'+IntToStr(ARevision);
  if not ADraft.IsValid then Exit(TCEAResult.Error(rcInvalidArgument,'ct_draft_invalid','{}'));
  Result:=FRepository.SaveDraft(ADraft);
  if not Result.Failed then Result:=TCEAResult.Ok('{"draft_id":"'+ADraft.Id+'"}');
end;

function TCEACTDraftService.Propose(const AProposal:TCEACTDraftProposal; out ADraft:TCEACTDraft):TCEAResult;
begin Result:=BuildDraft(AProposal,'',1,ADraft); end;

function TCEACTDraftService.Revalidate(const ADraftId:string; out ADraft:TCEACTDraft):TCEAResult;
var Old:TCEACTDraft; P:TCEACTDraftProposal; I:Integer;
begin
  Result:=FRepository.LoadDraft(ADraftId,Old); if Result.Failed then Exit;
  P.SchemaVersion:='1.0'; P.RecipeId:=Old.RecipeId; P.VerificationRunId:=Old.VerificationRunId; P.GameName:=Old.GameName; P.GameVersion:=Old.GameVersion;
  SetLength(P.Entries,Length(Old.Entries));
  for I:=0 to High(Old.Entries) do begin P.Entries[I].CandidateId:=Old.Entries[I].CandidateId; P.Entries[I].Description:=Old.Entries[I].Description; P.Entries[I].RequestedKind:=Old.Entries[I].Kind; P.Entries[I].RequestedValueType:=Old.Entries[I].ValueType; P.Entries[I].Order:=I; P.Entries[I].EvidenceIdsJson:=Old.Entries[I].EvidenceIdsJson; if Old.Entries[I].Kind=deGroup then P.Entries[I].EvidenceIdsJson:='[]'; P.Entries[I].ProofIdsJson:=Old.ProofIdsJson; end;
  Result:=BuildDraft(P,Old.Id,Old.Revision+1,ADraft);
end;

function TCEACTDraftService.Abandon(const ADraftId:string; out ADraft:TCEACTDraft):TCEAResult;
var Old:TCEACTDraft;
begin
  Result:=FRepository.LoadDraft(ADraftId,Old); if Result.Failed then Exit;
  ADraft:=Old; ADraft.ParentDraftId:=Old.Id; ADraft.Revision:=Old.Revision+1; ADraft.State:=dsInvalidated; ADraft.UpdatedAt:=FClock.UtcNowIso8601;
  ADraft.Id:='ctdraft:'+Copy(ADraft.ContentHash,8,32)+':'+IntToStr(ADraft.Revision);
  Result:=FRepository.SaveDraft(ADraft);
end;

end.
