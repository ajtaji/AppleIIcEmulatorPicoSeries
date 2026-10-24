"""Talk to the Apple IIc firmware on a real board over its USB serial port; never emulates anything.

Reads the board's output for --seconds into --output, and runs an optional --script, one command a line:

    wait <seconds>            let the board run
    type <text>               type text on the Apple keyboard (\\n is ENTER; the line ends without one)
    line <text>               type text, then ENTER
    key <hex>                 send one key byte (1b = ESC, 08 = left arrow, 15 = right arrow)
    cmd <letter>              a monitor command: $1D then the letter (s status, t text, c capture, f full speed)
    expect <seconds> <regex>  wait until the board's output matches, else FAIL
    screen <seconds> <regex>  ask for the text on the screen (cmd t) until it matches, else FAIL
    capture <file.png>        ask for the rendered picture (cmd c) and save it as a PNG (480 x 320)
    # comment

Exit 0 when every expect/screen matched, 1 when one did not, 2 when the port vanished.
"""
import argparse
import re
import struct
import sys
import time
import zlib
from pathlib import Path

import serial

p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument('--port', required=True)
p.add_argument('--seconds', type=float, default=10)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--script', type=Path)
p.add_argument('--key-gap', type=float, default=0.0, help='seconds between typed bytes (the firmware queues them)')
a = p.parse_args()

start = time.monotonic()
out = a.output.open('wb')
text = bytearray()          # everything received
port = None


def note(msg):
    print(f'board: {msg}', flush=True)


def open_port(limit=10):
    global port
    t = time.monotonic()
    while True:
        try:
            port = serial.Serial(a.port, 115200, timeout=0.05)
            return
        except serial.SerialException:
            if time.monotonic() - t > limit:
                note(f'{a.port} did not appear within {limit} s; the board is off USB')
                sys.exit(2)
            time.sleep(0.25)


def pump(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            data = port.read(4096)
        except (serial.SerialException, OSError):
            note('port lost; reopening')
            open_port()
            continue
        if data:
            out.write(data)
            out.flush()
            text.extend(data)


def send(data):
    if a.key_gap > 0:
        for b in data:
            port.write(bytes([b]))
            pump(a.key_gap)
    else:
        port.write(data)


def wait_for(pattern, seconds, since):
    rx = re.compile(pattern.encode())
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if rx.search(bytes(text[since:])):
            return True
        pump(0.1)
    return False


def write_png(path, w, h, rgb565):
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            v = rgb565[(y * w + x) * 2] | (rgb565[(y * w + x) * 2 + 1] << 8)
            r, g, b = (v >> 11) & 31, (v >> 5) & 63, v & 31
            rows += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b'')
    Path(path).write_bytes(png)


def capture(path):
    since = len(text)
    send(b'\x1dc')
    if not wait_for(r'CAP_BEGIN w=480 h=320\r\n', 10, since):
        return False
    m = re.search(rb'CAP_BEGIN w=480 h=320\r\n', bytes(text[since:]))
    body = since + m.end()
    need = 480 * 320 * 2
    end = time.monotonic() + 30
    while len(text) - body < need and time.monotonic() < end:
        pump(0.1)
    if len(text) - body < need:
        return False
    write_png(path, 480, 320, text[body:body + need])
    return True


open_port()
failed = False
if a.script:
    pump(0.5)
    for raw in a.script.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        verb, _, rest = line.partition(' ')
        note(line)
        if verb == 'wait':
            pump(float(rest))
        elif verb in ('type', 'line'):
            data = rest.replace('\\n', '\r').encode('latin-1')
            if verb == 'line':
                data += b'\r'
            send(data)
        elif verb == 'key':
            send(bytes([int(rest, 16)]))
        elif verb == 'cmd':
            send(b'\x1d' + rest.strip()[:1].encode())
        elif verb == 'expect':
            secs, _, pattern = rest.partition(' ')
            if not wait_for(pattern, float(secs), 0):
                note(f'FAIL: no match for {pattern!r} within {secs} s')
                failed = True
                break
        elif verb == 'screen':
            secs, _, pattern = rest.partition(' ')
            end = time.monotonic() + float(secs)
            ok = False
            while time.monotonic() < end and not ok:
                since = len(text)
                send(b'\x1dt')
                if wait_for(r'TEXT_END', 3, since):
                    block = bytes(text[since:])
                    ok = re.search(pattern.encode(), block) is not None
                if not ok:
                    pump(0.5)
            if not ok:
                note(f'FAIL: the screen never showed {pattern!r} within {secs} s')
                failed = True
                break
        elif verb == 'capture':
            if not capture(rest.strip()):
                note('FAIL: no complete picture came back')
                failed = True
                break
            note(f'saved {rest.strip()}')
        else:
            note(f'FAIL: unknown script command {verb!r}')
            failed = True
            break
remaining = a.seconds - (time.monotonic() - start)
if remaining > 0 and not failed:
    pump(remaining)
out.close()
log = a.output.read_bytes()
sys.stdout.write(re.sub(rb'CAP_BEGIN.*?CAP_END', b'CAP_BEGIN ... CAP_END', log, flags=re.S).decode('latin-1')[-6000:])
note('PASS' if not failed else 'FAILED')
sys.exit(1 if failed else 0)
