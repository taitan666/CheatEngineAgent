program test_secret_store;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows, cea_results, cea_secret_store;

var
  Store: TCEASecretStore;
  Target, Secret, Loaded: string;
  R: TCEAResult;

begin
  Target := 'CheatEngineAgent/Test/' + IntToStr(GetCurrentProcessId);
  Secret := 'test-secret-' + IntToStr(GetTickCount64);
  Store := TCEASecretStore.Create;
  try
    Store.DeleteValue(Target);
    R := Store.SaveValue(Target, Secret);
    Assert(R.Code = rcOk, 'secret saves to Windows Credential Manager');
    Assert(Pos(Secret, R.DataJson) = 0, 'save result never exposes secret');
    R := Store.ResolveValue(Target, Loaded);
    Assert((R.Code = rcOk) and (Loaded = Secret),
      'saved secret resolves for provider transport');
    Assert(Pos(Secret, R.DataJson) = 0, 'resolve metadata never exposes secret');
    Loaded := StringOfChar(#0, Length(Loaded));
    Loaded := '';
    Assert(Store.DeleteValue(Target).Code = rcOk,
      'test credential is deleted');
    Assert(Store.ResolveValue(Target, Loaded).Code = rcUnauthenticated,
      'deleted credential no longer resolves');
    WriteLn('SECRET_STORE=PASS');
  finally
    Store.DeleteValue(Target);
    Store.Free;
    Secret := StringOfChar(#0, Length(Secret));
  end;
end.
