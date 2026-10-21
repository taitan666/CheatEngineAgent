unit cea_ct_model;

{$mode objfpc}{$H+}

interface

type
  TCTStringArray = array of string;

  TCTEntry = record
    EntryId: string;
    ParentEntryId: string;
    Description: string;
    VariableType: string;
    AddressExpression: string;
    ModuleName: string;
    PointerOffsets: TCTStringArray;
    AobPatterns: TCTStringArray;
    AutoAssemblerText: string;
    LuaText: string;
    RiskFlags: string;
  end;

  TCTEntryArray = array of TCTEntry;

  TCTArtifact = record
    SourceUri: string;
    ContentHash: string;
    ParserVersion: string;
    TableVersion: string;
    GameName: string;
    GameVersion: string;
    LicenseSpdx: string;
    LicenseUri: string;
    LicenseStatus: string;
    Entries: TCTEntryArray;
  end;

implementation

end.
