# AdaC64

A Commodore 64, Commodore 128 and VIC-20 emulator written in Ada 2012 with
GtkAda, with Forge, an assembler IDE, debugger and graphics editors.
The Commodore ROMs are not included; see [ROMs](#roms) for which files are
needed and where they go.

## ROMs

The machines need the original Commodore ROMs. They are still under
copyright, so they are not part of this project and must not be added to
the repository (`roms/` is in `.gitignore`). Use dumps of your own
machines, or the ROM files that come with an emulator distribution that
includes them (the official VICE releases do; some Linux packages of VICE
leave some out). The files are found by these names:

| Machine | Where | Files |
|---|---|---|
| C64 | `<roms>/C64/` | `basic-901226-01.bin`, `kernal-901227-03.bin`, `chargen-901225-01.bin` |
| C128 | `<roms>/C128/` | `kernal-318020-05.bin`, `basiclo-318018-04.bin`, `basichi-318019-04.bin`, `chargen-390059-01.bin`, `basic64-901226-01.bin`, `kernal64-901227-03.bin` |
| VIC-20 | `roms/vic20/` (or `<roms>/VIC20/` with VICE names) | `basic.901486-01.bin`, `characters.901460-03.bin`, `kernal.901486-07.bin` (PAL), `kernal.901486-06.bin` (NTSC) |
| 1541 | `roms/drives/` or `<roms>/DRIVES/` | `1541-II.251968-03.bin`, or `dos1541.bin` = `1541-c000.325302-01.bin` + `1541-e000.901229-05.bin` |
| 1571 | `roms/drives/` | `1571-rom.310654-05.bin` |

`<roms>` is `/usr/share/vice` unless `--roms DIR` says otherwise;
`roms/...` is looked for next to `bin/` and in the current directory. To
check that you have the expected versions (`sha1sum FILE`):

    79015323128650c742a3694c9429aa91f355905e  basic-901226-01.bin
    1d503e56df85a62fee696e7618dc5b4e781df1bb  kernal-901227-03.bin
    adc7c31e18c7c7413d54802ef2f4193da14711aa  chargen-901225-01.bin
    ceb6e1a1bf7e08eb9cbc651afa29e26adccf38ab  kernal-318020-05.bin
    d53a7884404f7d18ebd60dd3080c8f8d71067441  basiclo-318018-04.bin
    c4fb4a714e48a7bf6c28659de0302183a0e0d6c0  basichi-318019-04.bin
    29ed066d513f2d5c09ff26d9166ba23c2afb2b3f  chargen-390059-01.bin
    587d1e90950675ab6b12d91248a3f0d640d02e8d  basic.901486-01.bin
    4fd85ab6647ee2ac7ba40f729323f2472d35b9b4  characters.901460-03.bin
    ce0137ed69f003a299f43538fa9eee27898e621e  kernal.901486-07.bin
    06de7ec017a5e78bd6746d89c2ecebb646efeb19  kernal.901486-06.bin
    d3b78c3dbac55f5199f33f3fe0036439811f7fb3  1541-II.251968-03.bin
    8e0547430135ba462525c224e76356bd3d430f11  1541-c000.325302-01.bin
    f5d60777440829e46dc91285e662ba072acd2d8b  1541-e000.901229-05.bin
    f1be619c106641a685f6609e4d43d6fc9eac1e70  1571-rom.310654-05.bin

Without a drive ROM the emulator still works, with KERNAL-level disk
access instead of an emulated drive (see Drive 8 below).

## Build and run

    make                  # needs GNAT, gprbuild, GtkAda (libgtkada-dev), libpulse-dev,
                          # libgtksourceview-4-0 (Forge's editor)
    bin/adac64            # C64
    bin/adac64 --c128     # C128, 40 columns
    bin/adac64 --c128 --80
    bin/adac64 game.d64   # autostart (also .t64 / .prg / .asm / .bas)
    bin/adac64-forge     # assembler IDE and debugger (with the emulator)
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

### VIC-20

Machine → Commodore VIC-20 (or `--vic20`, with `3k`, `8k`, `16k`, `24k` or
`35k` for a RAM expansion): the 6561 (PAL) / 6560 (NTSC) VIC, drawn cycle
by cycle (4 pixels per cycle with the registers of that moment, the text
area opened and counted like the chip does it, so raster splits, colour
changes in the middle of a line and second text areas lower on the screen
work; the whole 284 x 284 / 260 x 233 picture is shown, with the VIC-20's
wide pixels), multicolour and double-height characters, reverse mode and
its sound (three square-wave voices and noise, pitch
checked against VICE), the two 6522 VIAs (keyboard, joystick, serial bus,
Datasette, RESTORE as NMI) and the memory map with the expansion blocks.
The KERNAL sizes RAM itself, so the start-up screen shows 3583, 6655, 11775,
19967 or 28159 bytes free as on the real machine. The 1541 works as on the
C64 (fast load or the emulated drive), and autostart picks the expansion a
program was made for from its load address ($1001 unexpanded, $0401 +3K,
$1201 +8K or more, $A000 cartridge images run from RAM). Forge builds BASIC
and assembly programs for wherever BASIC starts on the configured VIC-20;
the graphics editors work with the C64 and C128 only. Checked against VICE
with the CNCD demo collection, Bouncing Ball II and Veni Vidi Vic (which
insists on exact 6561 timing), the cc65 sample programs and the
`tests/vic20_test.sh` programs (frame timing, keyboard, memory sizes,
cartridges, disk, tape).

Cartridges (File → Insert cartridge, or autostart the file): VICE `.crt`
images of the generic type, `.prg` files loading at `$A000`/`$B000` (or 16K /
32K images at `$2000`/`$4000`/`$6000`), headerless `.bin` / `.rom` / `.a0`
images, and split images such as `game-6000.prg` + `game-a000.prg` (opening
either part loads both). They are placed like VICE places them (16K images
go to their block plus `$A000`, 4K images are mirrored) and the machine is
reset, so the KERNAL starts the cartridge from its `A0CBM` signature.
**Mega-Cart** images (a raw 2 MB `.bin` or a VICE `.crt` of that type) get
the cartridge's ROM banks, 32K RAM and 8K NVRAM, with the bank registers at
`$9C80`/`$9D00`/`$9D80` and the software reset at `$9E00` as in VICE (the
NVRAM lasts until the emulator quits). **Final Expansion 3** images (a
raw 512K flash image or a VICE `.crt`) get its 512K RAM and 512K flash
(an AM29F040B that can be programmed and erased, like in VICE; changes are
not written back to the file) with the registers at `$9C02`/`$9C03` and
all the RAM / ROM modes. `tests/vic20_fe.asm` and the Mega-Cart test give
the same results here as in VICE. Input →
*VIC-20 light pen on the mouse* turns the mouse into a light pen: while
the left button is held (pen against the screen) the VIC latches the beam
position into `$9006`/`$9007` when the beam passes the pen, and the pen's
switch shows on the fire line. Snapshots (Machine menu, Shift+F9 /
Shift+F10) work on the VIC-20 too, including the RAM expansion and a
cartridge, Mega-Cart or Final Expansion.

**Paddles** (VIC-20 and C64; Input menu or `--paddles mouse|joystick`):
on the mouse, the position over the picture turns the two paddles (left /
right and up / down; moving right or down lowers the value, as in VICE)
and the left / right button are their fire buttons; on the joystick
(keys or a game controller), left / right turn paddle 1, up / down
paddle 2 and fire is paddle 1's button. The VIC-20 reads them at
`$9008`/`$9009`; on the C64 they are in the joystick port setting and
read through the SID at `$D419`/`$D41A` when CIA1 selects that port. While
paddles are on, the joystick lines carry only the paddle buttons (left =
paddle 1, right = paddle 2), as with real paddles.

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
`roms/drives/dos1541.bin` (next to `bin/`), `roms/drives/1541-II.251968-03.bin`
(see [ROMs](#roms)); `dos1541.bin` is `1541-c000.325302-01.bin` followed by
`1541-e000.901229-05.bin`.

**1571** (File menu or `--drive 1571`; needs `1571-rom.310654-05.bin` in
`roms/drives/`, see [ROMs](#roms)): the C128's drive with its 32 KB DOS, 1/2 MHz CPU clock,
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

The C128's Z80 boots CP/M Plus from the Commodore CP/M system disk (a D64,
not included; the latest version, `cpm.system.622-3297432`, 28 May 87,
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

## Forge: assembler and debugger

`bin/adac64-forge [file]` starts Forge (`bin/adac64 --forge` does the
same): an IDE as the main window, with the emulator in its own window as
the machine your programs run on (F12 brings it up; closing Forge
quits). `bin/adac64` alone is just the emulator. Forge is a 6502 editor with syntax highlighting (GtkSourceView), an
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
When a breakpoint, watchpoint, step or pause stops the machine, Forge
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
    !pseudopc $1000 { ... }  ; assembled for $1000, placed here (copied later)

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

In Forge, File → New BASIC program (Ctrl+Shift+N) gives a BASIC tab;
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

Forge → Tools → Sprite editor (Ctrl+E), or open a `.spr` file. A set holds
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

### Charset editor

Forge → Tools → Charset editor (Ctrl+K), or open a `.chr` / `.64c` file.
It starts from the C64 character ROM (*ROM* / *ROM lower* reload the upper
or lower case set). Click a character in the set (or move with the cursor
keys) and draw it in the 8 x 8 grid like a sprite; pens are background,
character colour, `$D022` and `$D023`; M switches multicolour (double-wide
pixels, character colours 0-7). Clear, invert, flip, rotate, shift,
copy/paste and undo work on the current character. The preview renders
your own text and the alphabet with the charset, plus the character tiled
to see how it joins up.

*Show in emulator* copies the charset to `$3000` and points the VIC at it,
so the text screen at READY shows it; with *Live in emulator* every stroke
appears on the C64 screen immediately. *Grab from emulator* takes the
charset the running program uses (ROM or RAM, any VIC bank) together with
its multicolour mode and colours. `.chr` files are the raw 2048 bytes
(`!binary "font.chr"` at a 2 KB boundary); *Export .asm* writes one `!byte`
line per character.

### Screen editor

Forge → Tools → Screen editor (Ctrl+R), or open a `.scr` file: a 40 x 25
text screen with a colour per cell, drawn with the charset of the charset
editor (the two share it, so redrawn characters show up at once; *ROM
upper* / *ROM lower* switch to the built-in sets). Pick a character from
the 16 x 16 table and a colour, then use the tools: *Draw* (right button
draws spaces), *Colour* (colours only), *Fill*, *Text* (click a cell and
type; lower case gives normal letters, R toggles reverse), *Pick*
(eyedropper), *Copy area* (drag) and *Paste area* (click). The status line
shows the cell under the mouse with its screen address. Undo is Ctrl+Z,
G toggles a grid. Multicolour charsets are shown as the VIC shows them
(cells with colours 8-15).

*Show in emulator* / *Live in emulator* put the screen (and, with *with
charset*, the charset) on the C64's display; *Grab from emulator* takes a
running program's text screen together with its charset and colours.
`.scr` files hold 1000 screen codes, 1000 colours, border and background
(2002 bytes; plain 1000-byte screens load too); *Export .asm* writes
`name_chars` / `name_colors` tables and the two colours as constants.

### Disk images

Build → Build disk image (Shift+F7) builds the program and writes
`<main>.d64` next to the source; Build → Build disk and run from disk
(Shift+F5) also puts it in drive 8 and autostarts it, so the program is
loaded through the emulated 1541 like a released disk. By default the
disk holds just the program. Build → Edit disk contents creates
`<main>.disk`, a small text file listing what goes on the disk:

    name = "MY GAME"
    id   = 01
    "my game" = *                      ; the program the build makes
    "music"   = music.prg
    "level 1" = levels/level1.bin, seq ; prg (default), seq or usr

Files are laid out as a 1541 writes them (tracks next to the directory
first, sector interleave 10), and errors in the list are reported with
their line like assembler errors. On the command line,
`bin/adac64 --mkd64 disk.d64 a.prg b.prg notes.seq` does the same (names
from the file names); `tests/disk_test.sh` checks the files and BAM of
such a disk and loads the program from it through the emulated drive.

### Bitmap editor

Forge → Tools → Bitmap editor (Ctrl+B), or open a Koala (`.kla`, `.koa`),
Art Studio (`.art`) or Doodle (`.dd`) picture. Pictures stay in the C64's
own format, so the VIC-II's limits always hold: hires is 320 x 200 with
two colours per 8 x 8 cell, multicolour 160 x 200 (double-wide pixels)
with the background plus three colours per cell. Painting a colour a cell
has no room for replaces the cell's least-used colour (reported as a
colour clash). The status line shows the colours of the cell under the
mouse; G shows the cell grid.

Left and right button paint with two colours (pick them by clicking the
palette with that button); tools: pencil, line, fill and pick. Switching
between hires and multicolour converts the picture. *Import image* (or
opening a `.png` / `.jpg` / `.gif` in Forge) scales a photo to fit,
reduces it to the 16 colours (optionally with Floyd-Steinberg dithering)
and picks the best colours per cell.

*Save* writes Koala for multicolour and Art Studio for hires; *Export
.asm* writes a complete program that shows the picture (F5 in Forge runs
it), *Export PNG* a 320 x 200 image. *Show in emulator* / *Live* display
the picture on the C64 (bitmap at `$2000`), *Grab from emulator* takes the
bitmap a running program shows. `tests/bitmap_test` assembles the
exported viewer, runs it and checks that the VIC-II shows exactly the
editor's picture in both modes.

### Forge on the C128

Forge works with the emulator in either mode (`bin/adac64-forge --c128`).
BASIC tabs are tokenized as BASIC 7.0 at `$1C01`, new assembly programs
start at `$1C01` with their BASIC line, and Run types RUN (programs at
other addresses get `SYS`). Breakpoints, stepping and watchpoints work on
the 8502 (not on the Z80). The editors' *Show in emulator* sets GRAPHM
(`$D8`) to `$FF` first, so the C128 KERNAL stops rewriting the VIC
registers every frame; sprites are shown from `$0E00`. The 80-column VDC
screen is not covered by the editors.

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

F9 autostart dialog, F10 toggle 40/80 view, F11 warp, F12 soft reset (the
reset button: RAM is kept), Ctrl+F12 hard reset (power off and on),
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
    src/vic_i.*      VIC-20 VIC (6560/6561) with its sound
    src/cia.*        CIA           src/vdc.*      VDC
    src/machine.*    memory maps, I/O, MMU, KERNAL traps, frame loop
    src/crt.*        CRT cartridge files
    src/reu.*        RAM Expansion Unit
    src/tape.*       Datasette / TAP images
    src/media.*      D64/T64/PRG images, fast-load traps, host directory
    src/drive1541.*  1541/1571 drive: CPU, VIAs, CIA, WD1770, GCR surface
    src/via.*        6522 VIA       src/iec.ads    serial bus lines
    src/keyboard.*   matrix and host key mapping
    src/paddles.*    paddles on the mouse or joystick
    src/audio.*      PulseAudio output    src/gui.*  GtkAda front end
    src/monitor*.*   machine-code monitor src/disasm.* disassembler
    src/asm.*        6502 assembler (ACME syntax)
    src/basic.*      BASIC V2 / 7.0 tokenizer and lister
    src/forge.*      Forge window    src/source_view.*  GtkSourceView binding
    src/sprite_*     sprite editor (data model / window)
    src/charset_*    charset editor (data model / window)
    src/screen_*     screen editor (data model / window)
    src/bitmap_*     bitmap editor (data model / window)
    src/disk_image.* D64 writer
    share/adac64/    6502 syntax highlighting (language-specs/*.lang)
    tests/           CPU, keyboard, debugger, sprite, charset, screen,
                     bitmap,
                     BASIC and disk tests,
                     mkd64.py image builder
    tests/tools/     batch game runner, 6502 disassembler, D64/G64 readers,
                     mkd71.py double-sided image builder, mktap.py
                     KERNAL-format TAP encoder
