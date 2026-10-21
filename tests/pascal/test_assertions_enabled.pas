program test_assertions_enabled;

{$mode objfpc}{$H+}

begin
  {$IFOPT C+}
  WriteLn('ASSERTIONS_ENABLED=PASS');
  {$ELSE}
  WriteLn('ASSERTIONS_ENABLED=FAIL');
  Halt(42);
  {$ENDIF}
end.
