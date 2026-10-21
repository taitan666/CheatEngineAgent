unit cea_save_discovery_types;

{$mode objfpc}{$H+}

interface

type
  TCEADiscoveryBudget = record
    MaxFiles: Integer;
    MaxDepth: Integer;
    MaxDurationMs: Cardinal;
  end;

  TCEADiscoveryScope = record
    Id: string;
    RootPath: string;
    AuthorizedAt: TDateTime;
    Budget: TCEADiscoveryBudget;
    Revoked: Boolean;
  end;

  TCEASaveCandidate = record
    Id: string;
    ScopeId: string;
    RelativePath: string;
    ByteCount: Int64;
    ModifiedAt: TDateTime;
    FileIdentityId: string;
    LastWriteHigh: Cardinal;
    LastWriteLow: Cardinal;
    SourceRuleVersion: string;
    InspectionRequired: Boolean;
  end;
  TCEASaveCandidateArray = array of TCEASaveCandidate;

implementation

end.
