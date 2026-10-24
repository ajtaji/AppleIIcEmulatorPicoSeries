; The speaker on the PC: the machine's 48 kHz ring (src/sound.pmi) to the sound card.
; Windows: waveOut with four 1024-sample buffers (about 85 ms queued at most). Elsewhere: silent.

#WO_BUFFERS = 4
#WO_SAMPLES = 1024

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
  Structure WoFormat
    wFormatTag.w : nChannels.w : nSamplesPerSec.l : nAvgBytesPerSec.l : nBlockAlign.w : wBitsPerSample.w : cbSize.w
  EndStructure
  Structure WoHeader
    *lpData : dwBufferLength.l : dwBytesRecorded.l : *dwUser : dwFlags.l : dwLoops.l : *lpNext : *reserved
  EndStructure
  Import "winmm.lib"
    waveOutOpen_(*handle, device.l, *format, callback.i, instance.i, flags.l) As "waveOutOpen"
    waveOutPrepareHeader_(handle.i, *header, size.l) As "waveOutPrepareHeader"
    waveOutUnprepareHeader_(handle.i, *header, size.l) As "waveOutUnprepareHeader"
    waveOutWrite_(handle.i, *header, size.l) As "waveOutWrite"
    waveOutReset_(handle.i) As "waveOutReset"
    waveOutClose_(handle.i) As "waveOutClose"
  EndImport
  #WO_DONE = 1
  Global WoHandle.i
  Global Dim WoHeaders.WoHeader(#WO_BUFFERS)
  Global Dim WoData.w(#WO_BUFFERS * #WO_SAMPLES)
CompilerEndIf
Global WoOpen.i, WoMuted.i, WoUnderruns.i, WoQueued.i, WoCursor.i, WoLast.w

Procedure.i WoBegin()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected fmt.WoFormat, i.i
    fmt\wFormatTag = 1 : fmt\nChannels = 1 : fmt\nSamplesPerSec = 48000 : fmt\wBitsPerSample = 16
    fmt\nBlockAlign = 2 : fmt\nAvgBytesPerSec = 96000
    If waveOutOpen_(@WoHandle, -1, @fmt, 0, 0, 0) <> 0 : WoHandle = 0 : ProcedureReturn 0 : EndIf
    For i = 0 To #WO_BUFFERS - 1
      WoHeaders(i)\lpData = @WoData(i * #WO_SAMPLES)
      WoHeaders(i)\dwBufferLength = #WO_SAMPLES * 2
      WoHeaders(i)\dwFlags = #WO_DONE
    Next
    WoOpen = 1 : SoundOn = 1 : WoCursor = SoundSamples
    ProcedureReturn 1
  CompilerElse
    ProcedureReturn 0
  CompilerEndIf
EndProcedure

; Fill every finished buffer from the ring; returns the samples the card still has queued.
Procedure.i WoPump()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected i.i, k.i, *dst, queued.i
    If WoOpen = 0 : ProcedureReturn 0 : EndIf
    ; never fall more than the ring behind
    If SoundSamples - WoCursor > #SOUND_RING - #WO_SAMPLES : WoCursor = SoundSamples - #WO_SAMPLES : EndIf
    For i = 0 To #WO_BUFFERS - 1
      If WoHeaders(i)\dwFlags & #WO_DONE
        If WoHeaders(i)\dwFlags & 2 : waveOutUnprepareHeader_(WoHandle, @WoHeaders(i), SizeOf(WoHeader)) : EndIf
        If SoundSamples - WoCursor < #WO_SAMPLES : Continue : EndIf
        *dst = @WoData(i * #WO_SAMPLES)
        For k = 0 To #WO_SAMPLES - 1
          PokeW(*dst + k * 2, SoundRing((WoCursor + k) & (#SOUND_RING - 1)))
        Next
        WoCursor + #WO_SAMPLES
        If WoMuted : FillMemory(*dst, #WO_SAMPLES * 2, 0) : EndIf
        WoHeaders(i)\dwFlags = 0
        waveOutPrepareHeader_(WoHandle, @WoHeaders(i), SizeOf(WoHeader))
        waveOutWrite_(WoHandle, @WoHeaders(i), SizeOf(WoHeader))
      EndIf
    Next
    For i = 0 To #WO_BUFFERS - 1
      If (WoHeaders(i)\dwFlags & #WO_DONE) = 0 : queued + #WO_SAMPLES : EndIf
    Next
    If queued = 0 : WoUnderruns + 1 : EndIf
    WoQueued = queued
    ProcedureReturn queued
  CompilerElse
    ProcedureReturn 0
  CompilerEndIf
EndProcedure

Procedure WoEnd()
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected i.i
    If WoHandle
      waveOutReset_(WoHandle)
      For i = 0 To #WO_BUFFERS - 1 : waveOutUnprepareHeader_(WoHandle, @WoHeaders(i), SizeOf(WoHeader)) : Next
      waveOutClose_(WoHandle) : WoHandle = 0
    EndIf
  CompilerEndIf
  WoOpen = 0
EndProcedure
