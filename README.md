# Apple IIc for the Raspberry Pi Pico series and the desktop — PureMetal and PureBasic

An Apple IIc emulator in two forms, one machine:

- **Pico W (RP2040) and Pico 2 W (RP2350)**, in PureMetal, compiled with PureMetalForge to bare-metal
  machine code: the LAFVIN ST7796 panel (480 x 320), the keyboard over USB serial, sound on the
  Bluetooth speaker.
- **Windows desktop**, in PureBasic (C back end, x64), drawn with the Neon Arcade Display Engine: the
  screen in a window, the PC's sound and keyboard, ROM and disk pickers, debug panes.

The machine (`src/*.pmi`) is one source: the desktop includes the Pico's own files unchanged. The CPU is
generated for both from one table (`tools/gen_cpu.py`).

**No Apple code is included.** The IIc ROM, its character generator and every disk image are Apple's
or their publishers'. Without a ROM both forms run this project's own **test ROM** (`tools/make_testrom.py`),
which checks the soft switches and shows every video mode; the character set is this project's own
(`tools/make_font.py`). `tools/make_private.py` builds a private firmware (in `private/`, ignored by git)
around your own ROM file and disk image.

## What is emulated

| Part | State |
|---|---|
| 65C02 (Rockwell R65C02: the CMOS instructions and modes, BBR/BBS/RMB/SMB, undefined opcodes as the silicon's NOPs, CMOS decimal mode), cycle counts | Pico W: 3072 SingleStepTests vectors and both Klaus Dormann tests; desktop: 87053 vectors and both Klaus tests |
| 128 KB: main and auxiliary banks, 80STORE, RAMRD, RAMWRT, ALTZP, the language card (both $D000 banks, pre-write), the ROM's two banks at $C028 (32 KB ROMs) | desktop: the test ROM's checks pass |
| Video: 40/80-column text with inverse, flashing, lower case and MouseText; lo-res, double lo-res, hi-res, double hi-res, mixed; PAGE2 | desktop: every mode drawn |
| Colour: NTSC artifact colour from the dot stream (see below); a monochrome switch | |
| Keyboard (latch, strobe, any-key-down, Open-Apple and Solid-Apple), VBL ($C019, the VBL interrupt) | |
| Speaker ($C030) sampled at 48 kHz against machine time | |
| The built-in drive (IWM in Disk II mode, two drives): stepping, the DOS 3.3 track format, 6-and-2; .DSK/.DO, .PO, .NIB; .WOZ 1/2 (desktop, read as nibbles) | desktop: this project's test disk boots and all 544 sectors of tracks 1-34 read back |
| Serial ports, the mouse, the memory expansion card | not emulated (the serial ports answer "nothing received") |

### Colour

The picture is 560 dots a line. The colour of a dot is the 4-bit value of dots x-1 .. x+2, each at
the bit of its position in the 4-dot colour cycle, read as a lo-res colour number: runs of dots are
white, lone pixels take their column's colour (hi-res violet/green, blue/orange with the palette bit),
double hi-res gets its 16 colours, from one rule. Text is not coloured. This is the composite (NTSC)
look, not the IIc's RGB adapter.

## The Pico builds

Pico W, 200 MHz; the CPU core and its dispatch run from SRAM. Guest RAM is 128 KB in sixteen 8 KB
blocks. Core 0 runs the machine paced to the real IIc (59.92 frames a second, 17030 cycles each);
core 1 draws the panel, a line only when what it shows changed, and keeps the Bluetooth radio going.

Panel: 560 dots to 480 pixels (40-column text 12 pixels a character, 80-column 6, graphics 6 of every
7 dots), 192 lines to 320 rows (5 for every 3).

Flash: the program and its data stay below $40000 (other programs on the shared boards keep data
above). A disk is stored in the image packed a track at a time (`tools/lzpack.py`) and unpacked into
SRAM when the head reaches the track; writes to it are dropped (counted in the status line).

```powershell
# public firmware (test ROM), uploaded and checked under the board lease
powershell -File tools/board.ps1 -Source rp2040/apple2c.picow -Output build/apple2c.uf2 -Script tests/testrom.txt
# the private build: your ROM, a disk, the speaker
py -3 tools/make_private.py --rom <IIc ROM> --disk <disk.dsk>
powershell -File tools/board.ps1 -Source private/apple2c.picow -Output private/apple2c.uf2
py -3 tools/console.py --port COM7
```

Over USB, Ctrl+] then a letter is a monitor command: `s` status, `t` the screen as text, `c` capture
the panel's picture, `p` CPU and switches, `f` full speed, `m` monochrome, `r` Ctrl+Reset, `R` power
off and on, `d` disk, `k` keyboard, `o`/`a` hold Open-/Solid-Apple for the next key.

## The desktop

```powershell
& "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\apple2c_desktop.pb /EXE desktop\PureMetalAppleIIc.exe /THREAD /DPIAWARE /OPTIMIZER
& "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\apple2c_check.pb /CONSOLE /OPTIMIZER /OUTPUT desktop\apple2c_check.exe
& "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\cpu_check.pb /CONSOLE /OPTIMIZER /OUTPUT desktop\apple2c_cpu_check.exe
```

`PureMetalAppleIIc.exe [--rom file] [--disk1 file] [--disk2 file] [--mono] [--mute] [--type TEXT]`.
Typing goes to the IIc; Left/Right Alt are Open-/Solid-Apple; Ctrl+F12 is Ctrl+Reset, Ctrl+Alt+F12 a
cold start; F5 run/pause, F6 step, F7 one frame, F9 full speed. Panes: CPU (registers, disassembly,
click a line to break there, the stack), Switches, Memory (as the CPU sees it, main, auxiliary), Disk
(both drives, the IWM), Tests (the CPU suites).

`apple2c_check.exe` runs the machine headless: `--frames N --type-at FRAME TEXT --expect TEXT --png file`.

## Measured

| | |
|---|---|
| Pico W, 65C02 core alone (Klaus tests) | 6.7-7.3 MHz of 65C02 time, about 7x a IIc |
| Desktop, 65C02 core alone (6502 functional test, 30,646,176 instructions) | 175 M instructions/s (C computed goto), 172 M through a procedure table |
| Desktop, whole machine paced | 60.0 frames/s, 1.02 MHz |

## Tests

| Where | What | Command |
|---|---|---|
| PC | 87053 vectors, Klaus 65C02 and 6502 | `desktop\apple2c_cpu_check.exe` |
| Pico W | 3072 vectors, Klaus 65C02 and 6502 | `tools/board.ps1 -Source rp2040/Diagnostics/cpu_verify.picow -Output build/cpu_verify.uf2 -Seconds 80` |
| PC | the test ROM's soft switch checks | `apple2c_check.exe --frames 60 --expect "ALL PASS"` |
| PC | the test disk: boot, 544 sectors | `apple2c_check.exe --disk1 build\testdisk.dsk --frames 4000 --type-at 30 D --expect "544 SECTORS PASS"` |
| Pico W | the test ROM, every mode captured | `tests/testrom.txt` |
| Pico W | the test disk | `tests/diskboot.txt` with `rp2040/Diagnostics/disk_boot.picow` |

Test inputs: `tools/fetch_tests.py`, then `tools/make_vectors.py` and `tools/embed_tests.py`.

## Sources and licences

The emulator is MIT (`LICENSE`). Test material keeps its own licence: SingleStepTests/65x02 (MIT),
Klaus Dormann's functional tests (GPLv3; the binaries and the 65C02 test's source with its licence are
in `Diagnostics/`; firmware containing them is a diagnostic, not the emulator). Read, not copied, for
the hardware's behaviour: the Apple IIc and IIe Technical Reference Manuals, "Beneath Apple DOS",
MAME's apple2e.cpp, CiderPress's Nibble.cpp.
