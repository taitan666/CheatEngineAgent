program test_ui_page_store;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, Classes, cea_results, cea_ui_page_types, cea_ui_page_store;

var
  DatabasePath: string;
  Store: TCEAUiPageStore;
  Pages: TCEAUiPageArray;
  Versions: TCEAUiSchemaVersionArray;
  Page: TCEAUiPage;
  Json: string;
  R: TCEAResult;
  Version: Integer;

procedure CleanupDatabase(const APath: string);
begin
  DeleteFile(APath);
  DeleteFile(APath + '-wal');
  DeleteFile(APath + '-shm');
end;

begin
  DatabasePath := GetTempDir(False) + 'cea-ui-page-' +
    IntToStr(GetProcessID) + '.sqlite3';
  CleanupDatabase(DatabasePath);
  Store := TCEAUiPageStore.Create(DatabasePath);
  try
    Assert(not Store.Initialize.Failed, 'page store initializes');

    // Saving twice must append versions, never overwrite them (FR-026).
    R := Store.SavePage('page-attrs', 'Attributes', 'ui-game',
      '{"id":"ui-game","page_title":"Attributes","sections":[]}', '2026-10-20T01:00:00Z',
      Version);
    Assert(not R.Failed, 'first page save succeeds');
    Assert(Version = 1, 'first save is version 1');

    R := Store.SavePage('page-attrs', 'Attributes', 'ui-game',
      '{"id":"ui-game","page_title":"Attributes v2","sections":[]}',
      '2026-10-20T01:05:00Z', Version);
    Assert(not R.Failed, 'second page save succeeds');
    Assert(Version = 2, 'second save is version 2');

    R := Store.ListVersions('ui-game', Versions);
    Assert(not R.Failed, 'versions list succeeds');
    Assert(Length(Versions) = 2, 'both versions are kept');
    Assert(Versions[0].Version = 2, 'newest version is listed first');
    Assert(Versions[1].Version = 1, 'oldest version is still present');

    // The page always points at the newest version.
    R := Store.GetPage('page-attrs', Page, Json);
    Assert(not R.Failed, 'page loads');
    Assert(Page.Version = 2, 'page points at the newest version');
    Assert(Pos('Attributes v2', Json) > 0, 'page serves the newest payload');

    // Rolling back is expressed as a new version, so history stays intact.
    R := Store.LoadVersion('ui-game', 1, Json);
    Assert(not R.Failed, 'old version loads');
    Assert(Pos('"page_title":"Attributes"', Json) > 0,
      'old version payload is intact');
    R := Store.SavePage('page-attrs', 'Attributes', 'ui-game', Json,
      '2026-10-20T01:10:00Z', Version);
    Assert(not R.Failed, 'rollback save succeeds');
    Assert(Version = 3, 'rollback appends version 3');
    R := Store.ListVersions('ui-game', Versions);
    Assert(Length(Versions) = 3, 'rollback does not erase history');

    // Multi-page switching (FR-033).
    R := Store.SavePage('page-inventory', 'Inventory', 'ui-inv',
      '{"id":"ui-inv","page_title":"Inventory","sections":[]}',
      '2026-10-20T01:15:00Z', Version);
    Assert(not R.Failed, 'second page saves');
    R := Store.ListPages(Pages);
    Assert(not R.Failed, 'pages list succeeds');
    Assert(Length(Pages) = 2, 'two pages are listed');

    R := Store.SetActivePage('page-attrs');
    Assert(not R.Failed, 'activating the first page succeeds');
    R := Store.GetActivePage(Page, Json);
    Assert(not R.Failed, 'active page loads');
    Assert(Page.PageId = 'page-attrs', 'first page is active');

    R := Store.SetActivePage('page-inventory');
    Assert(not R.Failed, 'activating the second page succeeds');
    R := Store.GetActivePage(Page, Json);
    Assert(Page.PageId = 'page-inventory', 'second page becomes active');

    R := Store.ListPages(Pages);
    Assert(not R.Failed, 'pages list still succeeds');
    Assert(Length(Pages) = 2, 'switching pages does not create rows');
    Assert(not Pages[0].Active or not Pages[1].Active,
      'at most one page is active');

    // Unknown identifiers must fail closed rather than fabricate a page.
    R := Store.SetActivePage('page-missing');
    Assert(R.Failed, 'activating an unknown page fails');
    Assert(R.StableCode = 'ui_page_not_found', 'unknown page reports not found');
    R := Store.LoadVersion('ui-game', 99, Json);
    Assert(R.Failed, 'unknown version fails');
    Assert(R.StableCode = 'ui_schema_version_not_found',
      'unknown version reports not found');
    R := Store.SavePage('', 'Empty', 'ui-x', '{}', '', Version);
    Assert(R.Failed, 'page without id fails');
  finally
    Store.Free;
    CleanupDatabase(DatabasePath);
  end;

  WriteLn('UI_PAGE_STORE=PASS');
end.
