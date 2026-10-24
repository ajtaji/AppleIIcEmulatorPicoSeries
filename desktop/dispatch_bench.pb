; Dispatch on the PC: the C computed goto of desktop/cpu65c02.pbi against a table of procedures
; (desktop/cpu65c02_procs.pbi, the same handlers). Build twice:
;   pbcompilerc desktop\dispatch_bench.pb /CONSOLE /OPTIMIZER /CONSTANT BENCH_PROCS=0 /OUTPUT desktop\bench_goto.exe
;   pbcompilerc desktop\dispatch_bench.pb /CONSOLE /OPTIMIZER /CONSTANT BENCH_PROCS=1 /OUTPUT desktop\bench_procs.exe
; Each runs Klaus Dormann's 6502 functional test and 65C02 extended test three times and prints the best.
EnableExplicit
CompilerIf Not Defined(BENCH_PROCS, #PB_Constant)
  #BENCH_PROCS = 0
CompilerEndIf
CompilerIf #BENCH_PROCS
  XIncludeFile "cpu65c02_procs.pbi"
CompilerElse
  XIncludeFile "cpu65c02.pbi"
CompilerEndIf
Procedure.i CpuBusRead(addr.i)
  ProcedureReturn $FF
EndProcedure
Procedure CpuBusWrite(addr.i, value.i)
EndProcedure
XIncludeFile "cpu_tests.pbi"

; instructions in one run of the functional test, counted one CpuRun(1) at a time
Procedure.q CountInstructions(file$, success.i)
  Protected f.i, n.q
  f = ReadFile(#PB_Any, file$) : CtMapFlat() : ReadData(f, CtRam, 65536) : CloseFile(f)
  CpuPC = $400 : CpuS = $FF : CpuSetStatus($04)
  Repeat
    CpuRun(1) : n + 1
  Until CpuPC = success
  ProcedureReturn n
EndProcedure

OpenConsole()
Define dir$ = GetPathPart(ProgramFilename()) + "..\Diagnostics\", i.i, best.q, pc.i, instr.q, name$
CompilerIf #BENCH_PROCS : name$ = "procedure table" : CompilerElse : name$ = "computed goto" : CompilerEndIf
instr = CountInstructions(dir$ + "6502_functional_test.bin", $3469)
best = 1 << 40
For i = 1 To 3
  pc = CtRunKlaus(dir$ + "6502_functional_test.bin", $400)
  If CtKlausMs < best : best = CtKlausMs : EndIf
Next
If best < 1 : best = 1 : EndIf
PrintN(name$ + ": 6502 functional test " + Str(instr) + " instructions, " + Str(CtKlausCycles) + " cycles, best " + Str(best) + " ms = " + StrF(instr / (best * 1000.0), 1) + " M instructions/s, " + StrF(CtKlausCycles / (best * 1000.0), 1) + " M cycles/s (PC $" + Hex(pc) + ")")
