unit cea_win32_readonly_backend;

{$mode objfpc}{$H+}
{$interfaces corba}

interface

uses
  Classes, SysUtils, Windows, JwaTlHelp32, fpjson,
  cea_types, cea_results, cea_ports, cea_runtime_backend_ports,
  cea_windows_sha256, cea_value_scan_types, cea_win32_memory_regions;

type
  TCEAWin32ReadOnlyBackend = class;

  TCEAScanWorker = class(TThread)
  private
    FOwner: TCEAWin32ReadOnlyBackend;
    FRequestJson: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AOwner: TCEAWin32ReadOnlyBackend;
      const ARequestJson: string);
  end;

  TCEAWin32ReadOnlyBackend = class(TObject, ICEAReadOnlyRuntimeBackend)
  private
    FHasher: ICEAHasher;
    FFileHasher: TCEAWindowsSha256;
    FHandle: THandle;
    FAttachedPid: Cardinal;
    FScanId: string;
    FScanGeneration: Cardinal;
    FScanMatches: array of QWord;
    FScanKind: string;
    FScanValueType: string;
    FScanCoverage: TCEAScanCoverage;
    FScanWorker: TCEAScanWorker;
    FScanLock: TRTLCriticalSection;
    FScanState: string;
    FScanWorkerResult: TCEAResult;
    FScanCancelRequested: LongInt;
    function BuildModuleSetHash(const APid: Cardinal;
      out AHash: string): TCEAResult;
    function ScanResultJson(const AMaxResults: Cardinal): TCEAResult;
    function ExecuteFirstScan(const ARequestJson: string): TCEAResult;
    function CancellationRequested: Boolean;
    procedure PublishWorkerResult(const AResult: TCEAResult);
    procedure StopScanWorker;
  public
    constructor Create(const AHasher: TCEAWindowsSha256);
    destructor Destroy; override;
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

uses
  JSONParser;

constructor TCEAScanWorker.Create(const AOwner: TCEAWin32ReadOnlyBackend;
  const ARequestJson: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FRequestJson := ARequestJson;
end;

procedure TCEAScanWorker.Execute;
var
  R: TCEAResult;
begin
  R := FOwner.ExecuteFirstScan(FRequestJson);
  FOwner.PublishWorkerResult(R);
end;

function JsonString(const AValue: UnicodeString): string;
var
  Item: TJSONString;
begin
  Item := TJSONString.Create(UTF8Encode(AValue));
  try
    Result := Item.AsJSON;
  finally
    Item.Free;
  end;
end;

function WideBufferToUtf8(const AValue: PWideChar): string;
begin
  Result := UTF8Encode(UnicodeString(AValue));
end;

function BytesToHex(const ABytes: array of Byte): string;
const
  Digits = '0123456789abcdef';
var
  Index: Integer;
begin
  SetLength(Result, Length(ABytes) * 2);
  for Index := 0 to High(ABytes) do
  begin
    Result[Index * 2 + 1] := Digits[(ABytes[Index] shr 4) + 1];
    Result[Index * 2 + 2] := Digits[(ABytes[Index] and $0F) + 1];
  end;
end;

constructor TCEAWin32ReadOnlyBackend.Create(
  const AHasher: TCEAWindowsSha256);
begin
  inherited Create;
  if AHasher = nil then
    raise EArgumentNilException.Create('AHasher');
  FHasher := AHasher;
  FFileHasher := AHasher;
  InitCriticalSection(FScanLock);
end;

destructor TCEAWin32ReadOnlyBackend.Destroy;
begin
  StopScanWorker;
  if FHandle <> 0 then
    CloseHandle(FHandle);
  DoneCriticalSection(FScanLock);
  inherited Destroy;
end;

function TCEAWin32ReadOnlyBackend.CancellationRequested: Boolean;
begin
  Result := InterlockedCompareExchange(FScanCancelRequested, 0, 0) <> 0;
end;

procedure TCEAWin32ReadOnlyBackend.PublishWorkerResult(
  const AResult: TCEAResult);
begin
  EnterCriticalSection(FScanLock);
  try
    FScanWorkerResult := AResult;
    if CancellationRequested then
      FScanState := 'cancelled'
    else if AResult.Failed then
      FScanState := 'failed'
    else
      FScanState := 'ready';
  finally
    LeaveCriticalSection(FScanLock);
  end;
end;

procedure TCEAWin32ReadOnlyBackend.StopScanWorker;
var
  Worker: TCEAScanWorker;
begin
  Worker := FScanWorker;
  if Worker = nil then Exit;
  InterlockedExchange(FScanCancelRequested, 1);
  Worker.WaitFor;
  FScanWorker := nil;
  Worker.Free;
end;

function TCEAWin32ReadOnlyBackend.ListProcesses: TCEAResult;
var
  Snapshot: THandle;
  Entry: TProcessEntry32;
  Items: string;
  Count: Cardinal;
begin
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcInternalError,
      'win32_process_snapshot_failed', '{}'));
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    Items := '';
    Count := 0;
    if Process32First(Snapshot, Entry) then
      repeat
        if Count > 0 then
          Items := Items + ',';
        Items := Items + '{"pid":' + IntToStr(Entry.th32ProcessID) +
          ',"name":' + JsonString(Entry.szExeFile) + '}';
        Inc(Count);
      until not Process32Next(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  Result := TCEAResult.Ok('{"processes":[' + Items + ']}');
end;

function TCEAWin32ReadOnlyBackend.BuildModuleSetHash(const APid: Cardinal;
  out AHash: string): TCEAResult;
var
  Snapshot: THandle;
  Entry: TModuleEntry32W;
  Signature: string;
begin
  Snapshot := CreateToolhelp32Snapshot(
    TH32CS_SNAPMODULE or TH32CS_SNAPMODULE32, APid);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcInternalError,
      'win32_module_snapshot_failed', '{}'));
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    Signature := '';
    if Module32FirstW(Snapshot, Entry) then
      repeat
        Signature := Signature + LowerCase(
          WideBufferToUtf8(@Entry.szExePath[0])) +
          #0 + IntToHex(QWord(PtrUInt(Entry.modBaseAddr)), 16) + #0 +
          IntToStr(Entry.modBaseSize) + #10;
      until not Module32NextW(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  if Signature = '' then
    Exit(TCEAResult.Error(rcInternalError,
      'win32_module_set_empty', '{}'));
  AHash := FHasher.HashUtf8(Signature);
  Result := TCEAResult.Ok('{}');
end;

function TCEAWin32ReadOnlyBackend.QueryProcessInfo(const APid: Cardinal;
  out AInfo: TCEARuntimeProcessInfo): TCEAResult;
var
  TempHandle: THandle;
  PathBuffer: array[0..32767] of WideChar;
  PathLength: DWORD;
  CreatedAt, ExitAt, KernelAt, UserAt: TFileTime;
  IsWow64: BOOL;
begin
  if APid = 0 then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'win32_process_id_required', '{}'));
  TempHandle := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ,
    False, APid);
  if TempHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized,
      'win32_query_open_failed', '{}'));
  try
    FillChar(CreatedAt, SizeOf(CreatedAt), 0);
    if not GetProcessTimes(TempHandle, CreatedAt, ExitAt, KernelAt, UserAt) then
      Exit(TCEAResult.Error(rcInternalError,
        'win32_process_time_failed', '{}'));
    FillChar(PathBuffer, SizeOf(PathBuffer), 0);
    PathLength := Length(PathBuffer);
    if not QueryFullProcessImageNameW(TempHandle, 0, @PathBuffer[0],
      @PathLength) then
      Exit(TCEAResult.Error(rcInternalError,
        'win32_process_path_failed', '{}'));
    AInfo.Pid := APid;
    AInfo.StartedAt := IntToHex(CreatedAt.dwHighDateTime, 8) +
      IntToHex(CreatedAt.dwLowDateTime, 8);
    AInfo.ExecutablePath := WideBufferToUtf8(@PathBuffer[0]);
    try
      AInfo.ExecutableSha256 := FFileHasher.HashFile(AInfo.ExecutablePath);
    except
      Exit(TCEAResult.Error(rcInternalError,
        'win32_executable_hash_failed', '{}'));
    end;
    {$ifdef CPU64}
    IsWow64 := False;
    if IsWow64Process(TempHandle, @IsWow64) and IsWow64 then
      AInfo.Architecture := caX86
    else
      AInfo.Architecture := caX86_64;
    {$else}
    AInfo.Architecture := caX86;
    {$endif}
    Result := BuildModuleSetHash(APid, AInfo.ModuleSetHash);
  finally
    CloseHandle(TempHandle);
  end;
end;

function TCEAWin32ReadOnlyBackend.AttachReadOnly(
  const APid: Cardinal): TCEAResult;
begin
  if (APid = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'win32_process_id_required', '{}'));
  if FHandle <> 0 then
    Exit(TCEAResult.Error(rcConflict, 'win32_already_attached', '{}'));
  FHandle := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ,
    False, APid);
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcUnauthorized,
      'win32_readonly_attach_failed', '{}'));
  FAttachedPid := APid;
  Result := TCEAResult.Ok('{"attached":true,"access":"query_read"}');
end;

function TCEAWin32ReadOnlyBackend.Detach: TCEAResult;
begin
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'win32_not_attached', '{}'));
  StopScanWorker;
  CloseHandle(FHandle);
  FHandle := 0;
  FAttachedPid := 0;
  FScanId := '';
  FScanKind := '';
  FScanValueType := '';
  SetLength(FScanMatches, 0);
  Result := TCEAResult.Ok('{"detached":true}');
end;

function TCEAWin32ReadOnlyBackend.ListModules(const APid,
  AMaxResults: Cardinal): TCEAResult;
var
  Snapshot: THandle;
  Entry: TModuleEntry32W;
  Items: string;
  Count: Cardinal;
begin
  if (FHandle = 0) or (APid <> FAttachedPid) or (AMaxResults = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'win32_module_request_invalid', '{}'));
  Snapshot := CreateToolhelp32Snapshot(
    TH32CS_SNAPMODULE or TH32CS_SNAPMODULE32, APid);
  if Snapshot = INVALID_HANDLE_VALUE then
    Exit(TCEAResult.Error(rcInternalError,
      'win32_module_snapshot_failed', '{}'));
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    Items := '';
    Count := 0;
    if Module32FirstW(Snapshot, Entry) then
      repeat
        if Count > 0 then
          Items := Items + ',';
        Items := Items + '{"name":' + JsonString(Entry.szModule) +
          ',"path":' + JsonString(Entry.szExePath) +
          ',"base_address":"0x' +
          IntToHex(QWord(PtrUInt(Entry.modBaseAddr)), 16) +
          '","size":' + IntToStr(Entry.modBaseSize) + '}';
        Inc(Count);
      until (Count >= AMaxResults) or not Module32NextW(Snapshot, Entry);
  finally
    CloseHandle(Snapshot);
  end;
  Result := TCEAResult.Ok('{"modules":[' + Items +
    '],"returned":' + IntToStr(Count) + '}');
end;

function TCEAWin32ReadOnlyBackend.ReadMemory(const AAddress: QWord;
  const AByteCount: Cardinal): TCEAResult;
var
  Buffer: array of Byte;
  BytesRead: SIZE_T;
begin
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'win32_not_attached', '{}'));
  if (AAddress = 0) or (AByteCount = 0) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'win32_read_invalid', '{}'));
  SetLength(Buffer, AByteCount);
  BytesRead := 0;
  if not Windows.ReadProcessMemory(FHandle, Pointer(PtrUInt(AAddress)),
    @Buffer[0], AByteCount, BytesRead) or (BytesRead <> AByteCount) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'win32_read_failed', '{}'));
  Result := TCEAResult.Ok('{"address":"0x' + IntToHex(AAddress, 16) +
    '","bytes":"' + BytesToHex(Buffer) + '"}');
end;

function TCEAWin32ReadOnlyBackend.PlanReadableRegions(
  const ARegionKinds: string; const AMaxBytes: QWord;
  const AMaxRegions: Cardinal): TCEAResult;
var
  Kinds: TCEAMemoryRegionKinds;
  Names: TStringList;
  Regions: TCEAMemoryRegionArray;
  Coverage: TCEAScanCoverage;
  I: Integer;
  KindName, RangesJson: string;
begin
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'win32_not_attached', '{}'));
  Kinds := [];
  Names := TStringList.Create;
  try
    Names.StrictDelimiter := True;
    Names.Delimiter := ',';
    Names.DelimitedText := LowerCase(StringReplace(Trim(ARegionKinds), ' ',
      '', [rfReplaceAll]));
    for I := 0 to Names.Count - 1 do
      if Names[I] = 'private' then Include(Kinds, mrkPrivate)
      else if Names[I] = 'image' then Include(Kinds, mrkImage)
      else if Names[I] = 'mapped' then Include(Kinds, mrkMapped)
      else Exit(TCEAResult.Error(rcInvalidArgument,
        'memory_region_kind_invalid', '{}'));
  finally
    Names.Free;
  end;
  Result := EnumerateProcessReadableRegions(FHandle, Kinds, AMaxBytes,
    AMaxRegions, Regions, Coverage);
  if Result.Failed then Exit;
  // 合并相邻同类区域，减少 .NET 等碎片化进程的 region 数量
  Regions := MergeAdjacentRegions(Regions);
  RangesJson := '[';
  for I := 0 to High(Regions) do
  begin
    if I > 0 then RangesJson := RangesJson + ',';
    case Regions[I].Kind of
      mrkPrivate: KindName := 'private';
      mrkImage: KindName := 'image';
      mrkMapped: KindName := 'mapped';
    end;
    RangesJson := RangesJson + '{"start":"0x' +
      IntToHex(Regions[I].StartAddress, 16) + '","size":' +
      IntToStr(Regions[I].Size) + ',"kind":"' + KindName + '"}';
  end;
  RangesJson := RangesJson + ']';
  Result := TCEAResult.Ok('{"ranges":' + RangesJson +
    ',"range_count":' + IntToStr(Length(Regions)) +
    ',"selected_bytes":' + IntToStr(Coverage.EligibleBytes) +
    ',"complete":' + LowerCase(BoolToStr(Coverage.Complete, True)) +
    ',"partial_reason":"' + Coverage.PartialReason + '"}');
end;

function TCEAWin32ReadOnlyBackend.ExecuteFirstScan(
  const ARequestJson: string): TCEAResult;
var
  Data, RangesData, RangeData: TJSONData;
  Obj: TJSONObject;
  StartText, PatternText, Token, ScanKind, ValueType,
    ScopePartialReason: string;
  StartAddress, RangeSize, StopAddress, Cursor, ReadAddress, MaxBytes,
    PreviousLast: QWord;
  MaxResults, MaxDurationMs, MaxRegions, I, MatchCount: Cardinal;
  RegionIndex: Integer;
  Regions, RangeRegions: TCEAMemoryRegionArray;
  ScanRanges: TCEScanRangeArray;
  PlanCoverage, RangeCoverage: TCEAScanCoverage;
  HadReadFailure: Boolean;
  J, RangeIndex, ExistingCount, K: Integer;
  Pattern, Mask, Buffer: array of Byte;
  Tokens: TStringList;
  BytesRead: SIZE_T;
  ReadSize, Offset, Advance, Alignment: Cardinal;
  Match: Boolean;
  StartedAt: QWord;
  TimedOut: Boolean;
begin
  Data := nil;
  Tokens := TStringList.Create;
  try
    try
      Data := GetJSON(ARequestJson);
      if Data.JSONType <> jtObject then
        raise EJSON.Create('object required');
      Obj := TJSONObject(Data);
      ScanKind := Obj.Get('scan_kind', '');
      ValueType := Obj.Get('value_type', '');
      ScopePartialReason := Obj.Get('scope_partial_reason', '');
      if (ScanKind <> 'aob') and (ScanKind <> 'value') then
        Exit(TCEAResult.Error(rcNotImplemented,
          'win32_scan_kind_not_supported', '{}'));
      StartText := Obj.Get('range_start', '');
      PatternText := Obj.Get('value_text', '');
      RangeSize := QWord(Obj.Get('range_size', Int64(0)));
      MaxBytes := QWord(Obj.Get('max_bytes', Int64(0)));
      MaxResults := Obj.Get('max_results', 0);
      MaxDurationMs := Obj.Get('max_duration_ms', 30000);
      MaxRegions := Obj.Get('max_regions', 4096);
      RangesData := Obj.Find('ranges');
      SetLength(ScanRanges, 0);
      if (RangesData <> nil) and (RangesData.JSONType = jtArray) then
      begin
        if (TJSONArray(RangesData).Count = 0) or
           (TJSONArray(RangesData).Count > MaxRegions) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'win32_scan_ranges_invalid', '{}'));
        SetLength(ScanRanges, TJSONArray(RangesData).Count);
        RangeSize := 0;
        PreviousLast := 0;
        for RangeIndex := 0 to High(ScanRanges) do
        begin
          RangeData := TJSONArray(RangesData).Items[RangeIndex];
          if RangeData.JSONType <> jtObject then
            Exit(TCEAResult.Error(rcInvalidArgument,
              'win32_scan_ranges_invalid', '{}'));
          StartText := TJSONObject(RangeData).Get('start', '');
          if (Copy(StartText, 1, 2) <> '0x') or
             not TryStrToQWord('$' + Copy(StartText, 3, MaxInt),
               ScanRanges[RangeIndex].StartAddress) then
            Exit(TCEAResult.Error(rcInvalidArgument,
              'win32_scan_ranges_invalid', '{}'));
          ScanRanges[RangeIndex].Size := QWord(TJSONObject(RangeData).Get(
            'size', Int64(0)));
          if (ScanRanges[RangeIndex].StartAddress = 0) or
             (ScanRanges[RangeIndex].Size = 0) or
             (ScanRanges[RangeIndex].StartAddress > High(QWord) -
               (ScanRanges[RangeIndex].Size - 1)) then
            Exit(TCEAResult.Error(rcInvalidArgument,
              'win32_scan_ranges_invalid', '{}'));
          StopAddress := ScanRanges[RangeIndex].StartAddress +
            ScanRanges[RangeIndex].Size - 1;
          if (RangeIndex > 0) and
             (ScanRanges[RangeIndex].StartAddress <= PreviousLast) then
            Exit(TCEAResult.Error(rcInvalidArgument,
              'win32_scan_ranges_overlap', '{}'));
          if RangeSize > High(QWord) - ScanRanges[RangeIndex].Size then
            Exit(TCEAResult.Error(rcBudgetExceeded,
              'win32_scan_budget_exceeded', '{}'));
          Inc(RangeSize, ScanRanges[RangeIndex].Size);
          PreviousLast := StopAddress;
        end;
        StartAddress := ScanRanges[0].StartAddress;
      end
      else
      begin
        if (Copy(StartText, 1, 2) <> '0x') or
           not TryStrToQWord('$' + Copy(StartText, 3, MaxInt), StartAddress) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'win32_scan_request_invalid', '{}'));
        SetLength(ScanRanges, 1);
        ScanRanges[0].StartAddress := StartAddress;
        ScanRanges[0].Size := RangeSize;
      end;
      if (RangeSize = 0) or (RangeSize > QWord(512) * 1024 * 1024) or
         (MaxBytes = 0) or (RangeSize > MaxBytes) or
         (MaxResults = 0) or (MaxResults > 10000) or
         (MaxDurationMs = 0) or (MaxDurationMs > 30000) or
         (MaxRegions = 0) or (MaxRegions > 4096) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'win32_scan_request_invalid', '{}'));

      if ScanKind = 'value' then
      begin
        Result := EncodeExactValue(ValueType, PatternText, Pattern,
          Alignment);
        if Result.Failed then Exit;
        SetLength(Mask, Length(Pattern));
        for I := 0 to High(Mask) do Mask[I] := $FF;
      end
      else
      begin
        Alignment := 1;
        Tokens.StrictDelimiter := True;
        Tokens.Delimiter := ' ';
        Tokens.DelimitedText := StringReplace(Trim(PatternText), '-', ' ',
          [rfReplaceAll]);
        for I := Tokens.Count - 1 downto 0 do
          if Tokens[I] = '' then Tokens.Delete(I);
        if Tokens.Count = 0 then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'win32_scan_pattern_invalid', '{}'));
        SetLength(Pattern, Tokens.Count);
        SetLength(Mask, Tokens.Count);
        for I := 0 to Tokens.Count - 1 do
        begin
          Token := Tokens[I];
          if (Token = '?') or (Token = '??') then
          begin
            Pattern[I] := 0;
            Mask[I] := 0;
          end
          else
          begin
            if (Length(Token) <> 2) or
               not TryStrToInt('$' + Token, J) or (J < 0) or (J > 255) then
              Exit(TCEAResult.Error(rcInvalidArgument,
                'win32_scan_pattern_invalid', '{}'));
            Pattern[I] := Byte(J);
            Mask[I] := $FF;
          end;
        end;
      end;
      for RangeIndex := 0 to High(ScanRanges) do
        if QWord(Length(Pattern)) > ScanRanges[RangeIndex].Size then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'win32_scan_pattern_too_large', '{}'));

      SetLength(Regions, 0);
      FillChar(PlanCoverage, SizeOf(PlanCoverage), 0);
      PlanCoverage.RequestedBytes := RangeSize;
      if ScanKind = 'value' then
      begin
        for RangeIndex := 0 to High(ScanRanges) do
        begin
          if Length(Regions) >= MaxRegions then
          begin
            PlanCoverage.SkippedBytes := PlanCoverage.SkippedBytes +
              ScanRanges[RangeIndex].Size;
            PlanCoverage.PartialReason := 'region_limit';
            Continue;
          end;
          Result := EnumerateReadableRegions(FHandle,
            ScanRanges[RangeIndex].StartAddress, ScanRanges[RangeIndex].Size,
            MaxRegions - Length(Regions), RangeRegions, RangeCoverage);
          if Result.Failed then Exit;
          ExistingCount := Length(Regions);
          SetLength(Regions, ExistingCount + Length(RangeRegions));
          for K := 0 to High(RangeRegions) do
            Regions[ExistingCount + K] := RangeRegions[K];
          Inc(PlanCoverage.EligibleBytes, RangeCoverage.EligibleBytes);
          Inc(PlanCoverage.SkippedBytes, RangeCoverage.SkippedBytes);
          if (PlanCoverage.PartialReason = '') and
             (RangeCoverage.PartialReason <> '') and
             (RangeCoverage.PartialReason <> 'not_scanned') then
            PlanCoverage.PartialReason := RangeCoverage.PartialReason;
        end;
        FScanCoverage := PlanCoverage;
      end
      else
      begin
        SetLength(Regions, Length(ScanRanges));
        for RangeIndex := 0 to High(ScanRanges) do
        begin
          Regions[RangeIndex].StartAddress := ScanRanges[RangeIndex].StartAddress;
          Regions[RangeIndex].Size := ScanRanges[RangeIndex].Size;
          Regions[RangeIndex].Protection := 0;
        end;
        FillChar(FScanCoverage, SizeOf(FScanCoverage), 0);
        FScanCoverage.RequestedBytes := RangeSize;
        FScanCoverage.EligibleBytes := RangeSize;
      end;
      SetLength(FScanMatches, 0);
      HadReadFailure := False;
      TimedOut := False;
      StartedAt := GetTickCount64;
      for RegionIndex := 0 to High(Regions) do
      begin
        TimedOut := GetTickCount64 - StartedAt >= MaxDurationMs;
        if CancellationRequested or TimedOut then Break;
        Cursor := Regions[RegionIndex].StartAddress;
        StopAddress := Cursor + Regions[RegionIndex].Size;
        while (Cursor < StopAddress) and
              (Length(FScanMatches) < MaxResults) do
        begin
          TimedOut := GetTickCount64 - StartedAt >= MaxDurationMs;
          if CancellationRequested or TimedOut then Break;
          ReadAddress := Cursor;
          if StopAddress - Cursor > 1024 * 1024 then
            ReadSize := 1024 * 1024
          else
            ReadSize := Cardinal(StopAddress - Cursor);
          SetLength(Buffer, ReadSize);
          BytesRead := 0;
          if ReadSize > Cardinal(Length(Pattern) - 1) then
            Advance := ReadSize - Cardinal(Length(Pattern) - 1)
          else Advance := ReadSize;
          if Windows.ReadProcessMemory(FHandle,
            Pointer(PtrUInt(ReadAddress)), @Buffer[0], ReadSize,
            BytesRead) and (BytesRead > 0) then
          begin
            if BytesRead >= Advance then
              Inc(FScanCoverage.InspectedBytes, Advance)
            else
              Inc(FScanCoverage.InspectedBytes, BytesRead);
            if BytesRead >= SIZE_T(Length(Pattern)) then
              for Offset := 0 to Cardinal(BytesRead) - Length(Pattern) do
              begin
                if (Offset and $FFF = 0) then
                  TimedOut := GetTickCount64 - StartedAt >= MaxDurationMs;
                if CancellationRequested or TimedOut then Break;
                if (ScanKind = 'value') and
                   not IsValueAligned(ReadAddress + Offset, Alignment) then
                  Continue;
                Match := True;
                for I := 0 to High(Pattern) do
                  if (Mask[I] <> 0) and
                     (Buffer[Offset + I] <> Pattern[I]) then
                  begin
                    Match := False;
                    Break;
                  end;
                if Match then
                begin
                  MatchCount := Length(FScanMatches);
                  SetLength(FScanMatches, MatchCount + 1);
                  FScanMatches[MatchCount] := ReadAddress + Offset;
                  if Length(FScanMatches) >= MaxResults then Break;
                end;
              end;
          end
          else HadReadFailure := True;
          Inc(Cursor, Advance);
        end;
        if Length(FScanMatches) >= MaxResults then Break;
      end;
      if FScanCoverage.InspectedBytes > RangeSize then
        FScanCoverage.InspectedBytes := RangeSize;
      FScanCoverage.SkippedBytes := RangeSize - FScanCoverage.InspectedBytes;
      FScanCoverage.Complete := (not CancellationRequested) and
        (not TimedOut) and
        (not HadReadFailure) and
        (ScopePartialReason = '') and
        (FScanCoverage.SkippedBytes = 0) and
        (Length(FScanMatches) < MaxResults);
      if FScanCoverage.Complete then
        FScanCoverage.PartialReason := ''
      else
      begin
        if CancellationRequested then
          FScanCoverage.PartialReason := 'cancelled'
        else if TimedOut then
          FScanCoverage.PartialReason := 'time_limit'
        else if Length(FScanMatches) >= MaxResults then
          FScanCoverage.PartialReason := 'result_limit'
        else if HadReadFailure then
          FScanCoverage.PartialReason := 'read_failed'
        else if ScopePartialReason <> '' then
          FScanCoverage.PartialReason := ScopePartialReason
        else if PlanCoverage.PartialReason <> '' then
          FScanCoverage.PartialReason := PlanCoverage.PartialReason
        else FScanCoverage.PartialReason := 'unreadable_region';
      end;
      FScanKind := ScanKind;
      FScanValueType := ValueType;
      Result := ScanResultJson(MaxResults);
    except
      on E: Exception do
      begin
        FScanId := '';
        FScanKind := '';
        FScanValueType := '';
        SetLength(FScanMatches, 0);
        Result := TCEAResult.Error(rcInvalidArgument,
          'win32_scan_json_invalid', '{}');
      end;
    end;
  finally
    Data.Free;
    Tokens.Free;
  end;
end;

function TCEAWin32ReadOnlyBackend.FirstScan(
  const ARequestJson: string): TCEAResult;
begin
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'win32_not_attached', '{}'));
  if FScanId <> '' then
    Exit(TCEAResult.Error(rcScanRunning, 'win32_scan_running', '{}'));
  Inc(FScanGeneration);
  FScanId := 'win32-scan-' + IntToStr(FScanGeneration);
  FScanState := 'running';
  FScanWorkerResult := TCEAResult.Ok('{}');
  InterlockedExchange(FScanCancelRequested, 0);
  FScanWorker := TCEAScanWorker.Create(Self, ARequestJson);
  try
    FScanWorker.Start;
  except
    FreeAndNil(FScanWorker);
    FScanId := '';
    FScanState := '';
    Exit(TCEAResult.Error(rcInternalError,
      'win32_scan_worker_start_failed', '{}'));
  end;
  Result := TCEAResult.Ok('{"scan_id":"' + FScanId + '",' +
    '"state":"running","execution":"background",' +
    '"can_refine":false}');
end;

function TCEAWin32ReadOnlyBackend.GetScanStatus(
  const AScanId: string): TCEAResult;
var
  State, Payload: string;
  WorkerResult: TCEAResult;
begin
  EnterCriticalSection(FScanLock);
  try
    if (FScanId = '') or (AScanId <> FScanId) then
      Exit(TCEAResult.Error(rcConflict, 'win32_scan_not_active', '{}'));
    State := FScanState;
    WorkerResult := FScanWorkerResult;
    if State = 'running' then
      Payload := '{"scan_id":"' + FScanId + '",' +
        '"state":"running","execution":"background",' +
        '"can_refine":false}'
    else if State = 'ready' then
    begin
      Payload := WorkerResult.DataJson;
      if (Payload <> '') and (Payload[Length(Payload)] = '}') then
        Delete(Payload, Length(Payload), 1);
      Payload := Payload + ',"state":"ready",' +
        '"execution":"background","can_refine":true}';
    end
    else if State = 'cancelled' then
      Payload := '{"scan_id":"' + FScanId + '",' +
        '"state":"cancelled","execution":"background",' +
        '"can_refine":false}'
    else
      Exit(WorkerResult);
  finally
    LeaveCriticalSection(FScanLock);
  end;
  Result := TCEAResult.Ok(Payload);
end;

function TCEAWin32ReadOnlyBackend.RefineScan(
  const ARequestJson: string): TCEAResult;
var
  Data, RequestData: TJSONData;
  Obj, RequestObj: TJSONObject;
  ScanId, PatternText, CleanHex, RequestKind, RequestType: string;
  Expected, Buffer: array of Byte;
  I, KeepCount: Integer;
  MaxResults: Cardinal;
  Alignment: Cardinal;
  BytesRead: SIZE_T;
  HadReadFailure: Boolean;
begin
  if (FHandle = 0) or (FScanId = '') then
    Exit(TCEAResult.Error(rcConflict, 'win32_scan_not_active', '{}'));
  EnterCriticalSection(FScanLock);
  try
    if FScanState <> 'ready' then
      Exit(TCEAResult.Error(rcScanRunning, 'win32_scan_running', '{}'));
  finally
    LeaveCriticalSection(FScanLock);
  end;
  Data := nil;
  try
    try
      Data := GetJSON(ARequestJson);
      Obj := TJSONObject(Data);
      ScanId := Obj.Get('scan_id', '');
      RequestData := Obj.Find('request');
      if (ScanId <> FScanId) or (RequestData = nil) or
         (RequestData.JSONType <> jtObject) then
        Exit(TCEAResult.Error(rcConflict,
          'win32_refine_scan_mismatch', '{}'));
      RequestObj := TJSONObject(RequestData);
      RequestKind := RequestObj.Get('scan_kind', '');
      RequestType := RequestObj.Get('value_type', '');
      if (RequestKind <> FScanKind) or
         ((RequestKind = 'value') and (RequestType <> FScanValueType)) then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'win32_refine_kind_mismatch', '{}'));
      PatternText := RequestObj.Get('value_text', '');
      MaxResults := RequestObj.Get('max_results', 0);
      if MaxResults = 0 then
        Exit(TCEAResult.Error(rcInvalidArgument,
          'win32_refine_pattern_invalid', '{}'));
      if RequestKind = 'value' then
      begin
        Result := EncodeExactValue(RequestType, PatternText, Expected,
          Alignment);
        if Result.Failed then Exit;
      end
      else
      begin
        CleanHex := StringReplace(StringReplace(PatternText, ' ', '',
          [rfReplaceAll]), '-', '', [rfReplaceAll]);
        if (CleanHex = '') or Odd(Length(CleanHex)) or
           (Pos('?', CleanHex) > 0) then
          Exit(TCEAResult.Error(rcInvalidArgument,
            'win32_refine_pattern_invalid', '{}'));
        SetLength(Expected, Length(CleanHex) div 2);
        for I := 0 to High(Expected) do
          Expected[I] := StrToInt('$' + Copy(CleanHex, I * 2 + 1, 2));
      end;
      SetLength(Buffer, Length(Expected));
      KeepCount := 0;
      HadReadFailure := False;
      for I := 0 to High(FScanMatches) do
      begin
        BytesRead := 0;
        if not Windows.ReadProcessMemory(FHandle,
          Pointer(PtrUInt(FScanMatches[I])), @Buffer[0], Length(Buffer),
          BytesRead) or (BytesRead <> SIZE_T(Length(Buffer))) then
        begin
          FScanMatches[KeepCount] := FScanMatches[I];
          Inc(KeepCount);
          HadReadFailure := True;
        end
        else if CompareMem(@Buffer[0], @Expected[0], Length(Expected)) then
        begin
          FScanMatches[KeepCount] := FScanMatches[I];
          Inc(KeepCount);
        end;
      end;
      SetLength(FScanMatches, KeepCount);
      if HadReadFailure then
      begin
        FScanCoverage.Complete := False;
        FScanCoverage.PartialReason := 'refine_read_failed';
      end;
      Result := ScanResultJson(MaxResults);
    except
      Result := TCEAResult.Error(rcInvalidArgument,
        'win32_refine_json_invalid', '{}');
    end;
  finally
    Data.Free;
  end;
end;

function TCEAWin32ReadOnlyBackend.CancelScan(
  const AScanId: string): TCEAResult;
begin
  if (FScanId = '') or (AScanId <> FScanId) then
    Exit(TCEAResult.Error(rcConflict, 'win32_scan_not_active', '{}'));
  StopScanWorker;
  FScanId := '';
  FScanKind := '';
  FScanValueType := '';
  FScanState := '';
  SetLength(FScanMatches, 0);
  Result := TCEAResult.Ok('{"cancelled":true}');
end;

function TCEAWin32ReadOnlyBackend.Disassemble(const AAddress: QWord;
  const AByteCount: Cardinal): TCEAResult;
var
  Buffer: array of Byte;
  BytesRead: SIZE_T;
  I: Cardinal;
  Items, Mnemonic: string;
begin
  if FHandle = 0 then
    Exit(TCEAResult.Error(rcConflict, 'win32_not_attached', '{}'));
  if (AAddress = 0) or (AByteCount = 0) or (AByteCount > 4096) or
     (AAddress + QWord(AByteCount - 1) < AAddress) then
    Exit(TCEAResult.Error(rcInvalidArgument,
      'win32_disassembly_invalid', '{}'));
  SetLength(Buffer, AByteCount);
  BytesRead := 0;
  if not Windows.ReadProcessMemory(FHandle, Pointer(PtrUInt(AAddress)),
    @Buffer[0], AByteCount, BytesRead) or (BytesRead <> AByteCount) then
    Exit(TCEAResult.Error(rcVerificationFailed,
      'win32_disassembly_read_failed', '{}'));
  Items := '';
  for I := 0 to AByteCount - 1 do
  begin
    case Buffer[I] of
      $90: Mnemonic := 'nop';
      $C3: Mnemonic := 'ret';
      $CC: Mnemonic := 'int3';
    else
      Mnemonic := 'db 0x' + LowerCase(IntToHex(Buffer[I], 2));
    end;
    if I > 0 then Items := Items + ',';
    Items := Items + '{"address":"0x' +
      IntToHex(AAddress + I, 16) + '","bytes":"' +
      LowerCase(IntToHex(Buffer[I], 2)) + '","text":' +
      JsonString(UnicodeString(Mnemonic)) + '}';
  end;
  Result := TCEAResult.Ok('{"decoder":"bounded-minimal-x86",' +
    '"instructions":[' + Items + ']}');
end;

function TCEAWin32ReadOnlyBackend.ScanResultJson(
  const AMaxResults: Cardinal): TCEAResult;
var
  I, ReturnCount: Cardinal;
  Items: string;
begin
  ReturnCount := Length(FScanMatches);
  if ReturnCount > AMaxResults then ReturnCount := AMaxResults;
  Items := '';
  if ReturnCount > 0 then
    for I := 0 to ReturnCount - 1 do
    begin
      if I > 0 then Items := Items + ',';
      Items := Items + '"' + LowerCase(IntToHex(FScanMatches[I], 16)) + '"';
    end;
  Result := TCEAResult.Ok('{"scan_id":"' + FScanId + '",' +
    '"match_count":' + IntToStr(Length(FScanMatches)) +
    ',"requested_bytes":' + IntToStr(FScanCoverage.RequestedBytes) +
    ',"inspected_bytes":' + IntToStr(FScanCoverage.InspectedBytes) +
    ',"skipped_bytes":' + IntToStr(FScanCoverage.SkippedBytes) +
    ',"complete":' + LowerCase(BoolToStr(FScanCoverage.Complete, True)) +
    ',"partial_reason":"' + FScanCoverage.PartialReason + '"' +
    ',"addresses":[' + Items + ']}');
end;

end.
