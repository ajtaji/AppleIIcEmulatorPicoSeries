"""Fetch the public test inputs the 65C02 checks are built from (not firmware dependencies):

  SingleStepTests/65x02, rockwell65c02/v1 (MIT): the first 128 KB of each opcode's file (whole tests
      in that part, about 340 per opcode), pinned to commit SINGLESTEP, into --out (default
      build/ss);
  Klaus2m5/6502_65C02_functional_tests (GPLv3): the 65C02 extended opcodes test and the 6502
      functional test, as assembled in the repository's bin_files, pinned to commit KLAUS, into
      Diagnostics/ with the 65C02 test's source and the licence in Diagnostics/upstream/.

    py -3 tools/fetch_tests.py
Then tools/make_vectors.py and tools/embed_tests.py.
"""
import argparse
import hashlib
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
KLAUS = '7954e2dbb49c469ea286070bf46cdd71aeb29e4b'
SINGLESTEP = '2f6980a2d95757486c7bee24355c360e40e2a224'

def get(url, first=None):
    req = Request(url)
    if first:
        req.add_header('Range', f'bytes=0-{first - 1}')
    with urlopen(req, timeout=60) as r:
        return r.read()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', default=str(ROOT / 'build' / 'ss'))
    a = p.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for op in range(256):
        url = f'https://raw.githubusercontent.com/SingleStepTests/65x02/{SINGLESTEP}/rockwell65c02/v1/{op:02x}.json'
        (out / f'{op:02x}.part').write_bytes(get(url, 131072))
    up = ROOT / 'Diagnostics/upstream'
    up.mkdir(parents=True, exist_ok=True)
    (up / 'singlestep-LICENSE').write_bytes(get(f'https://raw.githubusercontent.com/SingleStepTests/65x02/{SINGLESTEP}/LICENSE'))
    base = f'https://raw.githubusercontent.com/Klaus2m5/6502_65C02_functional_tests/{KLAUS}/'
    for src, dst in (('bin_files/65C02_extended_opcodes_test.bin', ROOT / 'Diagnostics/65C02_extended_opcodes_test.bin'),
                     ('bin_files/6502_functional_test.bin', ROOT / 'Diagnostics/6502_functional_test.bin'),
                     ('65C02_extended_opcodes_test.a65c', up / '65C02_extended_opcodes_test.a65c'),
                     ('license.txt', up / 'klaus-LICENSE.txt')):
        data = get(base + src)
        dst.write_bytes(data)
        print(dst.name, len(data), hashlib.sha256(data).hexdigest())

if __name__ == '__main__':
    main()
