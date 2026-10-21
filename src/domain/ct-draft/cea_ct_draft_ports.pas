unit cea_ct_draft_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_results, cea_ct_draft_types;

type
  ICEACTDraftRepository = interface
    function SaveDraft(const ADraft: TCEACTDraft): TCEAResult;
    function LoadDraft(const ADraftId: string;
      out ADraft: TCEACTDraft): TCEAResult;
    function ListDrafts(const ALimit: Cardinal;
      out ADrafts: TCEACTDraftArray): TCEAResult;
    function UpdateExportState(const ADraftId, AExpectedHash: string;
      const AState: TCEACTDraftState; const AExportJson: string): TCEAResult;
  end;

  ICEACTDraftSourceResolver = interface
    function Resolve(const AProposal: TCEACTDraftProposal;
      out ABundle: TCEACTDraftSourceBundle): TCEAResult;
  end;

  ICEACTXmlExporter = interface
    function Render(const ADraft: TCEACTDraft; out ABytes: TBytes;
      out ASha256: string): TCEAResult;
  end;

  ICEACTDraftFilePort = interface
    function CreateNewAndVerify(const ARequest: TCEACTDraftExportRequest;
      const ABytes: TBytes; out AResult: TCEACTDraftExportResult): TCEAResult;
    function Observe(const ARequest: TCEACTDraftExportRequest;
      out AResult: TCEACTDraftExportResult): TCEAResult;
  end;

implementation

end.

