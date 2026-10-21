unit cea_save_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_types, cea_results, cea_save_types;

type
  ICEASaveReader = interface
    function Inspect(const APath: string;
      out ASnapshot: TCEASaveSnapshot): TCEAResult;
    function ReadVerified(const ASnapshot: TCEASaveSnapshot;
      out ABytes: TBytes): TCEAResult;
  end;

  ICEASaveCodec = interface
    function Probe(const ABytes: TBytes;
      out ADescriptor: TCEASaveFormatDescriptor): TCEAResult;
    function Decode(const ABytes: TBytes;
      out AFields: TCEASaveFieldArray): TCEAResult;
    function Encode(const AOriginal: TBytes;
      const AEdit: TCEASaveEditProposal; out AEncoded: TBytes): TCEAResult;
    function Validate(const ABytes: TBytes): TCEAResult;
  end;

  ICEASaveFileEffects = interface
    function InvokeEffect(const AEffect: TCEAEffect): TCEAResult;
  end;

implementation

end.
