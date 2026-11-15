#!/usr/bin/env python3
"""Build a 2 MB Mega-Cart test image: mkmegacart.py out.bin boot.prg app.prg
Low ROM chips (0-127) are filled with their bank number, the high ones
(128-255) with $80 + bank; boot.prg goes to high bank $7F, app.prg to
high bank 5."""
import sys

out, boot, app = sys.argv[1:4]
img = bytearray()
for chip in range(256):
    img += bytes([chip if chip < 128 else 0x80 + (chip - 128) & 0xFF]) * 0x2000
for path, chip in ((boot, 128 + 0x7F), (app, 128 + 5)):
    code = open(path, 'rb').read()[2:]
    img[chip * 0x2000:chip * 0x2000 + len(code)] = code
img[3 * 0x2000:4 * 0x2000] = b'\x33' * 0x2000
open(out, 'wb').write(img)
