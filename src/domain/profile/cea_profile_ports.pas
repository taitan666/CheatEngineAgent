unit cea_profile_ports;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  SysUtils, cea_results, cea_profile_types;

type
  // Game Profile 持久化端口
  ICEAProfileStore = interface
    function Initialize: TCEAResult;
    function SaveProfile(const AProfile: TCEAGameProfile): TCEAResult;
    function LoadProfile(const AProfileId: string;
      out AProfile: TCEAGameProfile): TCEAResult;
    function ListProfiles(const AGameName: string;
      out AProfiles: TCEAGameProfileArray): TCEAResult;
    function DeleteProfile(const AProfileId: string): TCEAResult;
  end;

implementation

end.
