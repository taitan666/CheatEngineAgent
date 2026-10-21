library cea_self_target_plugin;

{$mode objfpc}{$H+}

function CEASelfTargetPluginMarker: Cardinal; stdcall;
begin
  Result := $CEA75001;
end;

exports
  CEASelfTargetPluginMarker;

begin
end.
