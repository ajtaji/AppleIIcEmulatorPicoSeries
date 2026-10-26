; PureMetal Apple IIc for the desktop: the same machine as the Picos (src/*.pmi, the 65C02 core generated
; from the same description), drawn with the Neon Arcade Display Engine.
;
; Build (PowerShell, from the repository root):
;   & "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\apple2c_desktop.pb /EXE desktop\PureMetalAppleIIc.exe /THREAD /DPIAWARE /OPTIMIZER
;   (the engine, github.com/ajtaji/Neon-Arcade-Dispay-Engine, is found cloned beside this repository
;    unless /CONSTANT GL_ENGINE_DIR$=<path>/ says otherwise; the trailing slash matters)
; Run:  desktop\PureMetalAppleIIc.exe [--rom file] [--disk1 file] [--disk2 file] [--mono] [--mute]
;          [--tab N] [--type TEXT] [--shot window.png --seconds S]
;
; Keys: typing goes to the IIc (Return, Backspace = left arrow, the arrows, Esc, Tab, Delete, Ctrl+letter).
;       Left Alt = Open-Apple, Right Alt = Solid-Apple. Ctrl+F12 = Ctrl+Reset, Ctrl+Alt+F12 = cold start.
;       F5 run / pause, F6 step one instruction, F7 step one frame, F9 full speed, F11 full screen.
EnableExplicit

CompilerIf Not Defined(GL_ENGINE_DIR$, #PB_Constant)
  #GL_ENGINE_DIR$ = #PB_Compiler_FilePath + "../../Neon-Arcade-Dispay-Engine/"   ; cloned beside this repository
CompilerEndIf
XIncludeFile #GL_ENGINE_DIR$ + "GlTypes.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUtilities.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlMath.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlSpriteFunctions.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUI.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUIChrome.pbi"

XIncludeFile "machine.pbi"

; This window is not drawn through DrawRetroCRT, so the engine's CRT pointer curve is off: left on (its
; default) it bends every pointer position, up to 28 px at 125%, worst at the top and bottom of the window.
UI_UseCRT = #False
CompilerIf Defined(PLANT_CRT, #PB_Constant)
  UI_UseCRT = #True   ; only to see --pointer-test fail
CompilerEndIf
XIncludeFile "audio.pbi"
XIncludeFile "cpu_tests.pbi"
XIncludeFile "view.pbi"

Global Win.i, Gl.i, PhysW.i, PhysH.i
Global Quit.i, Paused.i, FullSpeed.i
Global KeyCode.i, KeyChar.i, Wheel.i
Global EmuAccum.d, EmuLastUs.q, EmuFrameUs.d = 1000000.0 * 17030.0 / 1020484.0
Global FpsShown.d, FpsFrames.i, FpsSince.q, MhzShown.d, CyclesSince.i
Global ActiveTab.i, StatusLine$, LastFolder$
Global LastDraw.q, ShotFile$, ShotAtMs.q
Global TickUsSum.q, EmuUsSum.q, TickCount.i, TickMsShown.d, EmuMsShown.d

Global HostTimerFreq.q, HostTimerStart.q
Procedure.q HostUs()
  Protected now.q
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If HostTimerFreq = 0 : QueryPerformanceFrequency_(@HostTimerFreq) : QueryPerformanceCounter_(@HostTimerStart) : EndIf
    QueryPerformanceCounter_(@now)
    ProcedureReturn ((now - HostTimerStart) * 1000000) / HostTimerFreq
  CompilerElse
    ProcedureReturn ElapsedMilliseconds() * 1000
  CompilerEndIf
EndProcedure

; The chrome's four fonts at Neon_UIScale (logical pixel sizes, scaled and snapped); a rebuild frees the old.
Procedure BuildFonts()
  If *Neon_FontUI
    FreeGLFont(*Neon_FontUI) : FreeGLFont(*Neon_FontSmall) : FreeGLFont(*Neon_FontBold) : FreeGLFont(*Neon_FontMono)
  EndIf
  *Neon_FontUI    = Neon_CreateFontPx("Segoe UI", Round(Neon_S(14), #PB_Round_Nearest))
  *Neon_FontSmall = Neon_CreateFontPx("Segoe UI", Round(Neon_S(12), #PB_Round_Nearest))
  *Neon_FontBold  = Neon_CreateFontPx("Segoe UI", Round(Neon_S(15), #PB_Round_Nearest), #PB_Font_Bold)
  *Neon_FontMono  = Neon_CreateFontPx("Consolas", Round(Neon_S(13), #PB_Round_Nearest))
  GLFontSetSnapToPixel(*Neon_FontUI, #True) : GLFontSetSnapToPixel(*Neon_FontSmall, #True)
  GLFontSetSnapToPixel(*Neon_FontBold, #True) : GLFontSetSnapToPixel(*Neon_FontMono, #True)
EndProcedure

; The canvas is the PHYSICAL client size, Util_WinWidth/Height the LOGICAL one, and Neon_UIScale their
; ratio (1.25 at a 125% desktop): the engine's hosting notes, section 5a. A window moved to a monitor with
; another scale gets its fonts again.
Global FontsAt.f
Procedure MeasureWindow()
  Protected ui.f
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected client.RECT
    GetClientRect_(WindowID(Win), @client)
    PhysW = client\right - client\left : PhysH = client\bottom - client\top
  CompilerElse
    PhysW = WindowWidth(Win, #PB_Window_InnerCoordinate) * Linux_DPIScale
    PhysH = WindowHeight(Win, #PB_Window_InnerCoordinate) * Linux_DPIScale
  CompilerEndIf
  If PhysW < 1 : PhysW = 1 : EndIf
  If PhysH < 1 : PhysH = 1 : EndIf
  ResizeGadget(Gl, 0, 0, WindowWidth(Win, #PB_Window_InnerCoordinate), WindowHeight(Win, #PB_Window_InnerCoordinate))
  GL_ViewportX = 0 : GL_ViewportY = 0 : GL_ViewportW = PhysW : GL_ViewportH = PhysH
  Util_BaseWidth = PhysW : Util_BaseHeight = PhysH
  Util_WinWidth = WindowWidth(Win, #PB_Window_InnerCoordinate) : Util_WinHeight = WindowHeight(Win, #PB_Window_InnerCoordinate)
  If Util_WinWidth > 0 : ui = PhysW / Util_WinWidth : Else : ui = 1.0 : EndIf
  If ui < 1.0 : ui = 1.0 : EndIf
  Neon_UIScale = ui
  If FontsAt <> ui : BuildFonts() : FontsAt = ui : EndIf
EndProcedure

; ---------------------------------------------------------------- --pointer-test
; The real pointer is shared with everyone on this desktop, so it is never moved: the chrome is driven with
; synthetic positions in the units WindowMouseX/Y give a DPI-aware window (physical pixels), through the same
; Neon_ChromeBeginFrame call. For every control four points: just inside its top-left and its bottom-right
; corner (a press must land on it), just right of it and just below it (a press must not). Every frame
; Neon_MX / Neon_MY must read the point back unbent. The window opens 460 logical pixels high for the test, so
; the controls run from the top (the toolbar, the tab strip) to the bottom (the last disassembly row).
Global PtFile$, PtX.f, PtY.f, PtDown.i, PtCase.i, PtPoint.i, PtFrame.i, PtFails.i, PtPoints.i, PtWorst.f, PtDone.i
Global PtLog$, PtCount.i, Dim PtName$(48)

Procedure PtInit()
  Protected n$ = "ROM|Disk 1|Pause|Step|Frame|Ctrl+Reset|Power|Fast|Mono|Mute|tab 0|tab 1|tab 2|tab 3|tab 4|" +
                 "mem cpu|mem main|mem aux|mem back|mem next|mem zp|mem text|mem hires|mem PC|" +
                 "insert 1|eject 1|save 1|insert 2|eject 2|save 2|run tests|dis first row|dis last row"
  Protected i.i
  PtCount = CountString(n$, "|") + 1
  For i = 0 To PtCount - 1 : PtName$(i) = StringField(n$, i + 1, "|") : Next
EndProcedure

; The page a control is drawn on.
Procedure.i PtPage(name$)
  If Left(name$, 4) = "mem " : ProcedureReturn 2 : EndIf
  If Left(name$, 7) = "insert " Or Left(name$, 6) = "eject " Or Left(name$, 5) = "save " : ProcedureReturn 3 : EndIf
  If name$ = "run tests" : ProcedureReturn 4 : EndIf
  ProcedureReturn 0
EndProcedure

Procedure.i PtRect(name$, *r.CtlRect)
  Protected *row.Neon_TabRowLayout, i.i
  If Left(name$, 4) = "tab "
    If FindMapElement(Neon_TabLayout(), "1") = 0 : ProcedureReturn 0 : EndIf
    *row = @Neon_TabLayout() : i = Val(Mid(name$, 5))
    If i >= *row\Count : ProcedureReturn 0 : EndIf
    ; the row's last pixel is the strip's underline, not a tab
    *r\x = *row\X(i) : *r\w = *row\W(i) : *r\y = *row\Y : *r\h = *row\H - 1
    ProcedureReturn 1
  EndIf
  If FindMapElement(Ctl(), name$) = 0 : ProcedureReturn 0 : EndIf
  CopyStructure(@Ctl(), *r, CtlRect)
  ProcedureReturn 1
EndProcedure

; One step, after each frame is drawn.
Procedure PtStep()
  Protected r.CtlRect, name$, inside.i, got$, ok.i, f.i
  If PtCase >= PtCount
    PtLog$ + "pointer-test: " + Str(PtPoints) + " points on " + Str(PtCount) + " controls, " + Str(PtFails) + " failures, scale " +
             StrF(Neon_UIScale, 2) + ", canvas " + Str(Util_BaseWidth) + "x" + Str(Util_BaseHeight) + " physical, window " +
             Str(Util_WinWidth) + "x" + Str(Util_WinHeight) + " logical, UI_UseCRT " + Str(UI_UseCRT) +
             ", worst pointer read-back error " + StrF(PtWorst, 2) + " px" + #LF$
    f = CreateFile(#PB_Any, PtFile$)
    If f : WriteString(f, PtLog$) : CloseFile(f) : EndIf
    PtDone = 1
    ProcedureReturn
  EndIf
  name$ = PtName$(PtCase)
  If PtFrame > 1
    If Abs(Neon_MX - PtX) > PtWorst : PtWorst = Abs(Neon_MX - PtX) : EndIf
    If Abs(Neon_MY - PtY) > PtWorst : PtWorst = Abs(Neon_MY - PtY) : EndIf
  EndIf
  PtFrame + 1
  Select PtFrame
    Case 1                                       ; the page that shows the control, the pointer away
      ActiveTab = PtPage(name$)
      PtX = 1 : PtY = 1 : PtDown = 0
    Case 2                                       ; drawn: go to the point
      If PtRect(name$, @r) = 0
        PtLog$ + "FAIL " + name$ + ": not drawn" + #LF$ : PtFails + 1
        PtFrame = 0 : PtPoint = 0 : PtCase + 1 : ProcedureReturn
      EndIf
      Select PtPoint
        Case 0 : PtX = r\x + 2 : PtY = r\y + 2
        Case 1 : PtX = r\x + r\w - 2 : PtY = r\y + r\h - 2
        Case 2 : PtX = r\x + r\w + 2 : PtY = r\y + r\h - 2
        Case 3 : PtX = r\x + r\w - 2 : PtY = r\y + r\h + 2
      EndSelect
      PtClicked$ = ""
      If Left(name$, 4) = "tab " : ActiveTab = 99 : EndIf   ; no tab selected: a press shows as the new value
    Case 3 : PtDown = 1                          ; press
    Case 4 : PtDown = 0                          ; release
    Case 6                                       ; what the press did
      PtRect(name$, @r)
      inside = Bool(PtPoint < 2)
      If Left(name$, 4) = "tab "
        got$ = "tab " + Str(ActiveTab)
        ok = Bool((got$ = name$) = inside)
      Else
        got$ = PtClicked$
        If got$ = "" : got$ = "nothing" : EndIf
        ok = Bool((PtClicked$ = name$) = inside)
      EndIf
      PtPoints + 1
      PtLog$ + StringField("FAIL|ok", 1 + ok, "|") + "  " + LSet(name$, 14) + " rect (" + StrF(r\x, 1) + "," + StrF(r\y, 1) + " " +
               StrF(r\w, 1) + "x" + StrF(r\h, 1) + ")  point (" + StrF(PtX, 0) + "," + StrF(PtY, 0) + ") " +
               StringField("outside|inside", 1 + inside, "|") + "  read back (" + StrF(Neon_MX, 1) + "," + StrF(Neon_MY, 1) + ")  press -> " + got$ + #LF$
      If ok = 0 : PtFails + 1 : EndIf
      If Left(name$, 4) = "tab " : ActiveTab = 0 : EndIf
      PtPoint + 1 : PtFrame = 0
      If PtPoint = 4 : PtPoint = 0 : PtCase + 1 : EndIf
  EndSelect
EndProcedure

; ---------------------------------------------------------------- the machine
Procedure UpdateStatus()
  StatusLine$ = HostRomName$
  If HostDiskPath$(1) <> "" : StatusLine$ + "   disk 1: " + GetFilePart(HostDiskPath$(1)) : EndIf
  If HostDiskPath$(2) <> "" : StatusLine$ + "   disk 2: " + GetFilePart(HostDiskPath$(2)) : EndIf
EndProcedure

Procedure PowerOn()
  HostPowerOn()
  MachineForce = 1
  EmuAccum = 0 : EmuLastUs = HostUs()
  WoCursor = SoundSamples
  BreakHit = 0
  UpdateStatus()
EndProcedure

Procedure OpenRomDialog()
  Protected f$, r$
  f$ = OpenFileRequester("Apple IIc ROM (16 or 32 KB)", LastFolder$, "ROM images (*.rom;*.bin)|*.rom;*.bin|All files (*.*)|*.*", 0)
  If f$ = "" : ProcedureReturn : EndIf
  LastFolder$ = GetPathPart(f$)
  r$ = HostLoadRom(f$)
  If r$ <> "" : MessageRequester("Apple IIc", r$) : ProcedureReturn : EndIf
  PowerOn()
EndProcedure

Procedure ViewDiskInsert(drive.i)
  Protected f$, r$
  f$ = OpenFileRequester("Disk for drive " + Str(drive), LastFolder$, "Apple II disks (*.dsk;*.do;*.po;*.nib;*.woz)|*.dsk;*.do;*.po;*.nib;*.woz|All files (*.*)|*.*", 0)
  If f$ = "" : ProcedureReturn : EndIf
  LastFolder$ = GetPathPart(f$)
  r$ = HostLoadDisk(drive, f$)
  If r$ <> "" : MessageRequester("Apple IIc", r$) : EndIf
  UpdateStatus()
EndProcedure

; Runs the core's suites (they use the CPU on a flat 64 KB), then powers the machine on again.
Procedure ViewRunTests()
  ViewTestResult$ = CtAllTests(GetPathPart(ProgramFilename()) + "..\Diagnostics\")
  ViewTestFailed = Bool(CtVectorFails <> 0 Or Left(CtKlausResult$, 4) <> "PASS" Or Left(CtKlaus6502Result$, 4) <> "PASS")
  PowerOn()
EndProcedure

; One frame; with a breakpoint set, instruction by instruction so it stops on it.
Procedure RunOneFrame()
  If BreakAt < 0
    A2RunFrame()
    ProcedureReturn
  EndIf
  While A2FrameCycle < #A2_FRAME_CYCLES
    A2FrameCycle + CpuInterrupts()
    A2FrameCycle + CpuRun(1)
    If A2VblDone = 0 And A2FrameCycle >= #A2_VBL_CYCLE : A2VblStart() : A2VblDone = 1 : EndIf
    If CpuPC = BreakAt : BreakHit = 1 : Paused = 1 : ProcedureReturn : EndIf
  Wend
  A2FrameCycle - #A2_FRAME_CYCLES : A2VblDone = 0
  A2Frames + 1 : VFlash = (A2Frames >> 4) & 1
  A2KeyFrame()
  SoundCatchUp(CpuCycles)
EndProcedure

; Whole frames to keep pace with a real IIc (59.92 a second); at full speed as many as fit in 14 ms.
Procedure Emulate()
  Protected now.q, n.i, t0.q
  now = HostUs()
  If EmuLastUs = 0 : EmuLastUs = now : EndIf
  If Paused : EmuLastUs = now : ProcedureReturn : EndIf
  If FullSpeed
    t0 = now
    Repeat
      RunOneFrame() : FpsFrames + 1
    Until HostUs() - t0 > 14000 Or Paused
    EmuLastUs = HostUs() : EmuAccum = 0
    ProcedureReturn
  EndIf
  ; the machine keeps a real IIc's pace however long the window takes to draw (up to 12 frames a pass);
  ; the sound card is fed by its own thread (audio.pbi), never from here
  EmuAccum + (now - EmuLastUs) : EmuLastUs = now
  If EmuAccum > EmuFrameUs * 12 : EmuAccum = EmuFrameUs * 12 : EndIf
  While EmuAccum >= EmuFrameUs And n < 12 And Paused = 0
    RunOneFrame() : EmuAccum - EmuFrameUs : n + 1 : FpsFrames + 1
  Wend
EndProcedure

Procedure StepInstruction()
  Paused = 1
  A2FrameCycle + CpuInterrupts()
  A2FrameCycle + CpuRun(1)
  MachineForce = 1
EndProcedure
Procedure StepFrame()
  Paused = 1 : RunOneFrame()
EndProcedure

; The Apple's keys from the PC's: Return, the arrows, Esc, Tab, Delete and Ctrl+letter come from KeyDown,
; printable characters from Input.
Procedure AppleKeyDown(k.i)
  Protected ctrl.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ctrl = Bool(GetAsyncKeyState_(#VK_CONTROL) & $8000)
  CompilerEndIf
  Select k
    Case #PB_Shortcut_Return : A2KeyPut($0D)
    Case #PB_Shortcut_Back, #PB_Shortcut_Left : A2KeyPut($08)
    Case #PB_Shortcut_Right : A2KeyPut($15)
    Case #PB_Shortcut_Up : A2KeyPut($0B)
    Case #PB_Shortcut_Down : A2KeyPut($0A)
    Case #PB_Shortcut_Escape : A2KeyPut($1B)
    Case #PB_Shortcut_Tab : A2KeyPut($09)
    Case #PB_Shortcut_Delete : A2KeyPut($7F)
    Default
      If ctrl And k >= #PB_Shortcut_A And k <= #PB_Shortcut_Z
        A2KeyPut(k - #PB_Shortcut_A + 1)
      EndIf
  EndSelect
EndProcedure

Procedure SaveWindowShot(file$)
  Protected *buf = AllocateMemory(PhysW * PhysH * 4), img.i, x.i, y.i, c.l
  glReadPixels_(0, 0, PhysW, PhysH, #GL_RGBA, #GL_UNSIGNED_BYTE, *buf)
  img = CreateImage(#PB_Any, PhysW, PhysH, 24)
  StartDrawing(ImageOutput(img))
  For y = 0 To PhysH - 1
    For x = 0 To PhysW - 1
      c = PeekL(*buf + ((PhysH - 1 - y) * PhysW + x) * 4)
      Plot(x, y, RGB(c & 255, (c >> 8) & 255, (c >> 16) & 255))
    Next
  Next
  StopDrawing()
  UsePNGImageEncoder()
  SaveImage(img, file$, #PB_ImagePlugin_PNG)
  FreeImage(img) : FreeMemory(*buf)
EndProcedure

; ---------------------------------------------------------------- one frame of the window
Procedure Tick()
  Protected now.q, dt.f, mx.i, my.i, down.b, toolH.f, x.f, gx.f, gy.f, gw.f, gh.f, scale.f, side.f
  Protected panelX.f, label$
  now = ElapsedMilliseconds() : dt = (now - LastDraw) / 1000.0 : LastDraw = now
  If dt > 0.25 : dt = 0.25 : EndIf
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If GetActiveWindow() = Win
      A2OpenApple = Bool(GetAsyncKeyState_(#VK_LMENU) & $8000)
      A2SolidApple = Bool(GetAsyncKeyState_(#VK_RMENU) & $8000)
    EndIf
  CompilerEndIf
  Protected tEmu.q = HostUs()
  Emulate()
  EmuUsSum + HostUs() - tEmu
  If now - FpsSince >= 1000
    If TickCount : TickMsShown = TickUsSum / (TickCount * 1000.0) : EmuMsShown = EmuUsSum / (TickCount * 1000.0) : EndIf
    TickUsSum = 0 : EmuUsSum = 0 : TickCount = 0
    FpsShown = FpsFrames * 1000.0 / (now - FpsSince) : FpsFrames = 0
    MhzShown = (CpuCycles - CyclesSince) / ((now - FpsSince) * 1000.0) : CyclesSince = CpuCycles
    FpsSince = now
  EndIf

  ; in a DPI-aware window WindowMouseX/Y are already PHYSICAL pixels, the canvas's own units: they go to the
  ; chrome as they are (scaling them again put every click 25% right and down at 125%)
  mx = WindowMouseX(Win) : my = WindowMouseY(Win)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    If GetActiveWindow() = Win : down = Bool(GetAsyncKeyState_(#VK_LBUTTON) & $8000) : EndIf
  CompilerElse
    down = Bool(GetGadgetAttribute(Gl, #PB_OpenGL_Buttons) & #PB_OpenGL_LeftButton)
  CompilerEndIf
  If PtOn : mx = PtX : my = PtY : down = PtDown : EndIf   ; --pointer-test: the synthetic point, the same path
  ; the keyboard belongs to the IIc: the chrome is driven by the mouse only
  Neon_ChromeBeginFrame(mx, my, down, Wheel, 0, 0, dt)
  Wheel = 0 : KeyCode = 0 : KeyChar = 0

  SetGadgetAttribute(Gl, #PB_OpenGL_SetContext, #True)
  glBindFramebuffer(#GL_FRAMEBUFFER, 0)
  glDisable_(#GL_SCISSOR_TEST)
  glViewport_(GL_ViewportX, GL_ViewportY, GL_ViewportW, GL_ViewportH)
  glClearColor_(Neon_C_BgR, Neon_C_BgG, Neon_C_BgB, 1.0)
  glClear_(#GL_COLOR_BUFFER_BIT)
  glEnable_(#GL_BLEND) : glBlendFunc_(#GL_SRC_ALPHA, #GL_ONE_MINUS_SRC_ALPHA)

  toolH = Round(Neon_S(40), #PB_Round_Nearest)
  Neon_Box(0, 0, PhysW, toolH, Neon_C_HeadR, Neon_C_HeadG, Neon_C_HeadB)
  x = Neon_S(8)
  If Btn("ROM", x, Neon_S(6), Neon_S(84), toolH - Neon_S(12), "ROM...") : OpenRomDialog() : EndIf : x + Neon_S(90)
  If Btn("Disk 1", x, Neon_S(6), Neon_S(84), toolH - Neon_S(12), "Disk 1...") : ViewDiskInsert(1) : EndIf : x + Neon_S(90)
  label$ = "Pause" : If Paused : label$ = "Run" : EndIf
  If Btn("Pause", x, Neon_S(6), Neon_S(72), toolH - Neon_S(12), label$ + "  F5", Bool(Paused = 0)) : Paused = 1 - Paused : EmuLastUs = HostUs() : EndIf : x + Neon_S(78)
  If Btn("Step", x, Neon_S(6), Neon_S(80), toolH - Neon_S(12), "Step  F6") : StepInstruction() : EndIf : x + Neon_S(86)
  If Btn("Frame", x, Neon_S(6), Neon_S(88), toolH - Neon_S(12), "Frame  F7") : StepFrame() : EndIf : x + Neon_S(94)
  If Btn("Ctrl+Reset", x, Neon_S(6), Neon_S(100), toolH - Neon_S(12), "Ctrl+Reset") : A2WarmReset() : Paused = 0 : EndIf : x + Neon_S(106)
  If Btn("Power", x, Neon_S(6), Neon_S(70), toolH - Neon_S(12), "Power") : PowerOn() : Paused = 0 : EndIf : x + Neon_S(76)
  If Btn("Fast", x, Neon_S(6), Neon_S(82), toolH - Neon_S(12), "Fast  F9", FullSpeed) : FullSpeed = 1 - FullSpeed : EndIf : x + Neon_S(88)
  label$ = "Mono" : If VMono : label$ = "Colour" : EndIf
  If Btn("Mono", x, Neon_S(6), Neon_S(70), toolH - Neon_S(12), label$, VMono) : VMono = 1 - VMono : MachineForce = 1 : EndIf : x + Neon_S(76)
  label$ = "Mute" : If WoMuted : label$ = "Sound" : EndIf
  If Btn("Mute", x, Neon_S(6), Neon_S(64), toolH - Neon_S(12), label$, WoMuted) : WoMuted = 1 - WoMuted : EndIf : x + Neon_S(70)
  Neon_Text(*Neon_FontMono, x + Neon_S(8), toolH / 2 - Neon_S(8), StrD(FpsShown, 1) + " fps  " + StrD(MhzShown, 2) + " MHz (" + Str(MhzShown * 100 / 1.020484) + "% of a IIc)  window " + StrD(TickMsShown, 1) + " ms, machine " + StrD(EmuMsShown, 1) + " ms   " + StatusLine$, Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)

  ; the screen: 560 x 384 at the largest size that fits beside the panel
  side = Round(Neon_S(620), #PB_Round_Nearest)
  If side > PhysW * 0.5 : side = PhysW * 0.5 : EndIf
  gw = PhysW - side - Neon_S(24) : gh = PhysH - toolH - Neon_S(24)
  scale = gw / 560.0 : If gh / 384.0 < scale : scale = gh / 384.0 : EndIf
  gx = Neon_S(12) + (gw - 560 * scale) / 2 : gy = toolH + Neon_S(12) + (gh - 384 * scale) / 2
  ViewDrawScreen(gx, gy, 560 * scale, 384 * scale)
  If BreakHit : Neon_Text(*Neon_FontBold, gx + Neon_S(8), gy + Neon_S(8), "BREAKPOINT $" + Hex4(BreakAt) + " reached (F5 runs on)", Neon_C_RedR, Neon_C_RedG, Neon_C_RedB) : EndIf

  panelX = PhysW - side - Neon_S(6)
  ActiveTab = Neon_TabStrip(1, panelX, toolH + Neon_S(6), side, Neon_S(30), "CPU|Switches|Memory|Disk|Tests", ActiveTab)
  Select ActiveTab
    Case 0 : ViewCpu(panelX, toolH + Neon_S(40), side, PhysH - toolH - Neon_S(46))
    Case 1 : ViewSwitches(panelX, toolH + Neon_S(40), side, PhysH - toolH - Neon_S(46))
    Case 2 : ViewMemory(panelX, toolH + Neon_S(40), side, PhysH - toolH - Neon_S(46))
    Case 3 : ViewDisk(panelX, toolH + Neon_S(40), side, PhysH - toolH - Neon_S(46))
    Case 4 : ViewTests(panelX, toolH + Neon_S(40), side, PhysH - toolH - Neon_S(46))
  EndSelect

  Neon_ChromeEndFrame()
  If PtOn : PtStep() : If PtDone : Quit = 1 : EndIf : EndIf
  If ShotFile$ <> "" And now >= ShotAtMs : SaveWindowShot(ShotFile$) : Quit = 1 : EndIf
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
  TickUsSum + HostUs() - tEmu : TickCount + 1
EndProcedure

; ---------------------------------------------------------------- main
Procedure Main()
  Protected ev.i, et.i, k.i, rom$, r$, type$, i.i, runTests.i, noSound.i
  Protected Dim disk$(3)
  For k = 0 To CountProgramParameters() - 1
    Select LCase(ProgramParameter(k))
      Case "--rom" : k + 1 : rom$ = ProgramParameter(k)
      Case "--disk1" : k + 1 : disk$(1) = ProgramParameter(k)
      Case "--disk2" : k + 1 : disk$(2) = ProgramParameter(k)
      Case "--mono" : VMono = 1
      Case "--mute" : WoMuted = 1
      Case "--nosound" : noSound = 1
      Case "--tests" : runTests = 1
      Case "--tab" : k + 1 : ActiveTab = Val(ProgramParameter(k))
      Case "--type" : k + 1 : type$ = ReplaceString(ProgramParameter(k), "\r", #CR$)
      Case "--shot" : k + 1 : ShotFile$ = ProgramParameter(k) : If ShotAtMs = 0 : ShotAtMs = 5000 : EndIf
      Case "--seconds" : k + 1 : ShotAtMs = Val(ProgramParameter(k)) * 1000
      Case "--pointer-test" : k + 1 : PtFile$ = ProgramParameter(k) : PtOn = 1 : noSound = 1
    EndSelect
  Next
  If PtOn : PtInit() : k = 460 : Else : k = 820 : EndIf
  Gl = OpenGLWindow("PureMetal Apple IIc", 1400, k, #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_SizeGadget | #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget)
  If Gl = 0 : MessageRequester("PureMetal Apple IIc", "OpenGL could not be started.") : End 1 : EndIf
  Win = Util_MainWindowID
  MeasureWindow()                        ; sets Neon_UIScale and builds the fonts
  GL_SetVSync(1)
  DisInit()
  A2MemInit()
  DiskInit()
  ViewInit()
  r$ = HostLoadRom(rom$)
  If r$ <> "" : MessageRequester("Apple IIc", r$ + #LF$ + "The built-in test ROM runs instead.") : HostLoadRom("") : EndIf
  For i = 1 To 2
    If disk$(i) <> ""
      r$ = HostLoadDisk(i, disk$(i))
      If r$ <> "" : MessageRequester("Apple IIc", r$) : EndIf
    EndIf
  Next
  If noSound = 0 : WoBegin() : EndIf
  PowerOn()
  If runTests : ViewRunTests() : EndIf
  For i = 1 To Len(type$) : A2KeyPut(Asc(Mid(type$, i, 1))) : Next
  FpsSince = ElapsedMilliseconds() : LastDraw = FpsSince
  If ShotFile$ <> "" : ShotAtMs + FpsSince : EndIf
  Repeat
    Repeat
      ev = WindowEvent()
      Select ev
        Case #PB_Event_CloseWindow : Quit = 1
        Case #PB_Event_SizeWindow, #PB_Event_MaximizeWindow, #PB_Event_RestoreWindow : MeasureWindow()
        Case #PB_Event_Menu
          If EventMenu() = 1001 : A2KeyPut($1B) : EndIf          ; the engine's Escape shortcut
        Case #PB_Event_Gadget
          If EventGadget() = Gl
            et = EventType()
            Select et
              Case #PB_EventType_KeyDown
                k = GetGadgetAttribute(Gl, #PB_OpenGL_Key)
                Select k
                  Case #PB_Shortcut_F5 : Paused = 1 - Paused : EmuLastUs = HostUs() : BreakHit = 0
                  Case #PB_Shortcut_F6 : StepInstruction()
                  Case #PB_Shortcut_F7 : StepFrame()
                  Case #PB_Shortcut_F9 : FullSpeed = 1 - FullSpeed
                  Case #PB_Shortcut_F11 : GL_ToggleFullscreen() : MeasureWindow()
                  Case #PB_Shortcut_F12
                    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
                      If GetAsyncKeyState_(#VK_CONTROL) & $8000
                        If GetAsyncKeyState_(#VK_MENU) & $8000
                          PowerOn()
                        Else
                          A2WarmReset()
                        EndIf
                        Paused = 0
                      EndIf
                    CompilerEndIf
                  Default : AppleKeyDown(k)
                EndSelect
              Case #PB_EventType_Input
                k = GetGadgetAttribute(Gl, #PB_OpenGL_Input)
                If k >= 32 And k < 127 : A2KeyPut(k) : EndIf
              Case #PB_EventType_MouseWheel : Wheel + GetGadgetAttribute(Gl, #PB_OpenGL_WheelDelta)
            EndSelect
          EndIf
      EndSelect
    Until ev = 0 Or Quit
    If Quit : Break : EndIf
    Tick()
  Until Quit
  For i = 1 To 2 : HostEjectDisk(i) : Next
  WoEnd()
  If PtOn : End PtFails : EndIf   ; --pointer-test: the number of failures
EndProcedure
Main()
