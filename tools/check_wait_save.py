# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Read the save file of the wait counter: python tools/check_wait_save.py wait.sav

The debug builds neogeo_wait, neogeo8_wait, neogeo8_zbuf and neogeocd_wait write it (rtl/test/wait_counter.sv). The CD
core from 0.5.1 writes waits.sav, 8 records of layout 3 below, one per run, so one file compares several runs. Prints
what the memory cost the 68K, split by what CRAM0 was doing when each read's request arrived. Exit code 0 when
the file is good, whatever the numbers. --selftest runs the checks on made-up files.
Word 1 holds the layout. 1 is the cartridge core, whose owner codes are loader, idle, fix read and Z80 read. 2 is the
CD core up to 0.3.1, 256 bytes, which counts the BIOS and PROG RAM cycles and whose code 0 is the CD write queue. 3 is
the CD core from 0.3.2, 512 bytes: layout 2 with the settings in effect, the drive's last commands, the 68K, the
sector fetch and the DMA's memory path.
"""
import struct
import sys

MAGIC = 0x4E475754
WORDS = 64
WORDS_L3 = 128
PATTERN_OLD = 32        # layouts 1 and 2: the read-lag pattern is words 32-63
PATTERN_L3 = 48         # layout 3: words 48-63, and word 127
RUN_WORD = 105          # the CD core from 0.5.1: the run number. A blank record has no magic word
CLK_HZ = 48_000_000     # near enough for a time in minutes
# Mux owner codes by layout. In the CD core 2 and 3 never happen (no fix or Z80 read on CRAM0): a count there is a fault
CD_ORDER = [(1, "idle"), (0, "CD write queue"), (2, "fix read"), (3, "Z80 read")]
ORDER = {1: [(1, "idle"), (2, "fix read"), (3, "Z80 read"), (0, "loader")], 2: CD_ORDER, 3: CD_ORDER}
CD_WHAT = ("BIOS and PROG RAM cycles", "cycles")
WHAT = {1: ("ROM zone reads", "reads"), 2: CD_WHAT, 3: CD_WHAT}


# cd_defs.svh's status and command, cd_mount.sv's reason_t
DRIVE_STATE = {0x0: "STOP", 0x1: "PLAY", 0x2: "SEEK", 0x3: "SCAN", 0x4: "PAUSE", 0x5: "OPEN", 0x8: "ERROR", 0x9: "TOC",
               0xA: "TRACK MOVE", 0xB: "NO DISC", 0xC: "END", 0xE: "TRAY"}
DRIVE_COMMAND = {0x0: "IDLE", 0x1: "STOP", 0x2: "TOC", 0x3: "PLAY", 0x4: "SEEK", 0x6: "PAUSE", 0x7: "RESUME", 0x8: "FW SCAN",
                 0x9: "RW SCAN", 0xA: "TRACK MOVE", 0xB: "TRACK PLAY", 0xC: "TRAY CLOSE", 0xD: "TRAY OPEN"}
MOUNT_REASON = ("none yet", "mounted", "the slot's size is 0", "a read of the picked file failed",
                "the picked file is neither a CUE nor a MODE1/2352 BIN", "the CUE is too long", "the CUE has a line it can't read, or a FILE that is not BINARY",
                "the CUE has no FILE, or more than one", "a TRACK is out of order, more than 99, or not MODE1/2352 or AUDIO", "no TRACK has an INDEX 01",
                "getfile failed", "the path is too long", "openfile of the BIN failed: its name or folder", "the BIN has no readable sector",
                "a raw BIN with no whole sector")
REGION = {0b10: "US", 0b01: "EU", 0b11: "JP", 0b00: "ASIA"}     # neogeo_pocket.sv's remap, as CD_REGION reads
DMA_TARGETS = ("PROG", "FIX", "SPR", "PCM")
FETCH_FULL_SCALE = (1 << 26) - 1    # cd_fetch.sv's worst host read stops there


def pattern_at(w, first, last):
    """Words the pattern over first..last is shifted by: 0 is clean, None is no pattern found."""
    for shift in range(-4, 5):
        if all(w[i] == 0x5A000000 + i - shift for i in range(first, last)):
            return shift
    return None


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def cd_lines(r):
    """Words 23 to 30 of layouts 2 and 3: how far the BIOS got and what the drive and the transfers did."""
    reason = r[27] >> 28
    return [f"CD drive: last command {(r[23] & 0xFF) << 32 | r[24]:010X}, last status {(r[25] & 0xFF) << 32 | r[26]:010X}, "
            f"drive state {(r[27] >> 24) & 0xF:X} {DRIVE_STATE.get((r[27] >> 24) & 0xF, '?')} at LBA {r[27] & 0xFFFFFF}, disc BIN size {r[30]}",
            f"last mount: {MOUNT_REASON[reason] if reason < len(MOUNT_REASON) else reason}",
            f"since the start: {r[29] & 0xFFFF} CDD exchanges (modulo 65536), {r[28] & 0xFF} failed sectors (modulo 256), "
            f"writes to the transfer area: {r[23] >> 8} FIX, {r[25] >> 8} SPR, {r[28] >> 8} PCM (modulo 2^24), {r[29] >> 16} Z80 (modulo 65536)"]


def bios_model(s):
    """Word 32, bits 8 to 24: what the UniBIOS asked for as its model and region; cores before this field read as none seen."""
    if not (s >> 24) & 1:
        return "no UniBIOS seen (not a UniBIOS, or a core from before this field)"
    wanted, region = (s >> 16) & 0xFF, (s >> 8) & 0xFF
    names = {0: "TOPLOAD", 1: "FRONTLOADER", 2: "CDZ"}
    stored = "CDZ" if s & 1 else "TOPLOAD"
    return f"UniBIOS seen; it last wrote {names.get(wanted, hex(wanted))}, region setting {region}; the core stored {stored}"


def settings_lines(r):
    """Word 32: what was in effect at the last frame, and what the reset's words 33 say."""
    s = r[32]
    cdz, lid, speed, region, lid_dbg, in_reset = s & 1, (s >> 1) & 1, (s >> 2) & 3, (s >> 4) & 3, (s >> 6) & 1, (s >> 7) & 1
    tray = ("closed", "open") if lid else ("open", "closed")
    lines = ["--- Settings in effect at the last frame",
             f"CD/CDZ (SYSTEM_CDZ, taken only in a reset): {'on' if cdz else 'off'}",
             f"FF011C bit 12 (CD_LID) as the BIOS reads it: {lid}, which a top or front loader BIOS takes as tray {tray[0]}, "
             f"and a CDZ BIOS as tray {tray[1]}",
             f"CD Speed (cd_speed): {speed + 1}x; Region (CD_REGION): {REGION[region]}; Lid open (debug, status[15]): {'on' if lid_dbg else 'off'}",
             f"UniBIOS SYSTEM setting: {bios_model(s)}",
             f"resets: {r[33] >> 24} (modulo 256), counting the first start; the last ended at frame {r[33] & 0xFFFFFF}"]
    if in_reset:
        lines.append("at the last frame the core was held in reset, as after Quit: the drive state above reads STOP at LBA 0 "
                     "because of that, and the frame count stopped there. The status and command words keep their values")
    return lines


def sample_lines(r):
    """Words 34 to 37: the 68K at the last 4 VBlanks out of reset, oldest first."""
    lines = ["--- The 68K at the last 4 VBlanks (a sampled address and its bus cycles in that frame, oldest first)"]
    samples = [r[37 - i] for i in range(4)]
    for s in samples:
        lines.append(f"  address {(s & 0x7FFFFF) << 1:06X}, about {((s >> 23) & 0xFF) * 256} bus cycles, {'with' if s >> 31 else 'no'} writes")
    busy = [(s >> 23) & 0xFF for s in samples]
    addrs = {s & 0x7FFFFF for s in samples}
    if not any(samples):
        lines.append("  no frame out of reset was sampled")
    elif not any(busy):
        lines.append("  no bus cycles at all: the 68K is stopped, or the bus is held")
    elif len(addrs) == 1:
        lines.append("  bus cycles and one address each time: it may be in a tight loop, or the samples just landed on it")
    else:
        lines.append("  bus cycles and different addresses: the 68K is running")
    return lines


def valid_frame(v):
    return f"frame {v & 0x7FFFFFFF}" if v >> 31 else "none"


def fetch_lines(r):
    """Words 38 to 47, and 64 and 65 when the file has them."""
    data, audio, hit, miss, worst, busy, late, sink_poll = r[38:46]
    us = worst / (CLK_HZ / 1e6)
    lines = ["--- Sector fetch (cd_fetch)",
             f"sectors requested: {data} data, {audio} audio (modulo 2^24)",
             f"found in the prefetch bank: {hit}; needed a host read: {miss}",
             f"worst host read: {worst} clocks, {us:.0f} us{' or more: the count stopped' if worst >= FETCH_FULL_SCALE else ''}. "
             f"One sector's time is 13,333 us at 1x, 6,667 at 2x, 3,333 at 4x",
             f"requests that arrived with a prefetch read still at the host: {busy}",
             f"late: the drive's poll wanted the next sector with the last unanswered: {late}. No sector is lost: the position moves later",
             f"the drive's poll found the sink full: {sink_poll}. Normal: the poll (10, 5, 4, 2 ms by CD Speed) outruns a sector's time",
             f"first failed sector: {valid_frame(r[46])}; first late sector: {valid_frame(r[47])}"]
    return lines


def command_name(c):
    return DRIVE_COMMAND.get(c & 0xF, f"unknown {c & 0xF:X}")


def check_ok(word):
    """The check nibble: ~(5 + the other nine)."""
    return (~(5 + sum((word >> (4 * i)) & 0xF for i in range(9)))) & 0xF == word >> 36


def ring_lines(r, frames):
    """Words 80 to 104: the last 8 commands, oldest first; from 0.3.4 without TOC. The hex reads right to left: its last digit is nibble 0."""
    lines = [f"--- The drive's last commands other than IDLE and, from 0.3.4, TOC, oldest first ({r[80]} since the start, modulo 2^24)"]
    shown = 0
    for i in reversed(range(8)):
        a, c_lo, s_lo = r[81 + 3 * i:84 + 3 * i]
        cmd = ((a >> 8) & 0xFF) << 32 | c_lo
        ans = (a & 0xFF) << 32 | s_lo
        if cmd == 0:
            continue
        shown += 1
        frame = frames - ((frames - (a >> 16)) & 0xFFFF)
        text = f"  frame {frame}: {command_name(cmd)} {cmd:010X}{'' if check_ok(cmd) else ' BAD CHECK'}"
        if (cmd & 0xF) in (3, 4):
            n = lambda i: (cmd >> (4 * i)) & 0xF    # nibbles 2 to 7 are BCD M M S S F F
            text += f" to {n(2):X}{n(3):X}:{n(4):X}{n(5):X}:{n(6):X}{n(7):X}"
        if ans == 0:
            text += ", not answered yet"
        else:
            text += f", answered {DRIVE_STATE.get(ans & 0xF, '?')} {ans:010X}{'' if check_ok(ans) else ' BAD CHECK'}"
        lines.append(text)
    if not shown:
        lines.append("  none")
    return lines


def dma_lines(r):
    """Words 64 to 79."""
    words, stall = r[66:70], r[70:74]
    lines = ["--- Sector sink and DMA's memory path",
             f"requests that found the sink full after the drive looked: {r[64]}; streams abandoned by a reset: {r[65]}",
             "words a DMA wrote, and the worst time one held the DMA engine (DMA_SDRAM_BUSY), in 96 MHz clocks. "
             "A DMA word takes 20 anyway, so a stall under that costs nothing:"]
    for i, t in enumerate(DMA_TARGETS):
        lines.append(f"  {t:<5} {words[i]:>10} words, worst stall {stall[i]}")
    lines += [f"queue full: the 68K {r[74]} times (it waits, nothing lost), a DMA {r[75]} times (should be 0: it waits on the queue)",
              f"writes lost by a strobe that left a full queue: {r[76]}. Resets that emptied a queue with writes in it: {r[77]}",
              f"DMA writes that reached no memory (outside the window or an area not enabled): {r[78]}",
              f"times the LC8951's cache changed banks during a DMA: {r[79]}. In a DMA from the cache, the rest of it read the next sector"]
    return lines


def hold_line(r):
    """Words 106 to 109, from 0.5.2: the 2x hold in cd.sv, which keeps a sector back while the decoder's interrupt is masked."""
    if r[106] == 0xFFFFFFFF:        # a file of 0.5.1 has 106 words, and the host filled the rest with ones
        return "2x hold: not counted in this file (from 0.5.2)"
    holds, expired, worst, total = r[106:110]
    text = (f"2x hold (sector kept from the decoder while its interrupt is masked): {holds} times, {total / (CLK_HZ / 1e3):.1f} ms in all, "
            f"the longest {worst / (CLK_HZ / 1e3):.1f} ms; ran out at its 50 ms limit {expired} times")
    if expired:
        text += ": the program kept the interrupt masked for 50 ms, and the sector was let through with it masked"
    return text


RUNOUT_UNIT_MS = 32768 / CLK_HZ * 1e3     # the mask time after a run-out counts in 2^15 clocks


def runouts(r):
    """Words 110 to 125, from 0.5.3: the last 8 holds that ran out, oldest first, as (frame, LBA, ms masked after, still masked).
    None for an older file, whose words there are the host's ones."""
    if r[110] == 0xFFFFFFFF and r[111] == 0xFFFFFFFF:
        return None
    out = []
    for i in reversed(range(8)):
        a, b = r[110 + 2 * i], r[111 + 2 * i]
        if a == 0 and b == 0:
            continue
        frame = r[2] - ((r[2] - (a >> 16)) & 0xFFFF)
        out.append((frame, b & 0xFFFFFF, (a & 0xFFFF) * RUNOUT_UNIT_MS, bool(b >> 31)))
    return out


def runout_lines(r):
    got = runouts(r)
    if got is None:
        return ["the hold's run-outs, one by one: not in this file (from 0.5.3)"]
    lines = ["--- The last holds that ran out, oldest first: the sector then went in with the interrupt still masked"]
    for frame, lba, ms, still in got:
        lines.append(f"  frame {frame} ({frame / 60:.1f} s): drive at LBA {lba}, the mask stayed on {ms:.1f} ms more"
                     f"{', and was still on at the last frame' if still else ''}")
    if not got:
        lines.append("  none")
    return lines


def runout_short(r):
    got = runouts(r)
    return "" if not got else " at frames " + " ".join(str(f) for f, *_ in got)


def run_short(r):
    if rev(r) >= 6:
        return f"{r[108]} sectors DMA'd, last offered {header_text(r[109])}, timelines stopped: CD/CDZ off {r[126] >> 1 & 1}, on {r[126] >> 2 & 1}"
    if rev(r) >= 5:
        got = read_writes(r)
        last = f", the last at frame {got[-1][0]}: {QUEUE_VARS[got[-1][1]]}" if got else ""
        stop = "stopped at PLAY 60:58:21" if r[126] & 2 else "no PLAY 60:58:21"
        return f"{r[108]} sectors DMA'd, {r[107]} queue/read writes, {stop}{last}"
    if rev(r) >= 4:
        got = read_writes(r)
        last = f", the last at frame {got[-1][0]}: {READ_VARS[got[-1][1]]}" if got else ""
        return f"{r[108]} sectors DMA'd, last offered {header_text(r[109])}, {r[107]} BIOS read changes{last}"
    if rev(r) >= 3:
        got = bios_writes(r)
        return (f"{r[108]} sectors DMA'd, {r[126] >> 16} late STAT3 reads, special reads ended well {r[109]} (7782 {r[107]}, "
                f"status {r[126] >> 8 & 0xFF:02X}), {sum(1 for _, w, d in got if w == '7778' and d)} special reads started in the last 16 BIOS writes")
    if rev(r) >= 2:
        got = early_reads(r)
        last = f", the last at frame {got[-1][0]}, {got[-1][1]:06X}" if got else ""
        return f"{r[108]} sectors DMA'd, {r[109]} skipped, {r[107]} lost, {r[126]} early reads{last}"
    if rev(r) >= 1:
        got = lost_sectors(r)
        last = f", the last at frame {got[-1][0]}, {header_text(got[-1][1])}" if got else ""
        return f"hold {r[106]}x, {r[108]} sectors DMA'd, {r[109]} skipped, {r[126]} lost{last}"
    return hold_short(r) + runout_short(r)


def hold_short(r):
    if r[106] == 0xFFFFFFFF:
        return "hold not counted"
    return f"hold {r[106]}x, ran out {r[107]}x, longest {r[108] / (CLK_HZ / 1e3):.1f} ms"


def rev(r):
    """Word 1 bits 23:19: 0 up to 0.5.3, where words 108 to 125 are the hold's times and run-outs; 1 in 0.5.4, the sectors and
    the last lost; 2 from 0.5.5, the sectors and the early reads of PROG RAM."""
    return (r[1] >> 19) & 0x1F


def bcd(v):
    return (v >> 4) * 10 + (v & 0xF) if (v >> 4) < 10 and (v & 0xF) < 10 else None


def header_text(h):
    """A sector header as cd.sv keeps it: {mode, frame, second, minute}, BCD, minute in the low byte."""
    m, s, f = bcd(h & 0xFF), bcd((h >> 8) & 0xFF), bcd((h >> 16) & 0xFF)
    if None in (m, s, f):
        return f"header {h:08X}"
    return f"LBA {(m * 60 + s) * 75 + f - 150} ({m:02}:{s:02}:{f:02}, mode {h >> 24})"


def lost_sectors(r):
    """Words 110 to 125, from 0.5.4: the last 8 sectors lost, oldest first, as (frame, header, interrupt reached, dropped)."""
    out = []
    for i in reversed(range(8)):
        a, b = r[110 + 2 * i], r[111 + 2 * i]
        if a == 0 and b == 0:
            continue
        out.append((r[2] - ((r[2] - (a >> 16)) & 0xFFFF), b, bool(a & 2), bool(a & 1)))
    return out


def sector_lines(r):
    taken, skipped, lost = r[108], r[109], r[126]
    lines = [f"sectors the decoder offered: {taken} DMA'd, {skipped} skipped (status read, no DMA), {lost} LOST "
             "(never read: the next sector replaced it in cd.sv's one-sector cache)"]
    got = lost_sectors(r)
    if got:
        lines.append("--- The last sectors lost, oldest first. Interrupt: whether the decoder's reached the 68K's flags, or fell masked and was dropped")
        for frame, h, reached, dropped in got:
            fate = "reached" if reached else "DROPPED, masked" if dropped else "none seen"
            lines.append(f"  frame {frame} ({frame / 60:.1f} s): {header_text(h)}, interrupt {fate}")
    return lines


def early_reads(r):
    """Words 110 to 125, from 0.5.5: the last 16 reads of PROG RAM from a 2 KB block nothing had written since the reset,
    oldest first, as (frame, byte address, by a DMA). Frames are kept modulo 2048 and read as the latest before the file's."""
    out = []
    for i in reversed(range(min(16, r[126]))):
        e = r[110 + i]
        out.append((r[2] - ((r[2] - (e >> 21)) & 0x7FF), (e & 0xFFFFF) << 1, bool(e >> 20 & 1)))
    return out


def early_lines(r):
    lines = [f"sectors the decoder offered: {r[108]} DMA'd, {r[109]} skipped (status read, no DMA), {r[107]} lost",
             f"2x hold: {r[106] >> 16} times, ran out at its 50 ms limit {r[106] & 0xFFFF} times",
             f"reads of PROG RAM ahead of any write to their 2 KB block since the reset: {r[126]} blocks (counted through resets)"]
    got = early_reads(r)
    if got:
        lines.append("--- The last of them, oldest first: what was read there is whatever an earlier run left")
        for frame, addr, dma in got:
            lines.append(f"  frame {frame} ({frame / 60:.1f} s): {addr:06X} by {'a DMA' if dma else 'the 68K'}")
    return lines


QUEUE_VARS = ("$7650/1 queue head, tail", "$7472.. queue entry", "$7688 sectors to come", "$76B6/7 reading, stage",
              "$76C8 sought min:sec", "$76D8/9 CDDA", "$76F6/7 CDDA", "$7E04 flags")


def queue_lines(r):
    h = r[109]
    lines = [f"sectors the decoder offered and the program DMA'd: {r[108]}",
             f"STAT3 reads with the decoder on that found the status no longer valid: {r[126] >> 16}",
             f"2x hold: {r[106] >> 16} times, ran out at its 50 ms limit {r[106] & 0xFFFF} times",
             f"the last sector the decoder offered: {header_text(h)}",
             f"writes kept to the BIOS's queue and read variables: {r[107]}; "
             + ("the log STOPPED at the first PLAY to 60:58:21 (the music)" if r[126] & 2 else "no PLAY to 60:58:21 came: the log ran to the end")]
    got = read_writes(r)
    if got:
        lines.append("--- The last of them, oldest first (byte writes show their byte; queue entries are the BIOS's own codes)")
        for frame, var, ds, data in got:
            val = f"{data >> 8:02X}" if ds == 2 else f"{data & 0xFF:02X}" if ds == 1 else f"{data:04X}"
            side = " (upper byte)" if ds == 2 else " (lower byte)" if ds == 1 else ""
            lines.append(f"  frame {frame} ({frame / 60:.1f} s): {QUEUE_VARS[var]} = {val}{side}")
    return lines


READ_VARS = ("$76C8 sought min:sec", "$76CA sought frame", "$7688 sectors to come", "$76B6/7 reading, stage",
             "$7E04 flags", "FF0002 irq mask", "$7678/9 abort", "$76A6 sectors asked")


def read_writes(r):
    """Words 110 to 125, from 0.5.6 (second build): the last 16 changes the 68K made to the BIOS's sector read variables,
    oldest first, as (frame, variable, byte strobes, data as on the bus). Frames are modulo 2048."""
    out = []
    for i in reversed(range(16)):
        e = r[110 + i]
        if e == 0:
            continue
        out.append((r[2] - ((r[2] - (e >> 21)) & 0x7FF), e >> 18 & 7, e >> 16 & 3, e & 0xFFFF))
    return out


def read_lines(r):
    h = r[109]
    lines = [f"sectors the decoder offered and the program DMA'd: {r[108]}",
             f"STAT3 reads with the decoder on that found the status no longer valid: {r[126] >> 16}",
             f"2x hold: {r[106] >> 16} times, ran out at its 50 ms limit {r[106] & 0xFFFF} times",
             f"the last sector the decoder offered: {header_text(h)}, {'DMA' + chr(39) + 'd' if r[126] & 1 else 'not DMA' + chr(39) + 'd'}",
             f"changes to the BIOS's sector read variables: {r[107]}"]
    got = read_writes(r)
    if got:
        lines.append("--- The last of them, oldest first (byte writes show their byte)")
        for frame, var, ds, data in got:
            val = f"{data >> 8:02X}" if ds == 2 else f"{data & 0xFF:02X}" if ds == 1 else f"{data:04X}"
            lines.append(f"  frame {frame} ({frame / 60:.1f} s): {READ_VARS[var]} = {val}")
    return lines


BIOS_VARS = ("7778", "7698", "777E", "7780")


def bios_writes(r):
    """Words 110 to 125, from 0.5.6: the last 16 writes to the CDZ BIOS's $7778 (special read running), $7698 (stage), and
    $777E/$7780 (special reads that ended well), oldest first, as (frame, variable, data). Frames are modulo 16384."""
    out = []
    for i in reversed(range(16)):
        e = r[110 + i]
        if e == 0:
            continue
        out.append((r[2] - ((r[2] - (e >> 18)) & 0x3FFF), BIOS_VARS[e >> 16 & 3], e & 0xFFFF))
    return out


def bios_lines(r):
    lines = [f"sectors the decoder offered and the program DMA'd: {r[108]}",
             f"STAT3 reads with the decoder on that found the status no longer valid (nVALST back at 1, 1.8 ms after the "
             f"sector; the BIOS drops such a sector): {r[126] >> 16}",
             f"2x hold: {r[106] >> 16} times, ran out at its 50 ms limit {r[106] & 0xFFFF} times",
             "CDZ BIOS protection (work RAM, A5 = $108000), last values written:",
             f"  $777E special reads that ended well: {r[109]}; $7782 drive status count: {r[107]}; "
             f"$7786 status code: {r[126] >> 8 & 0xFF:02X}; $7679 abort flag: {r[126] & 0xFF:02X}",
             "  CPY.TXT's check passes only with both counts nonzero"]
    got = bios_writes(r)
    if got:
        lines.append("--- The last writes to $7778 (special read running), $7698 (stage), $777E/$7780 (count), oldest first")
        for frame, var, data in got:
            lines.append(f"  frame {frame} ({frame / 60:.1f} s): ${var} = {data:04X}")
    return lines


def verdict_lines(r):
    """The two questions the counters are for."""
    lost = r[76]
    lines = ["--- What this says"]
    lines.append(f"DMA data: LOST on the memory path, {lost} writes" if lost else "DMA data: nothing lost on the memory path, as far as the counters can see")
    if r[78]:
        lines.append(f"DMA data: {r[78]} DMA writes went nowhere: look at the area and the upload enables")
    if r[79]:
        lines.append(f"DMA data: {r[79]} cache bank changes in a DMA: if those DMAs read the cache, the BIOS or game got a mix of two sectors")
    if r[47] >> 31:
        lines.append(f"fetch: the host or the stream fell behind the drive from {valid_frame(r[47])}: {r[44]} late polls, worst host read {r[42] / (CLK_HZ / 1e3):.1f} ms")
    else:
        lines.append("fetch: never behind the drive")
    if r[46] >> 31:
        lines.append(f"fetch: sectors failed from {valid_frame(r[46])}: host reads, or a position off the disc")
    if rev(r) >= 6:
        return lines + [f"sectors the decoder offered and the program DMA'd: {r[108]}",
                        f"STAT3 reads with the decoder on that found the status no longer valid: {r[126] >> 16}",
                        f"2x hold: {r[106] >> 16} times, ran out at its 50 ms limit {r[106] & 0xFFFF} times",
                        f"the last sector the decoder offered: {header_text(r[109])}, changes to the BIOS's variables: {r[107]}",
                        "the events are in the timelines at the end of this report"]
    if rev(r) >= 5:
        return lines + queue_lines(r)
    if rev(r) >= 4:
        return lines + read_lines(r)
    if rev(r) >= 3:
        return lines + bios_lines(r)
    if rev(r) >= 2:
        return lines + early_lines(r)
    if rev(r) >= 1:
        return lines + [f"2x hold: {r[106]} times, ran out at its 50 ms limit {r[107]} times"] + sector_lines(r)
    lines.append(hold_line(r))
    return lines + runout_lines(r)


def check(data):
    """Returns (ok, lines)."""
    if len(data) < WORDS * 4:
        return False, [f"file is {len(data)} bytes, expected {WORDS * 4} or {WORDS_L3 * 4}"]
    n = WORDS_L3 if len(data) >= WORDS_L3 * 4 else WORDS
    w = struct.unpack(f">{n}I", data[:n * 4])
    # An old file's pattern starts at 32, and this looks past word 48 too. Layout 3's starts at 48: both are in 52-59
    shift = pattern_at(w, PATTERN_OLD + 4, WORDS - 4)
    new_pattern = shift is None
    if new_pattern:
        shift = pattern_at(w, PATTERN_L3 + 4, WORDS - 4)
    if shift is None:
        return False, ["no counting pattern found: the bridge read path did not work"]
    ok = shift == 0
    lines = ["read lag: none" if ok else f"read lag: FAIL, the pattern is {shift} word(s) off"]
    r = [w[i + shift] if 0 <= i + shift < n else 0 for i in range(n)]
    if r[0] != MAGIC:
        return False, lines + [f"no results: word 0 is {r[0]:08X}. No frame ended before the file was read, or not this core's file"]
    sum64 = lambda i: (r[i] << 32) | r[i + 1]
    total, frames, worst = sum64(4), r[2], r[3]
    reads = {c: sum64(6 + 2 * c) for c in range(4)}
    lost = {c: sum64(14 + 2 * c) for c in range(4)}
    n_all, all_lost = sum(reads.values()), sum(lost.values())
    lines.append(f"RD_WAIT {r[1] >> 24}, {frames} frames, {total} 68K clocks, {total / CLK_HZ / 60:.1f} minutes")
    if r[2] != r[22]:
        lines.append("frame count differs at the two ends: the file was read across a copy, next frame's file will be whole")
        ok = False
    layout = r[1] & 0xFFFF
    if layout not in ORDER:
        return False, lines + [f"layout {layout} is not one this tool knows"]
    if (layout == 3) != new_pattern:
        return False, lines + [f"layout {layout} with the read-lag pattern of the other layouts: not a file this tool knows"]
    c1_wait = (r[1] >> 16) & 7
    if c1_wait:
        lines.append(f"WARNING: this game sets C1 wait states ({c1_wait:03b}): lost clocks include the console's own")
    what, unit = WHAT[layout]
    lines.append(f"{what}: {n_all}. Lost {all_lost} clocks, {pct(all_lost, total):.3f}% of all 68K clocks, "
                 f"{pct(all_lost / 4, n_all):.2f}% of {unit} took a wait state")
    frame = total / frames if frames else 0
    lines.append(f"worst frame: {worst} lost clocks, {pct(worst, frame):.3f}% of a frame; "
                 f"the average frame {all_lost / frames if frames else 0:.0f}")
    lines.append(f"{'CRAM0 at arrival':<17}{unit:>10}    share  lost clocks  share of lost {'waits per ' + unit[:-1]:>16}")
    if layout != 1:
        lines.append("  (a write has no 68K read request of its own: it counts under the last read's code)")
    for code, name in ORDER[layout]:
        lines.append(f"  {name:<14} {reads[code]:>10} {pct(reads[code], n_all):>7.2f}% {lost[code]:>12} "
                     f"{pct(lost[code], all_lost):>12.2f}% {pct(lost[code] / 4, reads[code]):>13.2f}%")
    if layout != 1:
        lines += cd_lines(r)
    lines.append(f"slot writes while running: {r[31] & 0xFFFF}, last error {(r[31] >> 16) & 7}")
    if layout == 2:
        lines.append("this is an old file, layout 2, of a CD core up to 0.3.1: it has no settings, command ring, 68K samples, "
                     "fetch or DMA counts")
    if layout == 3:
        lines += settings_lines(r) + sample_lines(r) + fetch_lines(r)
        if n < WORDS_L3:
            ok = False
            lines.append(f"this file is {WORDS * 4} bytes and layout 3 writes {WORDS_L3 * 4}: the host kept an old file's size, so the "
                         "command ring and the DMA counts are missing. Delete wait.sav from the card and run again")
        elif r[127] != 0x5A000000 + 127:
            ok = False
            lines.append(f"word 127 is {r[127]:08X}, not the pattern: the file's second half is not what the core wrote. "
                         "Delete wait.sav from the card and run again")
        else:
            lines += ring_lines(r, frames) + dma_lines(r) + verdict_lines(r)
    return ok, lines


def check_runs(data):
    """The CD core from 0.5.1 keeps 8 records of 512 bytes: a line per run, oldest first, then each run. Returns (ok, lines)."""
    size = WORDS_L3 * 4
    runs = []
    for at in range(0, len(data) - size + 1, size):
        rec = data[at:at + size]
        words = struct.unpack(f">{WORDS_L3}I", rec)
        if words[0] == MAGIC:      # a blank record is 0 or, as the host creates a new file, all ones
            runs.append((words[RUN_WORD], words, rec))
    if not runs:
        return False, ["no run in the file: no record starts with the counter's magic"]
    runs.sort(key=lambda run: run[0])
    lines = ["--- The runs in this file, oldest first. Worst read in ms, one sector's time being 6.7 at 2x and 13.3 at 1x"]
    for no, r, _ in runs:
        lines.append(f"  run {no}: {r[2]} frames, {r[33] >> 24} resets, {r[28] & 0xFF} failed sectors, worst read {r[42] / (CLK_HZ / 1e3):.1f} ms, "
                     f"{r[44]} late polls, {run_short(r)}, drive {DRIVE_STATE.get((r[27] >> 24) & 0xF, '?')} at LBA {r[27] & 0xFFFFFF}")
    lines.append("Counts run on through a reset, so a run's own are the difference from the run before it, within one opening of the core")
    ok = True
    for no, _, rec in runs:
        run_ok, run_lines = check(rec)
        ok = ok and run_ok
        lines += ["", f"=== Run {no}"] + run_lines
    return ok, lines


TL_VARS = ("$7651 queue tail", "$7472.. queue entry", "$7688 sectors to come", "$76B6/7 reading, stage", "$76C8 position sought",
           "$7EC4 loading", "$76F6 CDDA request", "$7E04 flags")
MUSIC_PAYLOAD = 0x01285063      # the drive command PLAY to 60:58:21, as a timeline holds it
SEARCH_PAYLOAD = 0x07120003     # PLAY to 00:02:17, where the Start Game's directory search begins
TL_UNIT_MS = 1024 / CLK_HZ * 1e3


def timeline_event(ty, pay):
    if ty == 0:
        d = [(pay >> s) & 0xF for s in (4, 8, 12, 16, 20, 24)]
        text = command_name(pay)
        if pay & 0xF in (3, 4):
            text += f" to {d[0]}{d[1]}:{d[2]}{d[3]}:{d[4]}{d[5]}"
        return "command " + text
    if ty == 1:
        lba = pay & 0xFFFFFF
        lba = lba - (1 << 24) if lba >> 23 else lba
        return f"{'audio' if pay >> 31 else 'data'} sector {lba} asked for"
    if ty in (2, 3, 4):
        return f"sector {('DMA' + chr(39) + 'd', 'skipped', 'LOST')[ty - 2]}: {header_text(pay)}"
    if ty == 5:
        ds, data = pay >> 16 & 3, pay & 0xFFFF
        val = f"{data >> 8:02X}" if ds == 2 else f"{data & 0xFF:02X}" if ds == 1 else f"{data:04X}"
        return f"{TL_VARS[pay >> 18 & 7]} = {val}"
    if ty == 6:
        return f"drive status {DRIVE_STATE.get(pay >> 28, '?')} at LBA {pay & 0xFFFFFF}"
    return f"event type {ty}: {pay:08X}"


def timeline_lines(data):
    """The file's second 4 KB, from 0.5.6's last builds: a timeline per CD/CDZ setting, off then on. Times in ms from the music."""
    lines = []
    for half, name in enumerate(("off", "on")):
        w = struct.unpack(">512I", data[half * 2048:(half + 1) * 2048])
        lines += ["", f"=== Timeline, CD/CDZ {name}"]
        if w[0] >> 16 != 0x544C:
            lines.append("not recorded: the music's PLAY did not come in this setting, or 96 more events did not follow it")
            continue
        head, wrapped = w[0] & 0xFF, bool(w[0] >> 8 & 1)
        order = list(range(head, 256)) + list(range(1, head)) if wrapped else list(range(1, head))
        ev = [(w[2 * k] >> 28, w[2 * k] & 0xFFFFFFF, w[2 * k + 1]) for k in order]
        t0 = next((t for ty, t, pay in ev if ty == 0 and pay == MUSIC_PAYLOAD), None)
        if t0 is None:
            lines.append("the music's PLAY is not in the ring")
            continue
        search = [i for i, (ty, t, pay) in enumerate(ev) if ty == 0 and pay == SEARCH_PAYLOAD and t <= t0]
        lines.append(f"run {w[1]}, {len(ev)} events" + ("" if wrapped else ", the ring did not wrap"))
        if search:
            part = [e for e in ev[search[-1]:] if e[1] <= t0]
            asked = sum(1 for ty, t, pay in part if ty == 1 and not pay >> 31)
            offered = sum(1 for ty, t, pay in part if ty in (2, 3, 4))
            lines.append(f"from the last PLAY to 00:02:17 to the music, {(t0 - part[0][1]) * TL_UNIT_MS:.1f} ms: "
                         f"{asked} data sectors asked for, {offered} offered")
        else:
            lines.append("the PLAY to 00:02:17 before the music is not in the ring")
        for ty, t, pay in ev:
            lines.append(f"  {(t - t0) * TL_UNIT_MS:+10.1f} ms  {timeline_event(ty, pay)}")
    return lines


def read_file(data):
    if len(data) >= 8192:
        ok, lines = check_runs(data[:4096])
        return ok, lines + timeline_lines(data[4096:8192])
    return check_runs(data) if len(data) >= 2 * WORDS_L3 * 4 else check(data)


def selftest():
    assert "no UniBIOS" in bios_model(0)
    assert "wrote TOPLOAD, region setting 2; the core stored CDZ" in bios_model(1 << 24 | 0 << 16 | 2 << 8 | 1)
    assert "wrote CDZ, region setting 1; the core stored TOPLOAD" in bios_model(1 << 24 | 2 << 16 | 1 << 8)
    def make(total=48_000_000 * 600, frames=36000, worst=4000, reads=(0, 900, 60, 40), lost=(0, 0, 240, 80), layout=1):
        good = [MAGIC, (7 << 24) | layout, frames, worst, total >> 32, total & 0xFFFFFFFF]
        for x in reads + lost:
            good += [x >> 32, x & 0xFFFFFFFF]
        good += [frames] + [0] * (31 - 23) + [5]
        return good + [0x5A000000 + i for i in range(PATTERN_OLD, WORDS)]

    def make3(frames=36000):
        g = make(frames=frames, reads=(30, 900, 0, 0), lost=(120, 0, 0, 0), layout=3)[:32]
        g += [0] * (WORDS_L3 - 32)
        for i in range(PATTERN_L3, WORDS):
            g[i] = 0x5A000000 + i
        g[127] = 0x5A000000 + 127
        return g
    pack = lambda w: struct.pack(f">{len(w)}I", *w)
    ok, lines = check(pack(make()))
    assert ok and any("RD_WAIT 7" in l and "10.0 minutes" in l for l in lines), lines
    assert any("Lost 320 clocks" in l and "8.00% of reads" in l for l in lines), lines
    assert any("fix read" in l and "240" in l and "75.00%" in l and "100.00%" in l for l in lines), lines
    assert any("loader" in l for l in lines) and not any("CD write queue" in l for l in lines), lines
    # The CD core: code 0 is the CD write queue, the cycles are counted as cycles, and a layout nobody knows fails
    cd = make(reads=(30, 900, 0, 0), lost=(120, 0, 0, 0), layout=2)
    ok, lines = check(pack(cd))
    assert ok and any("BIOS and PROG RAM cycles: 930" in l and "of cycles took a wait state" in l for l in lines), lines
    assert any("CD write queue" in l and "120" in l and "100.00%" in l for l in lines), lines
    assert not any("loader" in l for l in lines), lines
    assert any("old file, layout 2" in l for l in lines), lines     # a 0.3.1 file says what it lacks
    # Words 23 to 30 of the CD core's file
    cdw = make(reads=(30, 900, 0, 0), lost=(120, 0, 0, 0), layout=2)
    cdw[23:31] = [(131072 << 8) | 0x12, 0x3456789A, (2 << 8) | 0xAB, 0xCDEF0123, (12 << 28) | (0xB << 24) | 4500, (1 << 8) | 3,
                  (688 << 16) | 7, 700_000_000]
    ok, lines = check(pack(cdw))
    assert ok and any("last command 123456789A" in l and "last status ABCDEF0123" in l and "state B NO DISC at LBA 4500" in l
                      and "BIN size 700000000" in l for l in lines), lines
    assert any("7 CDD exchanges" in l and "3 failed" in l and "131072 FIX, 2 SPR, 1 PCM" in l and "688 Z80" in l for l in lines), lines
    assert any("last mount: openfile" in l for l in lines), lines
    assert not any("CD drive" in l for l in check(pack(make()))[1])
    ok, lines = check(pack(make(layout=4)))
    assert not ok and any("layout 4" in l for l in lines), lines
    big = make(total=1 << 40, lost=(0, 0, 1 << 33, 0))
    ok, lines = check(pack(big))
    assert ok and any("0.781%" in l for l in lines), lines
    lagged = [0] + make()[:-1]
    ok, lines = check(pack(lagged))
    assert not ok and "1 word" in lines[0] and any("RD_WAIT 7" in l for l in lines), lines
    torn = make()
    torn[22] += 1
    ok, lines = check(pack(torn))
    assert not ok and any("across a copy" in l for l in lines), lines
    waits = make()
    waits[1] |= 1 << 16
    assert any("WARNING" in l for l in check(pack(waits))[1])
    empty = [0] * PATTERN_OLD + make()[PATTERN_OLD:]
    ok, lines = check(pack(empty))
    assert not ok and any("No frame ended" in l for l in lines), lines
    assert not check(b"\xff" * (WORDS * 4))[0]
    assert not check(b"")[0]

    # ---- Layout 3 ----
    l3 = make3()
    l3[32] = 1 | (0 << 1) | (3 << 2) | (0b11 << 4)      # CDZ on, bit 12 = 0, 4x, JP
    l3[33] = (2 << 24) | 35000
    l3[34:38] = [(1 << 31) | (200 << 23) | 0x1000, (195 << 23) | 0x2000, (190 << 23) | 0x3000, (100 << 23) | 0x4000]
    l3[38:48] = [900, 40, 800, 140, 480000, 3, 7, 11, 0x80000000 | 123, 0x80000000 | 456]
    l3[64:66] = [2, 1]
    l3[66:70] = [1024, 64, 2048, 128]
    l3[70:74] = [31, 22, 25, 28]
    l3[74:80] = [5, 0, 0, 1, 2, 9]
    l3[80] = 10
    # Newest first in the file: command i + 1 at frame 35990 + i, with i = 7 the newest
    def cmd(code, sub=0):
        c = code | (sub << 12)
        return c | ((~(5 + code + sub) & 0xF) << 36)
    for i in range(8):
        c = cmd(i + 1 if i + 1 != 5 else 2)
        a = 0x4 | ((~(5 + 4) & 0xF) << 36)
        at = 81 + 3 * (7 - i)
        l3[at:at + 3] = [((35990 + i) << 16) | ((c >> 32) << 8) | (a >> 32), c & 0xFFFFFFFF, a & 0xFFFFFFFF]
    ok, lines = check(pack(l3))
    assert ok, lines
    text = "\n".join(lines)
    assert "CD/CDZ (SYSTEM_CDZ, taken only in a reset): on" in text, lines
    assert "as the BIOS reads it: 0, which a top or front loader BIOS takes as tray open, and a CDZ BIOS as tray closed" in text, lines
    assert "CD Speed (cd_speed): 4x; Region (CD_REGION): JP; Lid open (debug, status[15]): off" in text, lines
    assert "resets: 2 (modulo 256), counting the first start; the last ended at frame 35000" in text, lines
    assert "held in reset" not in text, lines
    assert lines.index(next(l for l in lines if "004000" in l)) < lines.index(next(l for l in lines if "002000" in l)), lines    # oldest first
    assert "the 68K is running" in text, lines
    # The hold, words 106-109, 48,000 clocks to the millisecond
    assert "2x hold" in text and "0 times" in text and "ran out at its 50 ms limit 0 times" in text, lines
    held = l3[:]
    held[106:110] = [3, 1, 2_400_000, 4_800_000]
    htext = "\n".join(check(pack(held))[1])
    assert "3 times, 100.0 ms in all, the longest 50.0 ms; ran out at its 50 ms limit 1 times: the program kept" in htext, htext
    assert "sectors requested: 900 data, 40 audio" in text and "found in the prefetch bank: 800; needed a host read: 140" in text, lines
    assert "worst host read: 480000 clocks, 10000 us." in text, lines
    assert "still at the host: 3" in text and "unanswered: 7." in text and "sink full: 11." in text, lines
    assert "first failed sector: frame 123; first late sector: frame 456" in text, lines
    assert any(l.split() == "PROG 1024 words, worst stall 31".split() for l in lines), lines
    assert any(l.split() == "FIX 64 words, worst stall 22".split() for l in lines), lines
    assert any(l.split() == "PCM 128 words, worst stall 28".split() for l in lines), lines
    assert "the 68K 5 times" in text and "a DMA 0 times" in text and "full queue: 0." in text and "a queue with writes in it: 1" in text, lines
    assert "no memory (outside the window or an area not enabled): 2" in text and "during a DMA: 9." in text, lines
    assert "nothing lost on the memory path" in text and "fell behind the drive from frame 456" in text, lines
    # The ring prints oldest to newest, with its real frames, whatever the wrap
    ring = [l for l in lines if l.startswith("  frame ")]
    assert len(ring) == 8 and ring[0].startswith("  frame 35990: STOP") and ring[-1].startswith("  frame 35997: FW SCAN"), ring
    assert "PLAY" in ring[2] and " to 00:00:00" in ring[2], ring
    play = make3()
    play_cmd = 0x3 | (2 << 20) | (1 << 24) | (6 << 28)      # cdd_msg(PLAY, 0, 0, 0, 0, 2, 1, 6), the bench's
    play[81:84] = [(35999 << 16) | ((~(5 + 3 + 2 + 1 + 6) & 0xF) << 12), play_cmd, 0]
    assert any("PLAY" in l and " to 00:02:16" in l for l in check(pack(play))[1])
    assert all("answered PAUSE" in l and "BAD" not in l for l in ring), ring
    wrapped = make3(frames=70000)
    wrapped[22] = 70000
    wrapped[81:84] = [((70000 - 3) & 0xFFFF) << 16 | (0xA0 << 8), 0x00000001, 0]
    ring = [l for l in check(pack(wrapped))[1] if l.startswith("  frame ")]
    assert len(ring) == 1 and ring[0].startswith("  frame 69997: STOP") and "not answered yet" in ring[0] and "BAD" in ring[0], ring
    # Stopped, in reset, a lost write, a failed sector
    bad = make3()
    bad[32] = 0x80 | (1 << 1)
    bad[76], bad[46] = 2, 0x80000000 | 9
    ok, lines = check(pack(bad))
    assert ok, lines    # a file is good whatever the numbers
    text = "\n".join(lines)
    assert "held in reset" in text and "no frame out of reset" in text and "LOST on the memory path, 2 writes" in text, lines
    assert "sectors failed from frame 9" in text, lines
    stuck = make3()
    stuck[34:38] = [0x1000, 0x2000, 0x3000, 0x4000]
    assert "the 68K is stopped" in "\n".join(check(pack(stuck))[1])
    # The host kept the old file's 256 bytes: what is there, and what to do
    ok, lines = check(pack(l3[:WORDS]))
    text = "\n".join(lines)
    assert not ok and "CD Speed (cd_speed): 4x" in text and "first late sector: frame 456" in text and "Delete wait.sav" in text, lines
    assert "worst stall" not in text, lines
    # The second half not the core's
    half = l3[:]
    half[127] = 0
    ok, lines = check(pack(half))
    assert not ok and any("word 127" in l for l in lines), lines
    # A lag shifts layout 3 too, and a layout 3 word with the old pattern is no file
    ok, lines = check(pack([0] + l3[:-1]))
    assert not ok and "1 word" in lines[0], lines
    wrong = make(layout=3)
    ok, lines = check(pack(wrong))
    assert not ok and any("read-lag pattern" in l for l in lines), lines

    # ---- Several runs: in run order whatever the record, an empty record skipped ----
    def run(no, frames, late):
        g = make3(frames=frames)
        g[22], g[44], g[RUN_WORD] = frames, late, no
        return g
    empty = make3(frames=0)
    empty[:32] = [0] * 32
    file = [empty[:] for _ in range(8)]
    file[1], file[0], file[7] = run(9, 100, 1), run(8, 200, 2), run(7, 300, 3)
    ok, lines = read_file(pack([x for rec in file for x in rec]))
    assert ok, lines
    runs = [l for l in lines if l.startswith("  run ")]
    assert [l.split()[1] for l in runs] == ["7:", "8:", "9:"], runs
    assert "100 frames" in runs[2] and "3 late polls" in runs[0], runs
    assert [l for l in lines if l.startswith("=== Run")] == ["=== Run 7", "=== Run 8", "=== Run 9"], lines
    ok, lines = read_file(pack([x for _ in range(8) for x in empty]))
    assert not ok and "no run in the file" in lines[0], lines
    # One bad record says so for the whole file
    file[0][22] += 1
    assert not read_file(pack([x for rec in file for x in rec]))[0]
    # A file of one record is still read as before
    assert read_file(pack(l3))[0]
    # The run-outs, words 110-125: the newest first in the file, oldest first in print, frames past a 16-bit wrap
    ro = make3(frames=70000)
    ro[22] = 70000
    ro[106:110] = [2, 2, 2_400_000, 4_800_000]
    ro[110:114] = [((69990 & 0xFFFF) << 16) | 3, 0x80000000 | 4500, ((65540 & 0xFFFF) << 16) | 0, 1200]
    text = "\n".join(check(pack(ro))[1])
    assert "frame 65540 (1092.3 s): drive at LBA 1200, the mask stayed on 0.0 ms more\n" in text, text
    assert "frame 69990 (1166.5 s): drive at LBA 4500, the mask stayed on 2.0 ms more, and was still on" in text, text
    assert text.index("frame 65540 (") < text.index("frame 69990 ("), text
    assert "not in this file (from 0.5.3)" in "\n".join(check(pack([*l3[:110], *[0xFFFFFFFF] * 16, *l3[126:]]))[1])
    # 0.5.4, revision 1: the sectors in 108, 109 and 126, the last lost in 110-125, newest first in the file
    se = make3(frames=70000)
    se[1] |= 1 << 19
    se[22] = 70000
    se[106:110] = [5, 1, 900, 3]
    se[110:114] = [((69990 & 0xFFFF) << 16) | 1, 0x01_15_02_00, ((65540 & 0xFFFF) << 16) | 2, 0xFF]
    se[126] = 2
    text = "\n".join(check(pack(se))[1])
    assert "900 DMA'd, 3 skipped (status read, no DMA), 2 LOST" in text, text
    assert "frame 69990 (1166.5 s): LBA 15 (00:02:15, mode 1), interrupt DROPPED, masked" in text, text
    assert "frame 65540 (1092.3 s): header 000000FF, interrupt reached" in text, text
    assert text.index("frame 65540 (") < text.index("frame 69990 ("), text
    assert "mask stayed on" not in text, text
    se[RUN_WORD] = 3
    lines = read_file(pack(se + [0] * (8 * WORDS_L3 - len(se))))[1]
    assert "hold 5x, 900 sectors DMA'd, 3 skipped, 2 lost, the last at frame 69990, LBA 15" in lines[1], lines
    # 0.5.5, revision 2: the early reads, newest first in the file, frames modulo 2048
    ea = make3(frames=70000)
    ea[1] |= 2 << 19
    ea[22] = 70000
    ea[106:110] = [(5 << 16) | 1, 2, 900, 3]
    ea[110] = ((69990 & 0x7FF) << 21) | (1 << 20) | (0x1FFFFE >> 1)
    ea[111] = ((68000 & 0x7FF) << 21) | (0x001800 >> 1)
    ea[126] = 2
    text = "\n".join(check(pack(ea))[1])
    assert "900 DMA'd, 3 skipped (status read, no DMA), 2 lost" in text and "2x hold: 5 times, ran out at its 50 ms limit 1 times" in text, text
    assert "frame 68000 (1133.3 s): 001800 by the 68K\n  frame 69990 (1166.5 s): 1FFFFE by a DMA" in text, text
    ea[RUN_WORD] = 4
    lines = read_file(pack(ea + [0] * (8 * WORDS_L3 - len(ea))))[1]
    assert "900 sectors DMA'd, 3 skipped, 2 lost, 2 early reads, the last at frame 69990, 1FFFFE" in lines[1], lines
    # 0.5.6, revision 3: the CDZ BIOS's protection variables, newest first in the file, frames modulo 16384
    bw = make3(frames=70000)
    bw[1] |= 3 << 19
    bw[22] = 70000
    bw[106:110] = [(5 << 16) | 1, 7, 900, 0]
    bw[110] = ((69990 & 0x3FFF) << 18) | (0 << 16) | 0x0000
    bw[111] = ((69700 & 0x3FFF) << 18) | (0 << 16) | 0x0001
    bw[126] = (14 << 16) | (0x02 << 8) | 0x00
    text = "\n".join(check(pack(bw))[1])
    assert "$777E special reads that ended well: 0; $7782 drive status count: 7; $7786 status code: 02" in text, text
    assert "the BIOS drops such a sector): 14" in text, text
    assert "frame 69700 (1161.7 s): $7778 = 0001\n  frame 69990 (1166.5 s): $7778 = 0000" in text, text
    bw[RUN_WORD] = 5
    lines = read_file(pack(bw + [0] * (8 * WORDS_L3 - len(bw))))[1]
    assert "900 sectors DMA'd, 14 late STAT3 reads, special reads ended well 0 (7782 7, status 02), 1 special reads started" in lines[1], lines
    # 0.5.6 second build, revision 4: the BIOS's sector read variables, newest first in the file, frames modulo 2048
    rd = make3(frames=70000)
    rd[1] |= 4 << 19
    rd[22] = 70000
    rd[106:110] = [(5 << 16) | 1, 2, 900, 0x01_17_02_00]
    rd[110] = ((69990 & 0x7FF) << 21) | (2 << 18) | (3 << 16) | 0x0100
    rd[111] = ((69900 & 0x7FF) << 21) | (1 << 18) | (2 << 16) | 0x1700
    rd[126] = 1
    text = "\n".join(check(pack(rd))[1])
    assert "the last sector the decoder offered: LBA 17 (00:02:17, mode 1), DMA'd" in text, text
    assert "frame 69900 (1165.0 s): $76CA sought frame = 17\n  frame 69990 (1166.5 s): $7688 sectors to come = 0100" in text, text
    rd[RUN_WORD] = 6
    lines = read_file(pack(rd + [0] * (8 * WORDS_L3 - len(rd))))[1]
    assert "900 sectors DMA'd, last offered LBA 17 (00:02:17, mode 1), 2 BIOS read changes, the last at frame 69990: $7688" in lines[1], lines
    # Revision 5: the BIOS's queue and read variables, stopped at the PLAY to 00:02:00 (word 126 bit 1)
    rq = make3(frames=70000)
    rq[1] |= 5 << 19
    rq[22] = 70000
    rq[106:110] = [(5 << 16) | 1, 2, 900, 0x01_17_02_00]
    rq[110] = ((69990 & 0x7FF) << 21) | (1 << 18) | (2 << 16) | 0x0909
    rq[111] = ((69900 & 0x7FF) << 21) | (0 << 18) | (1 << 16) | 0x0001
    rq[126] = 2
    text = "\n".join(check(pack(rq))[1])
    assert "the log STOPPED at the first PLAY to 60:58:21 (the music)" in text, text
    assert "frame 69900 (1165.0 s): $7650/1 queue head, tail = 01 (lower byte)\n  frame 69990 (1166.5 s): $7472.. queue entry = 09 (upper byte)" in text, text
    rq[RUN_WORD] = 7
    lines = read_file(pack(rq + [0] * (8 * WORDS_L3 - len(rq))))[1]
    assert "900 sectors DMA'd, 2 queue/read writes, stopped at PLAY 60:58:21, the last at frame 69990: $7472.. queue entry" in lines[1], lines
    # Revision 6: the timelines in the file's second 4 KB. CD/CDZ on recorded, off blank, unwrapped, stale entries past the head
    tl = make3(frames=70000)
    tl[1] |= 6 << 19
    tl[22] = 70000
    tl[106:110] = [(5 << 16) | 1, 2, 900, 0x01_17_02_00]
    tl[126] = 4
    tl[RUN_WORD] = 8
    unit = int(CLK_HZ / 1024 / 1000)      # about a millisecond
    entries = [(0, 1000, SEARCH_PAYLOAD), (1, 1000 + unit, 17), (2, 1000 + 2 * unit, 0x01_17_02_00),
               (5, 1000 + 3 * unit, (2 << 18) | (3 << 16) | 0x0058), (0, 1000 + 10 * unit, MUSIC_PAYLOAD),
               (1, 1000 + 11 * unit, 0x80000000 | 1000), (6, 1000 + 12 * unit, 0x10000011), (1, 1000 + 13 * unit, 0xFFFFFC)]
    half = [0] * 512
    half[0], half[1] = 0x544C0000 | (len(entries) + 1), 9
    for k, (ty, t, pay) in enumerate(entries, 1):
        half[2 * k], half[2 * k + 1] = (ty << 28) | t, pay
    half[2 * (len(entries) + 1)], half[2 * (len(entries) + 1) + 1] = 0xFFFFFFFF, 0xFFFFFFFF
    whole = pack(tl + [0] * (8 * WORDS_L3 - len(tl))) + struct.pack(">512I", *[0xFFFFFFFF] * 512) + struct.pack(">512I", *half)
    ok, lines = read_file(whole)
    text = "\n".join(lines)
    assert ok, lines
    assert "900 sectors DMA'd, last offered LBA 17 (00:02:17, mode 1), timelines stopped: CD/CDZ off 0, on 1" in lines[1], lines
    assert "=== Timeline, CD/CDZ off\nnot recorded" in text, text
    assert "run 9, 8 events, the ring did not wrap" in text, text
    assert "1 data sectors asked for, 1 offered" in text, text
    assert "command PLAY to 00:02:17" in text and "data sector 17 asked for" in text and "sector DMA'd: LBA 17" in text, text
    assert "$7688 sectors to come = 0058" in text and "drive status PLAY at LBA 17" in text and "audio sector 1000 asked for" in text, text
    assert "data sector -4 asked for" in text and "event type 15" not in text, text
    assert text.index("command PLAY to 00:02:17") < text.index("command PLAY to 60:58:21") < text.index("audio sector 1000"), text
    print("selftest ok")


def main(argv):
    if argv == ["--selftest"]:
        selftest()
        return 0
    if len(argv) != 1:
        sys.exit(__doc__)
    with open(argv[0], "rb") as f:
        ok, lines = read_file(f.read())
    print("\n".join(lines))
    print("FILE GOOD" if ok else "FILE NOT GOOD: see above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
