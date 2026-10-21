unit cea_pointer_chain;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$interfaces corba}

{ Multi-level pointer chain resolution.

  A chain is expressed the way Cheat Engine and .CT files express it: a module
  relative base plus a list of hex offsets. The number of memory reads equals the
  number of offsets, and the last offset is added to the last pointer value
  without a further dereference. That matches CE's `getAddress`:

    address := moduleBase + baseOffset;
    for i := 0 to High(Offsets) do
      address := ReadPointer(address) + Offsets[i];

  So a chain with two offsets performs two reads. A chain with zero offsets is a
  plain module-relative address and performs no reads at all.

  The reader is an injected port so the algorithm is testable without any real
  process, and so the Windows backend stays behind the platform boundary. }

interface

uses
  SysUtils, cea_results;

const
  { Deepest chain accepted. Real .CT files rarely exceed five levels; eight
    leaves room while keeping a malformed chain from looping unbounded. }
  CeaPointerChainMaxDepth = 8;

type
  TCEAPointerOffsetArray = array of QWord;

  TCEAPointerChainSpec = record
    ModuleName: string;
    ModuleBaseOffset: QWord;
    Offsets: TCEAPointerOffsetArray;
    AddressWidthBits: Cardinal;
    function IsValid: Boolean;
    function Depth: Integer;
  end;

  ICEAPointerMemoryReader = interface
    { Reads AByteCount bytes at AAddress. Implementations must return exactly
      AByteCount bytes on success; the resolver treats a short read as a failure
      rather than padding it. }
    function ReadPointerBytes(const AAddress: QWord;
      const AByteCount: Cardinal; out ABytes: TBytes): TCEAResult;
  end;

  TCEAPointerChainResolver = class
  private
    FReader: ICEAPointerMemoryReader;
    FMaxDepth: Cardinal;
  public
    constructor Create(const AReader: ICEAPointerMemoryReader;
      const AMaxDepth: Cardinal = CeaPointerChainMaxDepth);
    function Resolve(const AModuleBase: QWord;
      const ASpec: TCEAPointerChainSpec; out AAddress: QWord): TCEAResult;
    property MaxDepth: Cardinal read FMaxDepth;
  end;

{ Accepts an optional 0x prefix followed by hex digits, at most 16 of them. }
function TryParseHexOffset(const AText: string; out AValue: QWord): Boolean;

{ Splits a .CT address expression into its module-relative parts.

  CE writes a module-relative entry as `module.exe+1A8`, and puts only the
  post-dereference offsets in <Offsets>. The `+1A8` is the module base offset and
  is part of the chain: dropping it resolves the chain from offset 0 and lands on
  the wrong address. This is the one place that split is defined, so the UI and
  any future importer agree on it.

  Accepted:   `game.exe+1A8`, `game.exe + 0x1A8`, `game.exe+0`
  Rejected:   `game.exe` (no '+' at all: CE writes a bare module name only for
              absolute/broken entries, and guessing offset 0 would resolve to a
              plausible-looking but wrong address),
              `game.exe+` (empty offset), `0x1234` (no module, absolute address),
              `game.exe+xyz` (offset is not hex) }
function ParseCTAddressExpression(const AAddressExpression: string;
  out AModuleName: string; out ABaseOffset: QWord): TCEAResult;

{ Serializes a spec back to the object form so it can be persisted on a field.
  The inverse of ParsePointerChainSpec: parse(encode(spec)) keeps the base
  offset and every offset intact. }
function PointerChainSpecJson(const ASpec: TCEAPointerChainSpec): string;

{ Parses a chain definition. Two shapes are accepted:

    ["10","1a8"]                        base offset comes from the caller
    {"base":"0x1234ABC","offsets":["10","1a8"]}

  The object form keeps the base offset next to the offsets, which is what a
  persisted field needs: a chain whose base offset was lost would silently
  resolve to a different address. When both are given the object's base wins. }
function ParsePointerChainSpec(const AOffsetsJson, AModuleName: string;
  const AModuleBaseOffset: QWord; const AAddressWidthBits: Cardinal;
  out ASpec: TCEAPointerChainSpec): TCEAResult;

implementation

uses
  fpjson, jsonparser;

function TCEAPointerChainSpec.IsValid: Boolean;
begin
  Result := (AddressWidthBits in [32, 64]) and
    (Depth <= CeaPointerChainMaxDepth) and
    (ModuleName <> '');
end;

function TCEAPointerChainSpec.Depth: Integer;
begin
  Result := Length(Offsets);
end;

function TryParseHexOffset(const AText: string; out AValue: QWord): Boolean;
var
  Start, Index, Digits: Integer;
  Digit: Integer;
  Accumulated: QWord;
begin
  AValue := 0;
  Result := False;
  Start := 1;
  if (Length(AText) >= 2) and (AText[1] = '0') and
     ((AText[2] = 'x') or (AText[2] = 'X')) then
    Start := 3;
  Digits := Length(AText) - Start + 1;
  if (Digits <= 0) or (Digits > 16) then
    Exit;
  Accumulated := 0;
  for Index := Start to Length(AText) do
  begin
    case AText[Index] of
      '0'..'9': Digit := Ord(AText[Index]) - Ord('0');
      'a'..'f': Digit := Ord(AText[Index]) - Ord('a') + 10;
      'A'..'F': Digit := Ord(AText[Index]) - Ord('A') + 10;
    else
      Exit;
    end;
    Accumulated := (Accumulated shl 4) or QWord(Digit);
  end;
  AValue := Accumulated;
  Result := True;
end;

function ParseCTAddressExpression(const AAddressExpression: string;
  out AModuleName: string; out ABaseOffset: QWord): TCEAResult;
var
  PlusAt: SizeInt;
  BaseText: string;
begin
  AModuleName := '';
  ABaseOffset := 0;
  if Trim(AAddressExpression) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_address_expression_required', '{}'));
  PlusAt := Pos('+', AAddressExpression);
  if PlusAt = 0 then
    // No '+' means a bare absolute address. Treating it as a module relative
    // chain would be a silent misread, so it is rejected instead.
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_address_expression_not_module_relative', '{}'));
  AModuleName := Trim(Copy(AAddressExpression, 1, PlusAt - 1));
  BaseText := Trim(Copy(AAddressExpression, PlusAt + 1,
    Length(AAddressExpression)));
  if AModuleName = '' then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_address_expression_module_missing', '{}'));
  if not TryParseHexOffset(BaseText, ABaseOffset) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'ct_address_expression_offset_invalid', '{}'));
  Result := TCEAResult.Ok('{"module":"' + AModuleName +
    '","base_offset":"0x' + IntToHex(ABaseOffset, 16) + '"}');
end;

function PointerChainSpecJson(const ASpec: TCEAPointerChainSpec): string;
var
  Index: Integer;
  Offsets: string;
begin
  Offsets := '';
  for Index := 0 to High(ASpec.Offsets) do
  begin
    if Offsets <> '' then
      Offsets := Offsets + ',';
    Offsets := Offsets + '"' + IntToHex(ASpec.Offsets[Index], 1) + '"';
  end;
  Result := '{"base":"0x' + IntToHex(ASpec.ModuleBaseOffset, 16) +
    '","offsets":[' + Offsets + ']}';
end;

function ParsePointerChainSpec(const AOffsetsJson, AModuleName: string;
  const AModuleBaseOffset: QWord; const AAddressWidthBits: Cardinal;
  out ASpec: TCEAPointerChainSpec): TCEAResult;
var
  Data: TJSONData;
  Item: TJSONData;
  ArrayNode: TJSONArray;
  ObjectNode: TJSONObject;
  BaseText: string;
  BaseOffset: QWord;
  Index: Integer;
begin
  FillChar(ASpec, SizeOf(ASpec), 0);
  ASpec.ModuleName := AModuleName;
  ASpec.ModuleBaseOffset := AModuleBaseOffset;
  ASpec.AddressWidthBits := AAddressWidthBits;
  if not (AAddressWidthBits in [32, 64]) then
    Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_chain_width_invalid',
      '{"address_width_bits":' + IntToStr(AAddressWidthBits) + '}'));
  if Trim(AOffsetsJson) = '' then
    Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_chain_offsets_required',
      '{}'));
  Data := nil;
  try
    try
      Data := GetJSON(AOffsetsJson);
    except
      Exit(TCEAResult.Error(rcInvalidArgument,
        'pointer_chain_offsets_json_invalid', '{}'));
    end;
    if Data = nil then
      Exit(TCEAResult.Error(rcInvalidArgument,
        'pointer_chain_offsets_array_required', '{}'));
    if Data.JSONType = jtObject then
    begin
      ObjectNode := TJSONObject(Data);
      // The object form carries the module base offset, so a persisted chain
      // stays self-contained. A malformed base is rejected rather than
      // ignored: silently falling back to the caller's offset would resolve
      // the chain against the wrong address.
      if ObjectNode.IndexOfName('base') >= 0 then
      begin
        BaseText := Trim(ObjectNode.Get('base', ''));
        if not TryParseHexOffset(BaseText, BaseOffset) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'pointer_chain_base_invalid', '{}'));
        ASpec.ModuleBaseOffset := BaseOffset;
      end;
      Item := ObjectNode.Find('offsets');
      if (Item = nil) or (Item.JSONType <> jtArray) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'pointer_chain_offsets_array_required', '{}'));
      ArrayNode := TJSONArray(Item);
    end
    else if Data.JSONType = jtArray then
      ArrayNode := TJSONArray(Data)
    else
      Exit(TCEAResult.Error(rcInvalidArgument,
        'pointer_chain_offsets_array_required', '{}'));
    if ArrayNode.Count > CeaPointerChainMaxDepth then
      Exit(TCEAResult.Error(rcBudgetExceeded, 'pointer_chain_depth_exceeded',
        '{"depth":' + IntToStr(ArrayNode.Count) + ',"max":' +
        IntToStr(CeaPointerChainMaxDepth) + '}'));
    SetLength(ASpec.Offsets, ArrayNode.Count);
    for Index := 0 to ArrayNode.Count - 1 do
    begin
      Item := ArrayNode.Items[Index];
      if Item.JSONType <> jtString then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'pointer_chain_offset_not_string',
          '{"index":' + IntToStr(Index) + '}'));
      if not TryParseHexOffset(Trim(Item.AsString), ASpec.Offsets[Index]) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'pointer_chain_offset_invalid',
          '{"index":' + IntToStr(Index) + '}'));
    end;
    Result := TCEAResult.Ok('{"depth":' + IntToStr(ASpec.Depth) +
      ',"base_offset":"0x' + IntToHex(ASpec.ModuleBaseOffset, 16) + '"}');
  finally
    Data.Free;
  end;
end;

constructor TCEAPointerChainResolver.Create(
  const AReader: ICEAPointerMemoryReader; const AMaxDepth: Cardinal);
begin
  inherited Create;
  FReader := AReader;
  FMaxDepth := AMaxDepth;
end;

function TCEAPointerChainResolver.Resolve(const AModuleBase: QWord;
  const ASpec: TCEAPointerChainSpec; out AAddress: QWord): TCEAResult;
var
  Level, Width: Cardinal;
  Bytes: TBytes;
  Current, PointerValue, Offset, Accumulated: QWord;
  Index: Integer;
begin
  AAddress := 0;
  if FReader = nil then
    Exit(TCEAResult.Error(rcInternalError, 'pointer_chain_reader_missing',
      '{}'));
  if not ASpec.IsValid then
    Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_chain_spec_invalid', '{}'));
  if QWord(ASpec.Depth) > QWord(FMaxDepth) then
    Exit(TCEAResult.Error(rcBudgetExceeded, 'pointer_chain_depth_exceeded',
      '{"depth":' + IntToStr(ASpec.Depth) + ',"max":' +
      IntToStr(FMaxDepth) + '}'));
  Width := ASpec.AddressWidthBits div 8;

  if AModuleBase > High(QWord) - ASpec.ModuleBaseOffset then
    Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_chain_address_overflow',
      '{"level":-1}'));
  Current := AModuleBase + ASpec.ModuleBaseOffset;

  for Index := 0 to High(ASpec.Offsets) do
  begin
    Level := Cardinal(Index);
    if Current = 0 then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'pointer_chain_null_pointer', '{"level":' + IntToStr(Level) + '}'));
    Result := FReader.ReadPointerBytes(Current, Width, Bytes);
    if Result.Failed then
      Exit(TCEAResult.Error(rcVerificationFailed, 'pointer_chain_read_failed',
        '{"level":' + IntToStr(Level) + ',"reader_code":"' +
        Result.StableCode + '"}'));
    if Cardinal(Length(Bytes)) <> Width then
      Exit(TCEAResult.Error(rcVerificationFailed, 'pointer_chain_short_read',
        '{"level":' + IntToStr(Level) + ',"expected":' + IntToStr(Width) +
        ',"actual":' + IntToStr(Length(Bytes)) + '}'));
    PointerValue := 0;
    for Level := 0 to Width - 1 do
      PointerValue := PointerValue or
        (QWord(Bytes[Level]) shl (Level * 8));
    if PointerValue = 0 then
      Exit(TCEAResult.Error(rcVerificationFailed,
        'pointer_chain_null_pointer', '{"level":' + IntToStr(Index) + '}'));
    Offset := ASpec.Offsets[Index];
    if PointerValue > High(QWord) - Offset then
      Exit(TCEAResult.Error(rcInvalidArgument, 'pointer_chain_address_overflow',
        '{"level":' + IntToStr(Index) + '}'));
    Accumulated := PointerValue + Offset;
    if ASpec.AddressWidthBits = 32 then
    begin
      { A 32-bit target cannot hold an address above 4 GiB; a value past that
        means the chain was read with the wrong width. }
      if Accumulated > High(Cardinal) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'pointer_chain_address_width_invalid',
          '{"level":' + IntToStr(Index) + '}'));
    end;
    Current := Accumulated;
  end;

  AAddress := Current;
  Result := TCEAResult.Ok('{"address":"0x' + IntToHex(Current, 16) +
    '","depth":' + IntToStr(ASpec.Depth) + '}');
end;

end.
