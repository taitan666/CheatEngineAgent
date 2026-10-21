program test_field_model;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, cea_field_model, cea_game_state_model;

var
  Field: TCEAGameField;
  Model: TCEAGameStateModel;
  ReadBack: TCEAGameField;
  Access: TCEAFieldAccess;
  Status: TCEAValidationStatus;
  Fields: TCEAGameFieldArray;
begin
  // 字段有效性
  FillChar(Field, SizeOf(Field), 0);
  Assert(not Field.IsValid, 'empty field is invalid');
  Field.FieldId := 'player.gold';
  Field.DisplayName := '金币';
  Field.ValueType := 'integer';
  Field.ValueJson := '500';
  Field.Source := 'win32_memory';
  Field.Confidence := 0.98;
  Field.Access := faReadOnly;
  Field.ValidationStatus := vsObserved;
  Field.LastUpdated := '2026-10-19T10:00:00Z';
  Assert(Field.IsValid, 'complete field is valid');
  Assert(Field.Access = faReadOnly, 'default access is read-only');
  Assert(Field.ValidationStatus = vsObserved,
    'default validation status is observed');

  // 枚举文本往返
  Assert(FieldAccessText(faVerifiedWritable) = 'verified_writable');
  Assert(TryParseFieldAccess('pending_write', Access));
  Assert(Access = faPendingWrite);
  Assert(not TryParseFieldAccess('bogus', Access));
  Assert(ValidationStatusText(vsHypothesis) = 'hypothesis');
  Assert(TryParseValidationStatus('verified', Status));
  Assert(Status = vsVerified);

  // 状态模型
  Model := TCEAGameStateModel.Create('TestGame', '1.0',
    'sha256:' + StringOfChar('a', 64), 'sha256:' + StringOfChar('b', 64));
  try
    Assert(Model.FieldCount = 0, 'model starts empty');
    Assert(Model.AddField(Field), 'add valid field');
    Assert(Model.FieldCount = 1);
    Assert(not Model.AddField(Field), 'duplicate field id rejected');

    Assert(Model.GetField('player.gold', ReadBack));
    Assert(ReadBack.DisplayName = '金币');
    Assert(not Model.GetField('missing', ReadBack),
      'missing field returns false');

    Field.ValueJson := '999';
    Assert(Model.UpdateField(Field), 'update existing field');
    Assert(Model.GetField('player.gold', ReadBack));
    Assert(ReadBack.ValueJson = '999', 'update reflects new value');

    Assert(Model.MatchesVersion('sha256:' + StringOfChar('a', 64),
      'sha256:' + StringOfChar('b', 64)), 'matching fingerprint');
    Assert(not Model.MatchesVersion('sha256:' + StringOfChar('c', 64),
      'sha256:' + StringOfChar('b', 64)), 'mismatched exe hash rejected');

    Fields := Model.GetFields;
    Assert(Length(Fields) = 1, 'get fields returns one');

    Assert(Model.RemoveField('player.gold'), 'remove field');
    Assert(Model.FieldCount = 0, 'field removed');
  finally
    Model.Free;
  end;

  WriteLn('FIELD_MODEL=PASS');
end.
