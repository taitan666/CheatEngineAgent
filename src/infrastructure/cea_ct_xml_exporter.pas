unit cea_ct_xml_exporter;

{$mode objfpc}{$H+}
{$interfaces corba}
{$codepage utf8}

interface

uses
  SysUtils, cea_results, cea_ports, cea_ct_draft_types, cea_ct_draft_ports;

type
  TCEACTXmlExporter = class(TObject, ICEACTXmlExporter)
  private
    FHasher: ICEAHasher;
  public
    constructor Create(const AHasher: ICEAHasher);
    function Render(const ADraft: TCEACTDraft; out ABytes: TBytes;
      out ASha256: string): TCEAResult;
  end;

implementation

function XmlText(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
end;

function CommentText(const S: string): string;
begin
  Result := StringReplace(XmlText(S), '--', '- -', [rfReplaceAll]);
  if (Result <> '') and (Result[Length(Result)] = '-') then Result := Result + ' ';
end;

function HexWithoutPrefix(const S: string): string;
begin
  if Copy(S, 1, 2) = '0x' then Result := Copy(S, 3, MaxInt)
  else Result := S;
end;

constructor TCEACTXmlExporter.Create(const AHasher: ICEAHasher);
begin
  inherited Create;
  FHasher := AHasher;
end;

function TCEACTXmlExporter.Render(const ADraft: TCEACTDraft;
  out ABytes: TBytes; out ASha256: string): TCEAResult;
var
  { The rendered document is UTF-8 by contract (the XML declaration says so),
    so the accumulator must be a UTF-8 string. Using RawByteString here would
    silently transcode every non-ASCII description from UTF-8 into the system
    ANSI code page, which corrupts Chinese/Japanese entry labels. }
  Output: UTF8String;
  OverBudget: Boolean;

  procedure AddLine(const AIndent: Integer; const AText: string);
  begin
    if OverBudget then Exit;
    Output := Output + StringOfChar(' ', AIndent) + AText + #10;
    OverBudget := Length(Output) > CECTDraftMaxXmlBytes;
  end;

  function AddressText(const E: TCEACTDraftEntry): string;
  begin
    if E.Kind = deAbsoluteAddress then
      Result := HexWithoutPrefix(E.AddressText)
    else
      Result := E.ModuleName + '+' + HexWithoutPrefix(E.AddressText);
  end;

  procedure WriteChildren(const AParentOrdinal, AIndent: Integer);
  var I, J: Integer; E: TCEACTDraftEntry;
  begin
    for I := 0 to High(ADraft.Entries) do
      if ADraft.Entries[I].ParentOrdinal = AParentOrdinal then begin
        E := ADraft.Entries[I];
        AddLine(AIndent, '<CheatEntry>');
        AddLine(AIndent + 2, '<ID>' + IntToStr(E.Ordinal) + '</ID>');
        AddLine(AIndent + 2, '<Description>' + XmlText(E.Description) +
          '</Description>');
        if E.Kind <> deGroup then begin
          AddLine(AIndent + 2, '<VariableType>' +
            XmlText(CTDraftValueTypeText(E.ValueType)) + '</VariableType>');
          AddLine(AIndent + 2, '<Address>' + XmlText(AddressText(E)) +
            '</Address>');
          if Length(E.PointerOffsets) > 0 then begin
            AddLine(AIndent + 2, '<Offsets>');
            for J := 0 to High(E.PointerOffsets) do
              AddLine(AIndent + 4, '<Offset>' +
                XmlText(HexWithoutPrefix(E.PointerOffsets[J])) + '</Offset>');
            AddLine(AIndent + 2, '</Offsets>');
          end;
        end;
        if E.Kind = deGroup then begin
          AddLine(AIndent + 2, '<CheatEntries>');
          WriteChildren(E.Ordinal, AIndent + 4);
          AddLine(AIndent + 2, '</CheatEntries>');
        end;
        AddLine(AIndent, '</CheatEntry>');
      end;
  end;

begin
  SetLength(ABytes, 0); ASha256 := '';
  if FHasher = nil then
    Exit(TCEAResult.Error(rcInternalError, 'ct_draft_hasher_missing', '{}'));
  if (ADraft.State <> dsValidated) or not ADraft.IsValid then
    Exit(TCEAResult.Error(rcCTDraftSourceUnverified,
      'ct_draft_source_unverified', '{"pointer":"/state"}'));
  Output := ''; OverBudget := False;
  AddLine(0, '<?xml version="1.0" encoding="utf-8"?>');
  AddLine(0, '<CheatTable CheatEngineTableVersion="45">');
  AddLine(2, '<!-- CEA provenance draft=' + CommentText(ADraft.Id) +
    ' recipe=' + CommentText(ADraft.RecipeId) +
    ' verification=' + CommentText(ADraft.VerificationRunId) +
    ' content=' + CommentText(ADraft.ContentHash) + ' -->');
  AddLine(2, '<CheatEntries>');
  WriteChildren(-1, 4);
  AddLine(2, '</CheatEntries>');
  AddLine(0, '</CheatTable>');
  if OverBudget then
    Exit(TCEAResult.Error(rcCTDraftBudgetExceeded,
      'ct_draft_budget_exceeded', '{"pointer":"/xml"}'));
  SetLength(ABytes, Length(Output));
  if Length(Output) > 0 then Move(Output[1], ABytes[0], Length(Output));
  ASha256 := FHasher.HashUtf8(Output);
  Result := TCEAResult.Ok('{"byte_count":' + IntToStr(Length(ABytes)) +
    ',"sha256":"' + ASha256 + '"}');
end;

end.

