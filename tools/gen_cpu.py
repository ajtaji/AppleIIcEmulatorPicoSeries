"""Generate the 65C02 core twice from one description:

  src/cpu65c02.pmi      PureMetal, both Picos (RP2040 / RP2350), computed-goto dispatch
  desktop/cpu65c02.pbi  PureBasic (C back end), the same handlers, a C computed goto

The CPU is the Rockwell R65C02 as SingleStepTests' rockwell65c02 set records it: the 65C02's
new instructions and addressing modes, BBR/BBS/RMB/SMB, every undefined opcode a NOP of the
silicon's length and time, $CB a two-cycle NOP and $DB a two-byte four-cycle NOP (no WAI, no
STP). Decimal mode as the CMOS parts do it: N and Z from the decimal result, one cycle more.

Memory is reached through 256-byte page tables, the way the 6809 core of this family does it:
CpuRdMap(page) / CpuWrMap(page) hold a host address minus page*256 (so the byte at `a` is at
CpuRdMap(a >> 8) + a), 0 sends the access to the machine's CpuBusRead / CpuBusWrite. The tables
have 512 entries so an address up to $1FFFF (an index past $FFFF) needs no mask: entry p+256 is
entry p minus 65536. Zero page and the stack are always memory: they are read through CpuZp, the
host address of page 0 (page 1 follows it), which the machine sets with the tables.

Edit this file, then:  py -3 tools/gen_cpu.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# ---------------------------------------------------------------- the opcode table
# (mnemonic, mode, cycles). Cycles are the base count; the rules below add the rest:
#   reads with abx/aby/iny crossing a page +1; ASL/LSR/ROL/ROR abx crossing +1;
#   a taken branch +1, crossing a page +1 more; BBR/BBS the same; ADC/SBC in decimal +1.
T = {}
def op(code, name, mode, cyc):
    T[code] = (name, mode, cyc)

rows = {
 'ORA': (0x00,), 'AND': (0x20,), 'EOR': (0x40,), 'ADC': (0x60,), 'STA': (0x80,), 'LDA': (0xA0,),
 'CMP': (0xC0,), 'SBC': (0xE0,)}
for name, (base,) in rows.items():
    op(base + 0x01, name, 'inx', 6)
    op(base + 0x05, name, 'zp', 3)
    op(base + 0x0D, name, 'abs', 4)
    op(base + 0x11, name, 'iny', 6 if name == 'STA' else 5)
    op(base + 0x12, name, 'izp', 5)
    op(base + 0x15, name, 'zpx', 4)
    op(base + 0x19, name, 'aby', 5 if name == 'STA' else 4)
    op(base + 0x1D, name, 'abx', 5 if name == 'STA' else 4)
    if name != 'STA':
        op(base + 0x09, name, 'imm', 2)
for name, base in (('ASL', 0x00), ('ROL', 0x20), ('LSR', 0x40), ('ROR', 0x60)):
    op(base + 0x06, name, 'zp', 5); op(base + 0x0A, name, 'acc', 2); op(base + 0x0E, name, 'abs', 6)
    op(base + 0x16, name, 'zpx', 6); op(base + 0x1E, name, 'abx', 6)
for name, base in (('DEC', 0xC0), ('INC', 0xE0)):
    op(base + 0x06, name, 'zp', 5); op(base + 0x0E, name, 'abs', 6)
    op(base + 0x16, name, 'zpx', 6); op(base + 0x1E, name, 'abx', 7)
op(0x1A, 'INC', 'acc', 2); op(0x3A, 'DEC', 'acc', 2)
op(0xA0, 'LDY', 'imm', 2); op(0xA4, 'LDY', 'zp', 3); op(0xAC, 'LDY', 'abs', 4)
op(0xB4, 'LDY', 'zpx', 4); op(0xBC, 'LDY', 'abx', 4)
op(0xA2, 'LDX', 'imm', 2); op(0xA6, 'LDX', 'zp', 3); op(0xAE, 'LDX', 'abs', 4)
op(0xB6, 'LDX', 'zpy', 4); op(0xBE, 'LDX', 'aby', 4)
op(0x84, 'STY', 'zp', 3); op(0x8C, 'STY', 'abs', 4); op(0x94, 'STY', 'zpx', 4)
op(0x86, 'STX', 'zp', 3); op(0x8E, 'STX', 'abs', 4); op(0x96, 'STX', 'zpy', 4)
op(0x64, 'STZ', 'zp', 3); op(0x74, 'STZ', 'zpx', 4); op(0x9C, 'STZ', 'abs', 4); op(0x9E, 'STZ', 'abx', 5)
op(0xC0, 'CPY', 'imm', 2); op(0xC4, 'CPY', 'zp', 3); op(0xCC, 'CPY', 'abs', 4)
op(0xE0, 'CPX', 'imm', 2); op(0xE4, 'CPX', 'zp', 3); op(0xEC, 'CPX', 'abs', 4)
op(0x24, 'BIT', 'zp', 3); op(0x2C, 'BIT', 'abs', 4); op(0x34, 'BIT', 'zpx', 4)
op(0x3C, 'BIT', 'abx', 4); op(0x89, 'BITI', 'imm', 2)
op(0x04, 'TSB', 'zp', 5); op(0x0C, 'TSB', 'abs', 6); op(0x14, 'TRB', 'zp', 5); op(0x1C, 'TRB', 'abs', 6)
for code, name in ((0x10, 'BPL'), (0x30, 'BMI'), (0x50, 'BVC'), (0x70, 'BVS'), (0x90, 'BCC'),
                   (0xB0, 'BCS'), (0xD0, 'BNE'), (0xF0, 'BEQ'), (0x80, 'BRA')):
    op(code, name, 'rel', 2)
for b in range(8):
    op(0x07 + b * 16, f'RMB{b}', 'zp', 5)
    op(0x87 + b * 16, f'SMB{b}', 'zp', 5)
    op(0x0F + b * 16, f'BBR{b}', 'zpr', 5)
    op(0x8F + b * 16, f'BBS{b}', 'zpr', 5)
for code, name in ((0x00, 'BRK'), (0x08, 'PHP'), (0x28, 'PLP'), (0x40, 'RTI'), (0x48, 'PHA'),
                   (0x68, 'PLA'), (0x60, 'RTS'), (0x5A, 'PHY'), (0x7A, 'PLY'), (0xDA, 'PHX'),
                   (0xFA, 'PLX'), (0x18, 'CLC'), (0x38, 'SEC'), (0x58, 'CLI'), (0x78, 'SEI'),
                   (0xB8, 'CLV'), (0xD8, 'CLD'), (0xF8, 'SED'), (0x88, 'DEY'), (0xC8, 'INY'),
                   (0xCA, 'DEX'), (0xE8, 'INX'), (0x8A, 'TXA'), (0x98, 'TYA'), (0xAA, 'TAX'),
                   (0xA8, 'TAY'), (0x9A, 'TXS'), (0xBA, 'TSX'), (0xEA, 'NOP')):
    cyc = {'BRK': 7, 'PHP': 3, 'PHA': 3, 'PHX': 3, 'PHY': 3, 'PLP': 4, 'PLA': 4, 'PLX': 4,
           'PLY': 4, 'RTI': 6, 'RTS': 6}.get(name, 2)
    op(code, name, 'imp', cyc)
op(0x20, 'JSR', 'abs', 6); op(0x4C, 'JMP', 'abs', 3); op(0x6C, 'JMP', 'ind', 6); op(0x7C, 'JMP', 'iax', 6)
# the undefined opcodes: NOPs of the silicon's size and time (bytes, cycles)
for code in (0x02, 0x22, 0x42, 0x62, 0x82, 0xC2, 0xE2):
    op(code, 'NOP', 'n2', 2)
op(0x44, 'NOP', 'n2', 3)
for code in (0x54, 0xD4, 0xF4):
    op(code, 'NOP', 'n2', 4)
op(0xDB, 'NOP', 'n2', 4)
for code in (0x5C, 0xDC, 0xFC):
    op(code, 'NOP', 'n3', 4)
op(0xCB, 'NOP', 'imp', 2)
for code in range(256):
    if code not in T and (code & 15) in (3, 11):
        op(code, 'NOP', 'imp', 1)
assert len(T) == 256, sorted(set(range(256)) - set(T))

READS = {'ORA', 'AND', 'EOR', 'ADC', 'SBC', 'CMP', 'LDA', 'LDX', 'LDY', 'BIT'}
SHIFTS = {'ASL', 'LSR', 'ROL', 'ROR'}

# ---------------------------------------------------------------- the handlers
out = []
def e(s):
    out.extend(s.strip('\n').splitlines())

def fetch_ea_abs():
    e('  RdB(CpuEa, CpuPC)\n  RdB(CpuTmp, CpuPC + 1)\n  CpuEa = CpuEa | (CpuTmp << 8)\n  CpuPC = (CpuPC + 2) & $FFFF')

def address(mode, cross):
    """Leave the operand's address in CpuEa. Zero-page modes leave 0-255 (read through CpuZp)."""
    if mode == 'zp':
        e('  RdB(CpuEa, CpuPC)\n  CpuPC = (CpuPC + 1) & $FFFF')
    elif mode in ('zpx', 'zpy'):
        r = 'CpuX' if mode == 'zpx' else 'CpuY'
        e(f'  RdB(CpuEa, CpuPC)\n  CpuPC = (CpuPC + 1) & $FFFF\n  CpuEa = (CpuEa + {r}) & 255')
    elif mode == 'abs':
        fetch_ea_abs()
    elif mode in ('abx', 'aby'):
        r = 'CpuX' if mode == 'abx' else 'CpuY'
        fetch_ea_abs()
        if cross:
            e(f'  If ((CpuEa & 255) + {r}) & $100\n    CpuLeft = CpuLeft - 1\n  EndIf')
        e(f'  CpuEa = CpuEa + {r}')
    elif mode == 'inx':
        e('  RdB(CpuTmp, CpuPC)\n  CpuPC = (CpuPC + 1) & $FFFF\n  CpuTmp = (CpuTmp + CpuX) & 255')
        e('  CpuEa = PeekA(CpuZp + CpuTmp) | (PeekA(CpuZp + ((CpuTmp + 1) & 255)) << 8)')
    elif mode in ('iny', 'izp'):
        e('  RdB(CpuTmp, CpuPC)\n  CpuPC = (CpuPC + 1) & $FFFF')
        e('  CpuEa = PeekA(CpuZp + CpuTmp) | (PeekA(CpuZp + ((CpuTmp + 1) & 255)) << 8)')
        if mode == 'iny':
            if cross:
                e('  If ((CpuEa & 255) + CpuY) & $100\n    CpuLeft = CpuLeft - 1\n  EndIf')
            e('  CpuEa = CpuEa + CpuY')
    else:
        raise ValueError(mode)

ZP = ('zp', 'zpx', 'zpy')

def load(dst, mode):
    """dst = the operand."""
    if mode == 'imm':
        e(f'  RdB({dst}, CpuPC)\n  CpuPC = (CpuPC + 1) & $FFFF')
    elif mode in ZP:
        e(f'  {dst} = PeekA(CpuZp + CpuEa)')
    else:
        e(f'  RdB({dst}, CpuEa)')

def store(mode, val):
    if mode in ZP:
        e(f'  PokeA(CpuZp + CpuEa, {val})')
    else:
        e(f'  WrB(CpuEa, {val})')

ADC = '''  CpuTmp = (CpuFC >> 8) & 1
  If CpuFD
    CpuLeft = CpuLeft - 1
    CpuLo = (CpuA & 15) + (CpuVal & 15) + CpuTmp
    If CpuLo > 9
      CpuLo = ((CpuLo + 6) & 15) + 16
    EndIf
    CpuRes = (CpuA & $F0) + (CpuVal & $F0) + CpuLo
    CpuFV = (~(CpuA ! CpuVal)) & (CpuA ! CpuRes)
    If CpuRes > $9F
      CpuRes = CpuRes + $60
    EndIf
    ; invalid BCD can take the adjusted sum past $1FF: the carry is "above 255", not bit 8
    If CpuRes > 255
      CpuFC = $100
    Else
      CpuFC = 0
    EndIf
    CpuA = CpuRes & 255
  Else
    CpuRes = CpuA + CpuVal + CpuTmp
    CpuFV = (~(CpuA ! CpuVal)) & (CpuA ! CpuRes)
    CpuFC = CpuRes
    CpuA = CpuRes & 255
  EndIf
  CpuFN = CpuA
  CpuFZ = CpuA'''
SBC = '''  CpuTmp = ((CpuFC >> 8) & 1) ! 1
  CpuRes = CpuA - CpuVal - CpuTmp
  CpuFV = (CpuA ! CpuVal) & (CpuA ! CpuRes)
  CpuFC = ~CpuRes
  If CpuFD
    CpuLeft = CpuLeft - 1
    CpuLo = (CpuA & 15) - (CpuVal & 15) - CpuTmp
    If CpuRes < 0
      CpuRes = CpuRes - $60
    EndIf
    If CpuLo < 0
      CpuRes = CpuRes - 6
    EndIf
  EndIf
  CpuA = CpuRes & 255
  CpuFN = CpuA
  CpuFZ = CpuA'''

BRANCH = {'BPL': '(CpuFN & $80) = 0', 'BMI': '(CpuFN & $80) <> 0', 'BVC': '(CpuFV & $80) = 0',
          'BVS': '(CpuFV & $80) <> 0', 'BCC': '(CpuFC & $100) = 0', 'BCS': '(CpuFC & $100) <> 0',
          'BNE': '(CpuFZ & 255) <> 0', 'BEQ': '(CpuFZ & 255) = 0'}
TAKE = '''    CpuTmp = (CpuPC + 1) & $FFFF
    CpuPC = (CpuTmp + CpuRes) & $FFFF
    If (CpuTmp ! CpuPC) & $FF00
      CpuLeft = CpuLeft - 2
    Else
      CpuLeft = CpuLeft - 1
    EndIf'''

def handler(code, name, mode, cyc):
    e(f'Op{code:02X}: ; ${code:02X} {name} {mode}')
    if name in READS or name == 'BITI':
        if mode != 'imm':
            address(mode, True)
        if name in ('LDA', 'LDX', 'LDY'):
            r = 'Cpu' + name[2]
            load(r, mode)
            e(f'  CpuFN = {r}\n  CpuFZ = {r}')
        elif name in ('ORA', 'AND', 'EOR'):
            load('CpuVal', mode)
            o = {'ORA': '|', 'AND': '&', 'EOR': '!'}[name]
            e(f'  CpuA = CpuA {o} CpuVal\n  CpuFN = CpuA\n  CpuFZ = CpuA')
        elif name in ('CMP', 'CPX', 'CPY'):
            pass
        elif name == 'ADC':
            load('CpuVal', mode); e(ADC)
        elif name == 'SBC':
            load('CpuVal', mode); e(SBC)
        elif name == 'BIT':
            load('CpuVal', mode)
            e('  CpuFN = CpuVal\n  CpuFV = CpuVal << 1\n  CpuFZ = CpuA & CpuVal')
        elif name == 'BITI':
            load('CpuVal', mode)
            e('  CpuFZ = CpuA & CpuVal')
    elif name in ('CPX', 'CPY'):
        pass
    if name in ('CMP', 'CPX', 'CPY'):
        if mode != 'imm' and name != 'CMP':
            address(mode, True)
        r = {'CMP': 'CpuA', 'CPX': 'CpuX', 'CPY': 'CpuY'}[name]
        load('CpuVal', mode)
        e(f'  CpuRes = {r} - CpuVal\n  CpuFN = CpuRes\n  CpuFZ = CpuRes & 255\n  CpuFC = ~CpuRes')
    elif name in READS or name == 'BITI':
        pass
    elif name in ('STA', 'STX', 'STY', 'STZ'):
        address(mode, False)
        store(mode, {'STA': 'CpuA', 'STX': 'CpuX', 'STY': 'CpuY', 'STZ': '0'}[name])
    elif name in SHIFTS or name in ('INC', 'DEC'):
        if mode == 'acc':
            e('  CpuVal = CpuA')
        else:
            address(mode, name in SHIFTS)
            load('CpuVal', mode)
        e({'ASL': '  CpuRes = CpuVal << 1\n  CpuFC = CpuRes',
           'LSR': '  CpuRes = CpuVal >> 1\n  CpuFC = CpuVal << 8',
           'ROL': '  CpuRes = (CpuVal << 1) | ((CpuFC >> 8) & 1)\n  CpuFC = CpuRes',
           'ROR': '  CpuRes = (CpuVal >> 1) | ((CpuFC >> 1) & $80)\n  CpuFC = CpuVal << 8',
           'INC': '  CpuRes = CpuVal + 1', 'DEC': '  CpuRes = CpuVal - 1'}[name])
        e('  CpuRes = CpuRes & 255\n  CpuFN = CpuRes\n  CpuFZ = CpuRes')
        if mode == 'acc':
            e('  CpuA = CpuRes')
        else:
            store(mode, 'CpuRes')
    elif name in ('TSB', 'TRB'):
        address(mode, False)
        load('CpuVal', mode)
        e('  CpuFZ = CpuA & CpuVal')
        store(mode, '(CpuVal | CpuA)' if name == 'TSB' else '(CpuVal & (~CpuA) & 255)')
    elif name[:3] in ('RMB', 'SMB'):
        bit = 1 << int(name[3])
        address('zp', False)
        e('  CpuVal = PeekA(CpuZp + CpuEa)')
        if name.startswith('RMB'):
            e(f'  PokeA(CpuZp + CpuEa, CpuVal & ${255 ^ bit:02X})')
        else:
            e(f'  PokeA(CpuZp + CpuEa, CpuVal | ${bit:02X})')
    elif name[:3] in ('BBR', 'BBS'):
        bit = 1 << int(name[3])
        e('  RdB(CpuEa, CpuPC)\n  CpuVal = PeekA(CpuZp + CpuEa)\n  RdSB(CpuRes, CpuPC + 1)\n  CpuPC = (CpuPC + 1) & $FFFF')
        cond = f'(CpuVal & ${bit:02X}) = 0' if name.startswith('BBR') else f'(CpuVal & ${bit:02X}) <> 0'
        e(f'  If {cond}\n{TAKE}\n  Else\n    CpuPC = (CpuPC + 1) & $FFFF\n  EndIf')
    elif mode == 'rel':
        e('  RdSB(CpuRes, CpuPC)')
        if name == 'BRA':
            e(TAKE.replace('\n    ', '\n  ').replace('    CpuTmp', '  CpuTmp', 1))
        else:
            e(f'  If {BRANCH[name]}\n{TAKE}\n  Else\n    CpuPC = (CpuPC + 1) & $FFFF\n  EndIf')
    elif name == 'JMP':
        fetch_ea_abs()
        if mode == 'abs':
            e('  CpuPC = CpuEa')
        else:
            if mode == 'iax':
                e('  CpuEa = (CpuEa + CpuX) & $FFFF')
            e('  RdB(CpuTmp, CpuEa)\n  RdB(CpuVal, CpuEa + 1)\n  CpuPC = CpuTmp | (CpuVal << 8)')
    elif name == 'JSR':
        e('  RdB(CpuTmp, CpuPC)\n  CpuPC = (CpuPC + 1) & $FFFF')
        e('  CpuPush(CpuPC >> 8)\n  CpuPush(CpuPC & 255)')
        e('  RdB(CpuVal, CpuPC)\n  CpuPC = CpuTmp | (CpuVal << 8)')
    elif name == 'RTS':
        e('  CpuPop(CpuTmp)\n  CpuPop(CpuVal)\n  CpuPC = ((CpuTmp | (CpuVal << 8)) + 1) & $FFFF')
    elif name == 'RTI':
        e('  CpuPop(CpuTmp)\n  CpuSetStatus(CpuTmp)\n  CpuPop(CpuTmp)\n  CpuPop(CpuVal)\n  CpuPC = CpuTmp | (CpuVal << 8)')
    elif name == 'BRK':
        e('  CpuPC = (CpuPC + 1) & $FFFF\n  CpuPush(CpuPC >> 8)\n  CpuPush(CpuPC & 255)')
        e('  CpuTmp = CpuStatus() | $10\n  CpuPush(CpuTmp)\n  CpuFI = 1\n  CpuFD = 0')
        e('  RdB(CpuTmp, $FFFE)\n  RdB(CpuVal, $FFFF)\n  CpuPC = CpuTmp | (CpuVal << 8)')
    elif name == 'PHP':
        e('  CpuTmp = CpuStatus() | $10\n  CpuPush(CpuTmp)')
    elif name == 'PLP':
        e('  CpuPop(CpuTmp)\n  CpuSetStatus(CpuTmp)')
    elif name in ('PHA', 'PHX', 'PHY'):
        e(f'  CpuPush(Cpu{name[2]})')
    elif name in ('PLA', 'PLX', 'PLY'):
        r = 'Cpu' + name[2]
        e(f'  CpuPop({r})\n  CpuFN = {r}\n  CpuFZ = {r}')
    elif name in ('TAX', 'TAY', 'TXA', 'TYA', 'TSX', 'TXS'):
        s, d = 'Cpu' + name[1], 'Cpu' + name[2]
        e(f'  {d} = {s}')
        if name != 'TXS':
            e(f'  CpuFN = {d}\n  CpuFZ = {d}')
    elif name in ('INX', 'INY', 'DEX', 'DEY'):
        r = 'Cpu' + name[2]
        s = '+' if name.startswith('IN') else '-'
        e(f'  {r} = ({r} {s} 1) & 255\n  CpuFN = {r}\n  CpuFZ = {r}')
    elif name in ('CLC', 'SEC', 'CLV', 'CLD', 'SED', 'CLI', 'SEI'):
        e('  ' + {'CLC': 'CpuFC = 0', 'SEC': 'CpuFC = $100', 'CLV': 'CpuFV = 0', 'CLD': 'CpuFD = 0',
                  'SED': 'CpuFD = 1', 'CLI': 'CpuFI = 0', 'SEI': 'CpuFI = 1'}[name])
    elif name == 'NOP':
        if mode == 'n2':
            e('  CpuPC = (CpuPC + 1) & $FFFF')
        elif mode == 'n3':
            e('  CpuPC = (CpuPC + 2) & $FFFF')
    else:
        raise ValueError((name, mode))
    e(f'  NextOp({cyc})')
    e('')

for code in range(256):
    handler(code, *T[code])
BODY = out

# ---------------------------------------------------------------- the two files around them
HEADER = '''; Generated by tools/gen_cpu.py. Edit the generator, then regenerate.
; Rockwell R65C02 (the 65C02 instructions and modes, BBR/BBS/RMB/SMB, undefined opcodes as the
; silicon's NOPs). Memory through 256-byte page tables: CpuRdMap / CpuWrMap hold a host address
; minus page*256, 0 sends the access to the machine's CpuBusRead / CpuBusWrite. Zero page and
; stack through CpuZp (host address of page 0; page 1 follows). CpuRun's budget is CYCLES; it
; returns the cycles used (whole instructions, so a few more than asked).
'''

COMMON_DECL = '''Global Dim CpuRdMap.i(512)
Global Dim CpuWrMap.i(512)
Global Dim CpuSink.a(256)
Global CpuZp.i
Global CpuPC.i, CpuA.i, CpuX.i, CpuY.i, CpuS.i
Global CpuFN.i, CpuFZ.i, CpuFC.i, CpuFV.i, CpuFD.i, CpuFI.i
Global CpuRes.i, CpuLeft.i, CpuBudget.i, CpuReady.i, CpuInWindow.i
Global CpuEa.i, CpuVal.i, CpuTmp.i, CpuLo.i, CpuPg.i, CpuCycles.i, CpuInitIndex.i
Global CpuIrqLine.i, CpuNmiPending.i
'''

COMMON_PROCS = '''
; ---- the bus ------------------------------------------------------------
; Interrupts are taken between run windows (CpuInterrupts); the machine keeps windows short
; (a scanline). An I/O hook that must end the window at once sets CpuLeft = 0.
Macro RdB(rbDst, rbAdr)
  CpuPg = CpuRdMap((rbAdr) >> 8)
  If CpuPg
    rbDst = PeekA(CpuPg + (rbAdr))
  Else
    rbDst = CpuIoRead(rbAdr)
  EndIf
EndMacro
Macro RdSB(rsDst, rsAdr)
  CpuPg = CpuRdMap((rsAdr) >> 8)
  If CpuPg
    rsDst = PeekB(CpuPg + (rsAdr))
  Else
    rsDst = (CpuIoRead(rsAdr) ! 128) - 128
  EndIf
EndMacro
Macro WrB(wbAdr, wbVal)
  CpuPg = CpuWrMap((wbAdr) >> 8)
  If CpuPg
    PokeA(CpuPg + (wbAdr), wbVal)
  Else
    CpuIoWrite(wbAdr, wbVal)
  EndIf
EndMacro
Macro CpuPush(puV)
  PokeA(CpuZp + 256 + CpuS, puV)
  CpuS = (CpuS - 1) & 255
EndMacro
Macro CpuPop(poV)
  CpuS = (CpuS + 1) & 255
  poV = PeekA(CpuZp + 256 + CpuS)
EndMacro

$RAM$.i CpuIoRead(addr.i)
  ProcedureReturn CpuBusRead(addr & $FFFF) & 255
EndProcedure
$RAM$ CpuIoWrite(addr.i, value.i)
  CpuBusWrite(addr & $FFFF, value & 255)
EndProcedure
Procedure.i CpuRead8(addr.i)
  Protected v.i
  RdB(v, addr & $FFFF)
  ProcedureReturn v
EndProcedure
Procedure CpuWrite8(addr.i, value.i)
  WrB(addr & $FFFF, value & 255)
EndProcedure

; Map `count` pages from `first` onto host memory `host` (writable = 0: writes are discarded),
; or route them to the bus (host = 0). Read and write separately: CpuMapRead / CpuMapWrite.
Procedure CpuMapRead(first.i, count.i, host.i)
  Protected i.i, p.i
  For i = 0 To count - 1
    p = (first + i) & 255
    If host
      CpuRdMap(p) = host + i * 256 - p * 256
      CpuRdMap(p + 256) = CpuRdMap(p) - 65536
    Else
      CpuRdMap(p) = 0 : CpuRdMap(p + 256) = 0
    EndIf
  Next
EndProcedure
Procedure CpuMapWrite(first.i, count.i, host.i)
  Protected i.i, p.i
  For i = 0 To count - 1
    p = (first + i) & 255
    If host
      CpuWrMap(p) = host + i * 256 - p * 256
      CpuWrMap(p + 256) = CpuWrMap(p) - 65536
    Else
      CpuWrMap(p) = 0 : CpuWrMap(p + 256) = 0
    EndIf
  Next
EndProcedure
; Writes to these pages go nowhere (ROM).
Procedure CpuMapSink(first.i, count.i)
  Protected i.i, p.i
  For i = 0 To count - 1
    p = (first + i) & 255
    CpuWrMap(p) = @CpuSink(0) - p * 256
    CpuWrMap(p + 256) = CpuWrMap(p) - 65536
  Next
EndProcedure

; ---- the status register as one byte --------------------------------------
; N is bit 7 of CpuFN; Z means the low byte of CpuFZ is 0; C is bit 8 of CpuFC; V is bit 7 of
; CpuFV; D and I are 0 or 1. Never read the flag variables directly from outside.
Procedure.i CpuStatus()
  Protected p.i
  p = $20 | (CpuFN & $80) | ((CpuFV & $80) >> 1) | (CpuFD << 3) | (CpuFI << 2) | ((CpuFC >> 8) & 1)
  If (CpuFZ & 255) = 0
    p = p | 2
  EndIf
  ProcedureReturn p
EndProcedure
Procedure CpuSetStatus(p.i)
  CpuFN = p & $80
  CpuFV = (p << 1) & $80
  CpuFC = (p & 1) << 8
  CpuFZ = (p & 2) ! 2
  CpuFD = (p >> 3) & 1
  CpuFI = (p >> 2) & 1
EndProcedure

; Reset: I set, D clear, S moved down three (the 65C02 does the pushes as reads), PC from $FFFC.
Procedure CpuReset()
  CpuS = (CpuS - 3) & 255
  CpuFI = 1 : CpuFD = 0
  CpuPC = CpuRead8($FFFC) | (CpuRead8($FFFD) << 8)
  CpuNmiPending = 0
  CpuCycles = CpuCycles + 7
EndProcedure

; Between run windows: take an NMI if one is pending, else an IRQ if the line is low and I is
; clear. 7 cycles; returns them (0 when nothing was taken). The 65C02 clears D.
Procedure.i CpuInterrupts()
  Protected vector.i
  If CpuNmiPending
    CpuNmiPending = 0
    vector = $FFFA
  ElseIf CpuIrqLine And CpuFI = 0
    vector = $FFFE
  Else
    ProcedureReturn 0
  EndIf
  CpuPush(CpuPC >> 8)
  CpuPush(CpuPC & 255)
  CpuPush(CpuStatus() & $EF)
  CpuFI = 1 : CpuFD = 0
  CpuPC = CpuRead8(vector) | (CpuRead8(vector + 1) << 8)
  CpuCycles = CpuCycles + 7
  ProcedureReturn 7
EndProcedure

; Inside CpuBusRead / CpuBusWrite: the cycles the window in progress used before the instruction
; making the access. 0 between windows.
Procedure.i CpuElapsed()
  If CpuInWindow = 0
    ProcedureReturn 0
  EndIf
  ProcedureReturn CpuBudget - CpuLeft
EndProcedure
'''

NEXTOP_PLAIN = """Macro NextOp(c)
  CpuLeft = CpuLeft - (c)
  If CpuLeft <= 0
    Goto Done
  EndIf
  DispatchNext()
EndMacro"""

# The Pico 2 series (RP2350, Cortex-M33): the cycle count and the dispatch in Thumb-2 - the page table
# read with a scaled index, the byte with a register offset, PC wrapped with UXTH, and the handler
# reached by loading pc straight from the dispatch table. The Pico W (Cortex-M0+) keeps Thumb-1.
# The opcode's page (its host address less page * 256) stays in r3 for the handler: its operand is read
# from it while it is on the same page (t2_operand). The slow fetch (an opcode in I/O) leaves r3 = 0.
T2_FETCH = """      lsr.w r1, r8, #8
      ldr r2, =global_cpurdmap
      ldr.w r3, [r2, r1, lsl #2]
      cmp r3, #0
      beq.w __ul_cpurun_slowfetch
      ldrb.w r2, [r3, r8]
      add.w r0, r8, #1
      uxth.w r8, r0
      ldr r1, =global_cpudispatch
      ldr.w pc, [r1, r2, lsl #2]"""

# A macro's parameter is not substituted inside an ASM block (the assembler refuses '#c'), so the
# Pico build writes each handler's Thumb-2 tail inline with its cycle count (t2_tail).
NEXTOP_PICO = NEXTOP_PLAIN

# A handler's first operand read, on the Pico 2 series, from the page the tail left in r3 (the operand
# follows the opcode): one ldrb.w, or for a 16-bit address one unaligned ldrh.w, while the operand is on
# that page (r8's low byte is not 0, and not 255 for two bytes) and r3 is not 0; otherwise the read the
# Pico W makes. Measured on the Pico 2 W against the same handlers without it (README).
T2_TARGETS = {'CpuEa': ('global', ''), 'CpuTmp': ('global', ''), 'CpuVal': ('global', ''),
              'CpuA': ('r9', 'CpuA'), 'CpuX': ('r4', 'CpuX'), 'CpuRes': ('r10', 'CpuRes')}
ABS_FETCH = ['  RdB(CpuEa, CpuPC)', '  RdB(CpuTmp, CpuPC + 1)', '  CpuEa = CpuEa | (CpuTmp << 8)']


def t2_operand(code, lines):
    """The CompilerIf block for a handler whose first lines are `lines` (one read or ABS_FETCH)."""
    slow, done = f't2op_{code:02x}_slow', f't2op_{code:02x}_done'
    if lines == ABS_FETCH:
        uses, load = 'CpuPC', ['      uxtb.w r0, r8', f'      cbz r0, {slow}', '      cmp r0, #255', f'      beq {slow}',
                               '      ldrh.w r0, [r3, r8]', '      ldr r1, =global_cpuea', '      str r0, [r1]']
    else:
        m = re.match(r'^  (RdB|RdSB)\((\w+), CpuPC\)$', lines[0])
        op, dst = m.group(1), m.group(2)
        where, reg = T2_TARGETS[dst]
        ld = 'ldrb.w' if op == 'RdB' else 'ldrsb.w'
        load = ['      tst.w r8, #255', f'      beq {slow}']
        if where == 'global':
            uses = 'CpuPC'
            load += [f'      {ld} r0, [r3, r8]', f'      ldr r1, =global_{dst.lower()}', '      str r0, [r1]']
        else:
            uses = 'CpuPC, ' + reg
            load += [f'      {ld} {where}, [r3, r8]']
    return (['  CompilerIf #CPU_TAIL_T2 = 1', f'    ASM Uses {uses}', f'      cbz r3, {slow}'] + load +
            [f'      b {done}', f'    {slow}:', '    EndASM'] + ['  ' + l for l in lines] +
            ['    ASM', f'    {done}:', '    EndASM', '  CompilerElse'] + ['  ' + l for l in lines] + ['  CompilerEndIf'])


def t2_body(body):
    """The handlers with their first operand read from r3's page (Pico 2 series) and Thumb-2 tails."""
    res, i = [], 0
    while i < len(body):
        line = body[i]
        m = re.match(r'^Op([0-9A-F]{2}):', line)
        if m:
            res.append(line)
            code = int(m.group(1), 16)
            if body[i + 1:i + 4] == ABS_FETCH:
                res += t2_operand(code, ABS_FETCH)
                i += 4
                continue
            r = re.match(r'^  (RdB|RdSB)\((\w+), CpuPC\)$', body[i + 1])
            if r and r.group(2) in T2_TARGETS:
                res += t2_operand(code, [body[i + 1]])
                i += 2
                continue
            i += 1
            continue
        t = re.match(r'^  NextOp\((\d+)\)$', line)
        res.extend(t2_tail(int(t.group(1))) if t else [line])
        i += 1
    return res


def t2_tail(cycles):
    return ['  CompilerIf #CPU_TAIL_T2 = 1', '    ASM Uses CpuLeft, CpuPC',
            f'      subs.w r11, r11, #{cycles}', '      ble.w __ul_cpurun_done'] + \
           T2_FETCH.split(chr(10)) + ['    EndASM', '  CompilerElse', f'    NextOp({cycles})', '  CompilerEndIf']

RUN_HEAD = '''
$RAM$.i CpuRun(n.i)
$DISPATCH$
$NEXTOP$
  If n <= 0
    ProcedureReturn 0
  EndIf
  If CpuReady = 0
'''
RUN_TAIL = '''Done:
  CpuInWindow = 0
  CpuCycles = CpuCycles + CpuBudget - CpuLeft
  ProcedureReturn CpuBudget - CpuLeft
$SLOW$
EndProcedure
'''

def build(kind):
    lines = [HEADER]
    if kind == 'pico':
        lines.append('; #CPU_TAIL_T2: 1 = the Thumb-2 tail (Pico 2 series); else #CPU_ASM_TAIL: 1 = the Thumb-1 tail')
        lines.append('; (Pico W), 0 = PureMetal computed Goto. Define both before including this file.')
        lines.append('EnableExplicit')
    lines.append('Declare.i CpuBusRead(addr.i)')
    lines.append('Declare CpuBusWrite(addr.i, value.i)')
    if kind == 'pico':
        lines.append('Global Dim CpuDispatch.Label(256)')
    else:
        lines.append('Global Dim CpuDispatch.i(256)')
    lines.append(COMMON_DECL.rstrip('\n'))
    if kind == 'pico':
        lines.append('ReserveRegister CpuPC = r8, CpuA = r9, CpuRes = r10, CpuLeft = r11, CpuX = r4, CpuFZ = r5')
    ram = 'ProcedureRAM' if kind == 'pico' else 'Procedure'
    lines.append(COMMON_PROCS.replace('$RAM$', ram))
    if kind == 'pico':
        dispatch = '''Macro DispatchNext()
  CompilerIf #CPU_TAIL_T2 = 1
    ASM Uses CpuPC
''' + T2_FETCH + '''
    EndASM
  CompilerElseIf #CPU_ASM_TAIL = 1
    ASM Uses CpuPC
      mov r0, r8
      lsrs r1, r0, #8
      lsls r1, r1, #2
      ldr r2, =global_cpurdmap
      ldr r1, [r2, r1]
      cmp r1, #0
      beq __ul_cpurun_slowfetch
      ldrb r2, [r1, r0]
      adds r0, #1
      lsls r0, r0, #16
      lsrs r0, r0, #16
      mov r8, r0
      lsls r2, r2, #2
      ldr r1, =global_cpudispatch
      ldr r1, [r1, r2]
      bx r1
    EndASM
  CompilerElse
    RdB(CpuTmp, CpuPC)
    CpuPC = (CpuPC + 1) & $FFFF
    Goto CpuDispatch(CpuTmp)
  CompilerEndIf
EndMacro'''
        slow = '''SlowFetch:
  CpuTmp = CpuIoRead(CpuPC)
  CpuPC = (CpuPC + 1) & $FFFF
  CompilerIf #CPU_TAIL_T2 = 1
    ; r3 = 0: the handler's operand read takes the slow way (there is no page in r3 to read it from)
    ASM
      movs r3, #0
      ldr r1, =global_cputmp
      ldr r2, [r1]
      ldr r1, =global_cpudispatch
      ldr.w pc, [r1, r2, lsl #2]
    EndASM
  CompilerElse
    Goto CpuDispatch(CpuTmp)
  CompilerEndIf'''
    else:
        dispatch = '''Macro DispatchNext()
  RdB(CpuTmp, CpuPC)
  CpuPC = (CpuPC + 1) & $FFFF
  !goto *(void*)((integer*)a_cpudispatch.a)[g_cputmp];
EndMacro'''
        slow = ''
    if kind == 'pico':
        nextop = NEXTOP_PICO
    else:
        nextop = NEXTOP_PLAIN
    head = RUN_HEAD.replace('$RAM$', ram).replace('$DISPATCH$', dispatch).replace('$NEXTOP$', nextop)
    lines.append(head.rstrip('\n'))
    for code in range(256):
        lines.append(f'    CpuDispatch(${code:02X}) = ?Op{code:02X}')
    lines.append('    CpuReady = 1')
    lines.append('  EndIf')
    lines.append('  CpuBudget = n')
    lines.append('  CpuLeft = n')
    lines.append('  CpuInWindow = 1')
    lines.append('  DispatchNext()')
    if kind == 'pico':
        lines.extend(t2_body(BODY))
    else:
        lines.extend(BODY)
    lines.append(RUN_TAIL.replace('$SLOW$', slow).rstrip('\n'))
    return '\n'.join(lines) + '\n'

def build_procs():
    # The same handlers as procedures, called through a table: the dispatch the C computed goto is
    # measured against (desktop/dispatch_bench.pb). Not used by the program.
    nl = chr(10)
    lines = [HEADER, '; THIS VARIANT: every opcode a procedure, called through CpuProc(). For the benchmark only.',
             'Declare.i CpuBusRead(addr.i)', 'Declare CpuBusWrite(addr.i, value.i)',
             'Prototype CpuOpProc()', 'Global Dim CpuProc.i(256)', COMMON_DECL.rstrip(nl),
             COMMON_PROCS.replace('$RAM$', 'Procedure'),
             'Macro NextOp(c)', '  CpuLeft = CpuLeft - (c)', 'EndMacro']
    for blk in nl.join(BODY).split(nl + 'Op'):
        if not blk.strip():
            continue
        blk = blk if blk.startswith('Op') else 'Op' + blk
        name, rest = blk.split(':', 1)
        lines += [f'Procedure {name}()', ';' + rest.rstrip(), 'EndProcedure']
    lines += ['Procedure.i CpuRun(n.i)', '  Protected op.CpuOpProc', '  If n <= 0 : ProcedureReturn 0 : EndIf', '  If CpuReady = 0']
    lines += [f'    CpuProc(${code:02X}) = @Op{code:02X}()' for code in range(256)]
    lines += ['    CpuReady = 1', '  EndIf', '  CpuBudget = n : CpuLeft = n : CpuInWindow = 1',
              '  While CpuLeft > 0', '    RdB(CpuTmp, CpuPC)', '    CpuPC = (CpuPC + 1) & $FFFF',
              '    op = CpuProc(CpuTmp) : op()', '  Wend', '  CpuInWindow = 0',
              '  CpuCycles = CpuCycles + CpuBudget - CpuLeft', '  ProcedureReturn CpuBudget - CpuLeft',
              'EndProcedure']
    return nl.join(lines) + nl

(ROOT / 'src').mkdir(exist_ok=True)
(ROOT / 'desktop').mkdir(exist_ok=True)
(ROOT / 'src/cpu65c02.pmi').write_text(build('pico'), encoding='utf-8')
(ROOT / 'desktop/cpu65c02.pbi').write_text(build('pc'), encoding='utf-8')
(ROOT / 'desktop/cpu65c02_procs.pbi').write_text(build_procs(), encoding='utf-8')

# the opcode metadata for the disassemblers (desktop pane, board monitor)
names = ''.join(f'{T[c][0]:<5}'[:4] for c in range(256))
modes = ['imp', 'acc', 'imm', 'zp', 'zpx', 'zpy', 'abs', 'abx', 'aby', 'inx', 'iny', 'izp', 'ind', 'iax', 'rel', 'zpr', 'n2', 'n3']
(ROOT / 'desktop/opcodes.pbi').write_text(
    '; Generated by tools/gen_cpu.py: mnemonic (4 characters) and addressing mode of every opcode.\n'
    '; Modes: ' + ' '.join(f'{i}={m}' for i, m in enumerate(modes)) + '\n'
    f'#OPC_NAMES$ = "{names}"\n'
    'DataSection\n  OpcModes:\n' +
    ''.join('  Data.a ' + ', '.join(str(modes.index(T[c][1])) for c in range(r, r + 16)) + '\n' for r in range(0, 256, 16)) +
    'EndDataSection\n', encoding='utf-8')
print('generated 256 handlers,', len(BODY), 'body lines')
