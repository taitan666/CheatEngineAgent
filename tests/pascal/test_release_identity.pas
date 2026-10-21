program test_release_identity;

{$mode objfpc}{$H+}

uses
  SysUtils, cea_results, cea_release_identity;

var
  Reader: TCEAReleaseIdentity;
  Info: TCEAReleaseIdentityInfo;
  R: TCEAResult;
begin
  Reader := TCEAReleaseIdentity.Create;
  try
    R := Reader.ReadCurrent(Info);
    Assert(R.Code = rcOk, 'current executable identity is readable');
    Assert((Length(Info.Sha256) = 71) and
      (Copy(Info.Sha256, 1, 7) = 'sha256:'),
      'identity exposes a prefixed SHA-256');
    Assert(Info.ByteCount > 0, 'identity exposes executable length');
    Assert(Info.BuildChannel = 'internal',
      'development executable cannot claim public channel');
    Assert(Info.SignatureStatus <> 'valid',
      'unsigned test executable is never reported as trusted');
    Assert(Pos(ExtractFilePath(ParamStr(0)), R.DataJson) = 0,
      'identity projection does not expose a local path');
    Assert(ClassifyWindowsWarning(
      'Microsoft Defender Antivirus quarantined a threat') =
      wwcAntivirus, 'Antivirus warning is classified separately');
    Assert(ClassifyWindowsWarning(
      'Windows protected your PC: unrecognized app') =
      wwcSmartScreen, 'SmartScreen reputation warning is separate');
    Assert(ClassifyWindowsWarning('unknown message') = wwcOther,
      'unknown warning remains unclassified');
  finally
    Reader.Free;
  end;
  WriteLn('RELEASE_IDENTITY=PASS');
end.
