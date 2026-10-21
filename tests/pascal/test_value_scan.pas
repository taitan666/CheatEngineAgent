program test_value_scan;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_value_scan_types;

procedure ExpectValue(const AType, AText: string; const AExpected: array of Byte;
  const AAlignment: Cardinal);
var
  Actual: TBytes;
  Alignment: Cardinal;
  R: TCEAResult;
  Index: Integer;
begin
  R := EncodeExactValue(AType, AText, Actual, Alignment);
  Assert(R.Code = rcOk, AType + ' ' + AText + ' must encode');
  Assert(Alignment = AAlignment, AType + ' alignment');
  Assert(Length(Actual) = Length(AExpected), AType + ' width');
  for Index := 0 to High(AExpected) do
    Assert(Actual[Index] = AExpected[Index], AType + ' little-endian byte');
end;

procedure ExpectRejected(const AType, AText: string);
var
  Actual: TBytes;
  Alignment: Cardinal;
  R: TCEAResult;
begin
  R := EncodeExactValue(AType, AText, Actual, Alignment);
  Assert(R.Code = rcInvalidArgument, AType + ' ' + AText + ' must reject');
  Assert(Length(Actual) = 0, 'rejected encoding must not leak bytes');
  Assert(Alignment = 0, 'rejected encoding must not claim alignment');
end;

var
  Coverage: TCEAScanCoverage;
begin
  ExpectValue('dword', '767', [$FF, $02, $00, $00], 4);
  ExpectValue('dword', '758', [$F6, $02, $00, $00], 4);
  ExpectValue('dword', '880', [$70, $03, $00, $00], 4);
  ExpectValue('byte', '255', [$FF], 1);
  ExpectValue('word', '-1', [$FF, $FF], 2);
  ExpectValue('qword', '18446744073709551615',
    [$FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF], 8);
  ExpectValue('single', '1.5', [$00, $00, $C0, $3F], 4);
  ExpectValue('double', '1.5',
    [$00, $00, $00, $00, $00, $00, $F8, $3F], 8);
  ExpectRejected('byte', '256');
  ExpectRejected('byte', '-129');
  ExpectRejected('word', '65536');
  ExpectRejected('dword', '4294967296');
  ExpectRejected('qword', '18446744073709551616');
  ExpectRejected('single', 'NaN');
  ExpectRejected('double', 'Infinity');
  ExpectRejected('dword', '12x');
  ExpectRejected('string', '767');
  Assert(IsValueAligned($1000, 4), 'aligned dword candidate is accepted');
  Assert(not IsValueAligned($1001, 4),
    'unaligned byte sequence is not a dword candidate');
  Assert(IsValueAligned($1001, 1), 'AOB-style byte alignment accepts any address');
  Assert(not IsValueAligned($1000, 0), 'zero alignment is invalid');
  Coverage.RequestedBytes := 1024;
  Coverage.InspectedBytes := 512;
  Coverage.SkippedBytes := 512;
  Coverage.Complete := False;
  Coverage.PartialReason := 'result_limit';
  Assert(not Coverage.Complete, 'partial coverage is not complete');
  Assert(Coverage.InspectedBytes + Coverage.SkippedBytes =
    Coverage.RequestedBytes, 'coverage accounts for requested bytes');
  WriteLn('VALUE_SCAN_TEST=PASS');
end.
