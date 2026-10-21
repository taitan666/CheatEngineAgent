program test_field_command_flow;

{$mode objfpc}{$H+}
{$codepage utf8}

uses
  SysUtils, cea_results, cea_field_model, cea_game_state_model,
  cea_command_types, cea_command_bus, cea_state_capture_service,
  cea_win32_effect_backend;

var
  // 模拟「游戏进程内存中的金币字段」
  Gold: DWord;

  Backend: TCEAWin32EffectBackend;
  Bus: TCEAFieldCommandBus;
  Capture: TCEAStateCaptureService;

  Field: TCEAGameField;
  Command: TCEAFieldWriteCommand;
  WriteResult: TCEAFieldWriteResult;
  CaptureResult: TCEAFieldCaptureResult;
  R: TCEAResult;

begin
  Gold := 500; // 初始金币 500

  Backend := TCEAWin32EffectBackend.Create(4096);
  try
    Bus := TCEAFieldCommandBus.Create(Backend, GetProcessID, '');
    Capture := TCEAStateCaptureService.Create(Backend, GetProcessID);
    try
      // 1. 定义字段（已验证可写，指向 Gold 地址）
      FillChar(Field, SizeOf(Field), 0);
      Field.FieldId := 'player.gold';
      Field.DisplayName := '金币';
      Field.ValueType := 'dword';
      Field.Source := 'win32_memory';
      Field.Confidence := 1.0;
      Field.Access := faVerifiedWritable;
      Field.ValidationStatus := vsVerified;
      Field.LastUpdated := '2026-10-19T10:00:00Z';
      Field.AddressHex := '0x' + LowerCase(IntToHex(QWord(PtrUInt(@Gold)), 16));

      // 2. 采集当前值
      R := Capture.CaptureField(Field, CaptureResult);
      Assert(R.Code = rcOk, 'capture reads current field bytes');
      Assert(LowerCase(CaptureResult.BytesHex) = 'f4010000',
        'capture reads 500 as dword little-endian'); // 500 = 0x01F4

      // 3. 写入新值 999（对比-写入-读回）
      Command.FieldId := 'player.gold';
      Command.ValueType := 'dword';
      Command.TargetValue := '999';
      Command.ExpectedCurrentValue := '500';
      Command.ProfileId := 'profile-test';
      Command.AddressHex := Field.AddressHex;
      R := Bus.ExecuteWrite(Field, Command, WriteResult);
      Assert(R.Code = rcOk, 'field write command succeeds');
      Assert(WriteResult.Outcome = coVerified,
        'write readback verified');
      Assert(Gold = 999, 'game memory actually updated to 999');

      // 4. 重新采集验证（两级反馈：验证成功）
      R := Capture.CaptureField(Field, CaptureResult);
      Assert(R.Code = rcOk, 're-capture after write');
      Assert(CaptureResult.Changed, 'capture detects value change');
      Assert(LowerCase(CaptureResult.BytesHex) = 'e7030000',
        'capture reads 999 as dword little-endian'); // 999 = 0x03E7

      // 5. 状态冲突检测：预期原值不匹配 → 拒绝
      Command.ExpectedCurrentValue := '500'; // 但现在是 999
      R := Bus.ExecuteWrite(Field, Command, WriteResult);
      Assert(R.Code <> rcOk, 'stale expected value rejected');
      Assert(WriteResult.Outcome = coOverwritten,
        'mismatched expected value flagged as overwritten');
      Assert(Gold = 999, 'game memory unchanged on stale write');

      // 6. 只读字段拒绝写入（AC-005）
      Field.Access := faReadOnly;
      Command.ExpectedCurrentValue := '999';
      R := Bus.ExecuteWrite(Field, Command, WriteResult);
      Assert(R.Code <> rcOk, 'read-only field write rejected');
      Assert(WriteResult.Outcome = coRejected, 'read-only rejected');

      WriteLn('FIELD_COMMAND_FLOW=PASS');
    finally
      Capture.Free;
      Bus.Free;
    end;
  finally
    Backend.Free;
  end;
end.
