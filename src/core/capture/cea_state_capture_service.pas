unit cea_state_capture_service;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, FPJSON, JSONParser, cea_results, cea_effect_backend_ports,
  cea_field_model;

type
  // 字段级采集：读字段当前值（hex 字节），检测变化（单调递增序列号 + 时间戳）
  TCEAFieldCaptureResult = record
    AddressHex: string;
    BytesHex: string;
    CapturedAt: string;   // UTC ISO8601
    Sequence: QWord;      // 单调递增，供统一时间线使用
    Changed: Boolean;     // 相对上次采集是否变化
  end;

  TCEAStateCaptureService = class
  private
    FBackend: ICEAMemoryEffectBackend;
    FPid: Cardinal;
    FSequence: QWord;
    FLastBytesHex: string;
    function TryParseHexAddress(const AText: string;
      out AValue: QWord): Boolean;
  public
    constructor Create(const ABackend: ICEAMemoryEffectBackend;
      const APid: Cardinal);
    // 读字段当前值（按 value_type 决定字节宽）
    function CaptureField(const AField: TCEAGameField;
      out AResult: TCEAFieldCaptureResult): TCEAResult;
    procedure ResetBaseline;
  end;

implementation

function ValueTypeByteWidth(const AValueType: string): Cardinal;
begin
  if AValueType = 'byte' then Result := 1
  else if AValueType = 'word' then Result := 2
  else if (AValueType = 'dword') or (AValueType = 'single') or
          (AValueType = 'integer') or (AValueType = 'bool') then Result := 4
  else if (AValueType = 'qword') or (AValueType = 'double') then Result := 8
  else Result := 0;
end;

constructor TCEAStateCaptureService.Create(
  const ABackend: ICEAMemoryEffectBackend; const APid: Cardinal);
begin
  inherited Create;
  FBackend := ABackend;
  FPid := APid;
  FSequence := 0;
  FLastBytesHex := '';
end;

function TCEAStateCaptureService.TryParseHexAddress(const AText: string;
  out AValue: QWord): Boolean;
begin
  Result := (Length(AText) > 2) and
    (LowerCase(Copy(AText, 1, 2)) = '0x') and
    TryStrToQWord('$' + Copy(AText, 3, MaxInt), AValue) and (AValue <> 0);
end;

procedure TCEAStateCaptureService.ResetBaseline;
begin
  FLastBytesHex := '';
end;

function TCEAStateCaptureService.CaptureField(const AField: TCEAGameField;
  out AResult: TCEAFieldCaptureResult): TCEAResult;
var
  Address: QWord;
  ByteCount: Cardinal;
  ReadResult: TCEAResult;
  Data: TJSONData;
  BytesHex: string;
begin
  FillChar(AResult, SizeOf(AResult), 0);
  if not TryParseHexAddress(AField.AddressHex, Address) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'capture_field_address_required', '{}'));
  ByteCount := ValueTypeByteWidth(AField.ValueType);
  if ByteCount = 0 then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'capture_field_value_type_unsupported', '{}'));
  ReadResult := FBackend.ReadCurrentHex(FPid, Address, ByteCount);
  if ReadResult.Failed then Exit(ReadResult);
  Data := nil;
  try
    Data := GetJSON(ReadResult.DataJson);
    BytesHex := TJSONObject(Data).Get('current', '');
  finally
    Data.Free;
  end;
  Inc(FSequence);
  AResult.AddressHex := '0x' + LowerCase(IntToHex(Address, 16));
  AResult.BytesHex := BytesHex;
  AResult.CapturedAt := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  AResult.Sequence := FSequence;
  AResult.Changed := (FLastBytesHex <> '') and (FLastBytesHex <> BytesHex);
  FLastBytesHex := BytesHex;
  Result := TCEAResult.Ok('{"address":"' + AResult.AddressHex +
    '","bytes":"' + BytesHex + '","sequence":' + IntToStr(FSequence) +
    ',"changed":' + BoolToStr(AResult.Changed, True) + '}');
end;

end.
