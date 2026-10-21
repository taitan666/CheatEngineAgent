unit cea_game_state_model;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, cea_field_model;

type
  // 游戏版本指纹：用于加载 Profile 前兼容性检测（PRD 6.7 FR-061）
  TCEAGameVersionFingerprint = record
    ExecutableSha256: string;
    ModuleSetHash: string;
    GameName: string;
    GameVersion: string;
    function IsValid: Boolean;
  end;

  TCEAGameStateModel = class
  private
    FFields: TCEAGameFieldArray;
    FGameName: string;
    FGameVersion: string;
    FExecutableSha256: string;
    FModuleSetHash: string;
    function FindIndex(const AFieldId: string): Integer;
  public
    constructor Create(const AGameName, AGameVersion,
      AExecutableSha256, AModuleSetHash: string);
    function AddField(const AField: TCEAGameField): Boolean;
    function UpdateField(const AField: TCEAGameField): Boolean;
    function GetField(const AFieldId: string;
      out AField: TCEAGameField): Boolean;
    function RemoveField(const AFieldId: string): Boolean;
    function FieldCount: Integer;
    function GetFields: TCEAGameFieldArray;
    function Fingerprint: TCEAGameVersionFingerprint;
    function MatchesVersion(const AExecutableSha256,
      AModuleSetHash: string): Boolean;
  end;

implementation

function TCEAGameVersionFingerprint.IsValid: Boolean;
begin
  Result := (ExecutableSha256 <> '') and (GameName <> '');
end;

constructor TCEAGameStateModel.Create(const AGameName, AGameVersion,
  AExecutableSha256, AModuleSetHash: string);
begin
  inherited Create;
  FGameName := AGameName;
  FGameVersion := AGameVersion;
  FExecutableSha256 := AExecutableSha256;
  FModuleSetHash := AModuleSetHash;
  SetLength(FFields, 0);
end;

function TCEAGameStateModel.FindIndex(const AFieldId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if FFields[I].FieldId = AFieldId then
      Exit(I);
  Result := -1;
end;

function TCEAGameStateModel.AddField(const AField: TCEAGameField): Boolean;
begin
  Result := False;
  if not AField.IsValid then Exit;
  if FindIndex(AField.FieldId) >= 0 then Exit;
  SetLength(FFields, Length(FFields) + 1);
  FFields[High(FFields)] := AField;
  Result := True;
end;

function TCEAGameStateModel.UpdateField(const AField: TCEAGameField): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not AField.IsValid then Exit;
  I := FindIndex(AField.FieldId);
  if I < 0 then Exit;
  FFields[I] := AField;
  Result := True;
end;

function TCEAGameStateModel.GetField(const AFieldId: string;
  out AField: TCEAGameField): Boolean;
var
  I: Integer;
begin
  I := FindIndex(AFieldId);
  if I < 0 then
  begin
    FillChar(AField, SizeOf(AField), 0);
    Exit(False);
  end;
  AField := FFields[I];
  Result := True;
end;

function TCEAGameStateModel.RemoveField(const AFieldId: string): Boolean;
var
  I: Integer;
begin
  I := FindIndex(AFieldId);
  Result := I >= 0;
  if not Result then Exit;
  for I := I to High(FFields) - 1 do
    FFields[I] := FFields[I + 1];
  SetLength(FFields, Length(FFields) - 1);
end;

function TCEAGameStateModel.FieldCount: Integer;
begin
  Result := Length(FFields);
end;

function TCEAGameStateModel.GetFields: TCEAGameFieldArray;
begin
  Result := FFields;
end;

function TCEAGameStateModel.Fingerprint: TCEAGameVersionFingerprint;
begin
  Result.ExecutableSha256 := FExecutableSha256;
  Result.ModuleSetHash := FModuleSetHash;
  Result.GameName := FGameName;
  Result.GameVersion := FGameVersion;
end;

function TCEAGameStateModel.MatchesVersion(const AExecutableSha256,
  AModuleSetHash: string): Boolean;
begin
  Result := (AExecutableSha256 <> '') and
    (AExecutableSha256 = FExecutableSha256);
  if Result and (FModuleSetHash <> '') then
    Result := AModuleSetHash = FModuleSetHash;
end;

end.
