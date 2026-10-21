program test_windows_sha256;

{$mode objfpc}{$H+}

uses
  cea_ports, cea_windows_sha256;

var
  Hasher: TCEAWindowsSha256;
  Port: ICEAHasher;

begin
  Hasher := TCEAWindowsSha256.Create;
  Port := Hasher;
  try
    Assert(Port.HashUtf8('') =
      'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'SHA-256 empty-string vector matches FIPS result');
    Assert(Port.HashUtf8('abc') =
      'sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'SHA-256 abc vector matches FIPS result');
    Assert(Port.HashUtf8('AgentOS') =
      'sha256:ea9f7bb8f449c37ab876067b87f6c2504c2b72feaa778acfad6e7e4024910049',
      'SHA-256 application vector is deterministic');
    WriteLn('WINDOWS_SHA256=PASS');
  finally
    Port := nil;
    Hasher.Free;
  end;
end.
