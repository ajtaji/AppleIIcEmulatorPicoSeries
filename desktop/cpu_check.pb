; Console check of the desktop 65C02 core alone: apple2c_cpu_check.exe [Diagnostics folder]
EnableExplicit
XIncludeFile "cpu65c02.pbi"
Procedure.i CpuBusRead(addr.i)
  ProcedureReturn $FF
EndProcedure
Procedure CpuBusWrite(addr.i, value.i)
EndProcedure
XIncludeFile "cpu_tests.pbi"

OpenConsole()
Define folder$ = "Diagnostics\"
If CountProgramParameters() > 0 : folder$ = ProgramParameter(0) : EndIf
PrintN(CtAllTests(folder$))
If CtVectorFails Or Left(CtKlausResult$, 4) <> "PASS" Or Left(CtKlaus6502Result$, 4) <> "PASS"
  PrintN("RESULT: FAIL")
  End 1
EndIf
PrintN("RESULT: PASS")
End 0
