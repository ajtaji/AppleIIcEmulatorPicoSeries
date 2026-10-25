"""Single-instruction vectors from SingleStepTests' rockwell65c02 set (MIT), for both checks.

Input: the first 128 KB of each opcode's JSON file (tools/fetch_tests.py puts them in
build/ss; only whole tests in that part are used).
Output: Diagnostics/vectors_full.bin, every test read (the desktop check). The board's share is
written by tools/embed_tests.py.
Record: initial pc(2) a x y s p, final pc(2) a x y s p cycles, n, then n x (addr(2), before, after).
"""
import struct, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from ss_load import load

SRC = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / 'build' / 'ss')
def record(t):
    i, f = t['initial'], t['final']
    b = struct.pack('<H5B', *[i[k] for k in ('pc', 'a', 'x', 'y', 's', 'p')])
    b += struct.pack('<H6B', *[f[k] for k in ('pc', 'a', 'x', 'y', 's', 'p')], len(t['cycles']))
    im, fm = dict(i['ram']), dict(f['ram'])
    addrs = sorted(im.keys() | fm.keys())
    b += bytes([len(addrs)])
    for a in addrs:
        b += struct.pack('<HBB', a, im.get(a, fm.get(a)), fm.get(a, im.get(a)))
    return b
def main():
    full, nf = bytearray(), 0
    for op in range(256):
        for t in load(SRC, op):
            full += record(t); nf += 1
    (ROOT / 'Diagnostics/vectors_full.bin').write_bytes(full)
    print(nf, 'vectors', len(full), 'bytes')

if __name__ == '__main__':
    main()
