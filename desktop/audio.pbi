; The speaker on the PC: the machine's 48 kHz ring (src/sound.pmi) to the sound card, through the engine's
; GL_AudioOpen / Next / Play (waveOut on Windows, ALSA on Linux): four 1024-sample buffers (about 85 ms queued
; at most), the mono speaker on both channels.

#WO_BUFFERS = 4
#WO_SAMPLES = 1024

Global WoOpen.i, WoMuted.i, WoUnderruns.i, WoQueued.i, WoCursor.i, WoThread.i, WoQuit.i

Declare WoPump()
; The sound card is fed from its own thread every 4 ms: the driver's calls can take milliseconds, and they
; must not hold up the window. It only reads the ring the machine writes.
Procedure WoThreadMain(*unused)
  Repeat
    WoPump()
    Delay(4)
  Until WoQuit
EndProcedure

Procedure.i WoBegin()
  If GL_AudioOpen(48000, #WO_SAMPLES, #WO_BUFFERS) = #False : ProcedureReturn 0 : EndIf
  WoOpen = 1 : SoundOn = 1 : WoCursor = SoundSamples
  WoThread = CreateThread(@WoThreadMain(), 0)
  ProcedureReturn 1
EndProcedure

; Every buffer the card has free, from the ring, while the ring holds a buffer's worth; then the samples the
; card still has queued (none: an underrun).
Procedure WoPump()
  Protected k.i, *dst, s.w
  If WoOpen = 0 : ProcedureReturn : EndIf
  ; never fall more than 4 buffers (85 ms) behind: a late card catches up
  If SoundSamples - WoCursor > #WO_BUFFERS * #WO_SAMPLES : WoCursor = SoundSamples - #WO_SAMPLES : EndIf
  While SoundSamples - WoCursor >= #WO_SAMPLES
    *dst = GL_AudioNext()                       ; (asked for only with samples ready: a buffer taken is played)
    If *dst = 0 : Break : EndIf
    For k = 0 To #WO_SAMPLES - 1
      s = SoundRing((WoCursor + k) & (#SOUND_RING - 1))
      If WoMuted : s = 0 : EndIf
      PokeW(*dst + k * 4, s) : PokeW(*dst + k * 4 + 2, s)
    Next
    WoCursor + #WO_SAMPLES
    GL_AudioPlay(*dst)
  Wend
  WoQueued = GL_AudioQueued()
  If WoQueued = 0 : WoUnderruns + 1 : EndIf
EndProcedure

Procedure WoEnd()
  WoQuit = 1
  If WoThread : WaitThread(WoThread) : WoThread = 0 : EndIf
  If WoOpen : GL_AudioClose() : EndIf
  WoOpen = 0
EndProcedure
