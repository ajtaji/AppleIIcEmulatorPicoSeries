"""Build the private firmware wrappers (private/ is ignored by git; nothing here is ever committed):

    py -3 tools/make_private.py --rom <your Apple IIc ROM> [--disk <.dsk/.do/.po/.nib>] [--no-sound]

Writes:
  private/rom_data.pmi      the ROM as a DataSection (A2RomData, #A2_ROM_BYTES = 16384 or 32768)
  private/disk_data.pmi     the disk for drive 1 (A2DiskData, #A2_DISK_KIND: 1 DOS order, 2 ProDOS, 3 nibbles)
  private/apple2c.picow     the Pico W firmware with them, and sound on the Bluetooth speaker
  private/apple2c.pico2w    the same for the Pico 2 W
The speaker's address is copied from the NES emulator's private wrapper (the same speaker), byte for
byte, without being printed. The ROM and the disk go into the firmware image, in flash.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NES_PRIVATE = ROOT / 'private' / 'speaker-source.picow'

def data_lines(label, blob):
    out = [label + ':']
    for s in range(0, len(blob), 32):
        out.append('  Data.a ' + ','.join(f'${b:02X}' for b in blob[s:s + 32]))
    return out

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--rom', required=True)
    p.add_argument('--disk')
    p.add_argument('--no-sound', action='store_true')
    a = p.parse_args()
    priv = ROOT / 'private'
    priv.mkdir(exist_ok=True)
    rom = Path(a.rom).read_bytes()
    if len(rom) not in (16384, 32768):
        sys.exit(f'{a.rom} is {len(rom)} bytes; an Apple IIc ROM is 16384 (ROM 255) or 32768 (ROM 0, 3, 4)')
    (priv / 'rom_data.pmi').write_text('\n'.join(
        ['; PRIVATE: the Apple IIc ROM (Apple\'s code; never committed).', f'#A2_ROM_BYTES = {len(rom)}',
         'DataSection'] + data_lines('A2RomData', rom) + ['EndDataSection']) + '\n')
    disk_kind = 0
    if a.disk:
        d = Path(a.disk).read_bytes()
        ext = Path(a.disk).suffix.lower()
        if ext in ('.dsk', '.do', '.po'):
            if len(d) != 143360:
                sys.exit(f'{a.disk} is {len(d)} bytes; a 5.25-inch sector image is 143360')
            disk_kind = 2 if ext == '.po' else 1
        elif ext == '.nib':
            if len(d) != 35 * 6656:
                sys.exit(f'{a.disk} is {len(d)} bytes; a .nib image is 232960')
            disk_kind = 3
        else:
            sys.exit(f'{a.disk}: the boards take .dsk .do .po .nib (the desktop also reads .woz)')
        (priv / 'disk_data.pmi').write_text('\n'.join(
            ['; PRIVATE: the disk in drive 1 (never committed).', f'#A2_DISK_KIND = {disk_kind}',
             'DataSection'] + data_lines('A2DiskData', d) + ['EndDataSection']) + '\n')
    speaker = None
    if not a.no_sound:
        m = re.search(r'PackBluetoothPeer:\s*\n\s*(Data\.a [^\n]+)', NES_PRIVATE.read_text())
        if not m:
            sys.exit('no speaker address found in the NES private wrapper; use --no-sound')
        speaker = m.group(1)
    for chip, body, ext in (('Pico W', '../rp2040/apple2c_body.pico', 'picow'),
                            ('Pico 2 W', '../rp2350/apple2c_body.pico2', 'pico2w')):
        lines = [f'; PRIVATE (private/ is ignored by git): the Apple IIc for the {chip} with its ROM'
                 + (', a disk' if disk_kind else '') + (' and sound' if speaker else '') + '.',
                 '#CPU_ASM_TAIL = 1', '#A2_ROM = 1', f'#A2_DISK = {1 if disk_kind else 0}',
                 f'#A2_AUDIO = {1 if speaker else 0}',
                 'XIncludeFile "rom_data.pmi"']
        if disk_kind:
            lines.append('XIncludeFile "disk_data.pmi"')
        lines.append(f'XIncludeFile "{body}"')
        if speaker:
            lines += ['DataSection', 'A2Speaker:', '  ' + speaker, 'EndDataSection', 'A2AudioPeer(?A2Speaker)']
        lines.append('Main()')
        (priv / f'apple2c.{ext}').write_text('\n'.join(lines) + '\n')
    print(f'private build: ROM {len(rom)} bytes, disk kind {disk_kind}, sound {"on" if speaker else "off"}')

if __name__ == '__main__':
    main()
