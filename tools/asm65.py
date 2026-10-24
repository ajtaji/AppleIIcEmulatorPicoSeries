"""A small two-pass 65C02 assembler for this project's own test programs (no Apple code).

    py -3 tools/asm65.py source.s output.bin [--listing out.lst]

Syntax: one statement a line; `;` starts a comment. `label:` or `label = expr`. Directives:
`.org addr` (the output starts at the first .org; gaps are filled with $FF), `.byte e,...`,
`.word e,...`, `.text "string"` (high bit set, as the Apple's screen wants), `.ascii "string"`
(as written), `.fill count, value`, `.align n`. Expressions: numbers ($hex, %bin, decimal, 'c'),
labels, `*`, + - * / & | ^ << >>, parentheses, `<e` (low byte), `>e` (high byte).
Operands: `#e`, `e`, `e,X`, `e,Y`, `(e,X)`, `(e),Y`, `(e)`, and `zp,label` for BBR/BBS.
The opcode table is tools/gen_cpu.py's (the one the core is generated from).
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
def opcode_table():
    # gen_cpu.py writes files when run; read its table without running the writer.
    src = (Path(__file__).resolve().parent / 'gen_cpu.py').read_text()
    cut = src.index('# ---------------------------------------------------------------- the handlers')
    ns = {'__file__': str(Path(__file__).resolve().parent / 'gen_cpu.py')}
    exec(src[:cut], ns)
    return ns['T']

T = opcode_table()
ENC = {}
for code, (name, mode, cyc) in T.items():
    if name == 'NOP' and code != 0xEA:
        continue
    if name == 'BITI':
        name = 'BIT'
    ENC[(name, mode)] = code
SIZE = {'imp': 1, 'acc': 1, 'imm': 2, 'zp': 2, 'zpx': 2, 'zpy': 2, 'abs': 3, 'abx': 3, 'aby': 3,
        'inx': 2, 'iny': 2, 'izp': 2, 'ind': 3, 'iax': 3, 'rel': 2, 'zpr': 3}

class AsmError(Exception):
    pass

def tokenize_expr(s):
    return re.findall(r"\$[0-9A-Fa-f]+|%[01]+|\d+|'.'|[A-Za-z_.][A-Za-z0-9_.]*|<<|>>|[-+*/&|^()<>~]|\*", s)

def evaluate(s, labels, pc, strict):
    toks = tokenize_expr(s)
    pos = 0
    def peek():
        return toks[pos] if pos < len(toks) else None
    def take():
        nonlocal pos
        t = toks[pos]; pos += 1; return t
    def atom():
        t = take()
        if t == '(':
            v = expr(); take(); return v
        if t == '-':
            return -atom()
        if t == '~':
            return ~atom()
        if t == '<':
            v = atom(); return None if v is None else v & 255
        if t == '>':
            v = atom(); return None if v is None else (v >> 8) & 255
        if t == '*':
            return pc
        if t[0] == '$':
            return int(t[1:], 16)
        if t[0] == '%':
            return int(t[1:], 2)
        if t[0] == "'":
            return ord(t[1])
        if t.isdigit():
            return int(t)
        if t in labels:
            return labels[t]
        if strict:
            raise AsmError(f'unknown label {t}')
        return None
    PREC = [('|',), ('^',), ('&',), ('<<', '>>'), ('+', '-'), ('*', '/')]
    def level(i):
        if i == len(PREC):
            return atom()
        v = level(i + 1)
        while peek() in PREC[i]:
            o = take(); w = level(i + 1)
            if v is None or w is None:
                v = None; continue
            v = {'|': v | w, '^': v ^ w, '&': v & w, '<<': v << w, '>>': v >> w, '+': v + w,
                 '-': v - w, '*': v * w, '/': v // w}[o]
        return v
    def expr():
        return level(0)
    v = expr()
    if pos != len(toks):
        raise AsmError(f'cannot read expression {s!r}')
    return v

def split_args(s):
    out, depth, cur, q = [], 0, '', False
    for ch in s:
        if ch == '"':
            q = not q
        if ch == ',' and depth == 0 and not q:
            out.append(cur.strip()); cur = ''; continue
        if ch == '(' and not q:
            depth += 1
        if ch == ')' and not q:
            depth -= 1
        cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out

def assemble(text):
    lines = text.splitlines()
    labels, sizes = {}, {}
    for pas in (1, 2):
        pc, start, out, listing = None, None, {}, []
        for no, raw in enumerate(lines, 1):
            line = raw.split(';', 1)[0].rstrip() if '"' not in raw else re.sub(r';(?=(?:[^"]*"[^"]*")*[^"]*$).*', '', raw).rstrip()
            try:
                m = re.match(r'^\s*([A-Za-z_.][A-Za-z0-9_.]*)\s*=\s*(.+)$', line)
                if m:
                    v = evaluate(m.group(2), labels, pc, pas == 2)
                    if v is not None:
                        labels[m.group(1)] = v
                    continue
                m = re.match(r'^\s*([A-Za-z_.][A-Za-z0-9_.]*):(.*)$', line)
                if m:
                    labels[m.group(1)] = pc
                    line = m.group(2)
                line = line.strip()
                if not line:
                    continue
                word, _, rest = line.partition(' ')
                word = word.upper(); rest = rest.strip()
                here = pc
                data = b''
                if word == '.ORG':
                    pc = evaluate(rest, labels, pc, True)
                    if start is None:
                        start = pc
                    continue
                elif word in ('.BYTE', '.WORD'):
                    for a in split_args(rest):
                        v = evaluate(a, labels, pc, pas == 2) or 0
                        data += bytes([v & 255]) if word == '.BYTE' else bytes([v & 255, (v >> 8) & 255])
                elif word in ('.TEXT', '.ASCII'):
                    s = rest.strip()
                    if not (s.startswith('"') and s.endswith('"')):
                        raise AsmError('a string in double quotes')
                    data = bytes((ord(c) | (0x80 if word == '.TEXT' else 0)) for c in s[1:-1])
                elif word == '.FILL':
                    n, v = [evaluate(a, labels, pc, True) for a in split_args(rest)]
                    data = bytes([v & 255]) * n
                elif word == '.ALIGN':
                    n = evaluate(rest, labels, pc, True)
                    data = b'\xff' * ((-pc) % n)
                else:
                    data = instruction(word, rest, labels, pc, pas, sizes, no)
                for i, b in enumerate(data):
                    out[here + i] = b
                listing.append(f'{here:04X}  {data[:8].hex(" "):<24} {raw}')
                pc += len(data)
            except AsmError as e:
                raise AsmError(f'line {no}: {e}: {raw.strip()}')
    lo, hi = min(out), max(out)
    blob = bytearray(b'\xff' * (hi - lo + 1))
    for a, b in out.items():
        blob[a - lo] = b
    return lo, bytes(blob), labels, '\n'.join(listing)

def instruction(name, rest, labels, pc, pas, sizes, no):
    strict = pas == 2
    if name.startswith(('BBR', 'BBS')):
        zp, target = split_args(rest)
        z = evaluate(zp, labels, pc, strict) or 0
        t = evaluate(target, labels, pc, strict)
        off = 0 if t is None else t - (pc + 3)
        if strict and not -128 <= off <= 127:
            raise AsmError('branch out of range')
        return bytes([ENC[(name, 'zpr')], z & 255, off & 255])
    r = rest.upper().replace(' ', '')
    if not rest:
        mode = 'acc' if (name, 'acc') in ENC else 'imp'
        return bytes([ENC[(name, mode)]])
    if r == 'A' and (name, 'acc') in ENC:
        return bytes([ENC[(name, 'acc')]])
    if rest.startswith('#'):
        v = evaluate(rest[1:], labels, pc, strict) or 0
        return bytes([ENC[(name, 'imm')], v & 255])
    if (name, 'rel') in ENC:
        t = evaluate(rest, labels, pc, strict)
        off = 0 if t is None else t - (pc + 2)
        if strict and not -128 <= off <= 127:
            raise AsmError('branch out of range')
        return bytes([ENC[(name, 'rel')], off & 255])
    if r.endswith(',X)'):
        e, modes = rest[1:rest.upper().rindex(',X)')], ('inx', 'iax')
    elif r.endswith('),Y'):
        e, modes = rest[1:rest.upper().rindex('),Y')], ('iny',)
    elif r.startswith('(') and r.endswith(')') and evaluate_is_paren(rest):
        e, modes = rest[1:-1], ('izp', 'ind')
    elif r.endswith(',X'):
        e, modes = rest[:rest.upper().rindex(',X')], ('zpx', 'abx')
    elif r.endswith(',Y'):
        e, modes = rest[:rest.upper().rindex(',Y')], ('zpy', 'aby')
    else:
        e, modes = rest, ('zp', 'abs')
    v = evaluate(e, labels, pc, strict)
    key = (no,)
    if pas == 1:
        small = v is not None and 0 <= v < 256
        choice = [m for m in modes if (name, m) in ENC and (SIZE[m] == 2) == small] or \
                 [m for m in modes if (name, m) in ENC]
        if not choice:
            raise AsmError(f'{name} has no mode for {rest}')
        sizes[key] = choice[0]
    mode = sizes[key]
    v = v or 0
    if SIZE[mode] == 2:
        if strict and not 0 <= v < 256:
            raise AsmError('operand is not on the zero page')
        return bytes([ENC[(name, mode)], v & 255])
    return bytes([ENC[(name, mode)], v & 255, (v >> 8) & 255])

def evaluate_is_paren(s):
    # "(a)+1" is an expression, "(a)" an indirect operand
    depth = 0
    for i, ch in enumerate(s):
        depth += ch == '('
        depth -= ch == ')'
        if depth == 0 and i < len(s) - 1:
            return False
    return True

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    lo, blob, labels, listing = assemble(Path(src).read_text())
    Path(dst).write_bytes(blob)
    if '--listing' in sys.argv:
        Path(sys.argv[sys.argv.index('--listing') + 1]).write_text(listing + '\n')
    print(f'{src}: ${lo:04X}-${lo + len(blob) - 1:04X}, {len(blob)} bytes')
