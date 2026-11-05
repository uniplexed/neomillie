# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The small ROM sets of sim/top and sim/topcd: python tools/make_test_roms.py [--cd] OUTDIR

No part of it comes from a Neo Geo ROM. Each word is hexadecimal, big
endian from the file's bytes as the APF bridge sends them: {b0, b1, b2, b3}. Files are sparse: only
what the program reads goes over the bridge.

bios   68000 program: work RAM, the ROM zones, palette, video RAM, a Z80 handshake, VBlank interrupts
p      P1 and two P2 banks, marker words
sfix   fix tile 1, srom the same tile with its pixels mirrored
c      sprite tile 1, one colour per column
lo     identity vertical shrink table for full size sprites
m1     Z80 program: its RAM, the handshake on NMI, and an ADPCM-A sample
v      the ADPCM-A sample

The bench holds its own copy of the numbers it checks (addresses, markers, palette words): a mismatch
fails it. Everything goes into one file, loads.hex, a bridge address and a word per line, in slot order.

--cd is the set of sim/topcd: a 512 KB addressed BIOS, whose last word is there as the core waits for it,
and LO. Its program, see bios_cd, holds the Z80 program and the fix tile it uploads.
"""
import pathlib
import struct
import sys

MBOX = 0x10FF00     # the program's progress: 1..6 in order, 0xE0xx if a check failed
VBL_COUNT = 0x10FF04
P1_COPY = 0x10FF06
P1_MAGIC, P2_MAGIC0, P2_MAGIC1 = 0x1357, 0x2468, 0x7531
Z80_CMD = 0x42
FIX_COL, FIX_ROW = 5, 10
SPR_X, SPR_Y = 100, 100


def pal_word(pal, i):
    """Palette entries the program writes, one colour for each index of palettes 1 and 2."""
    if pal == 1:
        return (i << 8) | ((15 - i) << 4) | 5
    return (i << 4) | (15 - i) | 0x300


class Asm:
    """Just enough of a 68000 assembler: words in order, 16-bit branches, labels in a second pass."""

    def __init__(self, base):
        self.base, self.words, self.labels, self.fix = base, [], {}, []

    def here(self):
        return self.base + 2 * len(self.words)

    def w(self, *ws):
        self.words += [w & 0xFFFF for w in ws]

    def long(self, v):
        self.w(v >> 16, v)

    def label(self, name):
        self.labels[name] = self.here()

    def branch(self, op, name):
        self.w(op)
        self.fix.append((len(self.words), name))
        self.w(0)

    def org(self, addr):
        self.w(*[0x4E71] * ((addr - self.here()) // 2))

    def done(self):
        for i, name in self.fix:
            self.words[i] = (self.labels[name] - (self.base + 2 * i)) & 0xFFFF
        return self.words

    # Instructions, named as in the source of a 68000 program
    def move_w_imm(self, v, a): self.w(0x33FC, v); self.long(a)
    def move_b_imm(self, v, a): self.w(0x13FC, v); self.long(a)
    def move_l_imm(self, v, a): self.w(0x23FC); self.long(v); self.long(a)
    def cmp_w_imm(self, v, a): self.w(0x0C79, v); self.long(a)
    def cmp_b_imm(self, v, a): self.w(0x0C39, v); self.long(a)
    def cmp_l_imm(self, v, a): self.w(0x0CB9); self.long(v); self.long(a)
    def bne(self, n): self.branch(0x6600, n)
    def beq(self, n): self.branch(0x6700, n)
    def bra(self, n): self.branch(0x6000, n)
    def bsr(self, n): self.branch(0x6100, n)
    def dbf_d1(self, n): self.branch(0x51C9, n)
    def rts(self): self.w(0x4E75)
    def rte(self): self.w(0x4E73)
    def nop(self, n=1): self.w(*[0x4E71] * n)
    def kick(self): self.w(0x13C0); self.long(0x300001)                 # MOVE.B D0,$300001
    def lea_a0(self, a): self.w(0x41F9); self.long(a)
    def tst_w_a0p(self): self.w(0x4A58)
    def addq_w_1(self, a): self.w(0x5279); self.long(a)
    def tas(self, a): self.w(0x4AF9); self.long(a)
    def move_w_d1_imm(self, v): self.w(0x323C, v)
    def move_b_to_d0(self, a): self.w(0x1039); self.long(a)
    def move_b_from_d0(self, a): self.w(0x13C0); self.long(a)
    def move_b_abs_abs(self, src, dst): self.w(0x13F9); self.long(src); self.long(dst)
    def move_w_abs_abs(self, src, dst): self.w(0x33F9); self.long(src); self.long(dst)
    def btst_5_abs(self, a): self.w(0x0839, 5); self.long(a)
    def move_w_abs_d0(self, a): self.w(0x3039); self.long(a)
    def cmp_w_d0_abs(self, a): self.w(0xB079); self.long(a)
    def move_sr(self, v): self.w(0x46FC, v)
    # The CD program's, only the registers it uses
    def lea_a1(self, a): self.w(0x43F9); self.long(a)
    def move_w_d0_imm(self, v): self.w(0x303C, v)
    def move_w_d2_imm(self, v): self.w(0x343C, v)
    def move_w_d2_abs(self, a): self.w(0x3439); self.long(a)
    def addq_w_1_d0(self): self.w(0x5240)
    def addq_w_1_d2(self): self.w(0x5242)
    def cmp_w_d2_abs(self, a): self.w(0xB479); self.long(a)
    def dbf_d2(self, n): self.branch(0x51CA, n)
    def move_d1_a0p(self): self.w(0x30C1)                               # MOVE.W D1,(A0)+
    def copy_a0p_a1p(self): self.w(0x32D8)                              # MOVE.W (A0)+,(A1)+
    def cmpm_a0p_a1p(self): self.w(0xB348)                              # CMPM.W (A0)+,(A1)+
    def move_d0_pda0(self): self.w(0x3100)                              # MOVE.W D0,-(A0)
    def move_a0p_d1(self): self.w(0x3218)                               # MOVE.W (A0)+,D1
    def cmp_w_d0_d1(self): self.w(0xB240)                               # CMP.W D0,D1
    def tst_w_d1(self): self.w(0x4A41)
    def push_regs(self): self.w(0x48E7, 0xE0C0)                         # MOVEM.L D0-D2/A0-A1,-(SP)
    def pop_regs(self): self.w(0x4CDF, 0x0307)                          # MOVEM.L (SP)+,D0-D2/A0-A1
    def btst_4_d0(self): self.w(0x0800, 4)
    def move_d0_a0p_b(self): self.w(0x10C0)                             # MOVE.B D0,(A0)+
    def move_a0p_abs_b(self, a): self.w(0x13D8); self.long(a)           # MOVE.B (A0)+,addr
    def add_a0p_d0_b(self): self.w(0xD018)                              # ADD.B (A0)+,D0
    def not_d0_b(self): self.w(0x4600)
    def andi_f_d0_b(self): self.w(0x0200, 0x000F)
    def cmp_a0_d0_b(self): self.w(0xB010)                               # CMP.B (A0),D0
    def moveq_d0(self, v): self.w(0x7000 | v)
    def moveq_d1(self, v): self.w(0x7200 | v)


def vram_set(a, addr, *data):
    a.move_w_imm(addr, 0x3C0000)
    for d in data:
        a.move_w_imm(d, 0x3C0002)
        a.nop(4)    # the LSPC takes a write in its own time


def bios():
    a = Asm(0xC00000)
    a.long(0x0010F300)
    a.long(0xC00402)
    vectors = {25: "vbl", 26: "irq_rte", 27: "irq_rte"}
    vec_at = len(a.words)
    for n in range(2, 64):
        a.w(0, 0)
    a.org(0xC00402)
    a.label("entry")
    a.kick()
    a.move_w_imm(7, 0x3C000C)

    # Work RAM as reset left it (the bench looks at every word, this is the CPU's view)
    a.lea_a0(0x100000)
    a.move_w_d1_imm(15)
    a.label("clear_lo")
    a.tst_w_a0p()
    a.bne("fail_clear")
    a.dbf_d1("clear_lo")
    a.lea_a0(0x10FFE0)
    a.move_w_d1_imm(15)
    a.label("clear_hi")
    a.tst_w_a0p()
    a.bne("fail_clear")
    a.dbf_d1("clear_hi")
    a.move_w_imm(1, MBOX)

    # Word, byte lanes, long, read-modify-write, stack
    a.move_w_imm(0x1234, 0x100000)
    a.move_w_imm(0x5678, 0x108000)
    a.cmp_w_imm(0x1234, 0x100000)
    a.bne("fail_ram")
    a.cmp_w_imm(0x5678, 0x108000)
    a.bne("fail_ram")
    a.move_b_imm(0xAA, 0x100100)
    a.move_b_imm(0x55, 0x100101)
    a.cmp_w_imm(0xAA55, 0x100100)
    a.bne("fail_ram")
    a.cmp_b_imm(0x55, 0x100101)
    a.bne("fail_ram")
    a.move_l_imm(0xDEADBEEF, 0x100104)
    a.cmp_l_imm(0xDEADBEEF, 0x100104)
    a.bne("fail_ram")
    a.addq_w_1(0x100100)
    a.cmp_w_imm(0xAA56, 0x100100)
    a.bne("fail_ram")
    a.tas(0x100200)
    a.cmp_b_imm(0x80, 0x100200)
    a.bne("fail_ram")
    a.bsr("sub")
    a.cmp_w_imm(0x0F0F, 0x100300)
    a.bne("fail_ram")
    a.move_w_imm(2, MBOX)

    # P1 and P2 through the mux
    a.cmp_w_imm(P1_MAGIC, 0x000200)
    a.bne("fail_rom")
    a.cmp_w_imm(P2_MAGIC0, 0x200100)
    a.bne("fail_rom")
    a.move_b_imm(1, 0x2FFFF1)
    a.cmp_w_imm(P2_MAGIC1, 0x200100)
    a.bne("fail_rom")
    a.move_b_imm(0, 0x2FFFF1)
    a.move_w_imm(3, MBOX)

    # Palette
    for pal, n in ((1, 9), (2, 16)):
        for i in range(1, n):
            a.move_w_imm(pal_word(pal, i), 0x400000 + (pal * 16 + i) * 2)
    a.cmp_w_imm(pal_word(2, 15), 0x400000 + (2 * 16 + 15) * 2)
    a.bne("fail_pal")
    a.move_w_imm(4, MBOX)

    # Video RAM: two fix tiles and one sprite one tile high
    fix_at = 0x7000 + FIX_COL * 32 + FIX_ROW
    a.move_w_imm(1, 0x3C0004)
    vram_set(a, fix_at, 0x1001)
    vram_set(a, fix_at + 32, 0x1001)
    vram_set(a, 0x0040, 0x0001, 0x0200)
    vram_set(a, 0x8001, 0x0FFF)
    vram_set(a, 0x8201, ((496 - SPR_Y) << 7) | 1)
    vram_set(a, 0x8401, SPR_X << 7)
    a.move_w_imm(fix_at, 0x3C0000)
    a.nop(8)
    a.cmp_w_imm(0x1001, 0x3C0002)
    a.bne("fail_vram")
    a.move_w_imm(5, MBOX)

    # Z80: command on the upper lane of $320000, the reply is the command plus one
    a.move_b_imm(Z80_CMD, 0x320000)
    a.move_w_d1_imm(0x7FFF)
    a.label("z80_wait")
    a.kick()
    a.cmp_b_imm(Z80_CMD + 1, 0x320000)
    a.beq("z80_ok")
    a.dbf_d1("z80_wait")
    a.bra("fail_z80")
    a.label("z80_ok")
    a.move_w_imm(6, MBOX)

    # Run: VBlank interrupts count frames, P1 goes to work RAM, cart fix from the fourth frame
    a.move_sr(0x2000)
    a.label("main")
    a.kick()
    a.move_b_to_d0(0x300000)
    a.move_b_from_d0(P1_COPY)
    a.cmp_w_imm(4, VBL_COUNT)
    a.bne("main")
    a.move_b_imm(0, 0x3A001B)
    a.bra("main")

    a.label("sub")
    a.move_w_imm(0x0F0F, 0x100300)
    a.rts()

    a.label("vbl")
    a.move_w_imm(4, 0x3C000C)
    a.addq_w_1(VBL_COUNT)
    a.rte()

    a.label("irq_rte")
    a.move_w_imm(3, 0x3C000C)
    a.rte()

    for name, code in (("clear", 0xE001), ("ram", 0xE002), ("rom", 0xE003), ("pal", 0xE004),
                       ("vram", 0xE005), ("z80", 0xE006), ("vec", 0xE00F)):
        a.label("fail_" + name)
        a.move_w_imm(code, MBOX)
        a.label("hang_" + name)
        a.kick()
        a.bra("hang_" + name)

    words = a.done()
    # Vectors: everything to fail_vec but the three interrupt levels
    for n in range(2, 64):
        target = a.labels[vectors.get(n, "fail_vec")]
        i = vec_at + (n - 2) * 2
        words[i], words[i + 1] = target >> 16, target & 0xFFFF
    return words


def words_le(words):
    """A 68000 ROM file holds each word low byte first: {b1, b0} is the word the core reads."""
    return b"".join(struct.pack("<H", w) for w in words)


def prom():
    """Sparse: only the words the program reads. Returns (file offset, bytes) pieces."""
    return [(0x000200, words_le([P1_MAGIC, 0])), (0x100100, words_le([P2_MAGIC0, 0])),
            (0x200100, words_le([P2_MAGIC1, 0]))]


def fix_rom(colours):
    """Tile 1 in the file's layout (MAME's charlayout): each row is four bytes, at 0x10, 0x18, 0x00 and
    0x08 from the tile's start, low nibble on the left."""
    tile = bytearray(32)
    for y in range(8):
        for byte_at, x in ((0x10, 0), (0x18, 2), (0x00, 4), (0x08, 6)):
            tile[byte_at + y] = colours[x] | (colours[x + 1] << 4)
    return bytes(32) + bytes(tile)


def c_rom():
    """Tile 1 of 128 bytes, in the file's layout (MAME's optimize_sprite_data): each row is four plane
    bytes at 0x40 for pixels 0..7 and four at 0x00 for pixels 8..15, bit 0 on the left. A pixel's colour
    is its column plus one, 16 being colour 0, except the first row, all colour 1."""
    tile = bytearray(128)
    for y in range(16):
        for x in range(16):
            colour = 1 if y == 0 else (x + 1) & 15
            base = (0x40 if x < 8 else 0x00) | (y << 2)
            for plane in range(4):
                tile[base + plane] |= ((colour >> plane) & 1) << (x & 7)
    return bytes(128) + bytes(tile) + bytes(256)


def z80():
    """Instructions as bytes: what sim/top/t80pa_model.sv can run."""
    rom = bytearray(512)
    rom[0x00:0x06] = bytes([0x31, 0xFC, 0xFF, 0xC3, 0x00, 0x01])            # LD SP,FFFC; JP 0100
    rom[0x66:0x6E] = bytes([0xDB, 0x00, 0xC6, 0x01, 0xD3, 0x0C, 0xED, 0x45])  # IN A,(0); ADD A,1; OUT (C),A; RETN
    main = [0x3E, 0x5A, 0x32, 0x00, 0xF8, 0x3E, 0x00, 0x3A, 0x00, 0xF8,     # RAM: LD (F800),A and back
            0xFE, 0x5A, 0x20, 0xFE,                                         # hang here if it differs
            0xD3, 0x08]                                                     # OUT (8),A: NMI on
    # ADPCM-A channel 1, 256 bytes from V ROM 0: end address, start address, levels, key on
    for reg, val in ((0x20, 0x00), (0x28, 0x00), (0x10, 0x00), (0x18, 0x00), (0x01, 0x3F), (0x08, 0xDF), (0x00, 0x01)):
        main += [0x3E, reg, 0xD3, 0x06, 0x3E, val, 0xD3, 0x07]
    main += [0x18, 0xFE]                                                    # JR $
    rom[0x100:0x100 + len(main)] = bytes(main)
    return bytes(rom)


# ---- The CD set ----

TX_BUF, RX_BUF = 0x10FF10, 0x10FF20     # the 10 nibbles to the drive and from it
CDD_COUNT = 0x10FF30                    # exchanges done
PLAY_REQ = 0x10FF44                     # the bench's: 1 PLAY again, 2 TRACK_PLAY 02, 3 read the card, 4 read FF011C
SECTOR_WORDS = 0x10FF46                 # the bench's: the words sector 16 holds on the disc that is in
CARD_SAVE = 0x10FF48                    # the card's first two and last two bytes, as the 68K read them
CARD_BYTES = (0x800001, 0x800003, 0x803FFD, 0x803FFF)
SYS_CONFIG = 0x10FF50                   # FF011C as the 68K read it: the lid or CDZ bit, 12, and the region, 11 to 8
CD_COMM_STOP, CD_COMM_TOC, CD_COMM_PLAY, CD_COMM_TRACK_PLAY, CD_COMM_TRAY_CLOSE = 0x1, 0x2, 0x3, 0xB, 0xC
CD_STAT_STOP, CD_STAT_TOC, CD_STAT_NO_DISC = 0x0, 0x9, 0xB
DISC_TRACKS = 3                         # tools/make_test_disc.py's
CRC_START = 5


def fix_tile():
    """The tile of fix_rom on its own: colours 1 to 8 from the left, tile 0 of the FIX RAM."""
    return fix_rom([1, 2, 3, 4, 5, 6, 7, 8])[32:]


def cdd_msg(*nibbles):
    """10 nibbles: the ones given, padded to nine, and the check nibble."""
    n = list(nibbles) + [0] * (9 - len(nibbles))
    return n + [~(CRC_START + sum(n)) & 0xF]


def cdd_cmd(code, sub=0):
    """The command, TOC's sub-command in the fourth nibble."""
    return cdd_msg(code, 0, 0, sub)


def set_tx(a, nibbles):
    a.move_sr(0x2700)   # the interrupt sends these: never half of them
    for i, v in enumerate(nibbles):
        a.move_b_imm(v, TX_BUF + i)
    a.move_sr(0x2000)


def wait_exchange(a, name):
    a.move_w_d2_abs(CDD_COUNT)
    a.addq_w_1_d2()
    a.label(name)
    a.kick()
    a.cmp_w_d2_abs(CDD_COUNT)
    a.bne(name)


def cdd_command(a, name, nibbles):
    """One exchange sends it and, with the drive's answer latched, the next brings its status."""
    set_tx(a, nibbles)
    wait_exchange(a, name + "_sent")
    set_tx(a, cdd_cmd(0))
    wait_exchange(a, name + "_read")


def prog_checks(a, name, at):
    """Word, byte lanes, long, read-modify-write and TAS at one PROG RAM address, then a write and a read of
    one word with nothing on the bus between them: MOVE to -(An) fetches ahead of its write, and the next
    MOVE starts with its read."""
    a.move_w_imm(0x1234, at)
    a.cmp_w_imm(0x1234, at)
    a.bne("fail_prog")
    a.move_b_imm(0xAA, at)
    a.move_b_imm(0x55, at + 1)
    a.cmp_w_imm(0xAA55, at)
    a.bne("fail_prog")
    a.cmp_b_imm(0x55, at + 1)
    a.bne("fail_prog")
    long_at = min(at, 0x1FFFFC)
    a.move_l_imm(0xDEADBEEF, long_at)
    a.cmp_l_imm(0xDEADBEEF, long_at)
    a.bne("fail_prog")
    a.move_w_imm(0xAA55, at)
    a.addq_w_1(at)
    a.cmp_w_imm(0xAA56, at)
    a.bne("fail_prog")
    a.move_w_imm(0, at)
    a.tas(at)
    a.cmp_b_imm(0x80, at)
    a.bne("fail_prog")
    a.lea_a0(at + 2)
    a.move_w_d0_imm(0x5555)
    a.move_w_d2_imm(63)
    a.label(name)
    a.move_d0_pda0()
    a.move_a0p_d1()
    a.cmp_w_d0_d1()
    a.bne("fail_prog")
    a.addq_w_1_d0()
    a.dbf_d2(name)


def bios_cd():
    """The CD program. 1 to 6 are the cart program's where the CD has the same thing: 3 is the P1 zone, RAM
    here, and 6 the memory card, as the Z80 waits for its upload. Then 7 PROG RAM, 8 a copy within it, the
    gate's phase, 9 FIX upload, 10 Z80 upload and the handshake, 11 and 12 the drive, which end here with no disc.
    With a disc: 13 STOP, PLAY at 00:02:16 (LBA 16), a wait for the LC8951's HEAD registers to hold it, a DMA of
    the sector to 0x120000 and the words compared; 14 TRACK_PLAY 02 and about 20 of the drive's ticks. Then, each
    time the bench writes PLAY_REQ: 1 a PLAY again, and 13; 2 TRACK_PLAY 02, and 15; 3 the card's ends read, and 16;
    4 FF011C read into SYS_CONFIG, and 17."""
    a = Asm(0xC00000)
    a.long(0x0010F300)
    a.long(0xC00402)
    vectors = {22: "cdd_irq", 25: "irq_rte", 26: "vbl"}     # cd.sv: CD comm, timer, VBlank
    vec_at = len(a.words)
    for n in range(2, 64):
        a.w(0, 0)
    a.org(0xC00402)
    a.label("entry")
    a.kick()
    a.move_w_imm(7, 0x3C000C)
    a.move_w_imm(1, MBOX)

    a.move_w_imm(0x1234, 0x100000)
    a.move_w_imm(0x5678, 0x108000)
    a.cmp_w_imm(0x1234, 0x100000)
    a.bne("fail_ram")
    a.cmp_w_imm(0x5678, 0x108000)
    a.bne("fail_ram")
    a.bsr("sub")
    a.cmp_w_imm(0x0F0F, 0x100300)
    a.bne("fail_ram")
    a.move_w_imm(2, MBOX)

    a.move_w_imm(P1_MAGIC, 0x000200)
    a.cmp_w_imm(P1_MAGIC, 0x000200)
    a.bne("fail_rom")
    a.move_w_imm(3, MBOX)

    for i in range(1, 9):
        a.move_w_imm(pal_word(1, i), 0x400000 + (16 + i) * 2)
    a.cmp_w_imm(pal_word(1, 8), 0x400000 + (16 + 8) * 2)
    a.bne("fail_pal")
    a.move_w_imm(4, MBOX)

    a.move_w_imm(1, 0x3C0004)
    vram_set(a, 0x0040, 0x1234)
    a.move_w_imm(0x0040, 0x3C0000)
    a.nop(8)
    a.cmp_w_imm(0x1234, 0x3C0002)
    a.bne("fail_vram")
    a.move_w_imm(5, MBOX)

    # The last byte of the CD's 8 KB card: each word of the zone is a byte of it
    a.move_b_imm(0x5A, 0x803FFF)
    a.cmp_b_imm(0x5A, 0x803FFF)
    a.bne("fail_card")
    a.move_w_imm(6, MBOX)

    prog_checks(a, "tight_lo", 0x100000)
    prog_checks(a, "tight_hi", 0x1FFFFE)
    prog_checks(a, "tight_p1", 0x0F0000)
    a.lea_a0(0x120000)
    a.move_w_d1_imm(1023)
    a.label("seed")
    a.move_d1_a0p()
    a.dbf_d1("seed")
    a.move_w_imm(7, MBOX)

    a.lea_a0(0x120000)
    a.lea_a1(0x130000)
    a.move_w_d1_imm(1023)
    a.label("copy")
    a.copy_a0p_a1p()
    a.dbf_d1("copy")
    a.move_w_imm(8, MBOX)
    a.lea_a0(0x120000)
    a.lea_a1(0x130000)
    a.move_w_d1_imm(1023)
    a.label("compare")
    a.cmpm_a0p_a1p()
    a.bne("fail_copy")
    a.dbf_d1("compare")

    a.move_b_imm(5, 0xFF0105)
    a.move_b_imm(1, 0xFF0129)
    for i, b in enumerate(fix_tile()):
        a.move_b_imm(b, 0xE00001 + 2 * i)
    # What landed, through the 68K's read paths and the top's DTACK holds, with SPR and PCM RAM likewise
    for i, b in enumerate(fix_tile()):
        a.cmp_b_imm(b, 0xE00001 + 2 * i)
        a.bne("fail_win")
    # And by DMA, the way UploadFIXDMABytes does, into tile 1: the words' bytes, high first. FIX_DMA_BYTES of sim/topcd
    other = fix_rom([8, 7, 6, 5, 4, 3, 2, 1])[32:]
    for i in range(0, len(other), 2):
        a.move_w_imm(other[i] << 8 | other[i + 1], 0x140010 + i)
    a.move_w_imm(0x0014, 0xFF0064)
    a.move_w_imm(0x0010, 0xFF0066)
    a.move_w_imm(0x00E0, 0xFF0068)
    a.move_w_imm(0x0040, 0xFF006A)
    a.move_w_imm(0x0000, 0xFF0070)
    a.move_w_imm(len(other) // 2, 0xFF0072)
    a.move_w_imm(0xF2DD, 0xFF007E)
    a.move_b_imm(0x40, 0xFF0061)
    a.nop(8)
    for i, b in enumerate(other):
        a.cmp_b_imm(b, 0xE00041 + 2 * i)
        a.bne("fail_win")
    a.move_b_imm(1, 0xFF0149)
    a.move_b_imm(0, 0xFF0105)
    a.move_b_imm(1, 0xFF0121)
    a.move_w_imm(0xBEEF, 0xE00100)
    a.move_w_imm(0x1234, 0xE00102)
    a.cmp_w_imm(0xBEEF, 0xE00100)
    a.bne("fail_win")
    a.cmp_w_imm(0x1234, 0xE00102)
    a.bne("fail_win")
    a.move_b_imm(1, 0xFF0141)
    a.move_b_imm(1, 0xFF0105)
    a.move_b_imm(1, 0xFF0123)
    a.move_b_imm(0x5A, 0xE00201)
    a.move_b_imm(0xA5, 0xE00203)
    a.cmp_b_imm(0x5A, 0xE00201)
    a.bne("fail_win")
    a.cmp_b_imm(0xA5, 0xE00203)
    a.bne("fail_win")
    # A DMA from PROG RAM into the window, the way UploadPCMDMABytes does: microcode F2DD copies words to bytes
    a.move_w_imm(0xA1B2, 0x140000)
    a.move_w_imm(0xC3D4, 0x140002)
    a.move_w_imm(0x0014, 0xFF0064)
    a.move_w_imm(0x0000, 0xFF0066)
    a.move_w_imm(0x00E0, 0xFF0068)
    a.move_w_imm(0x0300, 0xFF006A)
    a.move_w_imm(0x0000, 0xFF0070)
    a.move_w_imm(0x0002, 0xFF0072)
    a.move_w_imm(0xF2DD, 0xFF007E)
    a.move_b_imm(0x40, 0xFF0061)
    a.nop(8)
    a.move_b_imm(1, 0xFF0143)
    fix_at = 0x7000 + FIX_COL * 32 + FIX_ROW
    vram_set(a, fix_at, 0x1000)
    vram_set(a, fix_at + 32, 0x1000)
    a.move_w_imm(9, MBOX)

    a.move_b_imm(4, 0xFF0105)
    a.move_b_imm(0, 0xFF0183)
    a.move_b_imm(1, 0xFF0127)
    rom = z80()
    for start, end in ((0x00, 0x06), (0x66, 0x6E), (0x100, len(rom.rstrip(b"\0")))):
        for i in range(start, end):
            a.move_b_imm(rom[i], 0xE00001 + 2 * i)
    a.move_b_imm(1, 0xFF0147)
    a.move_b_imm(1, 0xFF0183)
    a.move_w_d1_imm(0x03FF)     # the Z80 enables its NMI after a few instructions
    a.label("z80_start")
    a.dbf_d1("z80_start")
    a.move_b_imm(Z80_CMD, 0x320000)
    a.move_w_d1_imm(0x7FFF)
    a.label("z80_wait")
    a.kick()
    a.cmp_b_imm(Z80_CMD + 1, 0x320000)
    a.beq("z80_ok")
    a.dbf_d1("z80_wait")
    a.bra("fail_z80")
    a.label("z80_ok")
    a.move_w_imm(10, MBOX)

    # The drive stays in reset until FF0181, and only then interrupts
    a.move_w_imm(0, CDD_COUNT)
    set_tx(a, cdd_cmd(0))
    a.move_b_imm(1, 0xFF0181)
    a.move_w_imm(0x0050, 0xFF0002)
    cdd_command(a, "close", cdd_cmd(CD_COMM_TRAY_CLOSE))
    a.cmp_b_imm(CD_STAT_STOP, RX_BUF)
    a.bne("fail_cdd")
    a.lea_a0(RX_BUF)
    a.moveq_d0(CRC_START)
    a.moveq_d1(8)
    a.label("crc")
    a.add_a0p_d0_b()
    a.dbf_d1("crc")
    a.not_d0_b()
    a.andi_f_d0_b()
    a.cmp_a0_d0_b()
    a.bne("fail_cdd")
    a.move_w_imm(11, MBOX)

    cdd_command(a, "toc", cdd_cmd(CD_COMM_TOC, 4))
    a.move_w_imm(0, VBL_COUNT)      # a reset leaves PROG RAM alone
    a.move_w_imm(0, PLAY_REQ)
    a.cmp_b_imm(CD_STAT_NO_DISC, RX_BUF)
    a.beq("no_disc")
    a.cmp_b_imm(CD_STAT_TOC, RX_BUF)
    a.bne("fail_toc")
    a.cmp_b_imm(DISC_TRACKS, RX_BUF + 5)
    a.bne("fail_toc")
    a.move_w_imm(12, MBOX)
    a.move_w_imm(0x0030, 0xFF0004)  # VBlank interrupts count frames

    cdd_command(a, "stop", cdd_cmd(CD_COMM_STOP))
    a.cmp_b_imm(CD_STAT_STOP, RX_BUF)
    a.bne("fail_cdd")
    a.move_b_imm(10, 0xFF0101)      # CTRL0: DECEN, or the HEAD registers do not follow
    a.move_b_imm(0x80, 0xFF0103)
    a.move_w_abs_d0(SECTOR_WORDS)
    a.bsr("play_dma")
    a.move_w_imm(13, MBOX)
    cdd_command(a, "track", cdd_msg(CD_COMM_TRACK_PLAY, 0, 0, 2))
    a.move_w_d1_imm(12)             # 13 exchanges of 15.6 ms: the drive's tick is 10 ms
    a.label("ticks")
    wait_exchange(a, "ticks_x")
    a.dbf_d1("ticks")
    a.move_w_imm(14, MBOX)
    a.bra("main")

    a.label("no_disc")
    a.move_w_imm(12, MBOX)
    a.move_w_imm(0x0030, 0xFF0004)

    a.label("main")
    a.kick()
    a.cmp_w_imm(0, PLAY_REQ)
    a.beq("main")
    a.cmp_w_imm(2, PLAY_REQ)
    a.beq("req_track")
    a.cmp_w_imm(3, PLAY_REQ)
    a.beq("req_card")
    a.cmp_w_imm(4, PLAY_REQ)
    a.beq("req_config")
    a.move_w_imm(0, PLAY_REQ)
    a.move_w_abs_d0(SECTOR_WORDS)
    a.bsr("play_dma")
    a.move_w_imm(13, MBOX)
    a.bra("main")

    a.label("req_track")
    a.move_w_imm(0, PLAY_REQ)
    cdd_command(a, "track_req", cdd_msg(CD_COMM_TRACK_PLAY, 0, 0, 2))
    a.move_w_imm(15, MBOX)
    a.bra("main")

    a.label("req_card")
    a.move_w_imm(0, PLAY_REQ)
    for i, at in enumerate(CARD_BYTES):
        a.move_b_abs_abs(at, CARD_SAVE + i)
    a.move_w_imm(16, MBOX)
    a.bra("main")

    a.label("req_config")
    a.move_w_imm(0, PLAY_REQ)
    a.move_w_abs_abs(0xFF011C, SYS_CONFIG)
    a.move_w_imm(17, MBOX)
    a.bra("main")

    # D0: the words of the sector. The HEAD registers follow the sector the LC8951 has just made ready, so a sector
    # read before this PLAY shows only as long as its flag, 1.8 ms, far shorter than a PLAY's seek
    a.label("play_dma")
    cdd_command(a, "play", cdd_msg(CD_COMM_PLAY, 0, 0, 0, 0, 2, 1, 6))
    a.label("head")
    a.kick()
    a.move_b_imm(1, 0xFF0101)       # IFSTAT: bit 5 low, a sector is ready
    a.btst_5_abs(0xFF0103)
    a.bne("head")
    a.move_b_imm(4, 0xFF0101)
    for b in (0x00, 0x02, 0x16, 0x01):
        a.cmp_b_imm(b, 0xFF0103)
        a.bne("head")
    a.move_w_imm(0x0012, 0xFF0064)
    a.move_w_imm(0x0000, 0xFF0066)
    a.move_w_imm(0x0000, 0xFF0070)
    a.move_w_imm(1024, 0xFF0072)
    a.move_w_imm(0xFF89, 0xFF007E)
    a.move_b_imm(0x40, 0xFF0061)
    a.cmp_w_d0_abs(0x120000 + 1023 * 2)     # the first read after the DMA is its last word
    a.bne("fail_dma")
    a.lea_a0(0x120000)
    a.move_w_d2_imm(15)
    a.label("dma_words")
    a.move_a0p_d1()
    a.cmp_w_d0_d1()
    a.bne("fail_dma")
    a.dbf_d2("dma_words")
    a.rts()

    a.label("sub")
    a.move_w_imm(0x0F0F, 0x100300)
    a.rts()

    a.label("vbl")
    a.move_w_imm(4, 0x3C000C)
    a.addq_w_1(VBL_COUNT)
    a.rte()

    a.label("irq_rte")
    a.move_w_imm(3, 0x3C000C)
    a.rte()

    # The exchange as drive.v takes it: the drive looks at HOCK at 250 kHz and answers on CDCK, bit 4 of
    # FF0161. HOCK low starts it. Ten status nibbles, each on CDCK low, HOCK high, CDCK high, HOCK low.
    # Ten command nibbles the same, except that HOCK stays high after the last, for the next HOCK low.
    a.label("cdd_irq")
    a.push_regs()
    a.move_w_imm(0x0010, 0xFF000E)
    a.move_b_imm(0, 0xFF0165)
    a.lea_a0(RX_BUF)
    a.moveq_d1(9)
    a.label("rx")
    a.move_b_to_d0(0xFF0161)
    a.btst_4_d0()
    a.bne("rx")
    a.move_d0_a0p_b()
    a.move_b_imm(1, 0xFF0165)
    a.label("rx_high")
    a.move_b_to_d0(0xFF0161)
    a.btst_4_d0()
    a.beq("rx_high")
    a.move_b_imm(0, 0xFF0165)
    a.dbf_d1("rx")
    a.lea_a0(TX_BUF)
    a.moveq_d1(9)
    a.label("tx")
    a.move_b_to_d0(0xFF0161)
    a.btst_4_d0()
    a.bne("tx")
    a.move_a0p_abs_b(0xFF0163)
    a.move_b_imm(1, 0xFF0165)
    a.label("tx_high")
    a.move_b_to_d0(0xFF0161)
    a.btst_4_d0()
    a.beq("tx_high")
    a.tst_w_d1()
    a.beq("tx_done")
    a.move_b_imm(0, 0xFF0165)
    a.dbf_d1("tx")
    a.label("tx_done")
    a.addq_w_1(CDD_COUNT)
    a.pop_regs()
    a.rte()

    for name, code in (("ram", 0xE002), ("rom", 0xE003), ("pal", 0xE004), ("vram", 0xE005), ("card", 0xE006),
                       ("prog", 0xE007), ("copy", 0xE008), ("win", 0xE009), ("z80", 0xE00A), ("cdd", 0xE00B), ("toc", 0xE00C),
                       ("dma", 0xE00D), ("vec", 0xE00F)):
        a.label("fail_" + name)
        a.move_w_imm(code, MBOX)
        a.label("hang_" + name)
        a.kick()
        a.bra("hang_" + name)

    words = a.done()
    for n in range(2, 64):
        target = a.labels[vectors.get(n, "fail_vec")]
        i = vec_at + (n - 2) * 2
        words[i], words[i + 1] = target >> 16, target & 0xFFFF
    return words


def write_hex(path, base, data):
    """Bridge address and word, one word per line."""
    data += bytes(-len(data) % 4)
    with open(path, "a") as f:
        for i in range(0, len(data), 4):
            f.write(f"{base + i:08x} {struct.unpack('>I', data[i:i + 4])[0]:08x}\n")


def main(argv):
    cd = "--cd" in argv
    argv = [x for x in argv if x != "--cd"]
    if len(argv) != 1:
        sys.exit("usage: make_test_roms.py [--cd] OUTDIR")
    out = pathlib.Path(argv[0])
    out.mkdir(parents=True, exist_ok=True)
    loads = out / "loads.hex"
    loads.unlink(missing_ok=True)
    if cd:
        write_hex(loads, 0x10A00000, words_le(bios_cd()))
        write_hex(loads, 0x10A7FFFC, bytes(4))
        write_hex(loads, 0x5000FF00, bytes(range(256)))
        print(f"{loads}: {sum(1 for _ in open(loads))} words")
        return 0
    # In the Overdrive's slot order, one bridge address space
    write_hex(loads, 0x10A00000, words_le(bios()))
    write_hex(loads, 0x5000FF00, bytes(range(256)))
    write_hex(loads, 0x10D00000, fix_rom([1, 2, 3, 4, 5, 6, 7, 8]))
    write_hex(loads, 0x10C00000, fix_rom([8, 7, 6, 5, 4, 3, 2, 1]))
    for off, piece in prom():
        write_hex(loads, 0x10000000 + off, piece)
    write_hex(loads, 0x40000000, c_rom())
    write_hex(loads, 0x10F80000, z80())
    write_hex(loads, 0x20000000, bytes([0x07] * 512))
    print(f"{loads}: {sum(1 for _ in open(loads))} words")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
