"""Pack a disk image for the Pico's flash, one track at a time (a track is unpacked into SRAM when the
head arrives: src/board_common.pmi DiskUnpack). The format, our own, LZ77 within the track:

  sequence: token = (literals << 4) | match code; literals 15 adds the bytes that follow (each 0-255,
  stop at one below 255); then the literal bytes; then, unless the track is complete, the match: an
  offset (2 bytes, little-endian, 1-4095 back) and a length of match code + 3 (code 15 adds bytes as
  for literals).
  Image: 35 x (offset 4 bytes, packed length 4 bytes) from the start of the image, then the tracks.

    py -3 tools/lzpack.py in.dsk out.bin        (a test: --check unpacks and compares)
"""
import struct
import sys

def pack_track(data):
    out = bytearray()
    n = len(data)
    i = 0
    lit_start = 0
    heads = {}
    def emit(lit, mlen, off):
        ll = len(lit)
        mc = 0 if mlen == 0 else min(mlen - 3, 15)
        out.append((min(ll, 15) << 4) | mc)
        if ll >= 15:
            r = ll - 15
            while r >= 255:
                out.append(255); r -= 255
            out.append(r)
        out.extend(lit)
        if mlen:
            out.extend(struct.pack('<H', off))
            if mlen - 3 >= 15:
                r = mlen - 3 - 15
                while r >= 255:
                    out.append(255); r -= 255
                out.append(r)
    while i < n:
        best_len, best_off = 0, 0
        if i + 3 <= n:
            key = bytes(data[i:i + 3])
            for j in reversed(heads.get(key, [])):
                if i - j > 4095:
                    break
                l = 0
                while i + l < n and data[j + l] == data[i + l] and l < 4000:
                    l += 1
                if l > best_len:
                    best_len, best_off = l, i - j
        if best_len >= 3:
            emit(data[lit_start:i], best_len, best_off)
            for k in range(i, min(i + best_len, n - 2)):
                heads.setdefault(bytes(data[k:k + 3]), []).append(k)
            i += best_len
            lit_start = i
        else:
            if i + 3 <= n:
                heads.setdefault(bytes(data[i:i + 3]), []).append(i)
            i += 1
    emit(data[lit_start:n], 0, 0)
    return bytes(out)

def unpack_track(src, n):
    out = bytearray()
    p = 0
    while True:
        t = src[p]; p += 1
        ll = t >> 4
        if ll == 15:
            while True:
                b = src[p]; p += 1; ll += b
                if b != 255:
                    break
        out += src[p:p + ll]; p += ll
        if len(out) >= n:
            return bytes(out[:n])
        off = src[p] | (src[p + 1] << 8); p += 2
        ml = (t & 15) + 3
        if (t & 15) == 15:
            while True:
                b = src[p]; p += 1; ml += b
                if b != 255:
                    break
        for _ in range(ml):
            out.append(out[-off])

def pack_image(img, track_bytes):
    tracks = [pack_track(img[t * track_bytes:(t + 1) * track_bytes]) for t in range(35)]
    head = bytearray()
    pos = 35 * 8
    for tr in tracks:
        head += struct.pack('<II', pos, len(tr))
        pos += len(tr)
    return bytes(head) + b''.join(tracks)

def unpack_image(blob, track_bytes):
    out = bytearray()
    for t in range(35):
        off, ln = struct.unpack_from('<II', blob, t * 8)
        out += unpack_track(blob[off:off + ln], track_bytes)
    return bytes(out)

if __name__ == '__main__':
    img = open(sys.argv[1], 'rb').read()
    tb = 6656 if len(img) == 35 * 6656 else 4096
    blob = pack_image(img, tb)
    open(sys.argv[2], 'wb').write(blob)
    assert unpack_image(blob, tb) == img
    print(f'{sys.argv[1]}: {len(img)} -> {len(blob)} bytes, unpacks identically')
