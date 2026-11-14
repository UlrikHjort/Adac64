# AdaC64

A Commodore 64 and Commodore 128 emulator written in Ada 2012 with GtkAda.
It uses the ROM images that ship with VICE (`/usr/share/vice` by default).

## Build and run

    make                  # needs GNAT, gprbuild, GtkAda (libgtkada-dev), libpulse-dev
    bin/adac64            # C64
    bin/adac64 --c128     # C128, 40 columns
    bin/adac64 --c128 --80
    bin/adac64 game.d64   # autostart (also .t64 / .prg)
    make tests            # keyboard + CPU tests

Options: `--roms DIR`, `--drive-rom FILE`, `--fast-drive`, `--attach FILE`
(insert without autostart), and for testing `--headless N` (run N frames, save
`shot.png` / `vdc_shot.png`), `--png FILE`, `--type "TEXT\n"`, `--wav FILE`,
`--dump FILE` (64 KB memory + 2 KB drive RAM), `--type-at FRAME TEXT`,
`--save-snapshot F`, `--load-snapshot F`, `--break ADDR` and
`--monitor "r;d e5cd;m 0400"` (monitor commands after the run).

## What is emulated

| Part | Notes |
|------|-------|
| 6510 / 8502 CPU | All documented and the stable undocumented opcodes, NMOS decimal mode, exact cycle counts. Passes Klaus Dormann's 6502 functional test. |
| VIC-II (PAL 6569) | Cycle-exact pixel output (mid-line colour/mode splits, side-border opening), all text/bitmap modes, ECM, smooth scroll, badlines with cycle stealing, sprites (expand, multicolour, priority, collisions, MSB X), border flip-flops (top/bottom border opening), raster IRQ. |
| SID 6581 | 3 voices, all waveforms, ring mod, sync, ADSR with real rate tables, multimode filter, volume-register digis. Output via PulseAudio, which also paces emulation. |
| CIA 6526 x2 | Timers A/B (all modes), TOD clock with alarm, ICR, keyboard, joysticks, VIC bank select. |
| C128 MMU | Banking of 128 KB, BASIC/KERNAL/char ROMs, common RAM, zero-page/stack relocation, PCR registers, GO64. |
| C128 VDC 8563 | 64 KB VRAM, block copy/fill, text mode with attributes (blink, underline, reverse, alt charset), bitmap mode, cursor. |
| C128 extras | 2 MHz mode, extended keyboard (`$D02F`), 40/80 key, 2 KB banked colour RAM. |

### Drive 8

**True drive emulation (default for D64 and G64 images):** a complete 1541
runs in lockstep with the computer: its own 6502 executing the real DOS ROM,
2 KB RAM, two 6522 VIAs, the IEC serial bus (ATN/CLK/DATA with hardware ATN
acknowledge), stepper motor with half-tracks and a bit-level rotating disk
surface (SYNC detection, byte framing, write shift register). D64 images are
converted to GCR tracks; G64 images (raw tracks, e.g. copy-protected
originals) are used as captured. Custom fast loaders work.
Writes (SAVE, scratch, format) are decoded back into the D64 and saved to the
file (G64 tracks are written back in place); read-only image files appear as
write-protected disks. This needs a
1541 ROM (16 KB), searched in this order: `--drive-rom FILE`,
`<roms>/DRIVES/dos1541-325302-01+901229-05.bin`, `<roms>/DRIVES/dos1541`,
`roms/drives/dos1541.bin` (next to `bin/`), `roms/drives/1541-II.251968-03.bin`.
The ROMs are available from
<https://www.zimmers.net/anonftp/pub/cbm/firmware/drives/new/1541/>;
`dos1541.bin` is `1541-c000.325302-01.bin` followed by `1541-e000.901229-05.bin`.

**Fast KERNAL loading** (on by default, File menu): with the true drive
active, KERNAL `LOAD`s from drive 8 are served instantly from the image and
written straight into RAM, like a fast-load cartridge, so "one-filer" cracks
that load under the I/O area work. G64 images are decoded to sectors for
this; a file touching a sector that does not decode cleanly falls back to the
emulated 1541. Custom loaders, drive code and SAVE always use the real drive.
`--no-fast-load` disables it.

**Fast mode** (File menu toggle, `--fast-drive`, or no drive ROM): KERNAL
`LOAD`/`SAVE` are trapped at `$FFD5`/`$FFD8` and served instantly from D64,
T64 and PRG images. With no image attached, drive 8 is always the current host
directory (`NAME.prg`), and `SAVE"NAME",8` writes `NAME.prg` there.

### Cartridges

`.crt` files (File → Insert cartridge, or pass/drop the file to autostart):
standard 8K and 16K, Ultimax (VIC fetches from the cartridge), Ocean,
Magic Desk, C64 Game System, Dinamic and EasyFlash (read-only flash, 256 bytes
of RAM at `$DF00`). On a C128 a cartridge makes the KERNAL boot in C64 mode,
as on the real machine.

### Snapshots

Machine → Save/Load snapshot saves the complete state (computer, 1541 with
its disk surface, cartridge) to a file; Shift+F9 / Shift+F10 quick-save and
quick-load `~/.local/share/adac64/quick.a64s`. The attached disk image is
re-attached by path when loading.

### Monitor

Machine → Monitor (Shift+F12) opens a machine-code monitor, which also pops
up when a breakpoint is hit. Numbers are hex (`$` optional):

    r            registers           z [n]       step n instructions
    d [addr]     disassemble         m [a [b]]   memory dump
    > addr bb..  write bytes         g [addr]    continue (optionally at addr)
    b addr       set breakpoint      bd [addr]   delete one / all breakpoints
    bl           list breakpoints    dev c | 8   view C64 or 1541 CPU
    x            close and continue

## Keys

Keyboard mapping is symbolic: type the character you want.
Esc = RUN/STOP, PgUp = RESTORE, Left Alt = C=, Home = CLR/HOME, Insert = INST,
`\` = £, `_` = ←, `^` = ↑, PgDn = HELP (C128), Pause = ESC (C128), Tab = TAB (C128).

Joystick (port 2 by default, changeable in the Input menu): keypad 8/2/4/6 with
diagonals, fire = keypad 0/5/Enter or Right Ctrl; alternatively the cursor keys.

F9 autostart dialog, F10 toggle 40/80 view, F11 warp, F12 reset,
Shift+F9 quick save, Shift+F10 quick load, Shift+F12 monitor.
Disk images can also be dropped onto the window.

## Source layout

    src/mos6502.*    CPU core (generic over the bus)
    src/vic_ii.*     VIC-II        src/sid.*      SID
    src/cia.*        CIA           src/vdc.*      VDC
    src/machine.*    memory maps, I/O, MMU, KERNAL traps, frame loop
    src/crt.*        CRT cartridge files
    src/media.*      D64/T64/PRG images, fast-load traps, host directory
    src/drive1541.*  1541 drive: CPU, memory map, GCR disk surface
    src/via.*        6522 VIA       src/iec.ads    serial bus lines
    src/keyboard.*   matrix and host key mapping
    src/audio.*      PulseAudio output    src/gui.*  GtkAda front end
    src/monitor*.*   machine-code monitor src/disasm.* disassembler
    tests/           CPU and keyboard tests, mkd64.py image builder
    tests/tools/     batch game runner, 6502 disassembler, D64/G64 readers
