# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Read the save file of the wait counter: python tools/check_wait_save.py wait.sav

The debug builds neogeo_wait, neogeo8_wait, neogeo8_zbuf and neogeocd_wait write it (rtl/test/wait_counter.sv). Prints
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
    return lines


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


def selftest():
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
    print("selftest ok")


def main(argv):
    if argv == ["--selftest"]:
        selftest()
        return 0
    if len(argv) != 1:
        sys.exit(__doc__)
    with open(argv[0], "rb") as f:
        ok, lines = check(f.read())
    print("\n".join(lines))
    print("FILE GOOD" if ok else "FILE NOT GOOD: see above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
