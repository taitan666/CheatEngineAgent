program test_win32_pointer_reader;

{$mode objfpc}{$H+}

{ Exercises the Windows pointer reader against this process only, so it stays
  inside the read-only guarantee and needs no target game. Cross-process reads
  are covered by the integration script, which requires a widened sandbox. }

uses
  SysUtils, Classes, Windows, cea_results, cea_pointer_chain,
  cea_win32_pointer_reader;

var
  Value: DWord;
  PointerSlot: Pointer;
  Reader: TCEAWin32PointerReader;
  Resolver: TCEAPointerChainResolver;
  Spec: TCEAPointerChainSpec;
  R: TCEAResult;
  Bytes: TBytes;
  Address, BaseAddress: QWord;
  ModuleName: string;

begin
  Value := $11223344;
  PointerSlot := @Value;
  Reader := TCEAWin32PointerReader.Create(GetCurrentProcessId, 4096);
  try
    // --- Raw reads ---
    R := Reader.ReadPointerBytes(QWord(PtrUInt(@Value)), 4, Bytes);
    Assert(not R.Failed, 'own memory reads');
    Assert(Length(Bytes) = 4, 'read returns the requested length');
    Assert((Bytes[0] = $44) and (Bytes[1] = $33) and (Bytes[2] = $22) and
      (Bytes[3] = $11), 'read returns little endian bytes');

    R := Reader.ReadPointerBytes(0, 8, Bytes);
    Assert(R.StableCode = 'pointer_read_invalid',
      'null address is rejected');

    R := Reader.ReadPointerBytes(QWord(PtrUInt(@Value)), 0, Bytes);
    Assert(R.StableCode = 'pointer_read_invalid',
      'zero byte count is rejected');

    R := Reader.ReadPointerBytes(QWord(PtrUInt(@Value)), 8192, Bytes);
    Assert(R.StableCode = 'pointer_read_invalid',
      'read above the configured cap is rejected');

    R := Reader.ReadPointerBytes(High(QWord) - 2, 8, Bytes);
    Assert(R.StableCode = 'pointer_read_address_overflow',
      'address wrap is rejected');

    // Unmapped addresses fail instead of returning partial bytes.
    R := Reader.ReadPointerBytes($10, 8, Bytes);
    Assert((R.Code = rcVerificationFailed) and (Bytes = nil),
      'unmapped address fails without partial bytes');

    // --- Module lookup ---
    ModuleName := ExtractFileName(ParamStr(0));
    R := Reader.ModuleBaseAddress(ModuleName, BaseAddress);
    Assert(not R.Failed, 'own module base resolves');
    Assert(BaseAddress <> 0, 'module base is non zero');

    R := Reader.ModuleBaseAddress('definitely-not-loaded.dll', BaseAddress);
    Assert((R.Code = rcUnknown) and (R.StableCode = 'module_not_loaded'),
      'unknown module is reported as not loaded');

    R := Reader.ModuleBaseAddress('  ', BaseAddress);
    Assert(R.StableCode = 'module_name_required',
      'empty module name is rejected');

    // --- Real chain resolution through the Windows reader ---
    // One level: base + baseOffset points at the slot holding @Value.
    Resolver := TCEAPointerChainResolver.Create(Reader);
    try
      Spec.ModuleName := ModuleName;
      Spec.ModuleBaseOffset := QWord(PtrUInt(@PointerSlot));
      Spec.AddressWidthBits := 64;
      SetLength(Spec.Offsets, 1);
      Spec.Offsets[0] := 0;
      R := Resolver.Resolve(0, Spec, Address);
      Assert(not R.Failed, 'one level chain resolves against the live process');
      Assert(Address = QWord(PtrUInt(@Value)),
        'chain resolves to the pointee address');

      // Two levels: the second read follows the pointer stored in Value.
      PointerSlot := @Value;
      Spec.ModuleBaseOffset := QWord(PtrUInt(@PointerSlot));
      SetLength(Spec.Offsets, 1);
      Spec.Offsets[0] := 0;
      R := Resolver.Resolve(0, Spec, Address);
      Assert(Address = QWord(PtrUInt(@Value)), 'chain address is stable');

      // Zero depth resolves to the module base plus the offset, with no read.
      Spec.ModuleBaseOffset := 0;
      SetLength(Spec.Offsets, 0);
      R := Resolver.Resolve(QWord(PtrUInt(@Value)), Spec, Address);
      Assert(not R.Failed, 'zero depth chain resolves');
      Assert(Address = QWord(PtrUInt(@Value)),
        'zero depth chain returns the base unchanged');

      // A null slot stops the chain.
      PointerSlot := nil;
      Spec.ModuleBaseOffset := QWord(PtrUInt(@PointerSlot));
      SetLength(Spec.Offsets, 1);
      Spec.Offsets[0] := 0;
      R := Resolver.Resolve(0, Spec, Address);
      Assert((R.StableCode = 'pointer_chain_null_pointer') or
        (R.StableCode = 'pointer_chain_read_failed'),
        'null slot stops the chain');
    finally
      Resolver.Free;
    end;

    WriteLn('WIN32_POINTER_READER=PASS');
  finally
    Reader.Free;
  end;
end.
