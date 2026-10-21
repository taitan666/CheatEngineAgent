unit cea_ui_page_types;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

interface

uses
  SysUtils, cea_results;

type
  // One secondary-screen page (FR-033 multi-page). A page is a stable slot the
  // operator can switch to; the layout it shows is the newest version of its
  // schema.
  TCEAUiPage = record
    PageId: string;
    Title: string;
    SchemaId: string;
    // Newest stored version of the page's schema.
    Version: Integer;
    // Exactly one page is active at a time.
    Active: Boolean;
    UpdatedAt: string;
    function IsValid: Boolean;
  end;

  TCEAUiPageArray = array of TCEAUiPage;

  // A stored snapshot of a page schema (FR-026 version history).
  TCEAUiSchemaVersion = record
    SchemaId: string;
    Version: Integer;
    CreatedAt: string;
    function IsValid: Boolean;
  end;

  TCEAUiSchemaVersionArray = array of TCEAUiSchemaVersion;

  // Persistence port for pages and their schema versions. The store never
  // deletes history: a rollback appends a new version instead of rewriting an
  // old one, so an operator can always walk the whole trail.
  ICEAUiPageStore = interface
    function Initialize: TCEAResult;
    // Stores ASchemaJson as the next version of ASchemaId and points APageId
    // at it. AVersion receives the version number that was just written.
    function SavePage(const APageId, ATitle, ASchemaId, ASchemaJson,
      AUpdatedAt: string; out AVersion: Integer): TCEAResult;
    function ListPages(out APages: TCEAUiPageArray): TCEAResult;
    function GetPage(const APageId: string; out APage: TCEAUiPage;
      out ASchemaJson: string): TCEAResult;
    function SetActivePage(const APageId: string): TCEAResult;
    function GetActivePage(out APage: TCEAUiPage;
      out ASchemaJson: string): TCEAResult;
    function ListVersions(const ASchemaId: string;
      out AVersions: TCEAUiSchemaVersionArray): TCEAResult;
    function LoadVersion(const ASchemaId: string; const AVersion: Integer;
      out ASchemaJson: string): TCEAResult;
  end;

function FindPage(const APages: TCEAUiPageArray; const APageId: string;
  out APage: TCEAUiPage): Boolean;

implementation

function TCEAUiPage.IsValid: Boolean;
begin
  Result := (PageId <> '') and (Title <> '') and (SchemaId <> '') and
    (Version > 0);
end;

function TCEAUiSchemaVersion.IsValid: Boolean;
begin
  Result := (SchemaId <> '') and (Version > 0);
end;

function FindPage(const APages: TCEAUiPageArray; const APageId: string;
  out APage: TCEAUiPage): Boolean;
var
  I: Integer;
begin
  APage.PageId := '';
  APage.Title := '';
  APage.SchemaId := '';
  APage.Version := 0;
  APage.Active := False;
  APage.UpdatedAt := '';
  if APageId = '' then Exit(False);
  for I := 0 to High(APages) do
    if APages[I].PageId = APageId then
    begin
      APage := APages[I];
      Exit(True);
    end;
  Result := False;
end;

end.
