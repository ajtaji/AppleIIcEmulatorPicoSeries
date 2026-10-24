; The desktop's side of the machine: the ROM file, the disk files, writing changed disks back.
; The machine itself is the Pico's own source (src/*.pmi), included unchanged.
;
; ROM: a 16 KB (IIc ROM 255) or 32 KB (ROM 0, 3, 4: two banks) image of $C000-$FFFF, the user's own file.
; Without one the machine runs this project's test ROM (src/testrom.pmi).
; Disks: .dsk / .do (DOS order), .po (ProDOS order), .nib (35 raw tracks of 6656), .woz (WOZ 1 and 2:
; each track's bit stream is read into nibbles once, at load; a WOZ disk is write-protected here).

Global HostRom.i, HostRomName$ = "built-in test ROM (no Apple code)", HostRomError$
Global Dim HostDisk.i(3)
Global Dim HostDiskPath$(3)
Global Dim HostDiskDirty.i(3)
Global Dim HostDiskNote$(3)

Procedure.i DiskHostSector(drive.i, track.i, sector.i)
  If HostDisk(drive) = 0 Or track < 0 Or track >= 35 : ProcedureReturn 0 : EndIf
  ProcedureReturn HostDisk(drive) + (track * 16 + sector) * 256
EndProcedure
Procedure.i DiskHostTrack(drive.i, track.i)
  If HostDisk(drive) = 0 Or track < 0 Or track >= 35 : ProcedureReturn 0 : EndIf
  ProcedureReturn HostDisk(drive) + track * #DISK_TRACK_BYTES
EndProcedure
Procedure.i DiskHostWrite(drive.i, track.i, sector.i, src.i)
  If HostDisk(drive) = 0 Or DiskProtect(drive) : ProcedureReturn 0 : EndIf
  CopyMemory(src, HostDisk(drive) + (track * 16 + sector) * 256, 256)
  HostDiskDirty(drive) = 1
  ProcedureReturn 1
EndProcedure
Procedure.i DiskHostWriteTrack(drive.i, track.i, src.i)
  If HostDisk(drive) = 0 Or DiskProtect(drive) : ProcedureReturn 0 : EndIf
  CopyMemory(src, HostDisk(drive) + track * #DISK_TRACK_BYTES, #DISK_TRACK_BYTES)
  HostDiskDirty(drive) = 1
  ProcedureReturn 1
EndProcedure

; Returns "" or why the ROM was refused.
Procedure.s HostLoadRom(path$)
  Protected f.i, size.i, *m
  If path$ = ""
    HostRom = ?A2TestRom : A2Rom = HostRom : A2RomBytes = 16384
    HostRomName$ = "built-in test ROM (no Apple code)"
    ProcedureReturn ""
  EndIf
  f = ReadFile(#PB_Any, path$)
  If f = 0 : ProcedureReturn "cannot open " + path$ : EndIf
  size = Lof(f)
  If size <> 16384 And size <> 32768
    CloseFile(f)
    ProcedureReturn GetFilePart(path$) + " is " + Str(size) + " bytes; an Apple IIc ROM is 16384 (ROM 255) or 32768 (ROM 0, 3, 4)"
  EndIf
  *m = AllocateMemory(32768)
  ReadData(f, *m, size) : CloseFile(f)
  HostRom = *m : A2Rom = *m : A2RomBytes = size
  HostRomName$ = GetFilePart(path$) + " (" + Str(size / 1024) + " KB)"
  ProcedureReturn ""
EndProcedure

; WOZ: the track's bits, twice round, into nibbles; the second turn's, from the first sync.
Procedure HostWozTrack(*bits, bitCount.i, *dst)
  Protected i.i, n.i, reg.i, b.i, k.i, start.i, total.i
  FillMemory(*dst, #DISK_TRACK_BYTES, $FF)
  If bitCount <= 0 : ProcedureReturn : EndIf
  total = bitCount * 2
  n = 0 : reg = 0
  For i = 0 To total - 1
    k = i % bitCount
    b = (PeekA(*bits + (k >> 3)) >> (7 - (k & 7))) & 1
    If reg = 0 And b = 0 : Continue : EndIf
    reg = (reg << 1) | b
    If reg & $80
      If i >= bitCount
        If n < #DISK_TRACK_BYTES : PokeA(*dst + n, reg) : n + 1 : EndIf
      EndIf
      reg = 0
    EndIf
  Next
EndProcedure

Procedure.s HostLoadWoz(drive.i, *file, size.i)
  Protected v2.i, p.i, id.l, len.i, tmap.i, trks.i, t.i, q.i, *img, blk.i, bits.i
  If size < 12 : ProcedureReturn "not a WOZ file" : EndIf
  If PeekL(*file) = $325A4F57 : v2 = 1 : ElseIf PeekL(*file) = $315A4F57 : v2 = 0 : Else : ProcedureReturn "not a WOZ file" : EndIf
  p = 12
  While p + 8 <= size
    id = PeekL(*file + p) : len = PeekL(*file + p + 4)
    If id = $50414D54 : tmap = *file + p + 8 : EndIf      ; TMAP
    If id = $534B5254 : trks = *file + p + 8 : EndIf      ; TRKS
    p = p + 8 + len
  Wend
  If tmap = 0 Or trks = 0 : ProcedureReturn "WOZ file without TMAP / TRKS" : EndIf
  *img = AllocateMemory(35 * #DISK_TRACK_BYTES)
  For t = 0 To 34
    q = PeekA(tmap + t * 4)
    If q = $FF : FillMemory(*img + t * #DISK_TRACK_BYTES, #DISK_TRACK_BYTES, $FF) : Continue : EndIf
    If v2
      blk = PeekU(trks + q * 8) : bits = PeekL(trks + q * 8 + 4)
      HostWozTrack(*file + blk * 512, bits, *img + t * #DISK_TRACK_BYTES)
    Else
      bits = PeekU(trks + q * 6656 + 6648)
      HostWozTrack(trks + q * 6656, bits, *img + t * #DISK_TRACK_BYTES)
    EndIf
  Next
  HostDisk(drive) = *img : DiskKind(drive) = 3 : DiskProtect(drive) = 1
  HostDiskNote$(drive) = "WOZ " + Str(1 + v2) + ", read as nibbles; write-protected"
  ProcedureReturn ""
EndProcedure

Declare HostEjectDisk(drive.i)

; Returns "" or why the disk was refused.
Procedure.s HostLoadDisk(drive.i, path$)
  Protected f.i, size.i, *m, ext$, r$
  HostEjectDisk(drive)
  If path$ = "" : ProcedureReturn "" : EndIf
  f = ReadFile(#PB_Any, path$)
  If f = 0 : ProcedureReturn "cannot open " + path$ : EndIf
  size = Lof(f)
  ext$ = LCase(GetExtensionPart(path$))
  *m = AllocateMemory(size + 16)
  ReadData(f, *m, size) : CloseFile(f)
  DiskProtect(drive) = 0 : HostDiskNote$(drive) = ""
  Select ext$
    Case "dsk", "do", "po"
      If size <> 143360
        FreeMemory(*m)
        ProcedureReturn GetFilePart(path$) + " is " + Str(size) + " bytes; a 5.25-inch sector image is 143360 (35 tracks x 16 sectors x 256)"
      EndIf
      HostDisk(drive) = *m
      If ext$ = "po" : DiskKind(drive) = 2 : Else : DiskKind(drive) = 1 : EndIf
    Case "nib"
      If size <> 35 * #DISK_TRACK_BYTES
        FreeMemory(*m)
        ProcedureReturn GetFilePart(path$) + " is " + Str(size) + " bytes; a .nib image is 232960 (35 tracks x 6656)"
      EndIf
      HostDisk(drive) = *m : DiskKind(drive) = 3
    Case "woz"
      r$ = HostLoadWoz(drive, *m, size)
      FreeMemory(*m)
      If r$ <> "" : ProcedureReturn GetFilePart(path$) + ": " + r$ : EndIf
    Default
      FreeMemory(*m)
      ProcedureReturn GetFilePart(path$) + ": not a disk image this machine reads (.dsk .do .po .nib .woz)"
  EndSelect
  HostDiskPath$(drive) = path$ : HostDiskDirty(drive) = 0
  DiskNibTrack = -1
  ProcedureReturn ""
EndProcedure

; Write a changed disk back to its file (not a WOZ: those are never written).
Procedure.s HostSaveDisk(drive.i)
  Protected f.i, size.i
  If HostDisk(drive) = 0 Or HostDiskDirty(drive) = 0 : ProcedureReturn "" : EndIf
  If DiskNibDrive = drive : DiskFlushTrack() : EndIf
  If DiskKind(drive) = 3 : size = 35 * #DISK_TRACK_BYTES : Else : size = 143360 : EndIf
  f = CreateFile(#PB_Any, HostDiskPath$(drive))
  If f = 0 : ProcedureReturn "cannot write " + HostDiskPath$(drive) : EndIf
  WriteData(f, HostDisk(drive), size) : CloseFile(f)
  HostDiskDirty(drive) = 0
  ProcedureReturn ""
EndProcedure

Procedure HostEjectDisk(drive.i)
  If HostDisk(drive)
    If DiskNibDrive = drive : DiskFlushTrack() : DiskNibTrack = -1 : EndIf
    HostSaveDisk(drive)
    FreeMemory(HostDisk(drive))
  EndIf
  HostDisk(drive) = 0 : DiskKind(drive) = 0 : HostDiskPath$(drive) = "" : HostDiskNote$(drive) = ""
EndProcedure

; Power on with the ROM loaded now.
Procedure HostPowerOn()
  A2ColdStart()
  SoundStart(CpuCycles)
EndProcedure
