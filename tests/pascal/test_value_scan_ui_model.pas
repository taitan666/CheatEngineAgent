program test_value_scan_ui_model;

{$mode objfpc}{$H+}

uses
  cea_results, cea_value_scan_ui_model;

var
  Input: TCEAValueScanUiInput;
begin
  Assert(ValidateValueScanUiInput('0x1000', '4096', 'dword', '767',
    '20', Input).Code = rcOk, 'valid bounded UI input accepted');
  Assert((Input.StartAddress = $1000) and (Input.RangeBytes = 4096) and
    (Input.MaxResults = 20), 'validated input preserves exact bounds');
  Assert(ValidateValueScanUiInput('0x1000', '536870913', 'dword', '767',
    '20', Input).Code = rcBudgetExceeded,
    'UI cannot request more than 512 MiB in the background');
  Assert(ValidateValueScanUiInput('0x1000', '4096', 'dword', 'bad',
    '20', Input).Code = rcInvalidArgument,
    'invalid value is rejected before process access');
  Assert(ValidateValueScanUiInput('0xGG', '4096', 'dword', '767',
    '20', Input).Code = rcInvalidArgument,
    'malformed address is rejected before process access');
  Assert(ValidateValueScanUiInput('0x1000', '4096', 'dword', '767',
    '10001', Input).Code = rcBudgetExceeded,
    'UI result budget is bounded');
  Assert(ValidateValueRefineUiInput('win32-scan-1', 'dword',
    'dword', '758').Code = rcOk,
    'refine accepts a new exact value for the active type');
  Assert(ValidateValueRefineUiInput('', 'dword', 'dword',
    '758').Code = rcConflict,
    'refine requires an active session');
  Assert(ValidateValueRefineUiInput('win32-scan-1', 'dword',
    'word', '758').Code = rcConflict,
    'refine cannot change value type after first scan');
  Assert(ValidateValueRefineUiInput('win32-scan-1', 'dword',
    'dword', 'bad').Code = rcInvalidArgument,
    'refine rejects invalid exact values before process access');
  Assert(ValidateValueScanScopeUiInput('0x1000', '4096',
    '20', Input).Code = rcOk,
    'UI can authorize a bounded scope before choosing a value');
  Assert(ValidateValueScanScopeUiInput('0x1000', '536870913',
    '20', Input).Code = rcBudgetExceeded,
    'separate MCP scope cannot exceed the UI byte budget');
  Assert(ValidateProcessValueScanUiInput('private', '8192', 'dword',
    '767', '20', Input).Code = rcOk,
    'process-level private selector accepts bounded typed input');
  Assert(ValidateProcessValueScanUiInput('private,image,mapped',
    '536870912', 'dword', '767', '10000', Input).Code = rcOk,
    'explicit image and mapped selection stays within hard ceilings');
  Assert(ValidateProcessValueScanUiInput('all', '8192', 'dword',
    '767', '20', Input).StableCode = 'value_scan_region_kinds_invalid',
    'region kinds must be explicit rather than an ambiguous all alias');
  WriteLn('VALUE_SCAN_UI_MODEL=PASS');
end.
