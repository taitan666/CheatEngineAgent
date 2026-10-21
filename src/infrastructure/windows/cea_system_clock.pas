unit cea_system_clock;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, DateUtils, Windows, cea_ports;

type
  TCEASystemClock = class(TObject, ICEAClock)
  public
    function UtcNowIso8601: string;
    function UtcAfterMinutes(const AMinutes: Word): string;
    function UtcAfterSeconds(const ASeconds: Cardinal): string;
  end;

implementation

function SystemTimeIso8601(const ASystemTime: TSystemTime): string;
begin
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.3dZ',
    [ASystemTime.wYear, ASystemTime.wMonth, ASystemTime.wDay,
     ASystemTime.wHour, ASystemTime.wMinute, ASystemTime.wSecond,
     ASystemTime.wMilliseconds]);
end;

function TCEASystemClock.UtcNowIso8601: string;
var
  SystemTime: TSystemTime;
begin
  GetSystemTime(SystemTime);
  Result := SystemTimeIso8601(SystemTime);
end;

function TCEASystemClock.UtcAfterMinutes(const AMinutes: Word): string;
var
  SystemTime: TSystemTime;
  Value: TDateTime;
begin
  GetSystemTime(SystemTime);
  Value := EncodeDateTime(SystemTime.wYear, SystemTime.wMonth,
    SystemTime.wDay, SystemTime.wHour, SystemTime.wMinute,
    SystemTime.wSecond, SystemTime.wMilliseconds) + AMinutes / 1440;
  DecodeDateFully(Value, SystemTime.wYear, SystemTime.wMonth,
    SystemTime.wDay, SystemTime.wDayOfWeek);
  DecodeTime(Value, SystemTime.wHour, SystemTime.wMinute,
    SystemTime.wSecond, SystemTime.wMilliseconds);
  Result := SystemTimeIso8601(SystemTime);
end;

function TCEASystemClock.UtcAfterSeconds(const ASeconds: Cardinal): string;
var
  SystemTime: TSystemTime;
  Value: TDateTime;
begin
  GetSystemTime(SystemTime);
  Value := EncodeDateTime(SystemTime.wYear, SystemTime.wMonth,
    SystemTime.wDay, SystemTime.wHour, SystemTime.wMinute,
    SystemTime.wSecond, SystemTime.wMilliseconds) + ASeconds / 86400;
  DecodeDateFully(Value, SystemTime.wYear, SystemTime.wMonth,
    SystemTime.wDay, SystemTime.wDayOfWeek);
  DecodeTime(Value, SystemTime.wHour, SystemTime.wMinute,
    SystemTime.wSecond, SystemTime.wMilliseconds);
  Result := SystemTimeIso8601(SystemTime);
end;

end.
