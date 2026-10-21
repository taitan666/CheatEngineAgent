unit cea_recipe_service;

{$mode objfpc}{$H+}

interface

uses
  cea_results, cea_reverse_types;

type
  TCEARecipeService = class
  private
    FItems: array of TCEAReverseRecipe;
  public
    function Publish(const ARecipe: TCEAReverseRecipe;
      const AVerification: TCEAVerificationRun): TCEAResult;
    function Count: Cardinal;
  end;

implementation

function TCEARecipeService.Publish(const ARecipe: TCEAReverseRecipe;
  const AVerification: TCEAVerificationRun): TCEAResult;
begin
  if not ARecipe.IsPortableDefinition then
    Exit(TCEAResult.Error(rcInvalidArgument, 'recipe_invalid', '{}'));
  if (AVerification.Outcome <> voPass) or (AVerification.ProofId = '') then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'recipe_verification_required', '{}'));
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := ARecipe;
  Result := TCEAResult.Ok('{"recipe_id":"' + ARecipe.Id + '"}');
end;

function TCEARecipeService.Count: Cardinal;
begin
  Result := Length(FItems);
end;

end.
