unit cea_gcm_cheat_publisher;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  SysUtils, Classes, cea_results, cea_ports, cea_gcm_types, cea_gcm_cheat_file;

type
  // Copies a validated cheat table into the application's own library and
  // records where it came from.
  //
  // Publication is atomic: the content is written to a temporary file inside
  // the destination directory, hashed, then renamed over the final name. A
  // crash therefore leaves either the previous file or nothing, never a
  // half-written table.
  TCEAGcmCheatPublisher = class
  private
    FLibraryDirectory: string;
    FHasher: ICEAHasher;
    // ICEAHasher only exposes HashUtf8, so file hashing is done here rather
    // than widening the shared port for one consumer.
    function HashFileContent(const APath: string): string;
    function WriteMetadata(const APublishedPath, AContentHash: string;
      const ACandidate: TCEACheatFileCandidate): Boolean;
  public
    constructor Create(const ALibraryDirectory: string;
      const AHasher: ICEAHasher);
    destructor Destroy; override;
    function LibraryDirectory: string;
    // Validates, copies and hashes one candidate. The result carries the final
    // path plus the SHA-256 of the bytes that actually landed on disk.
    function Publish(const ACandidate: TCEACheatFileCandidate;
      out AResult: TCEACheatFilePublishResult): TCEAResult;
    // Lists what was previously published, so the library survives restarts
    // without rescanning the GCM directory.
    function ListPublished(
      out ACandidates: TCEACheatFileCandidateArray): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser;

const
  MetadataFileName = 'gcm_info.json';
  // RenameFile maps to MoveFileW, which refuses to overwrite an existing
  // target. Republishing the same table must replace it, so the atomic step
  // goes through MoveFileExW with MOVEFILE_REPLACE_EXISTING.
  MoveFileReplaceExisting = $00000001;

function MoveFileExW(const AExisting, ANewName: PWideChar;
  const AFlags: LongWord): LongBool;
  stdcall; external 'kernel32.dll' name 'MoveFileExW';

constructor TCEAGcmCheatPublisher.Create(const ALibraryDirectory: string;
  const AHasher: ICEAHasher);
begin
  inherited Create;
  FLibraryDirectory := ALibraryDirectory;
  FHasher := AHasher;
end;

destructor TCEAGcmCheatPublisher.Destroy;
begin
  inherited Destroy;
end;

function TCEAGcmCheatPublisher.LibraryDirectory: string;
begin
  Result := FLibraryDirectory;
end;

function CopyFileContent(const ASource, ADestination: string): Boolean;
var
  Source, Target: TFileStream;
  Buffer: array[0..65535] of Byte;
  ReadCount: LongInt;
begin
  Result := False;
  Source := TFileStream.Create(ASource, fmOpenRead or fmShareDenyNone);
  try
    Target := TFileStream.Create(ADestination, fmCreate);
    try
      repeat
        ReadCount := Source.Read(Buffer, SizeOf(Buffer));
        if ReadCount > 0 then
          Target.WriteBuffer(Buffer, ReadCount);
      until ReadCount <= 0;
      Result := True;
    finally
      Target.Free;
    end;
  finally
    Source.Free;
  end;
end;

function TCEAGcmCheatPublisher.HashFileContent(const APath: string): string;
var
  Stream: TFileStream;
  Content: RawByteString;
begin
  Result := '';
  if not FileExists(APath) then
    Exit;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Content, Stream.Size);
    if Length(Content) > 0 then
      Stream.ReadBuffer(Content[1], Length(Content));
  finally
    Stream.Free;
  end;
  Result := FHasher.HashUtf8(Content);
end;

function TCEAGcmCheatPublisher.WriteMetadata(const APublishedPath,
  AContentHash: string; const ACandidate: TCEACheatFileCandidate): Boolean;
var
  Obj: TJSONObject;
  Json: UTF8String;
  Stream: TFileStream;
  Bytes: RawByteString;
begin
  Result := False;
  Obj := TJSONObject.Create;
  try
    Obj.Add('game_name', UTF8Encode(ACandidate.GameName));
    Obj.Add('origin', UTF8Encode(ACandidate.Origin));
    Obj.Add('version', UTF8Encode(ACandidate.Version));
    Obj.Add('source', CheatFileSourceName(ACandidate.Source));
    Obj.Add('original_path', ACandidate.FilePath);
    Obj.Add('sha256', AContentHash);
    Obj.Add('size_bytes', Int64(ACandidate.SizeBytes));
    Json := Obj.AsJSON;
  finally
    Obj.Free;
  end;
  Bytes := Json;
  Stream := TFileStream.Create(APublishedPath, fmCreate);
  try
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[1], Length(Bytes));
    Result := True;
  finally
    Stream.Free;
  end;
end;

function TCEAGcmCheatPublisher.Publish(
  const ACandidate: TCEACheatFileCandidate;
  out AResult: TCEACheatFilePublishResult): TCEAResult;
var
  TempPath, FinalPath, Hash, MetaPath: string;
  SafeTemp: string;
  Stream: TFileStream;
  Name: UnicodeString;
begin
  FillChar(AResult, SizeOf(AResult), 0);
  if FHasher = nil then
    Exit(TCEAResult.Error(rcInternalError, 'hasher_required', '{}'));
  if not ACandidate.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_candidate_invalid', '{}'));
  if FLibraryDirectory = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_library_directory_unset',
      '{}'));
  if not IsCheatTableFileName(ACandidate.FilePath) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_file_extension_invalid',
      '{}'));
  if not FileExists(ACandidate.FilePath) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_file_not_found', '{}'));
  // Re-check the size now, not at discovery time: the file may have grown.
  Stream := TFileStream.Create(ACandidate.FilePath, fmOpenRead or fmShareDenyNone);
  try
    if QWord(Stream.Size) > QWord(CeaCheatFileMaxBytes) then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'cheat_file_too_large', '{}'));
  finally
    Stream.Free;
  end;
  if not ForceDirectories(FLibraryDirectory) then
    Exit(TCEAResult.Error(rcInternalError, 'cheat_library_unwritable', '{}'));

  Hash := HashFileContent(ACandidate.FilePath);
  Name := PublishedCheatTableName(Hash, ACandidate.FileName);
  FinalPath := IncludeTrailingPathDelimiter(FLibraryDirectory) + Name;
  MetaPath := ChangeFileExt(FinalPath, '') + '.' + MetadataFileName;
  TempPath := FinalPath + '.tmp';
  // The temp file lives in the destination directory so the final rename stays
  // on one volume and is therefore atomic.
  SafeTemp := SafeCheatTablePath(FLibraryDirectory, TempPath);
  if SafeTemp = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_publish_path_invalid',
      '{}'));
  if FileExists(SafeTemp) then
    DeleteFile(SafeTemp);
  try
    if not CopyFileContent(ACandidate.FilePath, SafeTemp) then
      Exit(TCEAResult.Error(rcInternalError, 'cheat_publish_copy_failed', '{}'));
    AResult.Replaced := FileExists(FinalPath);
    // MoveFileExW, not RenameFile: RenameFile is MoveFileW and fails when the
    // destination already exists, which would break republishing.
    if not MoveFileExW(PWideChar(UnicodeString(SafeTemp)),
      PWideChar(UnicodeString(FinalPath)), MoveFileReplaceExisting) then
    begin
      DeleteFile(SafeTemp);
      Exit(TCEAResult.Error(rcInternalError, 'cheat_publish_rename_failed',
        '{}'));
    end;
  except
    if FileExists(SafeTemp) then
      DeleteFile(SafeTemp);
    Exit(TCEAResult.Error(rcInternalError, 'cheat_publish_failed', '{}'));
  end;
  // Hash the published bytes, not the source: this is the value later shown to
  // the operator and compared on reimport.
  Hash := HashFileContent(FinalPath);
  AResult.Candidate := ACandidate;
  AResult.Candidate.ContentHash := Hash;
  AResult.PublishedPath := FinalPath;
  AResult.MetadataPath := MetaPath;
  WriteMetadata(MetaPath, Hash, AResult.Candidate);
  Result := TCEAResult.Ok('{"published":true,"replaced":' +
    BoolToStr(AResult.Replaced, 'true', 'false') + '}');
end;

function TCEAGcmCheatPublisher.ListPublished(
  out ACandidates: TCEACheatFileCandidateArray): TCEAResult;
var
  Search: TSearchRec;
  Found: Integer;
  Candidate: TCEACheatFileCandidate;
  MetaPath: string;
  Stream: TFileStream;
  Content: RawByteString;
  Data: TJSONData;
  Obj: TJSONObject;
begin
  SetLength(ACandidates, 0);
  if FLibraryDirectory = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'cheat_library_directory_unset',
      '{}'));
  if not DirectoryExists(FLibraryDirectory) then
    Exit(TCEAResult.Ok('{"candidates":0}'));
  Found := FindFirst(IncludeTrailingPathDelimiter(FLibraryDirectory) + '*.ct',
    faAnyFile, Search);
  if Found <> 0 then
    Exit(TCEAResult.Ok('{"candidates":0}'));
  try
    repeat
      if (Search.Attr and faDirectory) <> 0 then
        Continue;
      FillChar(Candidate, SizeOf(Candidate), 0);
      Candidate.Source := cfsUserImport;
      Candidate.FilePath := IncludeTrailingPathDelimiter(FLibraryDirectory) +
        Search.Name;
      Candidate.FileName := UnicodeString(Search.Name);
      Candidate.SizeBytes := QWord(Search.Size);
      MetaPath := ChangeFileExt(Candidate.FilePath, '') + '.' + MetadataFileName;
      if FileExists(MetaPath) then
      begin
        Stream := TFileStream.Create(MetaPath, fmOpenRead or fmShareDenyNone);
        try
          SetLength(Content, Stream.Size);
          if Length(Content) > 0 then
            Stream.ReadBuffer(Content[1], Length(Content));
        finally
          Stream.Free;
        end;
        SetCodePage(Content, CP_UTF8, False);
        Data := nil;
        try
          try
            Data := GetJSON(string(Content));
          except
            Data := nil;
          end;
          if Data is TJSONObject then
          begin
            Obj := TJSONObject(Data);
            Candidate.GameName := UnicodeString(UTF8Decode(
              Obj.Get('game_name', '')));
            Candidate.Origin := UnicodeString(UTF8Decode(
              Obj.Get('origin', '')));
            Candidate.Version := UnicodeString(UTF8Decode(
              Obj.Get('version', '')));
            Candidate.ContentHash := Obj.Get('sha256', '');
          end;
        finally
          Data.Free;
        end;
      end;
      SetLength(ACandidates, Length(ACandidates) + 1);
      ACandidates[High(ACandidates)] := Candidate;
    until FindNext(Search) <> 0;
  finally
    FindClose(Search);
  end;
  Result := TCEAResult.Ok('{"candidates":' + IntToStr(Length(ACandidates)) + '}');
end;

end.
