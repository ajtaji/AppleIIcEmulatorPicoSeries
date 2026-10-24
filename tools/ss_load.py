"""Read the SingleStepTests rockwell65c02 partial files (the first 128 KB of each
opcode's JSON, fetched by tools/fetch_tests.py) into lists of test dicts. A file
cut mid-test loses only its last, incomplete line."""
import json
from pathlib import Path

def load(folder, op):
    tests = []
    for line in Path(folder, f'{op:02x}.part').read_text().splitlines():
        line = line.strip().rstrip(',')
        if line.startswith('{') and line.endswith('}'):
            try:
                tests.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return tests
