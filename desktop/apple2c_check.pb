; Console check of the desktop machine: the CPU suites, then the Apple IIc for a number of frames.
;
;   apple2c_check.exe [--cpu-tests] [--rom file] [--disk1 file] [--disk2 file] [--frames N]
;                     [--type-at FRAME TEXT]... [--png out.png] [--expect TEXT] [--mono] [--click-times] [--reset-at FRAME]
;
; TEXT: "\r" is Return. Prints the text screen at the end, the frames per second it ran at (unthrottled),
; and with --expect exits 1 unless TEXT is on the screen. --png saves the picture (560 x 384).
; --span-check: at the end, every line drawn a column span at a time (as the Pico's panel draws what
; changed) must equal the same columns of the whole line drawn; exits 1 otherwise.
EnableExplicit
XIncludeFile "machine.pbi"
XIncludeFile "cpu_tests.pbi"

Structure CheckType
  frame.i
  text$
EndStructure
Global NewList Typing.CheckType()

OpenConsole()
Define spanCheck.i, c0.i, c1.i, x.i, bad.i, spans.i, line.i
Dim spanFull.a(560)
Define traceN.i, peekAt.i = -1, peekFrame.i = -1, resetAt.i = -1, clickMark.i = 1000, clickReport.i, k.i, a$, rom$, frames.i = 120, png$, expect$, cpuTests.i, r$, f.i, t.q, screen$, i.i, c$
Dim disks$(3)
For k = 0 To CountProgramParameters() - 1
  a$ = ProgramParameter(k)
  Select LCase(a$)
    Case "--cpu-tests" : cpuTests = 1
    Case "--rom" : k + 1 : rom$ = ProgramParameter(k)
    Case "--disk1" : k + 1 : disks$(1) = ProgramParameter(k)
    Case "--disk2" : k + 1 : disks$(2) = ProgramParameter(k)
    Case "--frames" : k + 1 : frames = Val(ProgramParameter(k))
    Case "--png" : k + 1 : png$ = ProgramParameter(k)
    Case "--expect" : k + 1 : expect$ = ProgramParameter(k)
    Case "--mono" : VMono = 1
    Case "--span-check" : spanCheck = 1
    Case "--click-times" : clickReport = 1
    Case "--peek" : k + 1 : peekFrame = Val(ProgramParameter(k)) : k + 1 : peekAt = Val("$" + ProgramParameter(k))
    Case "--trace" : k + 1 : traceN = Val(ProgramParameter(k))
    Case "--reset-at" : k + 1 : resetAt = Val(ProgramParameter(k))
    Case "--type-at"
      AddElement(Typing())
      k + 1 : Typing()\frame = Val(ProgramParameter(k))
      k + 1 : Typing()\text$ = ReplaceString(ProgramParameter(k), "\r", #CR$)
  EndSelect
Next

If cpuTests
  PrintN(CtAllTests(GetPathPart(ProgramFilename()) + "..\Diagnostics\"))
EndIf

A2MemInit()
DiskInit()
MachinePaletteInit()
r$ = HostLoadRom(rom$)
If r$ <> "" : PrintN("ROM: " + r$) : End 2 : EndIf
For i = 1 To 2
  If disks$(i) <> ""
    r$ = HostLoadDisk(i, disks$(i))
    If r$ <> "" : PrintN("Disk " + Str(i) + ": " + r$) : End 2 : EndIf
  EndIf
Next
PrintN("ROM: " + HostRomName$)
HostPowerOn()
t = ElapsedMilliseconds()
For f = 1 To frames
  If f = resetAt
    A2WarmReset()
    For i = 1 To traceN
      PrintN("$" + RSet(Hex(CpuPC), 4, "0") + " op " + RSet(Hex(CpuRead8(CpuPC)), 2, "0") + " A=" + RSet(Hex(CpuA), 2, "0") + " X=" + RSet(Hex(CpuX), 2, "0") + " Y=" + RSet(Hex(CpuY), 2, "0") + " P=" + RSet(Hex(CpuStatus()), 2, "0") + " S=" + RSet(Hex(CpuS), 2, "0") + " bank=" + Str(A2RomBank))
      CpuRun(1)
    Next
  EndIf
  If f = peekFrame
    a$ = "frame " + Str(f) + " PC $" + Hex(CpuPC) + " main $" + Hex(peekAt) + ":"
    For i = 0 To 15 : a$ + " " + RSet(Hex(A2Peek(0, peekAt + i)), 2, "0") : Next
    a$ + "  aux:" : For i = 0 To 15 : a$ + " " + RSet(Hex(A2Peek(1, peekAt + i)), 2, "0") : Next
    PrintN(a$ + "  switches ramrd=" + Str(A2RamRd) + " ramwrt=" + Str(A2RamWrt) + " altzp=" + Str(A2AltZp) + " 80store=" + Str(A2Store80) + " lcread=" + Str(A2LcRead) + " rombank=" + Str(A2RomBank))
  EndIf
  ForEach Typing()
    If Typing()\frame = f
      For i = 1 To Len(Typing()\text$)
        c$ = Mid(Typing()\text$, i, 1)
        A2KeyPut(Asc(c$))
      Next
    EndIf
  Next
  A2RunFrame()
  If clickReport And A2SpeakerClicks >= clickMark
    PrintN("clicks " + Str(A2SpeakerClicks) + " by cycle " + Str(CpuCycles))
    clickMark + 1000
  EndIf
Next
t = ElapsedMilliseconds() - t
If t < 1 : t = 1 : EndIf
screen$ = MachineScreenText()
PrintN("---- screen after " + Str(frames) + " frames (" + Str(frames * 1000 / t) + " frames/s unthrottled, " + StrF(CpuCycles / (t * 1000.0), 1) + " MHz, PC $" + Hex(CpuPC) + ") ----")
Print(screen$)
PrintN("---- disk: reads " + Str(DiskReads) + " writes " + Str(DiskWrites) + " steps " + Str(DiskSteps) + " track " + Str(DiskHalf(1) >> 1) + " errors " + Str(DiskWriteErrors) + "; speaker clicks " + Str(A2SpeakerClicks) + "; keys " + Str(A2KeyTyped))
If png$ <> "" : MachineSavePng(png$) : PrintN("saved " + png$) : EndIf
If spanCheck
  For line = 0 To 191
    VideoRenderLine(line)
    For x = 0 To 559 : spanFull(x) = VDots(x) : Next
    For c0 = 0 To 39
      For c1 = c0 To 39
        For x = 0 To 562 : VDots(x) = 99 : VBits(x) = Random(1) : Next
        VideoRenderSpan(line, c0, c1)
        spans + 1
        For x = c0 * 14 To c1 * 14 + 13
          If VDots(x) <> spanFull(x)
            If bad < 10 : PrintN("SPAN line " + Str(line) + " columns " + Str(c0) + "-" + Str(c1) + " dot " + Str(x) + ": " + Str(VDots(x)) + " <> " + Str(spanFull(x))) : EndIf
            bad + 1 : Break
          EndIf
        Next
      Next
    Next
  Next
  VideoRenderLine(0)
  PrintN("SPAN CHECK: " + Str(spans) + " spans, " + Str(bad) + " wrong")
EndIf
For i = 1 To 2 : HostEjectDisk(i) : Next
If spanCheck And bad : End 1 : EndIf
If expect$ <> ""
  If FindString(screen$, expect$)
    PrintN("RESULT: PASS (the screen shows " + expect$ + ")")
  Else
    PrintN("RESULT: FAIL (the screen does not show " + expect$ + ")")
    End 1
  EndIf
EndIf
End 0
