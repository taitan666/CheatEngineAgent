program test_win32_effect_backend;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_results, cea_effect_backend_ports,
  cea_win32_effect_backend;

var
  Value: array[0..3] of Byte;
  Backend: TCEAWin32EffectBackend;
  R: TCEAResult;

begin
  Value[0] := $11;
  Value[1] := $22;
  Value[2] := $33;
  Value[3] := $44;
  Backend := TCEAWin32EffectBackend.Create(4096);
  try
    R := Backend.ReadCurrentHex(GetCurrentProcessId,
      QWord(PtrUInt(@Value[0])), 4);
    Assert((R.Code = rcOk) and
      (Pos('11223344', LowerCase(R.DataJson)) > 0),
      'read-only reconciliation observation returns current bytes');
    R := Backend.CompareWriteReadback(GetCurrentProcessId,
      QWord(PtrUInt(@Value[0])), '11223344', 'aabbccdd');
    Assert(R.Code = rcOk, 'compare/write/readback succeeds');
    Assert((Value[0] = $AA) and (Value[1] = $BB) and
      (Value[2] = $CC) and (Value[3] = $DD),
      'replacement bytes are applied');
    Assert((Pos('"before":"11223344"', LowerCase(R.DataJson)) > 0) and
      (Pos('"after":"aabbccdd"', LowerCase(R.DataJson)) > 0),
      'result contains before and verified after bytes');

    R := Backend.CompareWriteReadback(GetCurrentProcessId,
      QWord(PtrUInt(@Value[0])), '00000000', '01020304');
    Assert(R.Code = rcVerificationFailed,
      'changed original bytes reject the write');
    Assert(Value[0] = $AA, 'rejected write leaves memory unchanged');

    R := Backend.CompareWriteReadback(GetCurrentProcessId,
      QWord(PtrUInt(@Value[0])), 'aabbccdd', '11223344');
    Assert(R.Code = rcOk, 'self-test restores original bytes');
    Assert((Value[0] = $11) and (Value[3] = $44),
      'original bytes are restored');
    WriteLn('WIN32_EFFECT_BACKEND=PASS');
  finally
    Backend.Free;
  end;
end.
