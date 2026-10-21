program test_pointer_chain;

{$mode objfpc}{$H+}
{$interfaces corba}

{ Verifies multi-level pointer chain resolution without touching any process:
  the reader is a canned-response test double, so every branch (null pointer,
  short read, overflow, width mismatch) is exercised deterministically. }

uses
  SysUtils, Classes, cea_results, cea_pointer_chain;

type
  TCannedReader = class(TObject, ICEAPointerMemoryReader)
  private
    FValues: TStringList;
    FFailAt: QWord;
    FShortAt: QWord;
  public
    ReadCount: Cardinal;
    constructor Create;
    destructor Destroy; override;
    { Maps an address to the raw little-endian pointer bytes. }
    procedure SetPointer(const AAddress: QWord; const AValue: QWord;
      const AByteCount: Cardinal);
    function ReadPointerBytes(const AAddress: QWord;
      const AByteCount: Cardinal; out ABytes: TBytes): TCEAResult;
  end;

constructor TCannedReader.Create;
begin
  inherited Create;
  FValues := TStringList.Create;
  FValues.NameValueSeparator := '=';
  FFailAt := QWord(-1);
  FShortAt := QWord(-1);
end;

destructor TCannedReader.Destroy;
begin
  FValues.Free;
  inherited Destroy;
end;

procedure TCannedReader.SetPointer(const AAddress: QWord; const AValue: QWord;
  const AByteCount: Cardinal);
var
  Index: Cardinal;
  Hex: string;
begin
  Hex := '';
  for Index := 0 to AByteCount - 1 do
    Hex := Hex + IntToHex(Byte((AValue shr (Index * 8)) and $FF), 2);
  FValues.Values[IntToHex(AAddress, 16)] := Hex;
end;

function TCannedReader.ReadPointerBytes(const AAddress: QWord;
  const AByteCount: Cardinal; out ABytes: TBytes): TCEAResult;
var
  Hex: string;
  Index: Cardinal;
begin
  ABytes := nil;
  Inc(ReadCount);
  if AAddress = FFailAt then
    Exit(TCEAResult.Error(rcVerificationFailed, 'memory_read_failed', '{}'));
  Hex := FValues.Values[IntToHex(AAddress, 16)];
  if Hex = '' then
    Exit(TCEAResult.Error(rcVerificationFailed, 'memory_read_unmapped', '{}'));
  if AAddress = FShortAt then
    SetLength(Hex, 2);
  SetLength(ABytes, Length(Hex) div 2);
  for Index := 0 to High(ABytes) do
    ABytes[Index] := Byte(StrToInt('$' + Copy(Hex, Index * 2 + 1, 2)));
  Result := TCEAResult.Ok('{}');
end;

function MakeSpec(const AOffsets: array of QWord;
  const AWidth: Cardinal = 64): TCEAPointerChainSpec;
var
  Index: Integer;
begin
  Result.ModuleName := 'GameAssembly.dll';
  Result.ModuleBaseOffset := 0;
  Result.AddressWidthBits := AWidth;
  SetLength(Result.Offsets, Length(AOffsets));
  for Index := 0 to High(AOffsets) do
    Result.Offsets[Index] := AOffsets[Index];
end;

var
  Reader: TCannedReader;
  Resolver: TCEAPointerChainResolver;
  Spec: TCEAPointerChainSpec;
  R: TCEAResult;
  Address: QWord;
  Value: QWord;
  BaseOffset: QWord;
  ModuleName: string;

begin
  Reader := TCannedReader.Create;
  try
    // --- Hex offset parsing ---
    Assert(TryParseHexOffset('10', Value) and (Value = 16),
      'bare hex offset parses');
    Assert(TryParseHexOffset('0x1a8', Value) and (Value = 424),
      '0x prefixed offset parses');
    Assert(TryParseHexOffset('1A8', Value) and (Value = 424),
      'uppercase hex offset parses');
    Assert(TryParseHexOffset('FFFFFFFFFFFFFFFF', Value) and
      (Value = High(QWord)), 'full width offset parses');
    Assert(not TryParseHexOffset('', Value), 'empty offset is rejected');
    Assert(not TryParseHexOffset('xyz', Value), 'non hex offset is rejected');
    Assert(not TryParseHexOffset('0x', Value), 'bare prefix is rejected');
    Assert(not TryParseHexOffset('12345678901234567', Value),
      'offset wider than 64 bits is rejected');

    // --- .CT address expression split (module base offset lives here) ---
    R := ParseCTAddressExpression('SampleOfflineGame.exe+0020', ModuleName,
      BaseOffset);
    Assert(not R.Failed, 'module relative expression parses');
    Assert(ModuleName = 'SampleOfflineGame.exe', 'module name is split out');
    Assert(BaseOffset = $20, 'base offset is split out of the expression');

    R := ParseCTAddressExpression('game.exe + 0x1A8', ModuleName, BaseOffset);
    Assert(not R.Failed and (BaseOffset = $1A8),
      'spaced 0x base offset parses');

    R := ParseCTAddressExpression('game.exe+', ModuleName, BaseOffset);
    Assert(R.StableCode = 'ct_address_expression_offset_invalid',
      'empty base offset is rejected');

    R := ParseCTAddressExpression('0x1234', ModuleName, BaseOffset);
    Assert(R.StableCode = 'ct_address_expression_not_module_relative',
      'absolute address is rejected rather than misread as a module chain');

    R := ParseCTAddressExpression('+20', ModuleName, BaseOffset);
    Assert(R.StableCode = 'ct_address_expression_module_missing',
      'expression without a module name is rejected');

    R := ParseCTAddressExpression('game.exe+zz', ModuleName, BaseOffset);
    Assert(R.StableCode = 'ct_address_expression_offset_invalid',
      'non hex base offset is rejected');

    R := ParseCTAddressExpression('   ', ModuleName, BaseOffset);
    Assert(R.StableCode = 'ct_address_expression_required',
      'blank expression is rejected');

    // --- Spec parsing from a .CT offsets array ---
    R := ParsePointerChainSpec('["10","1a8"]', 'GameAssembly.dll', 0, 64, Spec);
    Assert(not R.Failed, 'offsets array parses');
    Assert(Spec.Depth = 2, 'depth matches the offset count');
    Assert(Spec.Offsets[0] = 16, 'first offset parses');
    Assert(Spec.Offsets[1] = 424, 'second offset parses');
    Assert(Spec.IsValid, 'parsed spec is valid');

    R := ParsePointerChainSpec('[]', 'GameAssembly.dll', 0, 64, Spec);
    Assert(not R.Failed, 'empty offsets array parses');
    Assert(Spec.Depth = 0, 'empty offsets array has depth zero');

    R := ParsePointerChainSpec('{"0":"10"}', 'GameAssembly.dll', 0, 64, Spec);
    Assert((R.Code = rcInvalidArgument) and
      (R.StableCode = 'pointer_chain_offsets_array_required'),
      'object instead of array is rejected');

    R := ParsePointerChainSpec('[10]', 'GameAssembly.dll', 0, 64, Spec);
    Assert(R.StableCode = 'pointer_chain_offset_not_string',
      'numeric offset is rejected');

    R := ParsePointerChainSpec('["zz"]', 'GameAssembly.dll', 0, 64, Spec);
    Assert(R.StableCode = 'pointer_chain_offset_invalid',
      'unparsable offset is rejected');

    R := ParsePointerChainSpec('', 'GameAssembly.dll', 0, 64, Spec);
    Assert(R.StableCode = 'pointer_chain_offsets_required',
      'missing offsets are rejected');

    R := ParsePointerChainSpec('["1","2","3","4","5","6","7","8","9"]',
      'GameAssembly.dll', 0, 64, Spec);
    Assert((R.Code = rcBudgetExceeded) and
      (R.StableCode = 'pointer_chain_depth_exceeded'),
      'chain deeper than the cap is rejected');

    R := ParsePointerChainSpec('["10"]', 'GameAssembly.dll', 0, 16, Spec);
    Assert(R.StableCode = 'pointer_chain_width_invalid',
      'unsupported address width is rejected');

    // --- Resolution: two levels, exactly two reads ---
    // level 0 reads moduleBase+0 -> $140010000, then adds $10 -> $140010010
    // level 1 reads $140010010 -> $140020000, then adds $1A8 -> $1400201A8
    Resolver := TCEAPointerChainResolver.Create(Reader);
    Reader.SetPointer($140000000, $140010000, 8);
    Reader.SetPointer($140010010, $140020000, 8);
    Spec := MakeSpec([$10, $1A8]);
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert(not R.Failed, 'two level chain resolves');
    Assert(Address = $1400201A8, 'resolved address adds the final offset');
    Assert(Reader.ReadCount = 2, 'one read per offset');

    // --- A chain with no offsets is a plain module relative address ---
    Reader.ReadCount := 0;
    Spec := MakeSpec([]);
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert(not R.Failed, 'zero depth chain resolves');
    Assert(Address = $140000000, 'zero depth chain needs no dereference');
    Assert(Reader.ReadCount = 0, 'zero depth chain performs no reads');

    // --- Module base offset applies before the first read ---
    Reader.ReadCount := 0;
    Spec := MakeSpec([$0]);
    Spec.ModuleBaseOffset := $1000;
    Reader.SetPointer($140001000, $140030000, 8);
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert(not R.Failed, 'module base offset chain resolves');
    Assert(Address = $140030000, 'module base offset is applied first');

    // --- Failure modes ---
    Spec := MakeSpec([$10, $1A8]);
    Reader.SetPointer($140000000, 0, 8);
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert((R.Code = rcVerificationFailed) and
      (R.StableCode = 'pointer_chain_null_pointer'),
      'null pointer stops resolution');

    Reader.SetPointer($140000000, $140010000, 8);
    Reader.FFailAt := $140010010;
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert(R.StableCode = 'pointer_chain_read_failed',
      'reader failure is surfaced');
    Reader.FFailAt := QWord(-1);

    Reader.FShortAt := $140010010;
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert(R.StableCode = 'pointer_chain_short_read',
      'short read is not padded');
    Reader.FShortAt := QWord(-1);

    Spec := MakeSpec([$10]);
    Spec.ModuleBaseOffset := High(QWord) - 1;
    R := Resolver.Resolve($140000000, Spec, Address);
    Assert(R.StableCode = 'pointer_chain_address_overflow',
      'module base overflow is detected');

    Spec := MakeSpec([$10, $1A8]);
    Spec.ModuleBaseOffset := 0;
    Reader.SetPointer($0, 0, 8);
    R := Resolver.Resolve(0, Spec, Address);
    Assert(R.StableCode = 'pointer_chain_null_pointer',
      'zero module base yields a null pointer read');

    // --- 32-bit targets reject addresses above 4 GiB ---
    Reader.SetPointer($1000, $FFFFFFF0, 4);
    Spec := MakeSpec([$20], 32);
    Spec.ModuleBaseOffset := $1000;
    R := Resolver.Resolve(0, Spec, Address);
    Assert(R.StableCode = 'pointer_chain_address_width_invalid',
      '32 bit width rejects an address above 4 GiB');

    Reader.SetPointer($1000, $2000, 4);
    Spec := MakeSpec([$0], 32);
    Spec.ModuleBaseOffset := $1000;
    R := Resolver.Resolve(0, Spec, Address);
    Assert(not R.Failed, '32 bit chain resolves');
    Assert(Address = $2000, '32 bit chain reads four bytes');

    // --- Guards ---
    Spec := MakeSpec([$10]);
    Spec.AddressWidthBits := 48;
    R := Resolver.Resolve(0, Spec, Address);
    Assert(R.StableCode = 'pointer_chain_spec_invalid',
      'spec with an unsupported width is invalid');

    Resolver.Free;
    Resolver := TCEAPointerChainResolver.Create(nil);
    Spec := MakeSpec([$10]);
    R := Resolver.Resolve(0, Spec, Address);
    Assert((R.Code = rcInternalError) and
      (R.StableCode = 'pointer_chain_reader_missing'),
      'missing reader is rejected');
    Resolver.Free;

    WriteLn('POINTER_CHAIN=PASS');
  finally
    Reader.Free;
  end;
end.
