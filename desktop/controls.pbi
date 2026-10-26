; THE CONTROLS: one table that the keyboard code (apple2c_desktop.pb), the window's shortcuts, the Controls
; tab (view.pbi) and the README's Controls section (tools/controls_readme.py) all read - so they cannot
; disagree.
;
; A row: kind, PC key (a #PB_Shortcut_ code), what the PC key is called, what it is on the IIc, and a value:
; the key code the IIc reads for a key, 1 / 2 for the Open-Apple / Solid-Apple keys, the action for a window
; shortcut. mods: the Ctrl (1) and Alt (2) a shortcut needs. window: 1 = in the window only (Esc).
;
; Esc: in the window Esc is the IIc's ESC; in full screen Esc leaves full screen and is not passed to the
; IIc - End is ESC there (and always).
EnableExplicit

#CTL_KEY = 0          ; a PC key typed as an IIc key (value = the code)
#CTL_APPLE = 1        ; a PC key held as the Open-Apple (value 1) or Solid-Apple (value 2) key
#CTL_SHORTCUT = 2     ; the window's own (value = the action)
#CTL_NOTE = 3         ; a row of the Controls tab and the README only

#ACT_RUNPAUSE = 1
#ACT_STEP = 2
#ACT_FRAME = 3
#ACT_FULLSPEED = 4
#ACT_FULLSCREEN = 5
#ACT_LEAVEFULL = 6
#ACT_RESET = 7
#ACT_POWER = 8

Structure CtlRow
  kind.i
  vk.i
  pc$
  a2$
  value.i
  mods.i
  window.i
EndStructure
Global NewList Controls.CtlRow()

Procedure CtlAdd(kind.i, vk.i, pc$, a2$, value.i = 0, mods.i = 0, window.i = 0)
  AddElement(Controls())
  Controls()\kind = kind : Controls()\vk = vk : Controls()\pc$ = pc$ : Controls()\a2$ = a2$
  Controls()\value = value : Controls()\mods = mods : Controls()\window = window
EndProcedure

Procedure ControlsInit()
  ClearList(Controls())
  ; the IIc keyboard
  CtlAdd(#CTL_NOTE, 0, "Letters, digits, punctuation", "the same keys, as typed (Applesoft wants capitals: Caps Lock)")
  CtlAdd(#CTL_KEY, #PB_Shortcut_Return, "Return", "RETURN", $0D)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Back, "Backspace", "left arrow", $08)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Left, "Left", "left arrow", $08)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Right, "Right", "right arrow", $15)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Up, "Up", "up arrow", $0B)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Down, "Down", "down arrow", $0A)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Escape, "Esc (in the window)", "ESC", $1B, 0, 1)
  CtlAdd(#CTL_KEY, #PB_Shortcut_End, "End", "ESC", $1B)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Tab, "Tab", "TAB", $09)
  CtlAdd(#CTL_KEY, #PB_Shortcut_Delete, "Delete", "DELETE", $7F)
  CtlAdd(#CTL_NOTE, 0, "Ctrl + a letter", "CONTROL + the letter")
  CtlAdd(#CTL_APPLE, #VK_LMENU, "Left Alt", "Open-Apple (and joystick button 0)", 1)
  CtlAdd(#CTL_APPLE, #VK_RMENU, "Right Alt", "Solid-Apple (and joystick button 1)", 2)
  ; the joystick
  CtlAdd(#CTL_NOTE, 0, "Joystick, paddles, gamepad", "not emulated (no paddle inputs); the two buttons are the Alt keys")
  ; the window
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F5, "F5", "run / pause", #ACT_RUNPAUSE)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F6, "F6", "step one instruction", #ACT_STEP)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F7, "F7", "step one frame", #ACT_FRAME)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F9, "F9", "full speed on / off", #ACT_FULLSPEED)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F11, "F11", "full screen on / off", #ACT_FULLSCREEN)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_Escape, "Esc (in full screen)", "leave full screen", #ACT_LEAVEFULL)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F12, "Ctrl+F12", "Ctrl+Reset", #ACT_RESET, 1)
  CtlAdd(#CTL_SHORTCUT, #PB_Shortcut_F12, "Ctrl+Alt+F12", "power off and on (a cold start)", #ACT_POWER, 3)
EndProcedure

; The window's action for a key (0: none), with the Ctrl / Alt held (mods) and whether it is full screen.
Procedure.i ControlsAction(vk.i, mods.i, fullscreen.i)
  ForEach Controls()
    If Controls()\kind = #CTL_SHORTCUT And Controls()\vk = vk And Controls()\mods = mods
      If Controls()\value = #ACT_LEAVEFULL And fullscreen = 0 : Continue : EndIf
      ProcedureReturn Controls()\value
    EndIf
  Next
  ProcedureReturn 0
EndProcedure

; The IIc key code a PC key types (-1: none). Ctrl + a letter is that letter's control code.
Procedure.i ControlsKey(vk.i, ctrl.i, fullscreen.i)
  ForEach Controls()
    If Controls()\kind = #CTL_KEY And Controls()\vk = vk
      If Controls()\window And fullscreen : Continue : EndIf
      ProcedureReturn Controls()\value
    EndIf
  Next
  If ctrl And vk >= #PB_Shortcut_A And vk <= #PB_Shortcut_Z : ProcedureReturn vk - #PB_Shortcut_A + 1 : EndIf
  ProcedureReturn -1
EndProcedure
