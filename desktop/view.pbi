; What the window shows: the IIc's screen and the debug panes (CPU, Switches, Memory, Disk, Tests).
; Every read here is free of side effects: memory through the CPU's own page tables, never through the
; I/O page ($C000-$C0FF reads as --).

XIncludeFile "opcodes.pbi"

Structure ViewTexture
  sprite.GLSprite
  *pixels
EndStructure

; (authored sizes go through the engine's Neon_S(): Neon_UIScale is set by MeasureWindow)

; Every control the pointer can press, by name, where it was last drawn (canvas units, physical pixels):
; --pointer-test (apple2c_desktop.pb) aims at them. In that test a press records the control's name and does
; nothing else.
Global PtOn.i, PtClicked$
Structure CtlRect : x.f : y.f : w.f : h.f : EndStructure
Global NewMap Ctl.CtlRect()
Procedure CtlSet(name$, x.f, y.f, w.f, h.f)
  Ctl(name$)\x = x : Ctl()\y = y : Ctl()\w = w : Ctl()\h = h
EndProcedure
Procedure.b Btn(name$, x.f, y.f, w.f, h.f, label.s, lit.b = #False)
  CtlSet(name$, x, y, w, h)
  If Neon_Button(x, y, w, h, label, lit)
    If PtOn : PtClicked$ = name$ : ProcedureReturn #False : EndIf
    ProcedureReturn #True
  EndIf
  ProcedureReturn #False
EndProcedure
Global ViewScreen.ViewTexture
Global ViewMemPage.i, ViewMemBank.i            ; bank 0 the CPU's view, 1 main, 2 auxiliary
Global ViewTestResult$, ViewTestFailed.i
Global BreakAt.i = -1, BreakHit.i

Procedure ViewTextureMake(*t.ViewTexture, w.i, h.i)
  *t\sprite\Width = w : *t\sprite\Height = h
  *t\pixels = AllocateMemory(w * h * 4)
  glGenTextures_(1, @*t\sprite\TextureID) : glBindTexture_(#GL_TEXTURE_2D, *t\sprite\TextureID)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_MIN_FILTER, #GL_LINEAR)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_MAG_FILTER, #GL_NEAREST)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_WRAP_S, #GL_CLAMP_TO_EDGE)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_WRAP_T, #GL_CLAMP_TO_EDGE)
  glTexImage2D_(#GL_TEXTURE_2D, 0, #GL_RGBA, w, h, 0, #GL_RGBA, #GL_UNSIGNED_BYTE, *t\pixels)
EndProcedure

; The engine's sprite draw samples a Windows texture bottom-up (its images come from DIBs).
Procedure.i ViewRow(*t.ViewTexture, y.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    ProcedureReturn *t\pixels + (*t\sprite\Height - 1 - y) * *t\sprite\Width * 4
  CompilerElse
    ProcedureReturn *t\pixels + y * *t\sprite\Width * 4
  CompilerEndIf
EndProcedure

Procedure ViewInit()
  ViewTextureMake(@ViewScreen, 560, 384)
  MachinePaletteInit()
EndProcedure

Procedure ViewDrawScreen(x.f, y.f, w.f, h.f)
  Protected yy.i
  If MachineRenderScreen()
    For yy = 0 To 383
      CopyMemory(@MachineRgba(yy * 560), ViewRow(@ViewScreen, yy), 560 * 4)
    Next
    glBindTexture_(#GL_TEXTURE_2D, ViewScreen\sprite\TextureID)
    glTexSubImage2D_(#GL_TEXTURE_2D, 0, 0, 0, 560, 384, #GL_RGBA, #GL_UNSIGNED_BYTE, ViewScreen\pixels)
  EndIf
  Neon_Box(x - 2, y - 2, w + 4, h + 4, 0, 0, 0)
  DrawGLSprite(@ViewScreen\sprite, x, y, 0.0, w / 560.0, 1.0, 1.0, 1.0, 1.0, #True, -1, -1, -1, -1, #True)
EndProcedure

; ---------------------------------------------------------------- reads without side effects

Procedure.i ViewPeek(addr.i)
  Protected base.i
  addr & $FFFF
  If (addr >> 8) = $C0 : ProcedureReturn -1 : EndIf
  base = CpuRdMap(addr >> 8)
  If base = 0 : ProcedureReturn -1 : EndIf
  ProcedureReturn PeekA(base + addr)
EndProcedure
Procedure.i ViewPeekByte(addr.i)
  Protected v.i = ViewPeek(addr)
  If v < 0 : v = 0 : EndIf
  ProcedureReturn v
EndProcedure
; bank 1 main, 2 auxiliary: RAM as it is, whatever the switches; $D000-$FFFF the language card's
Procedure.i ViewPeekBank(bank.i, addr.i)
  If addr >= $C000 And addr < $D000 : ProcedureReturn -1 : EndIf
  ProcedureReturn PeekA(A2RamHost(bank - 1, addr))
EndProcedure

Procedure.s Hex2(v.i)
  ProcedureReturn RSet(Hex(v & 255), 2, "0")
EndProcedure
Procedure.s Hex4(v.i)
  ProcedureReturn RSet(Hex(v & $FFFF), 4, "0")
EndProcedure

; ---------------------------------------------------------------- the disassembler

Global Dim DisLen.i(18)
Procedure DisInit()
  Protected i.i
  Restore DisLengths
  For i = 0 To 17 : Read.i DisLen(i) : Next
EndProcedure
Procedure.i DisLength(op.i)
  ProcedureReturn DisLen(PeekA(?OpcModes + (op & 255)))
EndProcedure
Procedure.s DisLine(addr.i)
  Protected op.i, mode.i, lo.i, hi.i, w.i, t.i, name$, arg$, bytes$, i.i, n.i
  op = ViewPeekByte(addr) : mode = PeekA(?OpcModes + op)
  name$ = Trim(Mid(#OPC_NAMES$, op * 4 + 1, 4))
  If name$ = "BITI" : name$ = "BIT" : EndIf
  lo = ViewPeekByte(addr + 1) : hi = ViewPeekByte(addr + 2) : w = lo | (hi << 8)
  Select mode
    Case 1 : arg$ = "A"
    Case 2 : arg$ = "#$" + Hex2(lo)
    Case 3 : arg$ = "$" + Hex2(lo)
    Case 4 : arg$ = "$" + Hex2(lo) + ",X"
    Case 5 : arg$ = "$" + Hex2(lo) + ",Y"
    Case 6 : arg$ = "$" + Hex4(w)
    Case 7 : arg$ = "$" + Hex4(w) + ",X"
    Case 8 : arg$ = "$" + Hex4(w) + ",Y"
    Case 9 : arg$ = "($" + Hex2(lo) + ",X)"
    Case 10 : arg$ = "($" + Hex2(lo) + "),Y"
    Case 11 : arg$ = "($" + Hex2(lo) + ")"
    Case 12 : arg$ = "($" + Hex4(w) + ")"
    Case 13 : arg$ = "($" + Hex4(w) + ",X)"
    Case 14
      t = (addr + 2 + ((lo ! 128) - 128)) & $FFFF
      arg$ = "$" + Hex4(t)
    Case 15
      t = (addr + 3 + ((hi ! 128) - 128)) & $FFFF
      arg$ = "$" + Hex2(lo) + ",$" + Hex4(t)
  EndSelect
  n = DisLen(mode)
  For i = 0 To 2
    If i < n : bytes$ + Hex2(ViewPeekByte(addr + i)) + " " : Else : bytes$ + "   " : EndIf
  Next
  ProcedureReturn Hex4(addr) + "  " + bytes$ + " " + name$ + " " + arg$
EndProcedure

; ---------------------------------------------------------------- panes

Procedure.f ViewLine(x.f, y.f, t$, r.f = -1, g.f = 0, b.f = 0)
  If r < 0 : r = Neon_C_TextR : g = Neon_C_TextG : b = Neon_C_TextB : EndIf
  Neon_Text(*Neon_FontMono, x, y, t$, r, g, b)
  ProcedureReturn y + GLFontLineHeight(*Neon_FontMono)
EndProcedure

Procedure.s ViewOnOff(v.i)
  If v : ProcedureReturn "ON " : EndIf
  ProcedureReturn "off"
EndProcedure

Procedure ViewCpu(x.f, y.f, w.f, h.f)
  Protected p.i, i.i, a.i, row$, lh.f, line$, mx.i, my.i
  lh = GLFontLineHeight(*Neon_FontMono)
  p = CpuStatus()
  For i = 0 To 7
    If p & (128 >> i) : row$ + Mid("NV-BDIZC", i + 1, 1) : Else : row$ + "." : EndIf
  Next
  Neon_Panel(x, y, w, h, "65C02", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  y + Neon_S(34) : x + Neon_S(12)
  y = ViewLine(x, y, "PC $" + Hex4(CpuPC) + "   A $" + Hex2(CpuA) + "   X $" + Hex2(CpuX) + "   Y $" + Hex2(CpuY) + "   S $" + Hex2(CpuS))
  y = ViewLine(x, y, "P  $" + Hex2(p) + " " + row$ + "   IRQ line " + Str(CpuIrqLine) + "   cycles " + Str(CpuCycles))
  y = ViewLine(x, y, "frame " + Str(A2Frames) + "   cycle in frame " + Str(A2FrameCycle) + "   line " + Str(A2FrameCycle / 65), Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  If BreakAt >= 0
    y = ViewLine(x, y, "breakpoint $" + Hex4(BreakAt) + "  (click a line to move it, click it again to clear)", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
  Else
    y = ViewLine(x, y, "click a disassembly line to break there", Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  EndIf
  y + Neon_S(6)
  Neon_Text(*Neon_FontSmall, x, y, "DISASSEMBLY", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + lh
  a = CpuPC
  For i = 0 To 19
    line$ = DisLine(a)
    If a = BreakAt : line$ = "* " + line$ : ElseIf i = 0 : line$ = "> " + line$ : Else : line$ = "  " + line$ : EndIf
    If i = 0 : CtlSet("dis first row", x, y, w - Neon_S(24), lh) : ElseIf i = 19 : CtlSet("dis last row", x, y, w - Neon_S(24), lh) : EndIf
    If Neon_MX >= x And Neon_MX < x + w - Neon_S(24) And Neon_MY >= y And Neon_MY < y + lh And Neon_MouseClicked
      If PtOn
        PtClicked$ = "dis row " + Str(i)
        If i = 0 : PtClicked$ = "dis first row" : ElseIf i = 19 : PtClicked$ = "dis last row" : EndIf
      ElseIf BreakAt = a
        BreakAt = -1
      Else
        BreakAt = a
      EndIf
    EndIf
    If i = 0
      y = ViewLine(x, y, line$, Neon_C_GrnR, Neon_C_GrnG, Neon_C_GrnB)
    ElseIf a = BreakAt
      y = ViewLine(x, y, line$, Neon_C_RedR, Neon_C_RedG, Neon_C_RedB)
    Else
      y = ViewLine(x, y, line$)
    EndIf
    a = (a + DisLength(ViewPeekByte(a))) & $FFFF
  Next
  y + Neon_S(6)
  Neon_Text(*Neon_FontSmall, x, y, "STACK  $01" + Hex2(CpuS + 1) + " up", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + lh
  row$ = ""
  For i = 1 To 16
    If CpuS + i > 255 : Break : EndIf
    row$ + Hex2(PeekA(CpuZp + 256 + CpuS + i)) + " "
  Next
  y = ViewLine(x, y, row$)
EndProcedure

Procedure ViewSwitches(x.f, y.f, w.f, h.f)
  Protected mode$
  Neon_Panel(x, y, w, h, "Soft switches", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  y + Neon_S(34) : x + Neon_S(12)
  Select VideoLineMode(0)
    Case #VM_TEXT40 : mode$ = "40-column text"
    Case #VM_TEXT80 : mode$ = "80-column text"
    Case #VM_LORES : mode$ = "lo-res"
    Case #VM_DLORES : mode$ = "double lo-res"
    Case #VM_HIRES : mode$ = "hi-res"
    Case #VM_DHIRES : mode$ = "double hi-res"
  EndSelect
  If A2Mixed And A2Text = 0 : mode$ + " with four lines of text" : EndIf
  If VideoPage2() : mode$ + ", page 2" : Else : mode$ + ", page 1" : EndIf
  y = ViewLine(x, y, "Video: " + mode$, Neon_C_GrnR, Neon_C_GrnG, Neon_C_GrnB)
  y + Neon_S(4)
  y = ViewLine(x, y, "TEXT     " + ViewOnOff(A2Text) + "   MIXED   " + ViewOnOff(A2Mixed) + "   PAGE2   " + ViewOnOff(A2Page2))
  y = ViewLine(x, y, "HIRES    " + ViewOnOff(A2Hires) + "   80COL   " + ViewOnOff(A2Col80) + "   ALTCHAR " + ViewOnOff(A2AltChar))
  y = ViewLine(x, y, "DHIRES   " + ViewOnOff(A2DHires) + "   IOUDIS  " + ViewOnOff(A2IouDis) + "   VBL int " + ViewOnOff(A2VblEnable))
  y + Neon_S(8)
  Neon_Text(*Neon_FontSmall, x, y, "MEMORY (MMU)", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + GLFontLineHeight(*Neon_FontMono)
  y = ViewLine(x, y, "80STORE  " + ViewOnOff(A2Store80) + "   RAMRD   " + ViewOnOff(A2RamRd) + "   RAMWRT  " + ViewOnOff(A2RamWrt))
  y = ViewLine(x, y, "ALTZP    " + ViewOnOff(A2AltZp) + "   ROM bank " + Str(A2RomBank) + " of " + Str(A2RomBytes / 16384))
  y + Neon_S(8)
  Neon_Text(*Neon_FontSmall, x, y, "LANGUAGE CARD ($D000-$FFFF)", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + GLFontLineHeight(*Neon_FontMono)
  y = ViewLine(x, y, "read " + StringField("ROM|RAM", A2LcRead + 1, "|") + "   write " + StringField("off (ROM)|RAM", A2LcWrite + 1, "|") + "   $D000 bank " + Str(2 - A2LcBank2) + "   prewrite " + Str(A2LcPrewrite))
  y + Neon_S(8)
  Neon_Text(*Neon_FontSmall, x, y, "KEYBOARD", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + GLFontLineHeight(*Neon_FontMono)
  y = ViewLine(x, y, "latch $" + Hex2(A2Key) + "   any key down " + Str(A2KeyDown) + "   queued " + Str(A2KeyPending()) + "   typed " + Str(A2KeyTyped))
  y = ViewLine(x, y, "Open-Apple " + Str(A2OpenApple) + "   Solid-Apple " + Str(A2SolidApple) + "   (Left Alt, Right Alt)")
  y + Neon_S(8)
  Neon_Text(*Neon_FontSmall, x, y, "SPEAKER", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + GLFontLineHeight(*Neon_FontMono)
  y = ViewLine(x, y, "clicks " + Str(A2SpeakerClicks) + "   samples " + Str(SoundSamples) + "   queued at the card " + Str(WoQueued) + "   underruns " + Str(WoUnderruns))
EndProcedure

Procedure ViewMemory(x.f, y.f, w.f, h.f)
  Protected i.i, p.i, a.i, v.i, row$, asc$
  Neon_Panel(x, y, w, h, "Memory", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  y + Neon_S(34) : x + Neon_S(12)
  If Btn("mem cpu", x, y, Neon_S(100), Neon_S(22), "CPU's view", Bool(ViewMemBank = 0)) : ViewMemBank = 0 : EndIf
  If Btn("mem main", x + Neon_S(106), y, Neon_S(70), Neon_S(22), "main", Bool(ViewMemBank = 1)) : ViewMemBank = 1 : EndIf
  If Btn("mem aux", x + Neon_S(182), y, Neon_S(70), Neon_S(22), "aux", Bool(ViewMemBank = 2)) : ViewMemBank = 2 : EndIf
  If Btn("mem back", x + Neon_S(270), y, Neon_S(28), Neon_S(22), "<") : ViewMemPage = (ViewMemPage - 1) & 255 : EndIf
  If Btn("mem next", x + Neon_S(302), y, Neon_S(28), Neon_S(22), ">") : ViewMemPage = (ViewMemPage + 1) & 255 : EndIf
  If Btn("mem zp", x + Neon_S(336), y, Neon_S(36), Neon_S(22), "zp") : ViewMemPage = 0 : EndIf
  If Btn("mem text", x + Neon_S(376), y, Neon_S(44), Neon_S(22), "text") : ViewMemPage = 4 : EndIf
  If Btn("mem hires", x + Neon_S(424), y, Neon_S(50), Neon_S(22), "hires") : ViewMemPage = $20 : EndIf
  If Btn("mem PC", x + Neon_S(478), y, Neon_S(36), Neon_S(22), "PC") : ViewMemPage = CpuPC >> 8 : EndIf
  y + Neon_S(30)
  y = ViewLine(x, y, "page $" + Hex2(ViewMemPage) + "00   " + StringField("as the CPU reads it now|main bank|auxiliary bank", ViewMemBank + 1, "|"), Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  For i = 0 To 15
    a = ViewMemPage * 256 + i * 16
    row$ = Hex4(a) + " " : asc$ = ""
    For p = 0 To 15
      If ViewMemBank = 0 : v = ViewPeek(a + p) : Else : v = ViewPeekBank(ViewMemBank, a + p) : EndIf
      If v < 0
        row$ + " --" : asc$ + " "
      Else
        row$ + " " + Hex2(v)
        If (v & $7F) >= 32 And (v & $7F) < 127 : asc$ + Chr(v & $7F) : Else : asc$ + "." : EndIf
      EndIf
    Next
    y = ViewLine(x, y, row$ + "  " + asc$)
  Next
EndProcedure

Declare ViewDiskInsert(drive.i)

Procedure ViewDisk(x.f, y.f, w.f, h.f)
  Protected d.i, kind$, name$
  Neon_Panel(x, y, w, h, "Disk drives (IWM)", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  y + Neon_S(34) : x + Neon_S(12)
  For d = 1 To 2
    kind$ = StringField("empty|DOS order|ProDOS order|nibble tracks", DiskKind(d) + 1, "|")
    name$ = GetFilePart(HostDiskPath$(d)) : If name$ = "" : name$ = "(no disk)" : EndIf
    Neon_Text(*Neon_FontSmall, x, y, "DRIVE " + Str(d) + StringField("| (built in)| (external)", d + 1, "|"), Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
    If Btn("insert " + Str(d), x + Neon_S(220), y - Neon_S(2), Neon_S(80), Neon_S(22), "Insert...") : ViewDiskInsert(d) : EndIf
    If Btn("eject " + Str(d), x + Neon_S(306), y - Neon_S(2), Neon_S(70), Neon_S(22), "Eject") : HostEjectDisk(d) : EndIf
    If Btn("save " + Str(d), x + Neon_S(382), y - Neon_S(2), Neon_S(70), Neon_S(22), "Save", HostDiskDirty(d)) : HostSaveDisk(d) : EndIf
    y + Neon_S(26)
    y = ViewLine(x, y, name$ + "   " + kind$)
    If HostDiskNote$(d) <> "" : y = ViewLine(x, y, HostDiskNote$(d), Neon_C_DimR, Neon_C_DimG, Neon_C_DimB) : EndIf
    y = ViewLine(x, y, "head: track " + Str(DiskHalf(d) >> 1) + StringField("|.5", (DiskHalf(d) & 1) + 1, "|") + "   write-protected " + Str(DiskProtect(d)) + "   changed, not saved " + Str(HostDiskDirty(d)))
    y + Neon_S(8)
  Next
  Neon_Text(*Neon_FontSmall, x, y, "THE IWM", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB) : y + GLFontLineHeight(*Neon_FontMono)
  y = ViewLine(x, y, "drive " + Str(DiskDrive) + "   motor " + ViewOnOff(DiskMotor) + "   phases %" + RSet(Bin(DiskPhases), 4, "0") + "   Q6 " + Str(DiskQ6) + "  Q7 " + Str(DiskQ7) + "   mode $" + Hex2(DiskMode))
  y = ViewLine(x, y, "latch $" + Hex2(DiskLatch) + "   nibble " + Str(DiskPos) + " of " + Str(#DISK_TRACK_BYTES) + " on track " + Str(DiskNibTrack) + " (drive " + Str(DiskNibDrive) + ")")
  y = ViewLine(x, y, "nibbles read " + Str(DiskReads) + "   written " + Str(DiskWrites) + "   steps " + Str(DiskSteps) + "   sectors not decoded " + Str(DiskWriteErrors))
EndProcedure

Declare ViewRunTests()

; The Controls tab: the controls table (controls.pbi), the same rows the keyboard code reads.
Global ViewControlsTop.i
Procedure ViewControls(x.f, y.f, w.f, h.f)
  Protected head$, kind.i, last.i = -1, c$
  Neon_Panel(x, y, w, h, "Controls", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  y + Neon_S(32) : x + Neon_S(10)
  Neon_Text(*Neon_FontSmall, x, y, "PC key  ->  the Apple IIc. Esc is the IIc's ESC in the window; in full screen it leaves full screen, and End is ESC.", Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  y + Neon_S(26)
  Neon_ListBegin(9, x, y, w - Neon_S(20), h - Neon_S(70), Neon_S(22), @ViewControlsTop)
  ForEach Controls()
    Select Controls()\kind
      Case #CTL_SHORTCUT : kind = 2 : head$ = "The window"
      Default
        If FindString(Controls()\pc$, "Joystick") : kind = 1 : head$ = "Joystick" : Else : kind = 0 : head$ = "Apple IIc keyboard" : EndIf
    EndSelect
    If kind <> last : Neon_ListItem(head$, 0, #False, #True) : last = kind : EndIf
    c$ = Controls()\pc$ + "   ->   " + Controls()\a2$
    Neon_ListItem(c$, 1)
  Next
  Neon_ListEnd()
EndProcedure

Procedure ViewTests(x.f, y.f, w.f, h.f)
  Protected i.i
  Neon_Panel(x, y, w, h, "Tests", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  y + Neon_S(34) : x + Neon_S(12)
  y = ViewLine(x, y, "The 65C02 core's suites, the same as apple2c_cpu_check.exe and the boards':")
  y = ViewLine(x, y, "SingleStepTests rockwell65c02 (87053 vectors), Klaus Dormann's 65C02", Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  y = ViewLine(x, y, "extended opcodes test and his 6502 functional test.", Neon_C_DimR, Neon_C_DimG, Neon_C_DimB)
  If Btn("run tests", x, y + Neon_S(4), Neon_S(140), Neon_S(26), "Run the tests") : ViewRunTests() : EndIf
  y + Neon_S(40)
  For i = 1 To CountString(ViewTestResult$, #LF$) + 1
    If ViewTestFailed
      y = ViewLine(x, y, StringField(ViewTestResult$, i, #LF$), Neon_C_RedR, Neon_C_RedG, Neon_C_RedB)
    Else
      y = ViewLine(x, y, StringField(ViewTestResult$, i, #LF$), Neon_C_GrnR, Neon_C_GrnG, Neon_C_GrnB)
    EndIf
  Next
EndProcedure

DataSection
  DisLengths:                            ; bytes of each addressing mode (opcodes.pbi's numbering)
  Data.i 1, 1, 2, 2, 2, 2, 3, 3, 3, 2, 2, 2, 3, 3, 2, 3, 2, 3
EndDataSection
