unit cea_runtime;

{$mode objfpc}{$H+}

interface

uses
  cea_ports, cea_results, cea_state_kernel, cea_governance_kernel,
  cea_execution_kernel;

type
  TCEAKernelRuntime = class
  private
    FStateKernel: TCEAStateKernel;
    FGovernanceKernel: TCEAGovernanceKernel;
    FExecutionKernel: TCEAExecutionKernel;
    FInitialized: Boolean;
  public
    constructor Create(const AStore: IStateStore; const AValidator: ISchemaValidator;
      const APolicy: IPolicyEngine; const AProcessPort: ICEProcessPort;
      const AMemoryPort: IMemoryPort);
    destructor Destroy; override;
    function Initialize: TCEAResult;
    procedure Shutdown;
    function IsInitialized: Boolean;
  end;

implementation

constructor TCEAKernelRuntime.Create(const AStore: IStateStore;
  const AValidator: ISchemaValidator; const APolicy: IPolicyEngine;
  const AProcessPort: ICEProcessPort; const AMemoryPort: IMemoryPort);
begin
  inherited Create;
  FStateKernel := TCEAStateKernel.Create(AStore, AValidator);
  FGovernanceKernel := TCEAGovernanceKernel.Create(APolicy);
  FExecutionKernel := TCEAExecutionKernel.Create(AProcessPort, AMemoryPort);
  FInitialized := False;
end;

destructor TCEAKernelRuntime.Destroy;
begin
  Shutdown;
  FExecutionKernel.Free;
  FGovernanceKernel.Free;
  FStateKernel.Free;
  inherited Destroy;
end;

function TCEAKernelRuntime.Initialize: TCEAResult;
begin
  Result := FStateKernel.Initialize;
  FInitialized := Result.Code = rcOk;
end;

procedure TCEAKernelRuntime.Shutdown;
begin
  FInitialized := False;
end;

function TCEAKernelRuntime.IsInitialized: Boolean;
begin
  Result := FInitialized;
end;

end.

