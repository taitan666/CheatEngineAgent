unit cea_gcm_cheat_library;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  SysUtils, Classes, cea_results, cea_gcm_types, cea_gcm_cheat_file;

type
  // Discovers cheat tables that already sit on this machine and validates
  // operator supplied files. Nothing here downloads, executes or trusts the
  // content: a candidate is a file on disk plus whatever metadata its sibling
  // gcm_info.json claims.
  TCEAGcmCheatLibrary = class
  private
    FTrainersDirectory: string;
    FMaxDepth: Integer;
    procedure ScanDirectory(const ADirectory: string; const ADepth: Integer;
      var ACandidates: TCEACheatFileCandidateArray);
    function ReadSidecarMetadata(const ADirectory: string;
      out AGameName, AOrigin, AVersion: UnicodeString): Boolean;
  public
    constructor Create(const ATrainersDirectory: string;
      const AMaxDepth: Integer = 2);
    destructor Destroy; override;
    function TrainersDirectory: string;
    // Enumerates *.ct files below the GCM trainers directory. A missing
    // directory is reported as an empty list, not as an error, because having
    // never run GCM is a normal state.
    function ScanGcmLibrary(
      out ACandidates: TCEACheatFileCandidateArray): TCEAResult;
    // Validates one operator supplied path. The file must exist, be a .ct and
    // be within the size ceiling; everything else is left to the caller.
    function ImportFromPath(const APath: string;
      out ACandidate: TCEACheatFileCandidate): TCEAResult;
    // Finds the candidate whose file name matches, used to resolve the
    // selection coming back from the UI.
    function FindCandidate(const ACandidates: TCEACheatFileCandidateArray;
      const AFilePath: string; out ACandidate: TCEACheatFileCandidate): Boolean;
  end;

// %APPDATA%\GCM Trainers, the directory GCM extracts downloaded tables into.
function DefaultGcmTrainersDirectory: string;

implementation

uses
  FPJSON, JSONParser;

function DefaultGcmTrainersDirectory: string;
var
  AppData: string;
begin
  AppData := GetEnvironmentVariable('APPDATA');
  if AppData = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(AppData) + 'GCM Trainers';
end;

constructor TCEAGcmCheatLibrary.Create(const ATrainersDirectory: string;
  const AMaxDepth: Integer);
begin
  inherited Create;
  FTrainersDirectory := ATrainersDirectory;
  if AMaxDepth < 1 then
    FMaxDepth := 1
  else
    FMaxDepth := AMaxDepth;
end;

destructor TCEAGcmCheatLibrary.Destroy;
begin
  inherited Destroy;
end;

function TCEAGcmCheatLibrary.TrainersDirectory: string;
begin
  Result := FTrainersDirectory;
end;

function TCEAGcmCheatLibrary.ReadSidecarMetadata(const ADirectory: string;
  out AGameName, AOrigin, AVersion: UnicodeString): Boolean;
var
  Path: string;
  Stream: TFileStream;
  Content: RawByteString;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  AGameName := '';
  AOrigin := '';
  AVersion := '';
  Result := False;
  Path := IncludeTrailingPathDelimiter(ADirectory) + 'gcm_info.json';
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Content, Stream.Size);
    if Length(Content) > 0 then
      Stream.ReadBuffer(Content[1], Length(Content));
  finally
    Stream.Free;
  end;
  // The sidecar is UTF-8. Without the explicit code page fpjson would decode
  // it with the host code page (GBK here) and mangle non-ASCII game names.
  SetCodePage(Content, CP_UTF8, False);
  Data := nil;
  try
    try
      Data := GetJSON(string(Content));
    except
      Exit;
    end;
    if not (Data is TJSONObject) then
      Exit;
    Obj := TJSONObject(Data);
    AGameName := UnicodeString(UTF8Decode(Obj.Get('game_name', '')));
    AOrigin := UnicodeString(UTF8Decode(Obj.Get('origin', '')));
    AVersion := UnicodeString(UTF8Decode(Obj.Get('version', '')));
    Result := True;
  finally
    Data.Free;
  end;
end;

procedure TCEAGcmCheatLibrary.ScanDirectory(const ADirectory: string;
  const ADepth: Integer; var ACandidates: TCEACheatFileCandidateArray);
var
  Search: TSearchRec;
  Found: Integer;
  Candidate: TCEACheatFileCandidate;
  GameName, Origin, Version: UnicodeString;
begin
  if ADepth > FMaxDepth then
    Exit;
  Found := FindFirst(IncludeTrailingPathDelimiter(ADirectory) + '*',
    faAnyFile, Search);
  if Found <> 0 then
    Exit;
  try
    repeat
      if (Search.Name = '.') or (Search.Name = '..') then
        Continue;
      if (Search.Attr and faDirectory) <> 0 then
      begin
        ScanDirectory(IncludeTrailingPathDelimiter(ADirectory) + Search.Name,
          ADepth + 1, ACandidates);
        Continue;
      end;
      if not IsCheatTableFileName(Search.Name) then
        Continue;
      Candidate.Source := cfsGcmLibrary;
      Candidate.FilePath := IncludeTrailingPathDelimiter(ADirectory) +
        Search.Name;
      // Search.Name is an AnsiString in the host code page (CP936 here), so the
      // implicit AnsiString -> UnicodeString conversion decodes it correctly.
      // UTF8Decode would decode it a second time and produce mojibake.
      Candidate.FileName := UnicodeString(Search.Name);
      if ReadSidecarMetadata(ADirectory, GameName, Origin, Version) then
      begin
        Candidate.GameName := GameName;
        Candidate.Origin := Origin;
        Candidate.Version := Version;
      end
      else
      begin
        Candidate.GameName := '';
        Candidate.Origin := '';
        Candidate.Version := '';
      end;
      Candidate.SizeBytes := QWord(Search.Size);
      Candidate.ContentHash := '';
      SetLength(ACandidates, Length(ACandidates) + 1);
      ACandidates[High(ACandidates)] := Candidate;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
end;

function TCEAGcmCheatLibrary.ScanGcmLibrary(
  out ACandidates: TCEACheatFileCandidateArray): TCEAResult;
begin
  SetLength(ACandidates, 0);
  if FTrainersDirectory = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'gcm_trainers_directory_unset',
      '{}'));
  if not DirectoryExists(FTrainersDirectory) then
    // Never having run GCM is a normal state, not a failure.
    Exit(TCEAResult.Ok('{"candidates":0,"directory_missing":true}'));
  try
    ScanDirectory(FTrainersDirectory, 1, ACandidates);
  except
    Exit(TCEAResult.Error(rcInternalError, 'gcm_library_scan_failed', '{}'));
  end;
  Result := TCEAResult.Ok('{"candidates":' + IntToStr(Length(ACandidates)) +
    ',"directory_missing":false}');
end;

function TCEAGcmCheatLibrary.ImportFromPath(const APath: string;
  out ACandidate: TCEACheatFileCandidate): TCEAResult;
var
  Stream: TFileStream;
  GameName, Origin, Version: UnicodeString;
begin
  FillChar(ACandidate, SizeOf(ACandidate), 0);
  if APath = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_file_path_required', '{}'));
  if not FileExists(APath) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_file_not_found', '{}'));
  if not IsCheatTableFileName(APath) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_file_extension_invalid',
      '{}'));
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if QWord(Stream.Size) > QWord(CeaCheatFileMaxBytes) then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'cheat_file_too_large', '{}'));
    ACandidate.SizeBytes := QWord(Stream.Size);
  finally
    Stream.Free;
  end;
  ACandidate.Source := cfsUserImport;
  ACandidate.FilePath := ExpandFileName(APath);
  ACandidate.FileName := UnicodeString(ExtractFileName(APath));
  if ReadSidecarMetadata(ExtractFileDir(ACandidate.FilePath), GameName, Origin,
    Version) then
  begin
    ACandidate.GameName := GameName;
    ACandidate.Origin := Origin;
    ACandidate.Version := Version;
  end;
  ACandidate.ContentHash := '';
  Result := TCEAResult.Ok('{"size_bytes":' + IntToStr(ACandidate.SizeBytes) + '}');
end;

function TCEAGcmCheatLibrary.FindCandidate(
  const ACandidates: TCEACheatFileCandidateArray; const AFilePath: string;
  out ACandidate: TCEACheatFileCandidate): Boolean;
var
  I: Integer;
  Wanted: string;
begin
  FillChar(ACandidate, SizeOf(ACandidate), 0);
  Result := False;
  if AFilePath = '' then
    Exit;
  Wanted := ExpandFileName(AFilePath);
  for I := 0 to High(ACandidates) do
    if SameText(ACandidates[I].FilePath, Wanted) then
    begin
      ACandidate := ACandidates[I];
      Exit(True);
    end;
end;

end.
