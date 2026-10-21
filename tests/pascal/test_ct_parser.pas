program test_ct_parser;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_windows_sha256, cea_ct_model, cea_ct_parser;

var
  Parser: TCTParser;
  Hasher: TCEAWindowsSha256;
  Artifact: TCTArtifact;
  Root, Path: string;
  R: TCEAResult;

begin
  Root := ExpandFileName('tests\fixtures\ct');
  Hasher := TCEAWindowsSha256.Create;
  Parser := TCTParser.Create(Hasher, 16 * 1024 * 1024);
  try
    Path := IncludeTrailingPathDelimiter(Root) + 'aob-and-pointer.ct';
    R := Parser.ParseFile(Path, 'file://local/aob-and-pointer.ct', Artifact);
    Assert(R.Code = rcOk, 'valid CT parses');
    Assert(Artifact.ContentHash = Hasher.HashFile(Path),
      'artifact stores immutable source hash');
    Assert(Artifact.ParserVersion <> '', 'parser version is recorded');
    Assert(Length(Artifact.Entries) = 2, 'nested entries are extracted');
    Assert(Artifact.Entries[0].ModuleName = 'SampleOfflineGame.exe',
      'module is extracted from address expression');
    Assert(Length(Artifact.Entries[0].PointerOffsets) = 2,
      'pointer chain is extracted');
    Assert(Length(Artifact.Entries[1].AobPatterns) = 1,
      'AOB pattern is extracted without execution');
    Assert(Artifact.Entries[1].AutoAssemblerText <> '',
      'AutoAssembler is retained only as text evidence');

    R := Parser.ParseFile(IncludeTrailingPathDelimiter(Root) +
      'dangerous-lua.ct',
      'file://local/Persona%204%20Golden%20v1.2.ct', Artifact);
    Assert(R.Code = rcOk, 'dangerous script remains parseable evidence');
    Assert((Artifact.GameName = 'Persona 4 Golden') and
      (Artifact.GameVersion = '1.2'),
      'missing CT identity falls back to source filename and version');
    Assert(Artifact.Entries[0].LuaText <> '', 'Lua block is identified');
    Assert(Pos('process_creation', Artifact.Entries[0].RiskFlags) > 0,
      'dangerous API is statically flagged');

    R := Parser.ParseFile(IncludeTrailingPathDelimiter(Root) +
      'external-entity.ct', 'file://local/external-entity.ct', Artifact);
    Assert(R.Code = rcPolicyDenied,
      'external entities are rejected before XML parsing');
    WriteLn('CT_PARSER=PASS');
  finally
    Parser.Free;
    Hasher.Free;
  end;
end.
