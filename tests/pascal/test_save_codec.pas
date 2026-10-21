program test_save_codec;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, cea_results, cea_save_types, cea_fixture_save_codec,
  cea_windows_sha256, cea_win32_save_reader, cea_save_service;

function ToBytes(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then Move(S[1], Result[0], Length(S));
end;

function FixtureBytes(const Hp, Gold: Integer): TBytes;
var
  Body: string;
  Hasher: TCEAWindowsSha256;
begin
  Body := 'CEA-SAVE-1' + #10 + '{"hp":' + IntToStr(Hp) +
    ',"gold":' + IntToStr(Gold) + '}';
  Hasher := TCEAWindowsSha256.Create;
  try
    Result := ToBytes(Body + #10 + Hasher.HashUtf8(Body) + #10);
  finally
    Hasher.Free;
  end;
end;

var
  Codec: TCEAFixtureSaveCodec;
  Good, Bad, Encoded: TBytes;
  Descriptor: TCEASaveFormatDescriptor;
  Fields: TCEASaveFieldArray;
  Proposal: TCEASaveEditProposal;
  Reader: TCEAWin32SaveReader;
  Service: TCEASaveService;
  Snapshot: TCEASaveSnapshot;
  Stream: TFileStream;
  SavePath: string;
  ProposalHasher: TCEAWindowsSha256;
begin
  Codec := TCEAFixtureSaveCodec.Create;
  try
    Good := FixtureBytes(400, 900);
    Assert(Codec.Probe(Good, Descriptor).Code = rcOk);
    Assert(Descriptor.Writable);
    Assert(Codec.Decode(Good, Fields).Code = rcOk);
    Assert((Length(Fields) = 2) and (Fields[0].ValueJson = '400') and
      (Fields[1].ValueJson = '900'));
    Bad := ToBytes('CEA-SAVE-2' + #10 + '{}');
    Assert(Codec.Probe(Bad, Descriptor).Code <> rcOk);
    Bad := Copy(Good, 0, Length(Good));
    Bad[15] := Bad[15] xor 1;
    Assert(Codec.Validate(Bad).Code <> rcOk, 'checksum catches mutation');
    FillChar(Proposal, SizeOf(Proposal), 0);
    Proposal.FieldPath := '/hp';
    Proposal.ExpectedJson := '400';
    Proposal.NewJson := '500';
    Assert(Codec.Encode(Good, Proposal, Encoded).Code = rcOk);
    Assert(Codec.Decode(Encoded, Fields).Code = rcOk);
    Assert((Fields[0].ValueJson = '500') and
      (Fields[1].ValueJson = '900'), 'unchanged field preserved');
    Proposal.NewJson := '10000';
    Assert(Codec.Encode(Good, Proposal, Encoded).Code = rcInvalidArgument);
    SavePath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'cea-fixture-' + IntToStr(GetProcessID) + '.sav';
    Stream := TFileStream.Create(SavePath, fmCreate);
    try
      Stream.WriteBuffer(Good[0], Length(Good));
    finally
      Stream.Free;
    end;
    Reader := TCEAWin32SaveReader.Create;
    ProposalHasher := TCEAWindowsSha256.Create;
    Service := TCEASaveService.Create(Reader, nil, nil,
      ProposalHasher, nil, Codec);
    try
      Assert(Service.Inspect('fixture-task', SavePath, Snapshot).Code = rcOk);
      Assert(Snapshot.FormatDescriptor.Id = 'cea-fixture-save');
      Assert(not Snapshot.Editable, 'backup required before edit');
      Assert(Service.GetFields(Snapshot, Fields).Code = rcOk);
      Assert((Length(Fields) = 2) and (Fields[0].ValueJson = '400'));
      Assert(Service.ProposeFieldEdit(Snapshot, '/hp', '400', '500',
        Proposal).Code = rcOk);
      Assert((Proposal.ContentHash <> '') and
        (Proposal.FieldPath = '/hp'));
      Assert(Proposal.ExpectedJson = '400');
      Assert(Service.ProposeFieldEdit(Snapshot, '/hp', '400', '10000',
        Proposal).Code = rcInvalidArgument);
    finally
      Service.Free;
      ProposalHasher.Free;
      Reader.Free;
      DeleteFile(SavePath);
    end;
  finally
    Codec.Free;
  end;
  WriteLn('SAVE_CODEC=PASS');
end.
