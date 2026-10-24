"""Type on the Apple IIc from this PC's keyboard (Windows console), and see what the board says.

    py -3 tools/console.py --port COM7

Keys go to the IIc as typed. Return, Backspace and the left arrow (the IIc's left arrow, $08), the right
arrow ($15), up ($0B), down ($0A), Esc, Tab and Delete are mapped; Ctrl+letter is the control key.
Ctrl+] then a letter is a firmware monitor command: s status, t the screen as text, p CPU, f full speed,
m monochrome, r Ctrl+Reset, R power off and on, o / a Open-/Solid-Apple with the next key. Ctrl+Q quits.
Letters are sent as typed; Applesoft wants capitals (Caps Lock), as on a real IIc.
"""
import argparse
import msvcrt
import threading
import time

import serial

EXTENDED = {72: 0x0B, 80: 0x0A, 75: 0x08, 77: 0x15, 83: 0x7F}

p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument('--port', required=True)
p.add_argument('--quiet', action='store_true', help='hide the periodic A2 status lines')
a = p.parse_args()
port = serial.Serial(a.port, 115200, timeout=0.05)
stop = False


def reader():
    buf = b''
    while not stop:
        try:
            data = port.read(4096)
        except serial.SerialException:
            print('\n[console] the port went away', flush=True)
            return
        if not data:
            continue
        buf += data
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            s = line.decode('latin-1').rstrip('\r')
            if a.quiet and s.startswith('A2 frames='):
                continue
            print(s, flush=True)


threading.Thread(target=reader, daemon=True).start()
print('[console] typing goes to the Apple IIc. Ctrl+Q quits, Ctrl+] then a letter is a monitor command.', flush=True)
while True:
    ch = msvcrt.getwch()
    if ch == '\x11':
        break
    if ch in ('\x00', '\xe0'):
        code = ord(msvcrt.getwch())
        if code in EXTENDED:
            port.write(bytes([EXTENDED[code]]))
        continue
    if ch == '\x1d':
        port.write(b'\x1d' + msvcrt.getwch()[:1].encode('latin-1', 'replace'))
        continue
    o = ord(ch)
    if o < 128:
        port.write(bytes([o]))
stop = True
time.sleep(0.1)
port.close()
