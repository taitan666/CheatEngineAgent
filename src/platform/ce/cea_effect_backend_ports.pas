unit cea_effect_backend_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_results;

type
  ICEAMemoryEffectBackend = interface
    function ReadCurrentHex(const APid: Cardinal; const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
    function CompareWriteReadback(const APid: Cardinal;
      const AAddress: QWord; const AExpectedHex,
      AReplacementHex: string): TCEAResult;
  end;

implementation

end.
