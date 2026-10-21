unit cea_ct_parser;

{$mode objfpc}{$H+}
{$codepage utf8}

interface

uses
  Classes, SysUtils, cea_results, cea_ports, cea_ct_model;

type
  TCTParser = class
  private
    FHasher: ICEAHasher;
    FMaxBytes: QWord;
    function ParseContent(const AContent, AContentHash,
      AProvenanceUri: string; out AArtifact: TCTArtifact): TCEAResult;
  public
    constructor Create(const AHasher: ICEAHasher;
      const AMaxBytes: QWord);
    function ParseFile(const APath, AProvenanceUri: string;
      out AArtifact: TCTArtifact): TCEAResult;
    function ParseBytes(const AContentHex, AContentHash,
      AProvenanceUri: string): TCEAResult;
  end;

implementation

uses
  DOM, XMLRead;

const
  CTParserVersion = 'cea-ct-parser/1.0';

function DirectChild(const ANode: TDOMNode; const AName: string): TDOMNode;
var
  Child: TDOMNode;
begin
  Result := nil;
  if ANode = nil then Exit;
  Child := ANode.FirstChild;
  while Child <> nil do
  begin
    if SameText(UTF8Encode(Child.NodeName), AName) then Exit(Child);
    Child := Child.NextSibling;
  end;
end;

function ChildText(const ANode: TDOMNode; const AName: string): string;
var
  Child: TDOMNode;
begin
  Child := DirectChild(ANode, AName);
  if Child = nil then Result := ''
  else Result := Trim(UTF8Encode(Child.TextContent));
end;

procedure AddString(var AValues: TCTStringArray; const AValue: string);
var
  Index: Integer;
begin
  if AValue = '' then Exit;
  for Index := 0 to High(AValues) do
    if SameText(AValues[Index], AValue) then Exit;
  SetLength(AValues, Length(AValues) + 1);
  AValues[High(AValues)] := AValue;
end;

function ModuleFromAddress(const AAddress: string): string;
var
  PlusAt: SizeInt;
begin
  PlusAt := Pos('+', AAddress);
  if PlusAt > 1 then Result := Trim(Copy(AAddress, 1, PlusAt - 1))
  else Result := '';
end;

function DecodeUriPath(const AValue: string): string;
var
  I, Parsed: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AValue) do
  begin
    if (AValue[I] = '%') and (I + 2 <= Length(AValue)) and
       TryStrToInt('$' + Copy(AValue, I + 1, 2), Parsed) then
    begin
      Result := Result + Chr(Parsed);
      Inc(I, 3);
    end
    else
    begin
      Result := Result + AValue[I];
      Inc(I);
    end;
  end;
end;

function IsConservativeVersion(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := AValue <> '';
  if not Result then Exit;
  for I := 1 to Length(AValue) do
    if not (AValue[I] in ['0'..'9', '.', '-', '_']) then Exit(False);
  Result := AValue[1] in ['0'..'9'];
end;

procedure ApplyFilenameIdentity(const AProvenanceUri: string;
  var AArtifact: TCTArtifact);
var
  PathText, BaseName, LowerName, Candidate: string;
  I, CutAt: Integer;
begin
  PathText := AProvenanceUri;
  CutAt := Pos('?', PathText);
  if CutAt > 0 then Delete(PathText, CutAt, MaxInt);
  CutAt := Pos('#', PathText);
  if CutAt > 0 then Delete(PathText, CutAt, MaxInt);
  PathText := DecodeUriPath(PathText);
  PathText := StringReplace(PathText, '/', '\', [rfReplaceAll]);
  BaseName := ChangeFileExt(ExtractFileName(PathText), '');
  LowerName := LowerCase(BaseName);
  for I := Length(BaseName) - 1 downto 2 do
    if (LowerName[I] = 'v') and (LowerName[I - 1] in [' ', '_', '-']) then
    begin
      Candidate := Copy(BaseName, I + 1, MaxInt);
      if IsConservativeVersion(Candidate) then
      begin
        AArtifact.GameVersion := Candidate;
        BaseName := Trim(Copy(BaseName, 1, I - 2));
        Break;
      end;
    end;
  BaseName := StringReplace(BaseName, '_', ' ', [rfReplaceAll]);
  if AArtifact.GameName = '' then AArtifact.GameName := Trim(BaseName);
end;

procedure ExtractAobPatterns(const AScript: string;
  var APatterns: TCTStringArray);
var
  Lines: TStringList;
  I, OpenAt, CloseAt, CommaAt: Integer;
  Line, LowerLine, Inside: string;
begin
  Lines := TStringList.Create;
  try
    Lines.Text := AScript;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      LowerLine := LowerCase(Line);
      if (Pos('aobscan(', LowerLine) <> 1) and
         (Pos('aobscanmodule(', LowerLine) <> 1) and
         (Pos('aobscanregion(', LowerLine) <> 1) then Continue;
      OpenAt := Pos('(', Line);
      CloseAt := LastDelimiter(')', Line);
      if (OpenAt = 0) or (CloseAt <= OpenAt) then Continue;
      Inside := Copy(Line, OpenAt + 1, CloseAt - OpenAt - 1);
      CommaAt := LastDelimiter(',', Inside);
      if CommaAt > 0 then
        AddString(APatterns, Trim(Copy(Inside, CommaAt + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
end;

function DetectRiskFlags(const AScript: string): string;
var
  Value: string;
  procedure AddFlag(const AFlag: string);
  begin
    if Result <> '' then Result := Result + ',';
    Result := Result + AFlag;
  end;
begin
  Result := '';
  Value := LowerCase(AScript);
  if (Pos('createprocess', Value) > 0) or
     (Pos('shellexecute', Value) > 0) or
     (Pos('os.execute', Value) > 0) then AddFlag('process_creation');
  if (Pos('getinternet', Value) > 0) or
     (Pos('http://', Value) > 0) or (Pos('https://', Value) > 0) then
    AddFlag('network_access');
  if (Pos('io.open', Value) > 0) or (Pos('writefile', Value) > 0) then
    AddFlag('filesystem_access');
end;

procedure ExtractOffsets(const AEntryNode: TDOMNode;
  var AOffsets: TCTStringArray);
var
  Offsets, Child: TDOMNode;
begin
  Offsets := DirectChild(AEntryNode, 'Offsets');
  if Offsets = nil then Exit;
  Child := Offsets.FirstChild;
  while Child <> nil do
  begin
    if SameText(UTF8Encode(Child.NodeName), 'Offset') then
      AddString(AOffsets, Trim(UTF8Encode(Child.TextContent)));
    Child := Child.NextSibling;
  end;
end;

procedure CollectEntries(const ANode: TDOMNode; const AParentId: string;
  var AArtifact: TCTArtifact);
var
  Child: TDOMNode;
  Entry: TCTEntry;
  EntryIndex: Integer;
  Script, ParentForChildren: string;
begin
  if ANode = nil then Exit;
  Child := ANode.FirstChild;
  while Child <> nil do
  begin
    ParentForChildren := AParentId;
    if SameText(UTF8Encode(Child.NodeName), 'CheatEntry') then
    begin
      FillChar(Entry, SizeOf(Entry), 0);
      Entry.EntryId := ChildText(Child, 'ID');
      Entry.ParentEntryId := AParentId;
      Entry.Description := ChildText(Child, 'Description');
      Entry.VariableType := ChildText(Child, 'VariableType');
      Entry.AddressExpression := ChildText(Child, 'Address');
      Entry.ModuleName := ModuleFromAddress(Entry.AddressExpression);
      ExtractOffsets(Child, Entry.PointerOffsets);
      Script := ChildText(Child, 'AssemblerScript');
      Entry.AutoAssemblerText := Script;
      if Pos('{$lua}', LowerCase(Script)) > 0 then Entry.LuaText := Script;
      ExtractAobPatterns(Script, Entry.AobPatterns);
      Entry.RiskFlags := DetectRiskFlags(Script);
      EntryIndex := Length(AArtifact.Entries);
      SetLength(AArtifact.Entries, EntryIndex + 1);
      AArtifact.Entries[EntryIndex] := Entry;
      ParentForChildren := Entry.EntryId;
      if (AArtifact.GameName = '') and (Entry.ModuleName <> '') then
      begin
        AArtifact.GameName := Entry.ModuleName;
        if SameText(ExtractFileExt(AArtifact.GameName), '.exe') then
          AArtifact.GameName := ChangeFileExt(AArtifact.GameName, '');
      end;
    end;
    CollectEntries(Child, ParentForChildren, AArtifact);
    Child := Child.NextSibling;
  end;
end;

constructor TCTParser.Create(const AHasher: ICEAHasher;
  const AMaxBytes: QWord);
begin
  inherited Create;
  if AMaxBytes = 0 then raise EArgumentOutOfRangeException.Create('AMaxBytes');
  FHasher := AHasher;
  FMaxBytes := AMaxBytes;
end;

function TCTParser.ParseContent(const AContent, AContentHash,
  AProvenanceUri: string; out AArtifact: TCTArtifact): TCEAResult;
var
  Document: TXMLDocument;
  Stream: TStringStream;
  Root: TDOMElement;
  LowerContent: string;
begin
  FillChar(AArtifact, SizeOf(AArtifact), 0);
  if (AContent = '') or (AContentHash = '') or (AProvenanceUri = '') then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_artifact_identity_required', '{}'));
  if QWord(Length(AContent)) > FMaxBytes then
    Exit(TCEAResult.Error(rcBudgetExceeded, 'ct_file_too_large', '{}'));
  LowerContent := LowerCase(AContent);
  if (Pos('<!doctype', LowerContent) > 0) or
     (Pos('<!entity', LowerContent) > 0) then
    Exit(TCEAResult.Error(rcPolicyDenied,
      'xml_external_entity_forbidden', '{}'));
  Document := nil;
  Stream := TStringStream.Create(AContent);
  try
    try
      ReadXMLFile(Document, Stream);
    except
      Exit(TCEAResult.Error(rcInvalidArgument, 'ct_xml_invalid', '{}'));
    end;
    Root := Document.DocumentElement;
    if (Root = nil) or not SameText(UTF8Encode(Root.TagName), 'CheatTable') then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ct_root_invalid', '{}'));
    AArtifact.SourceUri := AProvenanceUri;
    AArtifact.ContentHash := AContentHash;
    AArtifact.ParserVersion := CTParserVersion;
    AArtifact.LicenseSpdx := 'NOASSERTION';
    AArtifact.LicenseUri := '';
    AArtifact.LicenseStatus := 'unknown';
    AArtifact.TableVersion := UTF8Encode(
      Root.GetAttribute('CheatEngineTableVersion'));
    CollectEntries(Root, '', AArtifact);
    ApplyFilenameIdentity(AProvenanceUri, AArtifact);
    Result := TCEAResult.Ok('{"source_uri":"' + AProvenanceUri +
      '","content_hash":"' + AContentHash + '","entry_count":' +
      IntToStr(Length(AArtifact.Entries)) + '}');
  finally
    Document.Free;
    Stream.Free;
  end;
end;

function TCTParser.ParseFile(const APath, AProvenanceUri: string;
  out AArtifact: TCTArtifact): TCEAResult;
var
  Stream: TFileStream;
  Content: RawByteString;
  Hash: string;
begin
  FillChar(AArtifact, SizeOf(AArtifact), 0);
  if (FHasher = nil) or not FileExists(APath) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ct_file_not_found', '{}'));
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    if QWord(Stream.Size) > FMaxBytes then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'ct_file_too_large', '{}'));
    SetLength(Content, Stream.Size);
    if Length(Content) > 0 then Stream.ReadBuffer(Content[1], Length(Content));
  finally
    Stream.Free;
  end;
  Hash := FHasher.HashUtf8(Content);
  Result := ParseContent(Content, Hash, AProvenanceUri, AArtifact);
end;

function TCTParser.ParseBytes(const AContentHex, AContentHash,
  AProvenanceUri: string): TCEAResult;
var
  Content: RawByteString;
  Artifact: TCTArtifact;
  I, Parsed: Integer;
begin
  if Odd(Length(AContentHex)) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'ct_content_hex_invalid', '{}'));
  SetLength(Content, Length(AContentHex) div 2);
  for I := 1 to Length(Content) do
  begin
    if not TryStrToInt('$' + Copy(AContentHex, (I - 1) * 2 + 1, 2), Parsed) then
      Exit(TCEAResult.Error(rcInvalidArgument, 'ct_content_hex_invalid', '{}'));
    Content[I] := AnsiChar(Parsed);
  end;
  Result := ParseContent(Content, AContentHash, AProvenanceUri, Artifact);
end;

end.
