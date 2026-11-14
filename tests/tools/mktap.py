#!/usr/bin/env python3
"""Encode a PRG as a standard KERNAL tape (TAP v1) - test helper.

usage: mktap.py out.tap NAME file.prg
"""
import sys
S, M, L = 0x30, 0x42, 0x56

def byte_pulses(b):
    out = [L, M]
    ones = 0
    for i in range(8):
        bit = (b >> i) & 1
        ones += bit
        out += [M, S] if bit else [S, M]
    parity = 1 ^ (ones & 1)
    out += [M, S] if parity else [S, M]
    return out

def block(data, repeat):
    out = []
    start = 0x09 if repeat else 0x89
    for c in range(start, start - 9, -1):
        out += byte_pulses(c)
    chk = 0
    for b in data:
        out += byte_pulses(b); chk ^= b
    out += byte_pulses(chk)
    out += [L, S]
    return out

def record(data, leader):
    out = [S] * leader
    out += block(data, False)
    out += [S] * 79
    out += block(data, True)
    out += [S] * 78
    return out

out_path, name, prg = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(prg, 'rb').read()
start = d[0] | d[1] << 8; body = d[2:]; end = start + len(body)
hdr = bytes([0x01, start & 255, start >> 8, end & 255, end >> 8]) + \
      name.upper().encode().ljust(16, b' ')
hdr = hdr.ljust(192, b' ')
pulses = record(hdr, 0x6A00) + record(body, 0x1A00) + [S] * 2000
data = bytes(pulses)
tap = b'C64-TAPE-RAW' + bytes([1, 0, 0, 0]) + len(data).to_bytes(4, 'little') + data
open(out_path, 'wb').write(tap)
