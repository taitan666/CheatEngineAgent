unit cea_ct_draft_canonical;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_ct_draft_types;

function BuildCTDraftCanonicalJson(const ADraft: TCEACTDraft): string;
function IsCTDraftXml10Text(const AText: string): Boolean;
function NormalizeCTDraftModuleName(const AValue: string): string;

implementation

uses
  FPJSON, JSONParser;

function IsCTDraftXml10Text(const AText: string): Boolean;
var I, V: Integer;
begin
  for I := 1 to Length(AText) do begin
    V := Ord(AText[I]);
    if (V < 32) and not (V in [9, 10, 13]) then Exit(False);
  end;
  Result := True;
end;

function NormalizeCTDraftModuleName(const AValue: string): string;
begin
  Result := LowerCase(ExtractFileName(StringReplace(AValue, '/', '\',
    [rfReplaceAll])));
end;

function ParsedJson(const AJson, AFallback: string): TJSONData;
begin
  try Result := GetJSON(AJson);
  except Result := GetJSON(AFallback); end;
end;

function RiskJson(const AFlags: TCEACTDraftRiskFlags): TJSONArray;
begin
  Result := TJSONArray.Create;
  if drNonPortable in AFlags then Result.Add('non_portable');
  if drVersionBound in AFlags then Result.Add('version_bound');
  if drAobEvidenceOnly in AFlags then Result.Add('aob_evidence_only');
end;

function BuildCTDraftCanonicalJson(const ADraft: TCEACTDraft): string;
var Root, E: TJSONObject; Entries, Offsets: TJSONArray; I, J: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('schema_version', ADraft.SchemaVersion);
    Root.Add('game_name', ADraft.GameName);
    Root.Add('game_version', ADraft.GameVersion);
    Root.Add('target_executable_sha256', ADraft.TargetExecutableSha256);
    Root.Add('module_set_hash', ADraft.ModuleSetHash);
    Root.Add('compatibility_hash', ADraft.CompatibilityHash);
    Root.Add('recipe_id', ADraft.RecipeId);
    Root.Add('verification_run_id', ADraft.VerificationRunId);
    Root.Add('evidence_ids', ParsedJson(ADraft.EvidenceIdsJson, '[]'));
    Root.Add('proof_ids', ParsedJson(ADraft.ProofIdsJson, '[]'));
    Root.Add('source_hashes', ParsedJson(ADraft.SourceHashesJson, '{}'));
    Root.Add('generator_version', ADraft.GeneratorVersion);
    Entries := TJSONArray.Create;
    Root.Add('entries', Entries);
    for I := 0 to High(ADraft.Entries) do begin
      E := TJSONObject.Create; Entries.Add(E);
      E.Add('ordinal', ADraft.Entries[I].Ordinal);
      E.Add('parent_ordinal', ADraft.Entries[I].ParentOrdinal);
      E.Add('kind', CTDraftEntryKindText(ADraft.Entries[I].Kind));
      E.Add('description', ADraft.Entries[I].Description);
      E.Add('value_type', CTDraftValueTypeId(ADraft.Entries[I].ValueType));
      E.Add('address_width_bits', ADraft.Entries[I].AddressWidthBits);
      E.Add('address', LowerCase(ADraft.Entries[I].AddressText));
      E.Add('module_name', ADraft.Entries[I].ModuleName);
      Offsets := TJSONArray.Create; E.Add('pointer_offsets', Offsets);
      for J := 0 to High(ADraft.Entries[I].PointerOffsets) do
        Offsets.Add(LowerCase(ADraft.Entries[I].PointerOffsets[J]));
      E.Add('byte_array_length', ADraft.Entries[I].ByteArrayLength);
      E.Add('candidate_id', ADraft.Entries[I].CandidateId);
      E.Add('evidence_ids', ParsedJson(ADraft.Entries[I].EvidenceIdsJson, '[]'));
      E.Add('verification_outcome', 'pass');
      E.Add('compatibility_hash', ADraft.Entries[I].CompatibilityHash);
      E.Add('risk_flags', RiskJson(ADraft.Entries[I].RiskFlags));
      E.Add('aob_evidence', ParsedJson(ADraft.Entries[I].AobEvidenceJson, '[]'));
    end;
    Root.Add('findings', ParsedJson(ADraft.FindingsJson, '[]'));
    Root.Add('failure_modes', ParsedJson(ADraft.FailureModesJson, '[]'));
    Result := Root.AsJSON;
  finally Root.Free; end;
end;

end.

