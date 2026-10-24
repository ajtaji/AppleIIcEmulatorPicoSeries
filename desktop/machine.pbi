; The machine for the desktop programs: the 65C02 core (generated, desktop/cpu65c02.pbi) and the Pico's
; own machine source (src/*.pmi), included unchanged, then the desktop's host side.
#SOUND_RING = 16384                       ; the speaker ring: 341 ms, room for the window catching up
XIncludeFile "cpu65c02.pbi"
XIncludeFile "../src/machine.pmi"
XIncludeFile "../src/sound.pmi"
XIncludeFile "../src/disk.pmi"
XIncludeFile "../src/video.pmi"
XIncludeFile "../src/font.pmi"
XIncludeFile "../src/testrom.pmi"
XIncludeFile "host.pbi"

; The screen as text, one line per row.
Procedure.s MachineScreenText()
  Protected r.i, c.i, out$, line$
  For r = 0 To 23
    line$ = ""
    For c = 0 To VideoTextCols() - 1
      line$ + Chr(VideoTextChar(r, c))
    Next
    out$ + RTrim(line$) + #LF$
  Next
  ProcedureReturn out$
EndProcedure

; The picture as 560 x 384 RGBA (each line twice), 0 = row 0 at the top.
Global Dim MachineRgba.l(560 * 384)
Global Dim MachinePal.l(16)
Procedure MachinePaletteInit()
  Protected i.i, c.i
  For i = 0 To 15
    c = PeekL(?A2Palette + i * 4)
    MachinePal(i) = ((c >> 16) & 255) | (c & $FF00) | ((c & 255) << 16) | $FF000000
  Next
EndProcedure

Global Dim MachineLineHash.l(192)
Global MachineForce.i = 1
; Render the lines that changed; returns how many.
Procedure.i MachineRenderScreen()
  Protected line.i, h.l, x.i, n.i, *p
  For line = 0 To 191
    h = VideoLineHash(line)
    If MachineForce Or h <> MachineLineHash(line)
      MachineLineHash(line) = h
      VideoRenderLine(line)
      *p = @MachineRgba(line * 2 * 560)
      For x = 0 To 559
        PokeL(*p + x * 4, MachinePal(VDots(x)))
      Next
      CopyMemory(*p, *p + 560 * 4, 560 * 4)
      n + 1
    EndIf
  Next
  MachineForce = 0
  ProcedureReturn n
EndProcedure

Procedure MachineSavePng(file$)
  Protected img.i, x.i, y.i, c.l
  MachineForce = 1 : MachineRenderScreen()
  img = CreateImage(#PB_Any, 560, 384, 24)
  StartDrawing(ImageOutput(img))
  For y = 0 To 383
    For x = 0 To 559
      c = MachineRgba(y * 560 + x)
      Plot(x, y, RGB(c & 255, (c >> 8) & 255, (c >> 16) & 255))
    Next
  Next
  StopDrawing()
  UsePNGImageEncoder()
  SaveImage(img, file$, #PB_ImagePlugin_PNG)
  FreeImage(img)
EndProcedure
