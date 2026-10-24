; The 65C02 core's checks on the PC: SingleStepTests' rockwell65c02 vectors (Diagnostics/vectors_full.bin)
; and Klaus Dormann's functional tests (the 65C02 extended opcodes test and the 6502 functional test),
; each in a flat 64 KB RAM with every page mapped. The window's CPU pane and apple2c_check.exe both
; run these. Afterwards the machine's own memory map must be put back (MachineMapAll).

Global CtRam.i                            ; the flat 64 KB the tests run in
Global CtVectors.i, CtVectorFails.i, CtFirstFail$
Global CtKlausResult$, CtKlaus6502Result$, CtSpeedResult$

Procedure CtMapFlat()
  If CtRam = 0 : CtRam = AllocateMemory(65536 + 256) : EndIf
  CpuMapRead(0, 256, CtRam)
  CpuMapWrite(0, 256, CtRam)
  CpuZp = CtRam
EndProcedure

; Returns the number of failures; CtFirstFail$ describes the first.
Procedure.i CtRunVectors(file$)
  Protected f.i, size.i, *buf, p.i, n.i, k.i, addr.i, before.i, after.i, fail.i, used.i, i.i
  Protected pc.i, a.i, x.i, y.i, s.i, st.i, fpc.i, fa.i, fx.i, fy.i, fs.i, fp.i, cyc.i, op.i, why$
  CtVectors = 0 : CtVectorFails = 0 : CtFirstFail$ = ""
  f = ReadFile(#PB_Any, file$)
  If f = 0
    CtFirstFail$ = "cannot open " + file$ + " (build it with tools/make_vectors.py)"
    ProcedureReturn -1
  EndIf
  size = Lof(f) : *buf = AllocateMemory(size) : ReadData(f, *buf, size) : CloseFile(f)
  CtMapFlat()
  p = 0
  While p + 17 <= size
    pc = PeekU(*buf + p) : a = PeekA(*buf + p + 2) : x = PeekA(*buf + p + 3) : y = PeekA(*buf + p + 4)
    s = PeekA(*buf + p + 5) : st = PeekA(*buf + p + 6)
    fpc = PeekU(*buf + p + 7) : fa = PeekA(*buf + p + 9) : fx = PeekA(*buf + p + 10) : fy = PeekA(*buf + p + 11)
    fs = PeekA(*buf + p + 12) : fp = PeekA(*buf + p + 13) : cyc = PeekA(*buf + p + 14)
    n = PeekA(*buf + p + 15)
    k = p + 16
    For i = 0 To n - 1
      PokeA(CtRam + PeekU(*buf + k + i * 4), PeekA(*buf + k + i * 4 + 2))
    Next
    op = PeekA(CtRam + pc)
    CpuPC = pc : CpuA = a : CpuX = x : CpuY = y : CpuS = s : CpuSetStatus(st)
    used = CpuRun(1)
    why$ = ""
    If CpuPC <> fpc : why$ + " pc=$" + Hex(CpuPC) + "/$" + Hex(fpc) : EndIf
    If CpuA <> fa : why$ + " a=$" + Hex(CpuA) + "/$" + Hex(fa) : EndIf
    If CpuX <> fx : why$ + " x=$" + Hex(CpuX) + "/$" + Hex(fx) : EndIf
    If CpuY <> fy : why$ + " y=$" + Hex(CpuY) + "/$" + Hex(fy) : EndIf
    If CpuS <> fs : why$ + " s=$" + Hex(CpuS) + "/$" + Hex(fs) : EndIf
    If (CpuStatus() & $CF) <> (fp & $CF) : why$ + " p=$" + Hex(CpuStatus()) + "/$" + Hex(fp) : EndIf
    If used <> cyc : why$ + " cycles=" + Str(used) + "/" + Str(cyc) : EndIf
    For i = 0 To n - 1
      addr = PeekU(*buf + k + i * 4) : after = PeekA(*buf + k + i * 4 + 3)
      If PeekA(CtRam + addr) <> after
        why$ + " [$" + Hex(addr) + "]=$" + Hex(PeekA(CtRam + addr)) + "/$" + Hex(after)
      EndIf
      PokeA(CtRam + addr, 0)
    Next
    CtVectors + 1
    If why$ <> ""
      CtVectorFails + 1
      If CtFirstFail$ = ""
        CtFirstFail$ = "opcode $" + RSet(Hex(op), 2, "0") + " at $" + Hex(pc) + " (a=$" + Hex(a) + " p=$" + Hex(st) + "):" + why$
      EndIf
    EndIf
    p = k + n * 4
  Wend
  FreeMemory(*buf)
  ProcedureReturn CtVectorFails
EndProcedure

; Run a Klaus Dormann binary (64 KB image, start $400) until it loops on itself. Returns the PC it
; stopped at; *cycles and *ms receive the time taken.
Global CtKlausCycles.q, CtKlausMs.q
Procedure.i CtRunKlaus(file$, start.i)
  Protected f.i, last.i, op.i, t.q, pcs.i, same.i, off.i
  f = ReadFile(#PB_Any, file$)
  If f = 0 : ProcedureReturn -1 : EndIf
  CtMapFlat()
  ReadData(f, CtRam, 65536) : CloseFile(f)
  CpuPC = start : CpuS = $FF : CpuSetStatus($04) : CpuA = 0 : CpuX = 0 : CpuY = 0
  CtKlausCycles = 0
  t = ElapsedMilliseconds()
  last = -1
  Repeat
    CtKlausCycles + CpuRun(20000)
    ; a trap is an instruction that jumps or branches to itself (and, run once more, stays)
    op = PeekA(CtRam + CpuPC)
    same = 0
    If op = $4C And PeekU(CtRam + CpuPC + 1) = CpuPC : same = 1 : EndIf
    If ((op & $1F) = $10 Or op = $80) And PeekA(CtRam + CpuPC + 1) = $FE : same = 1 : EndIf
    If same
      pcs = CpuPC
      CtKlausCycles + CpuRun(1)
      If CpuPC = pcs : Break : EndIf
    EndIf
    If CtKlausCycles > 400000000 : Break : EndIf
  ForEver
  CtKlausMs = ElapsedMilliseconds() - t
  ProcedureReturn CpuPC
EndProcedure

Procedure.s CtAllTests(folder$)
  Protected r$, pc.i
  CtRunVectors(folder$ + "vectors_full.bin")
  r$ = "SingleStepTests rockwell65c02: " + Str(CtVectors - CtVectorFails) + " of " + Str(CtVectors) + " pass"
  If CtVectorFails : r$ + #LF$ + "  first failure: " + CtFirstFail$ : EndIf
  pc = CtRunKlaus(folder$ + "65C02_extended_opcodes_test.bin", $400)
  If pc = $24F1
    CtKlausResult$ = "PASS (reached $24F1)"
  Else
    CtKlausResult$ = "FAIL: trapped at $" + Hex(pc)
  EndIf
  r$ + #LF$ + "Klaus 65C02 extended opcodes test: " + CtKlausResult$ + ", " + Str(CtKlausCycles) + " cycles in " + Str(CtKlausMs) + " ms"
  pc = CtRunKlaus(folder$ + "6502_functional_test.bin", $400)
  If pc = $3469
    CtKlaus6502Result$ = "PASS (reached $3469)"
  Else
    CtKlaus6502Result$ = "FAIL: trapped at $" + Hex(pc)
  EndIf
  r$ + #LF$ + "Klaus 6502 functional test: " + CtKlaus6502Result$ + ", " + Str(CtKlausCycles) + " cycles in " + Str(CtKlausMs) + " ms"
  If CtKlausMs > 0
    CtSpeedResult$ = StrF(CtKlausCycles / (CtKlausMs * 1000.0), 1) + " M 65C02 cycles/s"
    r$ + " = " + CtSpeedResult$
  EndIf
  ProcedureReturn r$
EndProcedure
