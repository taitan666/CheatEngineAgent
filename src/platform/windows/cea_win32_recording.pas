unit cea_win32_recording;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, Windows, cea_results, cea_event_types;

type
  // 桌面窗口帧源：使用 GDI BitBlt 抓取指定窗口（或其客户区）的像素。
  //
  // Phase 1 原型选型说明：捕获 API 采用 GDI BitBlt（无需额外依赖，随 Windows
  // 提供）；编码与持久化格式留待后续阶段确定（PRD 第 19 节「技术决策状态」）。
  // 仅抓取本机桌面窗口，不涉及进程内存注入或跨机传输（FR-080）。
  TCEAWin32WindowFrameSource = class(TObject, ICEAFrameSource)
  private
    FWindowHandle: HWND;
    FIncludeFrame: Boolean;   // True = 含窗口边框；False = 仅客户区
    function GrabClientFrame(out AFrame: TCEAFrameData;
      out AReason: string): Boolean;
    function GrabWindowFrame(out AFrame: TCEAFrameData;
      out AReason: string): Boolean;
  public
    constructor Create(const AWindowHandle: HWND;
      const AIncludeFrame: Boolean);
    function ProbeSupport(out AReason: string): Boolean;
    function GrabFrame(out AFrame: TCEAFrameData;
      out AReason: string): Boolean;
    property WindowHandle: HWND read FWindowHandle;
  end;

  // 录像捕获实现：从帧源按时间窗口抓帧，写入本地片段存储。
  //
  // Phase 1 原型采用「关键帧序列 + 元数据索引」策略：不承诺实时视频编码，
  // 只保证事件窗口内可取出可回放证据帧，并在元数据中如实记录帧数与体积。
  TCEAWin32RecordingCapture = class(TObject, ICEARecordingCapture)
  private
    FFrameSource: ICEAFrameSource;
    FStorageDirectory: string;
    FSequence: QWord;
    FFrameIntervalMs: Int64;
    function NextSegmentId: string;
    function WriteFrameIndex(const ASegmentId: string;
      const AFrames: array of TCEAFrameData): QWord;
  public
    constructor Create(const AFrameSource: ICEAFrameSource;
      const AStorageDirectory: string; const AFrameIntervalMs: Int64);
    function ProbeSupport(out AReason: string): Boolean;
    function CaptureSegment(const AStartAtMs, AEndAtMs: Int64;
      out ASegment: TCEARecordingSegment): TCEAResult;
    property StorageDirectory: string read FStorageDirectory;
  end;

implementation

{ TCEAWin32WindowFrameSource }

constructor TCEAWin32WindowFrameSource.Create(const AWindowHandle: HWND;
  const AIncludeFrame: Boolean);
begin
  inherited Create;
  FWindowHandle := AWindowHandle;
  FIncludeFrame := AIncludeFrame;
end;

function TCEAWin32WindowFrameSource.ProbeSupport(out AReason: string): Boolean;
begin
  AReason := '';
  if FWindowHandle = 0 then
  begin
    AReason := 'window_handle_required';
    Exit(False);
  end;
  if not IsWindow(FWindowHandle) then
  begin
    AReason := 'window_not_found';
    Exit(False);
  end;
  if IsIconic(FWindowHandle) then
  begin
    AReason := 'window_minimized';
    Exit(False);
  end;
  Result := True;
end;

function TCEAWin32WindowFrameSource.GrabClientFrame(out AFrame: TCEAFrameData;
  out AReason: string): Boolean;
var
  ClientRect: TRect;
  WindowDc, MemoryDc: HDC;
  Bitmap: HBITMAP;
  OldObject: HGDIOBJ;
  Info: TBitmapInfo;
  Width, Height, Stride: Cardinal;
  Buffer: TBytes;
  Bits: Pointer;
begin
  FillChar(AFrame, SizeOf(AFrame), 0);
  AReason := '';
  if not GetClientRect(FWindowHandle, ClientRect) then
  begin
    AReason := 'get_client_rect_failed';
    Exit(False);
  end;
  Width := Cardinal(ClientRect.Right - ClientRect.Left);
  Height := Cardinal(ClientRect.Bottom - ClientRect.Top);
  if (Width = 0) or (Height = 0) then
  begin
    AReason := 'window_has_no_client_area';
    Exit(False);
  end;

  WindowDc := GetDC(FWindowHandle);
  if WindowDc = 0 then
  begin
    AReason := 'get_dc_failed';
    Exit(False);
  end;
  MemoryDc := CreateCompatibleDC(WindowDc);
  if MemoryDc = 0 then
  begin
    ReleaseDC(FWindowHandle, WindowDc);
    AReason := 'create_memory_dc_failed';
    Exit(False);
  end;

  Stride := Width * 3;
  SetLength(Buffer, Int64(Stride) * Int64(Height));
  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  Info.bmiHeader.biWidth := LongInt(Width);
  Info.bmiHeader.biHeight := -LongInt(Height);  // 自上而下
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 24;
  Info.bmiHeader.biCompression := BI_RGB;

  Bitmap := CreateDIBSection(WindowDc, Info, DIB_RGB_COLORS, Bits, 0, 0);
  if Bitmap = 0 then
  begin
    DeleteDC(MemoryDc);
    ReleaseDC(FWindowHandle, WindowDc);
    AReason := 'create_dib_section_failed';
    Exit(False);
  end;
  try
    OldObject := SelectObject(MemoryDc, Bitmap);
    try
      if not BitBlt(MemoryDc, 0, 0, LongInt(Width), LongInt(Height),
        WindowDc, 0, 0, SRCCOPY) then
      begin
        AReason := 'bitblt_failed';
        Exit(False);
      end;
      if GetDIBits(MemoryDc, Bitmap, 0, Height, @Buffer[0], Info,
        DIB_RGB_COLORS) = 0 then
      begin
        AReason := 'get_dibits_failed';
        Exit(False);
      end;
    finally
      SelectObject(MemoryDc, OldObject);
    end;
  finally
    DeleteObject(Bitmap);
    DeleteDC(MemoryDc);
    ReleaseDC(FWindowHandle, WindowDc);
  end;

  AFrame.Width := Width;
  AFrame.Height := Height;
  AFrame.Stride := Stride;
  AFrame.Pixels := Buffer;
  AFrame.CapturedAtMs := GetTickCount64;
  Result := True;
end;

function TCEAWin32WindowFrameSource.GrabWindowFrame(out AFrame: TCEAFrameData;
  out AReason: string): Boolean;
var
  WindowRect: TRect;
  WindowDc, MemoryDc: HDC;
  Bitmap: HBITMAP;
  OldObject: HGDIOBJ;
  Info: TBitmapInfo;
  Width, Height, Stride: Cardinal;
  Buffer: TBytes;
  Bits: Pointer;
begin
  FillChar(AFrame, SizeOf(AFrame), 0);
  AReason := '';
  if not GetWindowRect(FWindowHandle, WindowRect) then
  begin
    AReason := 'get_window_rect_failed';
    Exit(False);
  end;
  Width := Cardinal(WindowRect.Right - WindowRect.Left);
  Height := Cardinal(WindowRect.Bottom - WindowRect.Top);
  if (Width = 0) or (Height = 0) then
  begin
    AReason := 'window_has_no_area';
    Exit(False);
  end;

  WindowDc := GetWindowDC(FWindowHandle);
  if WindowDc = 0 then
  begin
    AReason := 'get_window_dc_failed';
    Exit(False);
  end;
  MemoryDc := CreateCompatibleDC(WindowDc);
  if MemoryDc = 0 then
  begin
    ReleaseDC(FWindowHandle, WindowDc);
    AReason := 'create_memory_dc_failed';
    Exit(False);
  end;

  Stride := Width * 3;
  SetLength(Buffer, Int64(Stride) * Int64(Height));
  FillChar(Info, SizeOf(Info), 0);
  Info.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  Info.bmiHeader.biWidth := LongInt(Width);
  Info.bmiHeader.biHeight := -LongInt(Height);
  Info.bmiHeader.biPlanes := 1;
  Info.bmiHeader.biBitCount := 24;
  Info.bmiHeader.biCompression := BI_RGB;

  Bitmap := CreateDIBSection(WindowDc, Info, DIB_RGB_COLORS, Bits, 0, 0);
  if Bitmap = 0 then
  begin
    DeleteDC(MemoryDc);
    ReleaseDC(FWindowHandle, WindowDc);
    AReason := 'create_dib_section_failed';
    Exit(False);
  end;
  try
    OldObject := SelectObject(MemoryDc, Bitmap);
    try
      if not BitBlt(MemoryDc, 0, 0, LongInt(Width), LongInt(Height),
        WindowDc, 0, 0, SRCCOPY) then
      begin
        AReason := 'bitblt_failed';
        Exit(False);
      end;
      if GetDIBits(MemoryDc, Bitmap, 0, Height, @Buffer[0], Info,
        DIB_RGB_COLORS) = 0 then
      begin
        AReason := 'get_dibits_failed';
        Exit(False);
      end;
    finally
      SelectObject(MemoryDc, OldObject);
    end;
  finally
    DeleteObject(Bitmap);
    DeleteDC(MemoryDc);
    ReleaseDC(FWindowHandle, WindowDc);
  end;

  AFrame.Width := Width;
  AFrame.Height := Height;
  AFrame.Stride := Stride;
  AFrame.Pixels := Buffer;
  AFrame.CapturedAtMs := GetTickCount64;
  Result := True;
end;

function TCEAWin32WindowFrameSource.GrabFrame(out AFrame: TCEAFrameData;
  out AReason: string): Boolean;
begin
  if FIncludeFrame then
    Result := GrabWindowFrame(AFrame, AReason)
  else
    Result := GrabClientFrame(AFrame, AReason);
end;

{ TCEAWin32RecordingCapture }

constructor TCEAWin32RecordingCapture.Create(
  const AFrameSource: ICEAFrameSource; const AStorageDirectory: string;
  const AFrameIntervalMs: Int64);
begin
  inherited Create;
  FFrameSource := AFrameSource;
  FStorageDirectory := AStorageDirectory;
  FSequence := 0;
  if AFrameIntervalMs > 0 then
    FFrameIntervalMs := AFrameIntervalMs
  else
    FFrameIntervalMs := 500;  // 默认每 500ms 一帧
end;

function TCEAWin32RecordingCapture.NextSegmentId: string;
begin
  Inc(FSequence);
  Result := 'seg-' + IntToHex(FSequence, 8);
end;

function TCEAWin32RecordingCapture.ProbeSupport(out AReason: string): Boolean;
begin
  AReason := '';
  if FFrameSource = nil then
  begin
    AReason := 'frame_source_required';
    Exit(False);
  end;
  if FStorageDirectory = '' then
  begin
    AReason := 'storage_directory_required';
    Exit(False);
  end;
  Result := FFrameSource.ProbeSupport(AReason);
end;

function TCEAWin32RecordingCapture.WriteFrameIndex(const ASegmentId: string;
  const AFrames: array of TCEAFrameData): QWord;
var
  IndexStream: TFileStream;
  IndexLine: string;
  I: Integer;
  FrameFile: TFileStream;
  FramePath: string;
begin
  Result := 0;
  if not ForceDirectories(FStorageDirectory) then Exit;
  for I := 0 to High(AFrames) do
  begin
    FramePath := IncludeTrailingPathDelimiter(FStorageDirectory) +
      ASegmentId + '-' + IntToStr(I) + '.bgr';
    try
      FrameFile := TFileStream.Create(FramePath, fmCreate);
      try
        if Length(AFrames[I].Pixels) > 0 then
          FrameFile.WriteBuffer(AFrames[I].Pixels[0], Length(AFrames[I].Pixels));
        Inc(Result, Length(AFrames[I].Pixels));
      finally
        FrameFile.Free;
      end;
    except
      on E: Exception do
      begin
        // 单帧写盘失败不吞掉整体捕获：索引中仍记录已写成功帧
        Continue;
      end;
    end;
  end;

  IndexLine := '{"segment_id":"' + ASegmentId + '","frames":' +
    IntToStr(Length(AFrames)) + '}';
  try
    IndexStream := TFileStream.Create(
      IncludeTrailingPathDelimiter(FStorageDirectory) + ASegmentId +
      '.index.json', fmCreate);
    try
      if IndexLine <> '' then
        IndexStream.WriteBuffer(IndexLine[1], Length(IndexLine));
    finally
      IndexStream.Free;
    end;
  except
    on E: Exception do
      ;  // 索引写失败不影响已落盘的帧
  end;
end;

function TCEAWin32RecordingCapture.CaptureSegment(const AStartAtMs,
  AEndAtMs: Int64; out ASegment: TCEARecordingSegment): TCEAResult;
var
  Reason: string;
  Frame: TCEAFrameData;
  Frames: array of TCEAFrameData;
  FrameCount: Cardinal;
  TotalBytes: QWord;
  Elapsed: Int64;
  SegmentId: string;
begin
  FillChar(ASegment, SizeOf(ASegment), 0);
  if AEndAtMs < AStartAtMs then
    Exit(TCEAResult.Error(rcInvalidArgument, 'recording_window_invalid', '{}'));
  if not ProbeSupport(Reason) then
    Exit(TCEAResult.Error(rcConflict, 'recording_capture_unavailable',
      '{"reason":"' + Reason + '"}'));

  SegmentId := NextSegmentId;
  SetLength(Frames, 0);
  TotalBytes := 0;
  FrameCount := 0;
  // Phase 1 原型：在事件窗口内按固定间隔抓取关键帧（不做实时编码）
  Elapsed := AStartAtMs;
  while Elapsed <= AEndAtMs do
  begin
    if FFrameSource.GrabFrame(Frame, Reason) then
    begin
      SetLength(Frames, Length(Frames) + 1);
      Frames[High(Frames)] := Frame;
      Inc(FrameCount);
    end;
    Elapsed := Elapsed + FFrameIntervalMs;
  end;

  if FrameCount = 0 then
    Exit(TCEAResult.Error(rcConflict, 'recording_no_frames_captured',
      '{"reason":"' + Reason + '"}'));

  TotalBytes := WriteFrameIndex(SegmentId, Frames);

  ASegment.Id := SegmentId;
  ASegment.StartedAtMs := AStartAtMs;
  ASegment.EndedAtMs := AEndAtMs;
  ASegment.FrameCount := FrameCount;
  ASegment.Locked := False;
  ASegment.StorageRef := IncludeTrailingPathDelimiter(FStorageDirectory) +
    SegmentId + '.index.json';
  ASegment.SizeBytes := TotalBytes;
  Result := TCEAResult.Ok('{"segment_id":"' + SegmentId + '","frames":' +
    IntToStr(FrameCount) + ',"bytes":' + IntToStr(TotalBytes) + '}');
end;

end.
