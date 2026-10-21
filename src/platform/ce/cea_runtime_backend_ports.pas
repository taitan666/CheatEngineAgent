unit cea_runtime_backend_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  cea_types, cea_results;

type
  TCEARuntimeProcessInfo = record
    Pid: Cardinal;
    StartedAt: string;
    ExecutablePath: string;
    ExecutableSha256: string;
    Architecture: TCEArchitecture;
    ModuleSetHash: string;
  end;

  ICEAReadOnlyRuntimeBackend = interface
    function ListProcesses: TCEAResult;
    function QueryProcessInfo(const APid: Cardinal;
      out AInfo: TCEARuntimeProcessInfo): TCEAResult;
    function AttachReadOnly(const APid: Cardinal): TCEAResult;
    function Detach: TCEAResult;
    function ListModules(const APid, AMaxResults: Cardinal): TCEAResult;
    function ReadMemory(const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
    function PlanReadableRegions(const ARegionKinds: string;
      const AMaxBytes: QWord; const AMaxRegions: Cardinal): TCEAResult;
    function FirstScan(const ARequestJson: string): TCEAResult;
    function GetScanStatus(const AScanId: string): TCEAResult;
    function RefineScan(const ARequestJson: string): TCEAResult;
    function CancelScan(const AScanId: string): TCEAResult;
    function Disassemble(const AAddress: QWord;
      const AByteCount: Cardinal): TCEAResult;
  end;

implementation

end.
