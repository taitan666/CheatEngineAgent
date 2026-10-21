unit cea_command_bus;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, cea_results, cea_effect_backend_ports, cea_command_types,
  cea_field_model;

type
  // 字段级写入命令总线：把结构化字段命令转换为受治理的内存写入，
  // 复用 compare-write-readback 原语 + 重读验证。
  TCEAFieldCommandBus = class
  private
    FEffectBackend: ICEAMemoryEffectBackend;
    FPid: Cardinal;
    FExecutableSha256: string;
    function EncodeValue(const AValueType, AText: string;
      out AHex: string): TCEAResult;
    function TryParseHexAddress(const AText: string;
      out AValue: QWord): Boolean;
  public
    constructor Create(const AEffectBackend: ICEAMemoryEffectBackend;
      const APid: Cardinal; const AExecutableSha256: string);
    // 执行字段级写入：校验 → 对比写入 → 重读验证 → 两级反馈
    function ExecuteWrite(const AField: TCEAGameField;
      const ACommand: TCEAFieldWriteCommand;
      out AResult: TCEAFieldWriteResult): TCEAResult;
  end;

implementation

uses
  FPJSON, JSONParser, cea_value_scan_types;

constructor TCEAFieldCommandBus.Create(
  const AEffectBackend: ICEAMemoryEffectBackend;
  const APid: Cardinal; const AExecutableSha256: string);
begin
  inherited Create;
  FEffectBackend := AEffectBackend;
  FPid := APid;
  FExecutableSha256 := AExecutableSha256;
end;

function TCEAFieldCommandBus.TryParseHexAddress(const AText: string;
  out AValue: QWord): Boolean;
begin
  Result := (Length(AText) > 2) and
    (LowerCase(Copy(AText, 1, 2)) = '0x') and
    TryStrToQWord('$' + Copy(AText, 3, MaxInt), AValue) and (AValue <> 0);
end;

function TCEAFieldCommandBus.EncodeValue(const AValueType, AText: string;
  out AHex: string): TCEAResult;
var
  Bytes: TBytes;
  Alignment: Cardinal;
  I: Integer;
begin
  AHex := '';
  Result := EncodeExactValue(AValueType, AText, Bytes, Alignment);
  if Result.Failed then Exit;
  AHex := '';
  for I := 0 to High(Bytes) do
    AHex := AHex + LowerCase(IntToHex(Bytes[I], 2));
end;

function TCEAFieldCommandBus.ExecuteWrite(const AField: TCEAGameField;
  const ACommand: TCEAFieldWriteCommand;
  out AResult: TCEAFieldWriteResult): TCEAResult;
var
  ExpectedHex, ReplacementHex: string;
  ObservedJson: TCEAResult;
  Data: TJSONData;
  CurrentAfterHex: string;
  Address: QWord;
begin
  FillChar(AResult, SizeOf(AResult), 0);

  // 1. 字段必须已验证可写（FR-040 / AC-005）
  if AField.Access <> faVerifiedWritable then
  begin
    AResult.Outcome := coRejected;
    AResult.StableCode := 'field_not_writable';
    Exit(TCEAResult.Error(rcUnauthorized, AResult.StableCode, '{}'));
  end;

  // 2. 命令必须有效，且 field_id 匹配
  if (not ACommand.IsValid) or (ACommand.FieldId <> AField.FieldId) then
  begin
    AResult.Outcome := coRejected;
    AResult.StableCode := 'command_invalid';
    Exit(TCEAResult.Error(rcInvalidArgument, AResult.StableCode, '{}'));
  end;

  // 3. 值类型编码（类型转换 + 边界检查，FR-041）
  if not TryParseHexAddress(ACommand.AddressHex, Address) then
  begin
    AResult.Outcome := coRejected;
    AResult.StableCode := 'address_invalid';
    Exit(TCEAResult.Error(rcInvalidArgument, AResult.StableCode, '{}'));
  end;
  Result := EncodeValue(ACommand.ValueType, ACommand.TargetValue,
    ReplacementHex);
  if Result.Failed then
  begin
    AResult.Outcome := coRejected;
    AResult.StableCode := 'value_encoding_failed';
    Exit(Result);
  end;
  Result := EncodeValue(ACommand.ValueType, ACommand.ExpectedCurrentValue,
    ExpectedHex);
  if Result.Failed then
  begin
    AResult.Outcome := coRejected;
    AResult.StableCode := 'expected_value_encoding_failed';
    Exit(Result);
  end;

  // 4. 对比-写入-读回（原子，复用现有原语）
  Result := FEffectBackend.CompareWriteReadback(FPid, Address,
    ExpectedHex, ReplacementHex);
  if Result.Failed then
  begin
    if Result.StableCode = 'memory_effect_original_changed' then
      AResult.Outcome := coOverwritten
    else if (Result.StableCode = 'memory_effect_write_failed') or
      (Result.StableCode = 'memory_effect_partial_write') or
      (Result.StableCode = 'memory_effect_readback_failed') or
      (Result.StableCode = 'memory_effect_readback_mismatch') then
      AResult.Outcome := coSentNotApplied
    else
      AResult.Outcome := coRejected;
    AResult.StableCode := Result.StableCode;
    AResult.DetailJson := Result.DataJson;
    Exit(Result);
  end;

  // 5. 重读验证（FR-044 / AC-007：只有实际状态符合预期才验证成功）
  AResult.Outcome := coSubmitted;
  AResult.StableCode := 'command_submitted';
  AResult.DetailJson := Result.DataJson;
  AResult.ReceiptId := Result.ReceiptId;
  AResult.ProofId := Result.ProofId;

  // compare-write-readback 已内含读回验证（readback_verified:true），
  // 这里再做一次独立读回以确认持久值。
  ObservedJson := FEffectBackend.ReadCurrentHex(FPid, Address,
    Length(ReplacementHex) div 2);
  if ObservedJson.Failed then
  begin
    AResult.Outcome := coSentNotApplied;
    AResult.StableCode := ObservedJson.StableCode;
    Exit(TCEAResult.Ok(Result.DataJson));
  end;
  Data := nil;
  try
    Data := GetJSON(ObservedJson.DataJson);
    CurrentAfterHex := TJSONObject(Data).Get('current', '');
  finally
    Data.Free;
  end;
  if LowerCase(CurrentAfterHex) = ReplacementHex then
  begin
    AResult.Outcome := coVerified;
    AResult.StableCode := 'verified';
    Result := TCEAResult.Ok(ObservedJson.DataJson);
    Result.ReceiptId := AResult.ReceiptId;
    Result.ProofId := AResult.ProofId;
    Exit;
  end;
  // 写入成功但读回不一致 → 被游戏覆盖
  AResult.Outcome := coOverwritten;
  AResult.StableCode := 'overwritten_by_game';
  Result := TCEAResult.Error(rcVerificationFailed, AResult.StableCode,
    '{"after":"' + CurrentAfterHex + '"}');
end;

end.
