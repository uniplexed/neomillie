# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""Turn a CD image into what the CD core reads: python cd_convert.py DISC.cue|DISC.chd OUTDIR [--name NAME]

Takes a CUE of MODE1/2048 or MODE1/2352 data tracks and AUDIO tracks in BINARY or WAVE files, as
TOSEC's ISO and WAV sets, or a CHD, and writes one NAME.bin of 2,352-byte sectors and NAME.cue beside
it, in OUTDIR/NAME. The sources are only read. A 2,048-byte sector gets its sync, header, EDC and ECC
as ECMA-130 gives them. A CHD needs MAME's chdman, on the PATH or beside this script; the rest needs
only Python. --selftest runs the checks on made-up files, and on CHDs if chdman is there.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import wave

SECTOR = 2352
USER = 2048

ECC_F = [((i << 1) ^ (0x11D if i & 0x80 else 0)) & 0xFF for i in range(256)]
ECC_B = [0] * 256
for i in range(256):
    ECC_B[i ^ ECC_F[i]] = i
EDC = []
for i in range(256):
    e = i
    for _ in range(8):
        e = (e >> 1) ^ (0xD8018001 if e & 1 else 0)
    EDC.append(e)


def edc(data):
    e = 0
    for b in data:
        e = EDC[(e ^ b) & 0xFF] ^ (e >> 8)
    return e


def ecc_block(src, majors, minors, major_mult, minor_inc):
    size = majors * minors
    out = bytearray(2 * majors)
    for major in range(majors):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minors):
            t = src[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= t
            b ^= t
            a = ECC_F[a]
        a = ECC_B[ECC_F[a] ^ b]
        out[major] = a
        out[major + majors] = a ^ b
    return out


def bcd(v):
    return (v // 10) << 4 | v % 10


def msf_text(lba):
    return f"{lba // 4500:02d}:{lba // 75 % 60:02d}:{lba % 75:02d}"


def parse_msf(text):
    m, s, f = map(int, text.split(":"))
    return (m * 60 + s) * 75 + f


def mode1_sector(lba, user):
    """A MODE1/2352 sector of a disc LBA, with the 150 sectors of the lead-in in its address."""
    a = lba + 150
    s = bytearray(SECTOR)
    s[0:12] = b"\x00" + b"\xFF" * 10 + b"\x00"
    s[12:16] = bytes((bcd(a // 4500), bcd(a // 75 % 60), bcd(a % 75), 1))
    s[16:16 + USER] = user
    s[0x810:0x814] = edc(s[:0x810]).to_bytes(4, "little")
    s[0x81C:0x8C8] = ecc_block(s[12:], 86, 24, 2, 86)
    s[0x8C8:SECTOR] = ecc_block(s[12:], 52, 43, 86, 88)
    return s


def parse_cue(path):
    """List of tracks: {file, kind, no, mode, pregap, indices}."""
    tracks, file, kind = [], None, None
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if m := re.match(r'FILE\s+"(.+)"\s+(\w+)', line):
            file, kind = path.parent / m[1], m[2].upper()
        elif m := re.match(r"TRACK\s+(\d+)\s+(\S+)", line):
            if m[2] not in ("MODE1/2048", "MODE1/2352", "AUDIO"):
                sys.exit(f"{path.name}: track {m[1]} is {m[2]}, which this does not handle")
            tracks.append({"file": file, "kind": kind, "no": int(m[1]), "mode": m[2], "pregap": 0, "indices": {}})
        elif m := re.match(r"PREGAP\s+(\S+)", line):
            tracks[-1]["pregap"] = parse_msf(m[1])
        elif m := re.match(r"INDEX\s+(\d+)\s+(\S+)", line):
            tracks[-1]["indices"][int(m[1])] = parse_msf(m[2])
    if not tracks:
        sys.exit(f"{path.name}: no tracks")
    locate(tracks)
    return tracks


def locate(tracks):
    """Where each track's bytes are in its file. A CUE's times count sectors of each track's own size."""
    by_file = {}
    for t in tracks:
        by_file.setdefault(t["file"], []).append(t)
    for shared in by_file.values():
        byte = 0
        for n, t in enumerate(shared):
            # A file's first track starts at the file's start, with any pregap the file holds
            t["first"] = min(t["indices"].values()) if n else 0
            t["start"], t["end"] = byte, None
            if n + 1 < len(shared):
                size = USER if t["mode"] == "MODE1/2048" else SECTOR
                t["end"] = byte = byte + (min(shared[n + 1]["indices"].values()) - t["first"]) * size


def read_track(t):
    if t["kind"] == "WAVE":
        if t["start"] or t["end"] is not None:
            sys.exit(f"{t['file'].name}: tracks sharing a WAV file are not handled")
        with wave.open(str(t["file"])) as w:
            if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (44100, 2, 2):
                sys.exit(f"{t['file'].name}: not 44.1 kHz 16-bit stereo")
            return w.readframes(w.getnframes())
    with open(t["file"], "rb") as f:
        f.seek(t["start"])
        if t["end"] is None:
            return f.read()
        data = f.read(t["end"] - t["start"])
    if len(data) != t["end"] - t["start"]:
        sys.exit(f"{t['file'].name}: shorter than its CUE says at track {t['no']}")
    return data


def convert(cue_path, out_root, name):
    tracks = parse_cue(cue_path)
    out = pathlib.Path(out_root) / name
    sources = {cue_path.resolve()} | {t["file"].resolve() for t in tracks}
    if {(out / f"{name}.bin").resolve(), (out / f"{name}.cue").resolve()} & sources:
        sys.exit(f"{out}: would overwrite the source. Pick another OUTDIR or --name")
    out.mkdir(parents=True, exist_ok=True)
    lines = [f'FILE "{name}.bin" BINARY']
    at = 0          # sectors written to the BIN
    gaps = 0        # sectors of PREGAP so far, on the disc and not in the BIN
    with open(out / f"{name}.bin", "wb") as f:
        for t in tracks:
            lines.append(f"  TRACK {t['no']:02d} {'MODE1/2352' if t['mode'] != 'AUDIO' else 'AUDIO'}")
            if t["pregap"]:
                lines.append(f"    PREGAP {msf_text(t['pregap'])}")
                gaps += t["pregap"]
            for i, offset in sorted(t["indices"].items()):
                lines.append(f"    INDEX {i:02d} {msf_text(at + offset - t['first'])}")
            data = read_track(t)
            if t["mode"] == "MODE1/2048":
                if len(data) % USER:
                    sys.exit(f"{t['file'].name}: not a whole number of 2,048-byte sectors")
                for n in range(len(data) // USER):
                    f.write(mode1_sector(at + gaps + n, data[n * USER:(n + 1) * USER]))
                at += len(data) // USER
            else:
                if t["mode"] != "AUDIO" and len(data) % SECTOR:
                    sys.exit(f"{t['file'].name}: not a whole number of 2,352-byte sectors")
                # A WAV may end inside a sector: the disc's sector is padded with silence
                data += bytes(-len(data) % SECTOR)
                f.write(data)
                at += len(data) // SECTOR
    (out / f"{name}.cue").write_text("\n".join(lines) + "\n", newline="\n")
    return out, at, gaps


def find_chdman():
    return shutil.which("chdman", path=os.pathsep.join((str(pathlib.Path(__file__).resolve().parent), os.environ.get("PATH", ""))))


def convert_chd(chd_path, out_root, name):
    chdman = find_chdman()
    if not chdman:
        sys.exit("A CHD needs chdman, which comes with MAME (mamedev.org): put it on the PATH or beside this script")
    pathlib.Path(out_root).mkdir(parents=True, exist_ok=True)
    # Beside the output: a disc takes hundreds of MB, and the system's temporary folder may not have them
    with tempfile.TemporaryDirectory(dir=out_root) as d:
        cue = pathlib.Path(d) / "x.cue"
        r = subprocess.run([chdman, "extractcd", "-i", str(chd_path), "-o", str(cue), "-ob", str(cue.with_suffix(".bin"))],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, errors="replace")
        if r.returncode:
            sys.exit(f"{chd_path}: chdman failed: {r.stderr.strip()}")
        return convert(cue, out_root, name)


def selftest():
    # ECC words must have zero syndromes on the data they cover, the EDC must close the CRC, and no
    # byte of the source may move
    user = bytes((i * 7 + 3) & 0xFF for i in range(USER))
    s = mode1_sector(16, user)
    assert s[:16] == b"\x00" + b"\xFF" * 10 + b"\x00" + bytes((0, 2, 0x16, 1)), s[:16].hex()
    assert s[16:16 + USER] == user
    assert edc(s[:0x814]) == 0
    assert s[0x814:0x81C] == bytes(8)

    def mul_a(x):
        return ((x << 1) ^ (0x11D if x & 0x80 else 0)) & 0xFF
    p = s[12:]
    for lane in range(2):
        for col in range(43):
            s0 = s1 = 0
            for row in range(26):
                v = p[(col * 2 + lane + row * 86)]
                s0 ^= v
                s1 = mul_a(s1) ^ v
            assert s0 == 0 and s1 == 0, f"P parity, lane {lane}, column {col}"

    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        (d / "a.iso").write_bytes(bytes(USER) + user)
        with wave.open(str(d / "b.wav"), "wb") as w:
            w.setnchannels(2), w.setsampwidth(2), w.setframerate(44100)
            w.writeframes(b"\x11\x22\x33\x44" * 588)
        with wave.open(str(d / "c.wav"), "wb") as w:
            w.setnchannels(2), w.setsampwidth(2), w.setframerate(44100)
            w.writeframes(b"\x55\x66\x77\x88" * 700)    # past a sector, then silence
        (d / "x.cue").write_text('FILE "a.iso" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                                 'FILE "b.wav" WAVE\n  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:00\n'
                                 'FILE "c.wav" WAVE\n  TRACK 03 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:00:01\n')
        out, at, gaps = convert(d / "x.cue", d / "o", "x")
        assert (at, gaps) == (5, 150), (at, gaps)
        b = (out / "x.bin").read_bytes()
        assert len(b) == 5 * SECTOR
        assert b[SECTOR + 16:SECTOR + 16 + USER] == user
        assert b[SECTOR + 12:SECTOR + 16] == bytes((0, 2, 1, 1))
        assert b[2 * SECTOR:3 * SECTOR] == b"\x11\x22\x33\x44" * 588
        assert b[3 * SECTOR:3 * SECTOR + 2800] == b"\x55\x66\x77\x88" * 700
        assert b[3 * SECTOR + 2800:] == bytes(2 * SECTOR - 2800)
        cue = (out / "x.cue").read_text().splitlines()
        assert cue == ['FILE "x.bin" BINARY', "  TRACK 01 MODE1/2352", "    INDEX 01 00:00:00",
                       "  TRACK 02 AUDIO", "    PREGAP 00:02:00", "    INDEX 01 00:00:02",
                       "  TRACK 03 AUDIO", "    INDEX 00 00:00:03", "    INDEX 01 00:00:04"], cue

        def refused(cue_path, out_root, name):
            try:
                convert(cue_path, out_root, name)
            except SystemExit:
                return True
            return False

        def same_disc(converted):
            assert (converted[0] / "x.bin").read_bytes() == b
            assert (converted[0] / "x.cue").read_text().splitlines() == cue

        # One BIN of 2,352-byte sectors comes out as it went in, not once per track
        same_disc(convert(out / "x.cue", d / "o1", "x"))

        # One BIN of 2,048-byte data and audio, as chdman writes the CHD of an ISO: times count sectors, not bytes
        (d / "m").mkdir()
        mixed = bytes(USER) + user + b[2 * SECTOR:]
        (d / "m/m.bin").write_bytes(mixed)
        (d / "m/m.cue").write_text('FILE "m.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                                   '  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:02\n'
                                   '  TRACK 03 AUDIO\n    INDEX 00 00:00:03\n    INDEX 01 00:00:04\n')
        same_disc(convert(d / "m/m.cue", d / "o2", "x"))

        # A BIN shorter than its CUE, and a WAV shared by two tracks
        (d / "m/m.bin").write_bytes(mixed[:USER])
        assert refused(d / "m/m.cue", d / "o3", "x")
        (d / "w.cue").write_text('FILE "b.wav" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n')
        assert refused(d / "w.cue", d / "o4", "x")

        # A CHD of each form gives the same disc. It needs chdman, which the rest does not. Not from x.cue: creating a CHD
        # drops the part of a WAV's last sector, which is chdman's and happens before this tool sees it
        if chdman := find_chdman():
            (d / "m/m.bin").write_bytes(mixed)
            for n, source in enumerate((d / "m/m.cue", out / "x.cue")):
                chd = d / f"s{n}.chd"
                subprocess.run([chdman, "createcd", "-i", str(source), "-o", str(chd)], check=True, capture_output=True)
                same_disc(convert_chd(chd, d / f"c{n}", "x"))
                assert [p.name for p in (d / f"c{n}").iterdir()] == ["x"], "a temporary file stayed"
            (d / "bad.chd").write_bytes(bytes(100))
            try:
                convert_chd(d / "bad.chd", d / "c9", "x")
                raise AssertionError("a bad CHD was taken")
            except SystemExit:
                pass
        else:
            print("selftest: no chdman, CHD not checked")

        # An output on top of its source would truncate the source before reading it
        (d / "same/z").mkdir(parents=True)
        (d / "same/z/z.bin").write_bytes(bytes(SECTOR))
        (d / "same/z/z.cue").write_text('FILE "z.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
        assert refused(d / "same/z/z.cue", d / "same", "z")
        assert (d / "same/z/z.bin").stat().st_size == SECTOR, "the source was overwritten"
    print("selftest ok")


def main(argv):
    if argv == ["--selftest"]:
        selftest()
        return 0
    name = None
    if "--name" in argv:
        i = argv.index("--name")
        name = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) != 2:
        sys.exit(__doc__)
    cue = pathlib.Path(argv[0])
    # "Metal Slug (1996)(SNK)(Jp-US)[!]" is "Metal Slug"
    name = name or re.split(r"\s*[(\[]", cue.stem)[0]
    out, at, gaps = (convert_chd if cue.suffix.lower() == ".chd" else convert)(cue, argv[1], name)
    print(f"{out}: {at} sectors in the BIN, {at + gaps} on the disc, {at * SECTOR} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
