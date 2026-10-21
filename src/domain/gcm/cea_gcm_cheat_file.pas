unit cea_gcm_cheat_file;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage utf8}

interface

uses
  SysUtils;

type
  // Where a candidate cheat table came from. Both sources are untrusted: the
  // file is only ever parsed, never executed.
  TCEACheatFileSource = (
    // Read from the directory GCM already downloaded into
    // (%APPDATA%\GCM Trainers\<folder>\*.ct).
    cfsGcmLibrary,
    // Handed over by the operator through an explicit file path.
    cfsUserImport
  );

  // One cheat table file discovered on disk. SizeBytes is the size observed at
  // scan time; it is re-checked before the file is copied so a file that grew
  // after discovery cannot slip past the limit.
  TCEACheatFileCandidate = record
    Source: TCEACheatFileSource;
    // Absolute path the candidate was found at.
    FilePath: string;
    // File name without directory, used as the display label.
    FileName: UnicodeString;
    // Game name taken from the sibling gcm_info.json, empty when unknown.
    GameName: UnicodeString;
    // Origin tag from gcm_info.json (fling_main, the_cheat_script, ...).
    Origin: UnicodeString;
    // Version string from gcm_info.json, empty when absent.
    Version: UnicodeString;
    SizeBytes: QWord;
    // SHA-256 of the file content, filled in when the candidate is published.
    ContentHash: string;
    function IsValid: Boolean;
  end;

  TCEACheatFileCandidateArray = array of TCEACheatFileCandidate;

  // Outcome of a publish (copy) operation. PublishedPath is only set when the
  // file was fully written and verified.
  TCEACheatFilePublishResult = record
    Candidate: TCEACheatFileCandidate;
    PublishedPath: string;
    MetadataPath: string;
    Replaced: Boolean;
  end;

const
  // Hard ceiling for one cheat table. Real tables are well below 1 MB; the
  // limit exists so a hostile or corrupt file cannot exhaust memory.
  CeaCheatFileMaxBytes = 16 * 1024 * 1024;

  // Directory under the application data directory where imported tables live.
  CeaCheatFileLibraryDirectoryName = 'cheat-tables';

// Normalises a candidate path and rejects anything that escapes ARootDirectory.
// Returns the absolute path when it is safe, an empty string otherwise.
//
// The check is done on the resolved absolute path, so "..\..\Windows\x.ct"
// cannot be smuggled in through a relative path.
function SafeCheatTablePath(const ARootDirectory, ACandidatePath: string): string;

// True when the extension is .ct (case insensitive). Anything else is refused
// so a renamed executable cannot be pulled into the library.
function IsCheatTableFileName(const AFileName: string): Boolean;

// Deterministic file name for the published copy: "<hash prefix>-<name>.ct".
// The hash prefix keeps two different tables with the same name apart without
// inventing a random identifier.
function PublishedCheatTableName(const AContentHash: string;
  const AFileName: UnicodeString): UnicodeString;

// Stable wire name for a source, used in the metadata sidecar and in the JSON
// returned to the UI.
function CheatFileSourceName(const ASource: TCEACheatFileSource): string;

implementation

function TCEACheatFileCandidate.IsValid: Boolean;
begin
  Result := (FilePath <> '') and (FileName <> '');
end;

function IsCheatTableFileName(const AFileName: string): Boolean;
begin
  Result := SameText(ExtractFileExt(AFileName), '.ct');
end;

function SafeCheatTablePath(const ARootDirectory, ACandidatePath: string): string;
var
  Root, Candidate: string;
begin
  Result := '';
  if (ARootDirectory = '') or (ACandidatePath = '') then
    Exit;
  Root := IncludeTrailingPathDelimiter(ExpandFileName(ARootDirectory));
  Candidate := ExpandFileName(ACandidatePath);
  // Both sides are expanded first, so "." and ".." segments are already
  // resolved by the time the prefix comparison happens.
  if Length(Candidate) <= Length(Root) then
    Exit;
  if not SameText(Copy(Candidate, 1, Length(Root)), Root) then
    Exit;
  Result := Candidate;
end;

function PublishedCheatTableName(const AContentHash: string;
  const AFileName: UnicodeString): UnicodeString;
var
  Digest: string;
  Stem: UnicodeString;
begin
  // Strip the "sha256:" scheme prefix so the prefix is digest hex, not the
  // literal "sha256:abcdef" the caller happens to pass in.
  Digest := AContentHash;
  if Pos(':', Digest) > 0 then
    Digest := Copy(Digest, Pos(':', Digest) + 1, Length(Digest));
  if Length(Digest) > 12 then
    Digest := Copy(Digest, 1, 12);
  Stem := AFileName;
  if Length(Stem) > 4 then
    Stem := Copy(Stem, 1, Length(Stem) - 4);
  Result := UnicodeString(Digest) + '-' + Stem + '.ct';
end;

function CheatFileSourceName(const ASource: TCEACheatFileSource): string;
begin
  case ASource of
    cfsGcmLibrary: Result := 'gcm_library';
    cfsUserImport: Result := 'user_import';
  else
    Result := 'unknown';
  end;
end;

end.
