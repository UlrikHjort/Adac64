# AdaC64

A Commodore 64 and Commodore 128 emulator written in Ada 2012 with GtkAda.
It uses the ROM images that ship with VICE (`/usr/share/vice` by default).

## Build and run

    make                  # needs GNAT, gprbuild, GtkAda (libgtkada-dev), libpulse-dev,
                          # libgtksourceview-4-0 (the studio's editor)
    bin/adac64            # C64
    bin/adac64 --c128     # C128, 40 columns
    bin/adac64 --c128 --80
    bin/adac64 game.d64   # autostart (also .t64 / .prg / .asm / .bas)
    bin/adac64 --studio   # assembler IDE and debugger
    make tests            # keyboard, CPU and debugger tests

Autostart types what a user would: `LOAD"name",8,1` + `RUN` on the C64, and
`DLOAD"name"` + `RUN` (or `BLOAD` + `SYS`) on the C128, using the first
program's real name. If the first file is data, the first BASIC program on
the disk is started instead. On the C128, a program that asks for an
80-column screen, or runs in FAST mode with the 40-column display, is
restarted automatically with the 40/80 key down.

Options: `--roms DIR`, `--drive-rom FILE`, `--fast-drive`, `--attach FILE`
(insert without autostart), and for testing `--headless N` (run N frames, save
`shot.png` / `vdc_shot.png`), `--png FILE`, `--type "TEXT\n"`, `--wav FILE`,
`--dump FILE` (64 KB memory + 2 KB drive RAM), `--type-at FRAME TEXT`,
`--save-snapshot F`, `--load-snapshot F`, `--break ADDR` and
`--monitor "r;d e5cd;m 0400"` (monitor commands after the run), and
`--keys-at FRAME TEXT` (type through the keyboard matrix, e.g. for CP/M).

## What is emulated

| Part | Notes |
|------|-------|
| 6510 / 8502 CPU | All documented and the stable undocumented opcodes, NMOS decimal mode, exact cycle counts. Passes Klaus Dormann's 6502 functional test. |
| VIC-II (PAL 6569 / NTSC 6567R8) | Cycle-exact pixel output (mid-line colour/mode splits, side-border opening), all text/bitmap modes, ECM, smooth scroll, badlines with cycle stealing, sprites (expand, multicolour, priority, collisions, MSB X), border flip-flops (top/bottom border opening), raster IRQ. |
| SID 6581 / 8580 | 3 voices, all waveforms incl. modelled combined waveforms (sparse on the 6581, fuller on the 8580), ring mod, sync, ADSR with real rate tables and the ADSR delay bug, multimode filter with each chip's cutoff curve and resonance, OSC3/ENV3 readback, volume-register digis (loud on the 6581, nearly silent on the 8580 as on real hardware). Machine menu or `--sid 6581\|8580`. Output via PulseAudio, which also paces emulation. |
| CIA 6526 x2 | Timers A/B (all modes), TOD clock with alarm, ICR, keyboard, joysticks, VIC bank select. |
| C128 MMU | Banking of 128 KB, BASIC/KERNAL/char ROMs, common RAM, zero-page/stack relocation, PCR registers, GO64. |
| C128 VDC 8563 | 64 KB VRAM, block copy/fill, text mode with attributes (blink, underline, reverse, alt charset), bitmap mode, cursor. |
| Z80 (C128) | Full instruction set incl. undocumented IXH/IXL and DDCB copies, IM 0/1/2, NMI. Runs the Z80 BIOS at power-on, then hands over to the 8502 as on the real machine; CPU switching through the MMU. Boots CP/M 3.0. |
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

**1571** (File menu or `--drive 1571`; needs `1571-rom.310654-05.bin` from
<https://www.zimmers.net/anonftp/pub/cbm/firmware/drives/new/1571/> in
`roms/drives/`): the C128's drive with its 32 KB DOS, 1/2 MHz CPU clock,
double-sided head (D71 images, 1328 blocks), a WD1770 (no MFM disks) and
its CIA for the C128 fast serial / burst mode, which the C128 KERNAL and CP/M
use automatically (several times faster than a 1541; CP/M boots in ~40 s at
real speed). On a C64 it behaves like a 1541.

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

### Tape

`.tap` images (File → Insert tape, or autostart/drop the file): a Datasette
with pulse-accurate playback into CIA1's FLAG input, motor control and PLAY
sense through the CPU port, so the KERNAL tape routines and turbo tape
loaders work. Autostart types `LOAD` + `RUN` and warps while the motor runs.
T64 files are still loaded instantly through the KERNAL trap.

### PAL / NTSC

PAL (6569, 63 cycles x 312 lines, 985 kHz) is the default. Machine → NTSC or
`--ntsc` switches to the 6567R8 (65 cycles x 263 lines, 1.023 MHz, 60 Hz);
SID pitch, drive timing and the C128 VDC follow, and the KERNAL detects the
standard by itself. NTSC-only games (e.g. Spy vs Spy NTSC) need it, and so
do many US demos. The choice is saved in the settings file.

### Cartridges

`.crt` files (File → Insert cartridge, or pass/drop the file to autostart):
standard 8K and 16K, Ultimax (VIC fetches from the cartridge), Ocean,
Magic Desk, C64 Game System, Dinamic and EasyFlash (read-only flash, 256 bytes
of RAM at `$DF00`). On a C128 a cartridge makes the KERNAL boot in C64 mode,
as on the real machine.

### RAM expansion (REU)

Machine menu or `--reu KB`: Commodore 1700 (128 KB), 1764 (256 KB), 1750
(512 KB) or larger (2 MB, 16 MB) RAM Expansion Units with the 8726 DMA
controller at `$DF00` (stash, fetch, swap, verify, autoload, `$FF00`
trigger, IRQ). The CPU is halted during DMA as on the real hardware.

### CP/M

The C128's Z80 boots CP/M Plus from the official Commodore system disk (a
D64; available at <https://www.zimmers.net/anonftp/pub/cbm/demodisks/c128/>;
`cpm.system.622-3297432.d64.gz` is the latest, 28 May 87, version, which
also supports an REU as RAM disk `M:`). Attach or autostart it on the C128;
the KERNAL boots it from its boot sector (40 or 80 columns, per the 40/80
key). Autostarting a boot disk runs in warp until the drive is quiet, so the
`A>` prompt appears after a few seconds instead of ~90 (real 1541 speed):

    bin/adac64 --c128 --80 --reu 512 roms/cpm/cpm.system.622-3297432.d64

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

## Studio: assembler and debugger

`bin/adac64 --studio [file.asm]` (or Machine → Studio) opens an IDE next to
the emulator: a 6502 editor with syntax highlighting (GtkSourceView), an
assembler, and a source-level debugger working on the running machine.

| Key | | Key | |
|---|---|---|---|
| F5 | build and run, or continue when stopped | F9 | toggle breakpoint (or click the gutter) |
| Ctrl+F5 | rebuild and run | F10 | step over (runs a `JSR` to its end) |
| F6 | pause | F11 / Shift+F11 | step into / step out |
| F7 | build | Ctrl+F10 | run to the cursor line |
| F12 | show the emulator | Ctrl+N/O/S/W | new / open / save / close tab |

Run resets the machine, waits for READY, copies the program into memory
(the disk in the drive is left alone) and types `RUN` when the program
starts with a BASIC line at `$0801` (`!basic`), otherwise `SYS start`.
When a breakpoint, watchpoint, step or pause stops the machine, the studio
shows the source line, registers and cycle count (also since the previous
stop), a disassembly with labels and a memory view (type `$addr` or a
label). Watchpoints stop after the instruction that touches the address:
`$d020 w`, `score rw`, `$0400-$07e7 w`, `$d020 off`, `clear`.
Clicking an error in the build output jumps to the line. The open files
are reopened next time.

The assembler also works on its own: `bin/adac64 --asm game.asm` writes
`game.prg` (or the `!to` name) plus a VICE label file `game.lbl`; passing
an `.asm` file to `adac64` assembles and autostarts it. The syntax is
ACME's:

    *= $0801                 ; program counter
    !basic                   ; BASIC line "10 SYS <next address>"
    border = $d020           ; constant
    start   ldx #0           ; label (a colon is optional)
    -       lda text,x       ; anonymous labels: bne - / beq +
            beq +
            sta $0400,x
            inx
            bne -
    +       rts
    !zone print { .loop ... }  ; .local labels per zone, @local per label
    !macro poke .a, .v { lda #.v : sta .a }   ; called as  +poke $d020, 0
    !if DEBUG { ... } else { ... }    !for i, 0, 7 { !byte 1 << i }
    text    !scr "hello", 0  ; also !byte !word !text !pet !fill !align
                             ; !binary "f",size,skip  !source "f"  !to "f"

Expressions: `$ff %1010 0x1f 'a' *` (PC), `+ - * / % & | ^ << >>`,
`<x` / `>x` low / high byte, comparisons and `&& ||` for `!if`. Zero page
addressing is chosen automatically, forward references are resolved over
several passes, and the illegal opcodes (`lax sax dcp isc slo rla sre rra
anc alr arr sbx ...`) are available. All 151 legal opcodes assemble
identically to 64tass; `tests/debug_test` exercises the debugger.

### BASIC programs

`.bas` files are Commodore BASIC as text (petcat style): numbered lines,
keywords in any case, `?` for PRINT. In strings lower-case letters are the
normal PETSCII letters and upper-case ones the shifted letters; special
characters are written in braces: `{clr} {home} {wht} {red} {rvon} {rvof}
{down} {3 down} {left*2} {f1} {pi} {pound} {$a6}` (see `src/basic.ads`).

In the studio, File → New BASIC program (Ctrl+Shift+N) gives a BASIC tab;
F5 tokenizes it (BASIC V2 on the C64, BASIC 7.0 with its extra keywords on
the C128), loads it and types RUN, and the line being executed is
highlighted while it runs. File → Import BASIC PRG lists a program file,
and File → Get BASIC program from emulator lists whatever is in the
machine's memory (e.g. a program typed in by hand).

On the command line: `bin/adac64 --basic prog.bas` writes `prog.prg`
(`--c128` for BASIC 7.0), `bin/adac64 --list prog.prg` prints the listing,
and `bin/adac64 prog.bas` tokenizes and runs it. `tests/basic_test.sh`
types the test programs into the emulated C64 and C128 and checks that the
real ROM tokenizers produce exactly the same bytes.

### Sprite editor

Studio → Tools → Sprite editor (Ctrl+E), or open a `.spr` file. A set holds
up to 256 sprites (strip at the bottom, PgUp/PgDn). Draw with the left
button, erase with the right, Shift+click flood-fills; pens 1-4 are
background, sprite colour, multicolour 1 and 2 (`$D025`/`$D026`), and a
click in the palette gives the selected pen its colour. M toggles
multicolour (double-wide pixels). Clear, invert, flip, shift (wrapping),
copy/paste between sprites and undo (Ctrl+Z) are on the toolbar; the
preview shows the sprite enlarged and at real size, with X/Y expansion,
and can animate a range of sprites.

*Show in emulator* puts the sprite on the real VIC-II as sprite 0 (data at
`$0340`, at the READY prompt), *Live in emulator* does that on every change,
and *Grab from emulator* copies all sprites that are switched on in the
running program (any VIC bank) into the set, with their colours.

`.spr` files are raw 64-byte blocks (63 bytes of data + colour/multicolour
byte), so `!binary "ship.spr"` includes them directly; *Export .asm* writes
ACME source with one `!byte %...###...` line per row and a label per sprite.

## Keys

Keyboard mapping is symbolic by default: type the character you want.
Input → Positional keyboard mapping uses PC key positions instead (like the
C64 keyboard: e.g. Shift+2 gives `"`, `[` / `]` are `@` / `*`, Delete is ↑),
which suits games and CP/M.
Esc = RUN/STOP, PgUp = RESTORE, Left Alt = C=, Home = CLR/HOME, Insert = INST,
`\` = £, `_` = ←, `^` = ↑, PgDn = HELP (C128), Pause = ESC (C128), Tab = TAB (C128).

Joystick (port 2 by default, changeable in the Input menu): a USB joystick or
gamepad (`/dev/input/jsN`, chosen in the Input menu; the first non-wheel
controller is used by default), and/or keypad 8/2/4/6 with diagonals, fire =
keypad 0/5/Enter or Right Ctrl; alternatively the cursor keys.
`bin/adac64 --list-joysticks` shows the controllers found.

F9 autostart dialog, F10 toggle 40/80 view, F11 warp, F12 reset,
Shift+F9 quick save, Shift+F10 quick load, Shift+F12 monitor,
Alt+Enter fullscreen, Ctrl+Shift+V paste text (typed into the machine).
View menu: fullscreen, integer scaling, CRT scanlines.

Settings (machine, 40/80 key, joystick, controller, drive options, display,
keyboard mode, last directory, window size) are saved in
`~/.config/adac64/settings`; command-line options override them.
Disk images can also be dropped onto the window.

## Source layout

    src/mos6502.*    6502 CPU core (generic over the bus)
    src/z80.*        Z80 CPU core (C128 / CP/M)
    src/vic_ii.*     VIC-II        src/sid.*      SID
    src/cia.*        CIA           src/vdc.*      VDC
    src/machine.*    memory maps, I/O, MMU, KERNAL traps, frame loop
    src/crt.*        CRT cartridge files
    src/reu.*        RAM Expansion Unit
    src/tape.*       Datasette / TAP images
    src/media.*      D64/T64/PRG images, fast-load traps, host directory
    src/drive1541.*  1541/1571 drive: CPU, VIAs, CIA, WD1770, GCR surface
    src/via.*        6522 VIA       src/iec.ads    serial bus lines
    src/keyboard.*   matrix and host key mapping
    src/audio.*      PulseAudio output    src/gui.*  GtkAda front end
    src/monitor*.*   machine-code monitor src/disasm.* disassembler
    src/asm.*        6502 assembler (ACME syntax)
    src/basic.*      BASIC V2 / 7.0 tokenizer and lister
    src/studio.*     studio window    src/source_view.*  GtkSourceView binding
    src/sprite_*     sprite editor (data model / window)
    share/adac64/    6502 syntax highlighting (language-specs/*.lang)
    tests/           CPU, keyboard, debugger, sprite and BASIC tests,
                     mkd64.py image builder
    tests/tools/     batch game runner, 6502 disassembler, D64/G64 readers,
                     mkd71.py double-sided image builder, mktap.py
                     KERNAL-format TAP encoder
