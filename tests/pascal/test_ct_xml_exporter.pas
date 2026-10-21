program test_ct_xml_exporter;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  Classes, SysUtils, cea_results, cea_ports, cea_reverse_types,
  cea_ct_draft_types, cea_ct_xml_exporter, cea_ct_model, cea_ct_parser,
  cea_test_ports;

procedure Check(const ACondition:Boolean; const AMessage:string);
begin if not ACondition then raise Exception.Create(AMessage); end;

function HashOf(const C:Char):string;
begin Result:='sha256:'+StringOfChar(C,64); end;

function BytesText(const B:TBytes):RawByteString;
begin SetLength(Result,Length(B)); if Length(B)>0 then Move(B[0],Result[1],Length(B)); end;

function ReadAll(const APath:string):RawByteString;
var S:TFileStream;
begin S:=TFileStream.Create(APath,fmOpenRead or fmShareDenyNone); try SetLength(Result,S.Size); if S.Size>0 then S.ReadBuffer(Result[1],S.Size); finally S.Free; end; end;

procedure BaseEntry(var E:TCEACTDraftEntry; const AOrdinal:Cardinal;
  const AParent:Integer; const AKind:TCEACTDraftEntryKind;
  const ADescription,AAddress,AModule:string);
begin
  FillChar(E,SizeOf(E),0); E.Ordinal:=AOrdinal; E.ParentOrdinal:=AParent;
  E.Kind:=AKind; E.Description:=ADescription; E.ValueType:=dvDword;
  E.AddressWidthBits:=64; E.AddressText:=AAddress; E.ModuleName:=AModule;
  E.CandidateId:='candidate:'+IntToStr(AOrdinal);
  E.EvidenceIdsJson:='["evidence:scan"]'; E.VerificationOutcome:=voPass;
  E.CompatibilityHash:=HashOf('c'); E.AobEvidenceJson:='[]';
end;

var
  Draft:TCEACTDraft; Bytes1,Bytes2:TBytes; Hash1,Hash2,Path,Text:string;
  Exporter:TCEACTXmlExporter; Hasher:TCEATestHasher; HasherPort:ICEAHasher;
  Parser:TCTParser; Artifact:TCTArtifact; R:TCEAResult; Stream:TFileStream;
begin
  Hasher:=TCEATestHasher.Create; HasherPort:=Hasher;
  Exporter:=TCEACTXmlExporter.Create(HasherPort); Parser:=TCTParser.Create(HasherPort,16*1024*1024);
  try
    FillChar(Draft,SizeOf(Draft),0); Draft.Id:='ctdraft:fixture:1'; Draft.Revision:=1;
    Draft.SchemaVersion:='1.0'; Draft.State:=dsValidated; Draft.GameName:='Fixture Game';
    Draft.TargetExecutableSha256:=HashOf('b'); Draft.ModuleSetHash:=HashOf('f');
    Draft.CompatibilityHash:=HashOf('c'); Draft.RecipeId:='recipe:fixture';
    Draft.VerificationRunId:='verification:pass'; Draft.EvidenceIdsJson:='["evidence:scan"]';
    Draft.ProofIdsJson:='["proof:pass"]'; Draft.SourceHashesJson:='{"evidence:scan":"'+HashOf('e')+'"}';
    Draft.GeneratorVersion:='ct-draft-v1'; Draft.ContentHash:=HashOf('d');
    Draft.FindingsJson:='[]'; Draft.FailureModesJson:='[]'; Draft.CreatedAt:='2026-09-22T00:00:00Z'; Draft.UpdatedAt:=Draft.CreatedAt;
    SetLength(Draft.Entries,4);
    FillChar(Draft.Entries[0],SizeOf(Draft.Entries[0]),0); Draft.Entries[0].Ordinal:=0;
    Draft.Entries[0].ParentOrdinal:=-1; Draft.Entries[0].Kind:=deGroup; Draft.Entries[0].Description:='Player & Stats'; Draft.Entries[0].ValueType:=dvNone;
    BaseEntry(Draft.Entries[1],1,0,deModuleOffset,'Health & "Lives"','0x1234','game.exe');
    BaseEntry(Draft.Entries[2],2,0,dePointerChain,'生命值','0x2000','game.exe');
    SetLength(Draft.Entries[2].PointerOffsets,2); Draft.Entries[2].PointerOffsets[0]:='0x10'; Draft.Entries[2].PointerOffsets[1]:='0x20';
    BaseEntry(Draft.Entries[3],3,-1,deAbsoluteAddress,'Raw <address>','0x1000',''); Include(Draft.Entries[3].RiskFlags,drNonPortable);
    Check(Draft.IsValid,'fixture draft valid');

    Check(Exporter.Render(Draft,Bytes1,Hash1).Code=rcOk,'first render');
    Check(Exporter.Render(Draft,Bytes2,Hash2).Code=rcOk,'second render');
    Check((BytesText(Bytes1)=BytesText(Bytes2)) and (Hash1=Hash2),'byte-identical repeat');
    Check(BytesText(Bytes1)=ReadAll('tests\fixtures\ct\generated-script-free.expected.ct'),'exact fixture bytes');
    Text:=LowerCase(BytesText(Bytes1));
    Check((Pos('<assemblerscript>',Text)=0) and (Pos('<luascript>',Text)=0) and
      (Pos('<hotkeys>',Text)=0) and (Pos('<enable>',Text)=0) and
      (Pos('<disable>',Text)=0) and (Pos('<!doctype',Text)=0) and
      (Pos('<!entity',Text)=0) and (Pos('<binary',Text)=0),'forbidden capabilities absent');

    Path:=IncludeTrailingPathDelimiter(GetTempDir(False))+'cea-generated-'+IntToStr(GetTickCount64)+'.ct';
    Stream:=TFileStream.Create(Path,fmCreate); try if Length(Bytes1)>0 then Stream.WriteBuffer(Bytes1[0],Length(Bytes1)); finally Stream.Free; end;
    try
      R:=Parser.ParseFile(Path,'file://local/generated-script-free.ct',Artifact);
      Check(R.Code=rcOk,'hardened parser round-trip');
      Check((Length(Artifact.Entries)=4) and (Artifact.Entries[1].ModuleName='game.exe'),'round-trip entries and module');
      Check((Length(Artifact.Entries[2].PointerOffsets)=2) and
        (Artifact.Entries[2].PointerOffsets[0]='10'),'round-trip pointer offsets');
      Check((Artifact.Entries[1].AutoAssemblerText='') and
        (Artifact.Entries[1].LuaText=''),'round-trip remains script free');
    finally if FileExists(Path) then DeleteFile(Path); end;

    Draft.State:=dsProposed;
    Check(Exporter.Render(Draft,Bytes1,Hash1).Code=rcCTDraftSourceUnverified,
      'non-validated draft rejected');
    WriteLn('CT_XML_EXPORTER=PASS');
  finally Parser.Free; Exporter.Free; HasherPort:=nil; Hasher.Free; end;
end.
