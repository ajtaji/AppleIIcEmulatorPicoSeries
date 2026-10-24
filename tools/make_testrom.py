"""Build this project's own test ROM (no Apple code): a 16 KB image for $C000-$FFFF that the machine
runs when no Apple IIc ROM is given. It checks the soft switches and the memory banks, prints the
verdicts on the text screen (the board's USB text dump reads them), and on a key shows each video mode:

    1 40-column text and the character set   A  toggle the alternate character set (MouseText)
    2 80-column text                         3  lo-res, 16 colour bars
    4 hi-res, colour bands                   5  double hi-res, 16 colour bars
    6 mixed (hi-res and four text lines)     7  double lo-res
    B a beep through the speaker             any other key is shown on the bottom line

Writes build/testrom.s, build/testrom.lst and src/testrom.pmi (DataSection A2TestRom, 16384 bytes).
    py -3 tools/make_testrom.py
"""
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from asm65 import assemble

def text_row(r):
    return 0x400 + (r & 7) * 0x80 + (r >> 3) * 0x28

def hires_line(y):
    return 0x2000 + (y & 7) * 0x400 + ((y >> 3) & 7) * 0x80 + (y >> 6) * 0x28

def dhr_bytes(c):
    # four bytes (aux, main, aux, main) holding 28 dots of colour c: dot j = bit (j & 3) of c
    dots = [(c >> (j & 3)) & 1 for j in range(28)]
    return [sum(dots[7 * k + i] << i for i in range(7)) for k in range(4)]

def table(name, values):
    out = [f'{name}:']
    for s in range(0, len(values), 16):
        out.append('  .byte ' + ','.join(f'${v & 255:02X}' for v in values[s:s + 16]))
    return '\n'.join(out)

# Entry points a disk's own program calls (tools/make_testdisk.py): fixed addresses.
JUMPS = '''
        .org $CF00
        jmp READSEC          ; $CF00
        jmp PRINT            ; $CF03
        jmp LOOP             ; $CF06
        jmp DISKON           ; $CF09
        jmp SHOWKEY          ; $CF0C
'''
LINE80 = 'Eighty columns: even ones from the auxiliary bank, odd from main. 0123456789'
LINE80 = (LINE80 + ' ' * 80)[:80]
RULER80 = '0123456789' * 8
tables = '\n'.join([
    table('ROWLO', [text_row(r) & 255 for r in range(24)]),
    table('ROWHI', [text_row(r) >> 8 for r in range(24)]),
    table('HLO', [hires_line(y) & 255 for y in range(192)]),
    table('HHI', [hires_line(y) >> 8 for y in range(192)]),
    table('DHRTAB', [b for c in range(16) for b in dhr_bytes(c)]),
    table('LOCOL', [(c * 16 // 40) * 17 for c in range(40)]),
    table('T80AUX', [ord(ch) | 0x80 for ch in LINE80[0::2]]),
    table('T80MAIN', [ord(ch) | 0x80 for ch in LINE80[1::2]]),
    table('R80AUX', [ord(ch) | 0x80 for ch in RULER80[0::2]]),
    table('R80MAIN', [ord(ch) | 0x80 for ch in RULER80[1::2]]),
    table('HBAND', [0x55, 0x2A, 0x2A, 0x55, 0xD5, 0xAA, 0xAA, 0xD5, 0x7F, 0x7F, 0x00, 0x00, 0x11, 0x22]),
])

SRC = r'''
; PureMetal Apple IIc emulator's own test ROM. Not Apple's code. Assembled by tools/asm65.py.
STR    = $00          ; string pointer
ROW    = $02
COL    = $03
BAS    = $04          ; text / hi-res line pointer
TMP    = $06
CNT    = $07
FAILS  = $08
LASTK  = $09
MODE   = $0A
YLINE  = $0B
GRP    = $0C
COLR   = $0D

KBD    = $C000
KBDSTRB = $C010
CLR80STORE = $C000
SET80STORE = $C001
RDMAINRAM = $C002
RDCARDRAM = $C003
WRMAINRAM = $C004
WRCARDRAM = $C005
SETSTDZP = $C008
SETALTZP = $C009
CLR80VID = $C00C
SET80VID = $C00D
CLRALTCHAR = $C00E
SETALTCHAR = $C00F
RDLCBNK2 = $C011
RDLCRAM = $C012
RDRAMRD = $C013
RDRAMWRT = $C014
RDALTZP = $C016
RD80STORE = $C018
SPKR   = $C030
TXTCLR = $C050
TXTSET = $C051
MIXCLR = $C052
MIXSET = $C053
LOWSCR = $C054
HISCR  = $C055
LORES  = $C056
HIRES  = $C057
DHIRESON = $C05E
DHIRESOFF = $C05F
IOUDISON = $C07E

        .org $C000
        .fill $100, $FF          ; $C000-$C0FF is the I/O page, never read from the ROM
        .org $C100               ; below $D000: the language card check switches RAM in there
RESET:  sei
        cld
        ldx #$FF
        txs
        sta IOUDISON
        jsr NORMAL
        jsr CLS
        lda #0
        sta FAILS
        lda #0
        sta ROW
        lda #0
        sta COL
        lda #<TITLE
        ldx #>TITLE
        jsr PRINT
        jsr SELFTEST
        jsr MENU
        jmp LOOP

; ---------------------------------------------------------------- the soft switch checks
SELFTEST:
        ; 1. RAMRD / RAMWRT: $55 into main $2000, $AA into aux $2000, read each back
        sta WRMAINRAM
        lda #$55
        sta $2000
        sta WRCARDRAM
        lda #$AA
        sta $2000
        lda RDRAMWRT
        bpl F1
        sta WRMAINRAM
        sta RDMAINRAM
        lda $2000
        cmp #$55
        bne F1
        sta RDCARDRAM
        lda RDRAMRD
        bpl F1x
        lda $2000
        sta RDMAINRAM
        cmp #$AA
        bne F1
        lda #<T_RAM
        ldx #>T_RAM
        jsr PASSLINE
        jmp T2
F1x:    sta RDMAINRAM
F1:     lda #<T_RAM
        ldx #>T_RAM
        jsr FAILLINE
T2:     ; 2. ALTZP: zero page $80 differs between the banks (no subroutine while it is on)
        lda #$11
        sta $80
        sta SETALTZP
        lda #$22
        sta $80
        ldx RDALTZP          ; kept in X: a store now would go to the auxiliary zero page
        lda $80
        sta SETSTDZP
        cmp #$22
        bne F2
        lda $80
        cmp #$11
        bne F2
        txa
        bpl F2
        lda #<T_ZP
        ldx #>T_ZP
        jsr PASSLINE
        jmp T3
F2:     lda #<T_ZP
        ldx #>T_ZP
        jsr FAILLINE
T3:     ; 3. the language card: bank 2 and bank 1 at $D000 hold different bytes, ROM reads ROM
        lda $C083
        lda $C083            ; read and write RAM, bank 2
        lda #$12
        sta $D000
        lda $C08B
        lda $C08B            ; read and write RAM, bank 1
        lda #$34
        sta $D000
        lda $D000
        cmp #$34
        bne F3
        lda RDLCBNK2
        bmi F3
        lda $C083
        lda $C083
        lda $D000
        cmp #$12
        bne F3
        lda RDLCBNK2
        bpl F3
        lda RDLCRAM
        bpl F3
        lda $C082            ; ROM again
        lda $D000
        cmp ROMD000          ; the ROM's byte there
        bne F3
        lda #<T_LC
        ldx #>T_LC
        jsr PASSLINE
        jmp T4
F3:     lda $C082
        lda #<T_LC
        ldx #>T_LC
        jsr FAILLINE
T4:     ; 4. 80STORE with PAGE2: $0400 is the auxiliary bank's, without it the main bank's
        sta SET80STORE
        sta HISCR
        lda #$C1             ; 'A' in aux
        sta $0427
        sta LOWSCR
        lda #$C2             ; 'B' in main
        sta $0427
        sta HISCR
        lda $0427
        sta LOWSCR
        cmp #$C1
        bne F4
        lda RD80STORE
        bpl F4
        sta CLR80STORE
        lda $0427
        cmp #$C2
        bne F4
        lda #$A0
        sta $0427
        lda #<T_80
        ldx #>T_80
        jsr PASSLINE
        jmp T5
F4:     sta CLR80STORE
        sta LOWSCR
        lda #<T_80
        ldx #>T_80
        jsr FAILLINE
T5:     ; 5. the 65C02's own instructions run (STZ, TSB, BRA, PHX, BBS)
        lda #$FF
        sta TMP
        stz TMP
        lda #$03
        tsb TMP
        lda TMP
        cmp #$03
        bne F5
        smb7 TMP
        bbs7 TMP,T5a
        bra F5
T5a:    ldx #$5A
        phx
        ldx #0
        plx
        cpx #$5A
        bne F5
        lda #<T_CPU
        ldx #>T_CPU
        jsr PASSLINE
        jmp T6
F5:     lda #<T_CPU
        ldx #>T_CPU
        jsr FAILLINE
T6:     inc ROW
        lda #0
        sta COL
        lda FAILS
        bne T6f
        lda #<T_ALLOK
        ldx #>T_ALLOK
        jsr PRINT
        rts
T6f:    lda #<T_ALLBAD
        ldx #>T_ALLBAD
        jsr PRINT
        rts

PASSLINE:
        jsr PRLINE
        lda #<T_PASS
        ldx #>T_PASS
        jmp PRINT
FAILLINE:
        inc FAILS
        jsr PRLINE
        lda #<T_FAIL
        ldx #>T_FAIL
        jmp PRINT
PRLINE: pha
        inc ROW
        lda #0
        sta COL
        pla
        jmp PRINT

; ---------------------------------------------------------------- text output
; PRINT: the zero-terminated string at A (low) / X (high), at ROW / COL, in page 1 main.
PRINT:  sta STR
        stx STR+1
        ldx ROW
        lda ROWLO,x
        clc
        adc COL
        sta BAS
        lda ROWHI,x
        sta BAS+1
        ldy #0
PR1:    lda (STR),y
        beq PR2
        sta (BAS),y
        iny
        bra PR1
PR2:    tya
        clc
        adc COL
        sta COL
        rts

; CLS: page 1 text all spaces.
CLS:    lda #$A0
        ldx #0
CL1:    sta $400,x
        sta $500,x
        sta $600,x
        sta $700,x
        inx
        bne CL1
        rts

; NORMAL: 40-column text page 1, primary characters, nothing double.
NORMAL: sta TXTSET
        sta MIXCLR
        sta LOWSCR
        sta LORES
        sta CLR80VID
        sta CLR80STORE
        sta CLRALTCHAR
        sta DHIRESOFF
        rts

MENU:   lda #18
        sta ROW
        lda #0
        sta COL
        lda #<T_MENU1
        ldx #>T_MENU1
        jsr PRINT
        lda #19
        sta ROW
        lda #0
        sta COL
        lda #<T_MENU2
        ldx #>T_MENU2
        jsr PRINT
        lda #20
        sta ROW
        lda #0
        sta COL
        lda #<T_MENU3
        ldx #>T_MENU3
        jmp PRINT

; ---------------------------------------------------------------- the key loop
LOOP:   lda KBD
        bpl LOOP
        sta KBDSTRB
        sta LASTK
        cmp #$B1             ; '1'
        bne K2
        jsr SHOWCHARS
        jmp KDONE
K2:     cmp #$B2
        bne K3
        jsr SHOW80
        jmp KDONE
K3:     cmp #$B3
        bne K4
        jsr SHOWLORES
        jmp KDONE
K4:     cmp #$B4
        bne K5
        jsr SHOWHIRES
        jmp KDONE
K5:     cmp #$B5
        bne K6
        jsr SHOWDHR
        jmp KDONE
K6:     cmp #$B6
        bne K7
        jsr SHOWHIRES
        sta MIXSET
        jmp KDONE
K7:     cmp #$B7
        bne KA
        jsr SHOWDLORES
        jmp KDONE
KA:     cmp #$C1             ; 'A'
        beq KAy
        cmp #$E1             ; 'a'
        bne KB
KAy:    lda $C01E
        bmi KA0
        sta SETALTCHAR
        jmp KDONE
KA0:    sta CLRALTCHAR
        jmp KDONE
KB:     cmp #$C2             ; 'B'
        beq KBy
        cmp #$E2
        bne KD
KBy:    jsr BEEP
        jmp KDONE
KD:     cmp #$C4             ; 'D': boot drive 1
        beq KDy
        cmp #$E4
        bne KOTHER
KDy:    jsr NORMAL
        jmp BOOT
KOTHER: jsr NORMAL
KDONE:  jsr SHOWKEY
        jmp LOOP

; The last key on line 23: "KEY x $hh"
SHOWKEY:
        lda #23
        sta ROW
        lda #0
        sta COL
        lda #<T_KEY
        ldx #>T_KEY
        jsr PRINT
        lda LASTK
        ldy #4
        sta (BAS),y          ; BAS is where the text began: the key goes after "KEY "
        iny
        iny
        lda #$A4             ; '$'
        sta (BAS),y
        iny
        lda LASTK
        lsr a
        lsr a
        lsr a
        lsr a
        tax
        lda HEXCH,x
        sta (BAS),y
        iny
        lda LASTK
        and #$0F
        tax
        lda HEXCH,x
        sta (BAS),y
        rts

; ---------------------------------------------------------------- the modes
; 1: every character code, eight rows of 32, on rows 4-11
SHOWCHARS:
        jsr NORMAL
        lda #0
        sta TMP              ; the code
        ldx #4
SC1:    lda ROWLO,x
        clc
        adc #4
        sta BAS
        lda ROWHI,x
        sta BAS+1
        ldy #0
SC2:    lda TMP
        sta (BAS),y
        inc TMP
        iny
        cpy #32
        bne SC2
        inx
        cpx #12
        bne SC1
        rts

; 2: 80 columns; the auxiliary half through 80STORE + PAGE2
SHOW80: jsr NORMAL
        sta SET80VID
        sta SET80STORE
        ldx #0
S80a:   lda ROWLO,x
        sta BAS
        lda ROWHI,x
        sta BAS+1
        ldy #39
        txa
        and #1
        bne S80r
S80b:   sta HISCR            ; even rows: a sentence, its even columns in the aux bank
        lda T80AUX,y
        sta (BAS),y
        sta LOWSCR
        lda T80MAIN,y
        sta (BAS),y
        dey
        bpl S80b
        bra S80n
S80r:   sta HISCR            ; odd rows: a ruler 0-9 eight times
        lda R80AUX,y
        sta (BAS),y
        sta LOWSCR
        lda R80MAIN,y
        sta (BAS),y
        dey
        bpl S80r
S80n:   inx
        cpx #24
        bne S80a
        rts

; 3: lo-res, 16 colour bars of 2.5 columns, mixed with the four text lines (the menu stays readable)
SHOWLORES:
        jsr NORMAL
        jsr LOFILL
        sta TXTCLR
        sta MIXSET
        rts
LOFILL: ldx #0
LF1:    lda ROWLO,x
        sta BAS
        lda ROWHI,x
        sta BAS+1
        ldy #0
LF2:    lda LOCOL,y          ; column -> its bar's colour, in both halves of the byte
        sta (BAS),y
        iny
        cpy #40
        bne LF2
        inx
        cpx #20
        bne LF1
        rts

; 4: hi-res page 1, six bands of 32 lines: violet, green, blue, orange, white, thin lines
SHOWHIRES:
        jsr NORMAL
        lda #0
        sta YLINE
SH1:    ldx YLINE
        lda HLO,x
        sta BAS
        lda HHI,x
        sta BAS+1
        txa
        lsr a
        lsr a
        lsr a
        lsr a
        and #$0E             ; band * 2 (bands of 32 lines)
        tax
        ldy #0
SH2:    lda HBAND,x
        sta (BAS),y
        iny
        lda HBAND+1,x
        sta (BAS),y
        iny
        cpy #40
        bne SH2
        inc YLINE
        lda YLINE
        cmp #192
        bne SH1
        sta TXTCLR
        sta HIRES
        rts

; 5: double hi-res, 20 bars of 4 bytes (aux, main, aux, main) each, colours 0-15 then white
SHOWDHR:
        jsr NORMAL
        sta SET80STORE
        sta HIRES            ; with 80STORE, PAGE2 now picks the bank of $2000-$3FFF
        lda #0
        sta YLINE
SD1:    ldx YLINE
        lda HLO,x
        sta BAS
        lda HHI,x
        sta BAS+1
        lda #0
        sta GRP
        ldy #0
SD2:    lda GRP
        cmp #16
        bcc SD3
        lda #15
SD3:    asl a
        asl a
        tax                  ; DHRTAB + colour * 4
        sta HISCR
        lda DHRTAB,x
        sta (BAS),y
        sta LOWSCR
        lda DHRTAB+1,x
        sta (BAS),y
        iny
        sta HISCR
        lda DHRTAB+2,x
        sta (BAS),y
        sta LOWSCR
        lda DHRTAB+3,x
        sta (BAS),y
        iny
        inc GRP
        cpy #40
        bne SD2
        inc YLINE
        lda YLINE
        cmp #192
        bne SD1
        sta LOWSCR
        sta TXTCLR
        sta SET80VID
        sta DHIRESON
        rts

; 7: double lo-res: the main half as lo-res bars, the auxiliary half the same colours (rotated
; one bit left, as the auxiliary bytes need)
SHOWDLORES:
        jsr NORMAL
        jsr LOFILL           ; main bank, page 1
        sta SET80STORE
        sta HISCR
        ldx #0
DL1:    lda ROWLO,x
        sta BAS
        lda ROWHI,x
        sta BAS+1
        ldy #0
DL2:    sta LOWSCR
        lda (BAS),y
        and #$0F
        asl a
        cmp #$10
        bcc DL3
        ora #1
        and #$0F
DL3:    sta TMP
        asl a
        asl a
        asl a
        asl a
        ora TMP
        sta HISCR
        sta (BAS),y
        iny
        cpy #40
        bne DL2
        inx
        cpx #20
        bne DL1
        sta LOWSCR
        sta TXTCLR
        sta MIXSET
        sta SET80VID
        sta DHIRESON
        rts

; B: about 1 kHz for a tenth of a second (200 clicks, 510 cycles apart)
BEEP:   ldx #200
BP1:    sta SPKR
        ldy #100
BP2:    dey
        bne BP2
        dex
        bne BP1
        rts

IRQ:    rti

; ---------------------------------------------------------------- the disk (drive 1, the IWM as a Disk II)
; Our own sector reader, not Apple's: seek by stepping the phases one half track at a time, find the
; address field of the wanted physical sector, read and decode its 6-and-2 data field.
DPH0   = $C0E0        ; phase 0 off; phase n on is DPH0 + 2n + 1
DMOTOFF = $C0E8
DMOTON = $C0E9
DSEL1  = $C0EA
DQ6L   = $C0EC
DQ7L   = $C0EE
CURHT  = $10          ; the head, in half tracks
WTRK   = $11          ; wanted track
WSEC   = $12          ; wanted physical sector
DEST   = $13          ; and $14: where the 256 bytes go
SUM    = $15
TRIES  = $16
FTRK   = $17
FSEC   = $18
T44    = $19
CAND   = $1A          ; a candidate disk byte
ZPAIR  = $1B          ; its pairs of neighbouring zeros
UNTAB  = $0300        ; disk byte -> 6-bit value (built at run time)
TWOS   = $0280        ; the 86 low-bit values

DISKON: lda DSEL1
        lda DMOTON
        lda DQ7L
        lda DQ6L
        ; the 6-and-2 disk bytes from their rule - the high bit set, two neighbouring ones below it, at
        ; most one pair of neighbouring zeros, not $AA or $D5 - numbered in order: disk byte -> 6 bits
        ldx #0
        lda #$80
        sta CAND
DO1:    lda CAND
        cmp #$AA
        beq DO3
        cmp #$D5
        beq DO3
        lsr a
        and CAND
        and #$3F
        beq DO3              ; no two neighbouring ones
        lda CAND
        eor #$FF
        sta ZPAIR
        lsr a
        and ZPAIR
        and #$3F
        beq DO2              ; no pair of zeros
        sta ZPAIR
        dec a
        and ZPAIR
        bne DO3              ; more than one pair
DO2:    txa
        ldy CAND
        sta UNTAB,y
        inx
DO3:    inc CAND
        bne DO1
        ; recalibrate: from 80 half tracks down to 0
        lda #80
        sta CURHT
        lda #0
        sta WTRK
        jmp SEEK

; SEEK: move the head to track WTRK.
SEEK:   lda WTRK
        asl a
        cmp CURHT
        beq SKDONE
        bcs SKUP
        dec CURHT
        bra SKSTEP
SKUP:   inc CURHT
SKSTEP: lda CURHT
        and #3
        asl a
        tax
        lda DPH0+1,x         ; this phase on
        ldy #40
SKW:    dey
        bne SKW
        lda DPH0,x           ; and off again: the head stays
        bra SEEK
SKDONE: rts

RDN:    lda DQ6L
        bpl RDN
        rts
RD44:   jsr RDN
        sec
        rol a
        sta T44
        jsr RDN
        and T44
        rts

; READSEC: physical sector WSEC of track WTRK into (DEST). Carry clear = read, set = failed.
READSEC: jsr SEEK
        lda #48
        sta TRIES
RS1:    dec TRIES
        bne RS2
        jmp RSBAD
RS2:    jsr RDN
        cmp #$D5
        bne RS2
        jsr RDN
        cmp #$AA
        bne RS1
        jsr RDN
        cmp #$96
        bne RS1
        jsr RD44             ; volume
        jsr RD44
        sta FTRK
        jsr RD44
        sta FSEC
        jsr RD44             ; checksum
        lda FSEC
        cmp WSEC
        bne RS1
        lda FTRK
        cmp WTRK
        beq RSTOK
        jmp RSBAD
RSTOK:  ldx #32
RS3:    dex
        beq RS1
        jsr RDN
        cmp #$D5
        bne RS3
        jsr RDN
        cmp #$AA
        bne RS1
        jsr RDN
        cmp #$AD
        bne RS1
        ; 86 low-bit values (written last first), then 256 high six bits, then the checksum
        lda #0
        sta SUM
        ldy #85
RS4:    jsr RDN
        tax
        lda UNTAB,x
        eor SUM
        sta SUM
        sta TWOS,y
        dey
        bpl RS4
        ldy #0
RS5:    jsr RDN
        tax
        lda UNTAB,x
        eor SUM
        sta SUM
        asl a
        asl a
        sta (DEST),y
        iny
        bne RS5
        jsr RDN
        tax
        lda UNTAB,x
        cmp SUM
        bne RSBAD
        ; the two low bits of byte i are in TWOS(85 - i mod 86), two bits further up each 86 bytes
        ldy #0
        ldx #85
RS6:    lda TWOS,x
        and #3
        phx
        tax
        lda SWAP2,x
        plx
        ora (DEST),y
        sta (DEST),y
        lsr TWOS,x
        lsr TWOS,x
        iny
        beq RSOK
        dex
        bpl RS6
        ldx #85
        bra RS6
RSOK:   clc
        rts
RSBAD:  sec
        rts

; BOOT: physical sector 0 of track 0 to $0800 and on at $0801, as a IIc does it (with our own reader).
BOOT:   lda #13
        sta ROW
        lda #0
        sta COL
        lda #<T_BOOT
        ldx #>T_BOOT
        jsr PRINT
        jsr DISKON
        lda #0
        sta WTRK
        sta WSEC
        sta DEST
        lda #8
        sta DEST+1
        jsr READSEC
        bcs BOOTBAD
        ldx #$60
        jmp $0801
BOOTBAD: lda DMOTOFF
        lda #<T_NOBOOT
        ldx #>T_NOBOOT
        jsr PRINT
        jmp LOOP

SWAP2:  .byte 0, 2, 1, 3
T_BOOT: .text "BOOTING DRIVE 1... "
        .byte 0
T_NOBOOT: .text "NO DISK"
        .byte 0

HEXCH:  .text "0123456789ABCDEF"
TITLE:  .text "PUREMETAL APPLE IIC  -  TEST ROM"
        .byte 0
T_RAM:  .text "RAMRD/RAMWRT MAIN+AUX RAM "
        .byte 0
T_ZP:   .text "ALTZP ZERO PAGE AND STACK "
        .byte 0
T_LC:   .text "LANGUAGE CARD BANKS 1+2   "
        .byte 0
T_80:   .text "80STORE WITH PAGE2        "
        .byte 0
T_CPU:  .text "65C02 INSTRUCTIONS        "
        .byte 0
T_PASS: .text "PASS"
        .byte 0
T_FAIL: .text "FAIL"
        .byte 0
T_ALLOK: .text "SOFT SWITCH TESTS: ALL PASS"
        .byte 0
T_ALLBAD: .text "SOFT SWITCH TESTS: FAILED"
        .byte 0
T_MENU1: .text "1 TEXT+CHARS 2 80COL 3 LORES 4 HIRES"
        .byte 0
T_MENU2: .text "5 DHIRES 6 MIXED 7 DLORES A ALTCHAR"
        .byte 0
T_MENU3: .text "B BEEP  D BOOT DRIVE 1  OTHER: TEXT"
        .byte 0
T_KEY:  .text "KEY "
        .byte 0
'''

def main():
    src = SRC + '\n' + tables + '\nTABLES_END:\n' + JUMPS + '\n        .org $D000\nROMD000: .byte $5A\n        .org $FFFA\n        .word IRQ, RESET, IRQ\n'
    (ROOT / 'build').mkdir(exist_ok=True)
    (ROOT / 'build/testrom.s').write_text(src)
    lo, blob, labels, listing = assemble(src)
    assert lo == 0xC000, hex(lo)
    assert labels['TABLES_END'] <= 0xCF00, 'the code and tables no longer fit below the jump table at $CF00'
    blob = blob + b'\xff' * (0x4000 - len(blob))
    assert len(blob) == 0x4000
    (ROOT / 'build/testrom.lst').write_text(listing + '\n')
    (ROOT / 'build/testrom.bin').write_bytes(blob)
    lines = ['; Generated by tools/make_testrom.py: this project\'s own test ROM ($C000-$FFFF), no Apple code.',
             'DataSection', 'A2TestRom:']
    for s in range(0, len(blob), 32):
        lines.append('  Data.a ' + ','.join(f'${b:02X}' for b in blob[s:s + 32]))
    lines.append('EndDataSection')
    (ROOT / 'src/testrom.pmi').write_text('\n'.join(lines) + '\n')
    used = max(a for a in range(len(blob)) if blob[a] != 0xFF and a < 0x3FF0) + 0xC000
    print(f'test ROM: code to ${used:04X}, RESET ${labels["RESET"]:04X}')

if __name__ == '__main__':
    main()
