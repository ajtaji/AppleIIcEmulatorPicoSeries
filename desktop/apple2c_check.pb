; Console check of the desktop machine: the CPU suites, then the Apple IIc for a number of frames.
;
;   apple2c_check.exe [--cpu-tests] [--rom file] [--disk1 file] [--disk2 file] [--frames N]
;                     [--type-at FRAME TEXT]... [--png out.png] [--expect TEXT] [--mono] [--full-speed]
;
; TEXT: "\r" is Return. Prints the text screen at the end, the frames per second it ran at (unthrottled),
; and with --expect exits 1 unless TEXT is on the screen. --png saves the picture (560 x 384).
EnableExplicit
XIncludeFile "machine.pbi"
XIncludeFile "cpu_tests.pbi"

Structure CheckType
  frame.i
  text$
EndStructure
Global NewList Typing.CheckType()

OpenConsole()
Define k.i, a$, rom$, frames.i = 120, png$, expect$, cpuTests.i, r$, f.i, t.q, screen$, i.i, c$
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
  ForEach Typing()
    If Typing()\frame = f
      For i = 1 To Len(Typing()\text$)
        c$ = Mid(Typing()\text$, i, 1)
        A2KeyPut(Asc(c$))
      Next
    EndIf
  Next
  A2RunFrame()
Next
t = ElapsedMilliseconds() - t
If t < 1 : t = 1 : EndIf
screen$ = MachineScreenText()
PrintN("---- screen after " + Str(frames) + " frames (" + Str(frames * 1000 / t) + " frames/s unthrottled, " + StrF(CpuCycles / (t * 1000.0), 1) + " MHz, PC $" + Hex(CpuPC) + ") ----")
Print(screen$)
PrintN("---- disk: reads " + Str(DiskReads) + " writes " + Str(DiskWrites) + " steps " + Str(DiskSteps) + " track " + Str(DiskHalf(1) >> 1) + " errors " + Str(DiskWriteErrors) + "; speaker clicks " + Str(A2SpeakerClicks) + "; keys " + Str(A2KeyTyped))
If png$ <> "" : MachineSavePng(png$) : PrintN("saved " + png$) : EndIf
For i = 1 To 2 : HostEjectDisk(i) : Next
If expect$ <> ""
  If FindString(screen$, expect$)
    PrintN("RESULT: PASS (the screen shows " + expect$ + ")")
  Else
    PrintN("RESULT: FAIL (the screen does not show " + expect$ + ")")
    End 1
  EndIf
EndIf
End 0
