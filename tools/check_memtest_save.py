# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Read the save file of the memory test: python tools/check_memtest_save.py memtest.sav

Checks the counting pattern for the bridge's read lag (words are shifted if the core's read path
does not match what the host does) and prints the results. Exit code 0 when the pattern is clean
and no row has errors. The 3FFFFFh row gives an answer, either of which is good. --selftest runs
the checks on made-up files.
"""
import struct
import sys

MAGIC = 0x4E474D54
WORDS = 1024
PATTERN_FROM = 128
DIAG_FROM = 32
OWNERS = ["loader", "68K", "fix", "Z80"]
RFSH_LIMIT = 754    # clocks, 7.8 us at 96.67 MHz
ANSWERS = ["no answer yet",
           "another address aborts the sequence: no guard needed",
           "the sequence survives another address: Task 5's guard is required",
           "inconsistent"]
ROWS = ["1 CRAM", "2 SDRAM", "3 Mixed traffic", "4 3FFFFFh sequence", "5 File from SD"]
SUBS = [["CRAM0 walk", "CRAM0 random", "CRAM1 walk", "CRAM1 random"],
        ["bursts", "retention", "refresh gap"],
        ["fix", "sprite", "68K", "Z80"],
        ["CRAM0 die 0 read-back", "CRAM0 die 1 read-back", "CRAM1 die 0 read-back", "CRAM1 die 1 read-back",
         "dies or loops disagree"],
        ["CRAM0", "CRAM1", "SDRAM"]]


def pattern_shift(w):
    """Words the pattern is shifted by: 0 is clean, None is no pattern found."""
    for shift in range(-4, 5):
        if all(w[i] == 0x5A000000 + i - shift for i in range(PATTERN_FROM + 4, WORDS - 4)):
            return shift
    return None


def check(data):
    """Returns (ok, lines)."""
    if len(data) < WORDS * 4:
        return False, [f"file is {len(data)} bytes, expected {WORDS * 4}"]
    w = struct.unpack(f">{WORDS}I", data[:WORDS * 4])
    lines = []
    shift = pattern_shift(w)
    if shift is None:
        return False, ["no counting pattern found: the bridge read path did not work"]
    ok = shift == 0
    lines.append("read lag: none, the pattern is where it should be" if ok
                 else f"read lag: FAIL, the pattern is {shift} word(s) off")
    # Results are read through the same path: undo the shift so that they can still be printed
    r = [w[i + shift] if 0 <= i + shift < WORDS else 0 for i in range(PATTERN_FROM)]
    if r[0] != MAGIC:
        return False, lines + [f"no results block: word 0 is {r[0]:08X}"]
    lines.append(f"RD_WAIT {r[1] >> 24}, loops {r[1] & 0xFFFF}, seconds {r[2]}, loader overflow {(r[1] >> 16) & 1}")
    lines.append(f"worst clocks: fix {r[3] >> 24} of 23, sprite {(r[3] >> 16) & 255} of 27, "
                 f"68K {(r[3] >> 8) & 255}, Z80 {r[3] & 255}")
    ok &= not (r[1] >> 16) & 1
    lines.append(f"refresh: {r[24]} commands, largest gap {r[25]} clocks, limit {RFSH_LIMIT}")
    answer, dies = (r[26] >> 16) & 3, r[26] & 15
    for n, name in enumerate(ROWS):
        passes, errs, addr, gotexp = r[4 + 4 * n: 8 + 4 * n]
        lines.append(f"{name}: {passes} passes, {errs} errors")
        if n == 3:
            lines.append(f"    answer: {ANSWERS[answer]} (dies that survive: {dies:04b})")
            if answer == 2 and not errs:
                lines.append(f"    read back {gotexp >> 16:04X} where a plain write would give {gotexp & 0xFFFF:04X}")
        if errs:
            ok = False
            sub = addr >> 28
            what = SUBS[n][sub] if sub < len(SUBS[n]) else f"part {sub}"
            lines.append(f"    first: {what}, byte address {addr & 0x0FFFFFFF:07X}, "
                         f"got {gotexp >> 16:04X}, expected {gotexp & 0xFFFF:04X}")
        elif passes == 0:
            lines.append("    never completed")
            ok = False
    lines += failure_records(r)
    return ok, lines


def failure_records(r):
    """Row 3's last failures, oldest first."""
    errs, next_rec = r[4 + 4 * 2 + 1], r[27] & 7
    n = min(errs, 8)
    if n == 0:
        return []
    out = [f"Mixed traffic, last {n} of {errs} failures, oldest first:"]
    for k in range(n):
        e = r[DIAG_FROM + 8 * ((next_rec - n + k) & 7):][:8]
        sub = e[0] >> 28
        client = SUBS[2][sub] if sub < 4 else f"client {sub}"
        out.append(f"  {client}, byte address {e[0] & 0x0FFFFFF:06X}, got {e[1] >> 16:04X}, expected {e[1] & 0xFFFF:04X}, "
                   f"second {e[2]}, loop {e[7] >> 16}, clock {(e[7] & 0xFFFF) << 12:#x} of the step")
        out.append(f"    now: 68K word {e[3] >> 16:04X} {'busy' if e[4] >> 31 else 'idle'}, "
                   f"Z80 word {e[3] & 0xFFFF:04X} {'busy' if (e[4] >> 30) & 1 else 'idle'}, clock {(e[4] >> 24) & 63} of the line, "
                   f"CRAM0 {'busy' if (e[4] >> 23) & 1 else 'idle'} with {OWNERS[(e[4] >> 21) & 3]}, "
                   f"pending 68K {(e[4] >> 20) & 1} fix {(e[4] >> 19) & 1}")
        out.append(f"    previous grant: {OWNERS[(e[5] >> 23) & 3]} word {e[5] & 0x7FFFFF:06X}; "
                   f"when requested: CRAM0 {'busy' if (e[6] >> 27) & 1 else 'idle'} with {OWNERS[(e[6] >> 25) & 3]} "
                   f"word {e[6] & 0x7FFFFF:06X}, pending 68K {(e[6] >> 24) & 1} fix {(e[6] >> 23) & 1}")
    return out


def selftest():
    good = [MAGIC, (8 << 24) | 30, 600, (21 << 24) | (20 << 16) | (20 << 8) | 40]
    for _ in range(5):
        good += [30, 0, 0, 0]
    good += [77000, 728, 1 << 16]
    good += [0] * (PATTERN_FROM - len(good))
    good += [0x5A000000 + i for i in range(PATTERN_FROM, WORDS)]
    pack = lambda w: struct.pack(f">{WORDS}I", *w)
    assert check(pack(good))[0]
    bad = list(good)
    bad[4 + 4 + 1], bad[4 + 4 + 2], bad[4 + 4 + 3] = 3, (1 << 28) | 0x12344, 0x12341235
    ok, lines = check(pack(bad))
    assert not ok and any("retention" in l and "0012344" in l for l in lines)
    lagged = [0] + good[:-1]        # every word one place late
    ok, lines = check(pack(lagged))
    assert not ok and "1 word" in lines[0] and any("RD_WAIT 8" in l for l in lines)
    survives = list(good)
    survives[26], survives[4 + 3 * 4 + 3] = (2 << 16) | 15, 0x0BAD0002
    ok, lines = check(pack(survives))
    assert ok and any("guard is required" in l for l in lines) and any("0BAD" in l for l in lines)
    late = list(good)
    late[25], late[4 + 4 + 1], late[4 + 4 + 2] = 2000, 1, 2 << 28
    ok, lines = check(pack(late))
    assert not ok and any("refresh gap" in l for l in lines)
    mixed = list(good)
    mixed[4 + 2 * 4 + 1], mixed[4 + 2 * 4 + 2], mixed[27] = 9, 0x00C00008, 1
    mixed[DIAG_FROM:DIAG_FROM + 8] = [0x00C00008, 0xC756C951, 480, 0x12340056, 0x2020000, 5 | (1 << 23), 0, (22 << 16) | 3]
    ok, lines = check(pack(mixed))
    assert not ok and any("last 8 of 9" in l for l in lines) and any("got C756, expected C951, second 480, loop 22" in l for l in lines)
    assert not check(b"\xff" * (WORDS * 4))[0]
    assert not check(b"")[0]
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
    print("ALL GOOD" if ok else "NOT GOOD: see above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
