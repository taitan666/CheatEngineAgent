unit cea_save_types;

{$mode objfpc}{$H+}

interface

type
  TCEASaveTarget = record
    Id: string;
    AuthorizedPath: string;
    FileIdentityId: string;
    GameLabel: string;
    OfflineAttested: Boolean;
  end;

  TCEASaveFormatDescriptor = record
    Id: string;
    Version: string;
    AdapterHash: string;
    Readable: Boolean;
    Writable: Boolean;
  end;

  TCEASaveSnapshot = record
    Id: string;
    TargetId: string;
    CanonicalPath: string;
    FileIdentityId: string;
    ByteCount: Int64;
    Sha256: string;
    ReadCoverage: Int64;
    FormatDescriptor: TCEASaveFormatDescriptor;
    Editable: Boolean;
  end;

  TCEASaveFieldObservation = record
    Path: string;
    ValueJson: string;
    SourceSnapshotId: string;
  end;
  TCEASaveFieldArray = array of TCEASaveFieldObservation;

  TCEASaveEditProposal = record
    Id: string;
    SnapshotId: string;
    FieldPath: string;
    ExpectedJson: string;
    NewJson: string;
    ContentHash: string;
  end;

implementation

end.
