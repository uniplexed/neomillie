# SPDX-License-Identifier: GPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

"""The converter's checks on made-up images: python cd_convert.py --selftest

Each case_* gets its own empty folder. Cases that need chdman or ffmpeg say so when the tool is missing.
"""
import json
import os
import shutil
import subprocess
import tempfile
import threading
import wave
from pathlib import Path

import cdconv
from cdconv.disc import (SECTOR, USER, Cancelled, ConvertError, default_name, edc, find_tool, mode1_sector, msf_text,
                         safe_name)

USER_DATA = bytes((i * 7 + 3) & 0xFF for i in range(USER))
REF_CUE = ['FILE "x.bin" BINARY', "  TRACK 01 MODE1/2352", "    INDEX 01 00:00:00",
           "  TRACK 02 AUDIO", "    PREGAP 00:02:00", "    INDEX 01 00:00:02",
           "  TRACK 03 AUDIO", "    INDEX 00 00:00:03", "    INDEX 01 00:00:04"]


def raises(exc, f, *args, **kw):
    try:
        f(*args, **kw)
    except exc:
        return True
    return False


def conv(src, dest, name):
    r = cdconv.convert(Path(src), Path(dest), name)
    return r.out, r.sectors, r.gaps


def write_wav(path, frames, rate=44100, channels=2, width=2):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(channels), w.setsampwidth(width), w.setframerate(rate)
        w.writeframes(frames)


def make_ref_cue(d):
    """An ISO and two WAVs behind one CUE, the reference disc; returns the CUE's path."""
    d.mkdir(parents=True, exist_ok=True)
    (d / "a.iso").write_bytes(bytes(USER) + USER_DATA)
    write_wav(d / "b.wav", b"\x11\x22\x33\x44" * 588)
    write_wav(d / "c.wav", b"\x55\x66\x77\x88" * 700)     # past a sector, then silence
    (d / "x.cue").write_text('FILE "a.iso" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                             'FILE "b.wav" WAVE\n  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:00\n'
                             'FILE "c.wav" WAVE\n  TRACK 03 AUDIO\n    INDEX 00 00:00:00\n    INDEX 01 00:00:01\n')
    return d / "x.cue"


def ref_bin():
    """The BIN the reference disc converts to."""
    return (mode1_sector(0, bytes(USER)) + mode1_sector(1, USER_DATA) + b"\x11\x22\x33\x44" * 588
            + b"\x55\x66\x77\x88" * 700 + bytes(2 * SECTOR - 2800))


def same_disc(converted, name="x"):
    out = converted[0]
    assert (out / f"{name}.bin").read_bytes() == ref_bin()
    assert (out / f"{name}.cue").read_text().splitlines() == [REF_CUE[0].replace("x.bin", f"{name}.bin")] + REF_CUE[1:]


def case_sectors(d):
    # ECC words must have zero syndromes on the data they cover, the EDC must close the CRC, and no
    # byte of the source may move
    s = mode1_sector(16, USER_DATA)
    assert s[:16] == b"\x00" + b"\xFF" * 10 + b"\x00" + bytes((0, 2, 0x16, 1)), s[:16].hex()
    assert s[16:16 + USER] == USER_DATA
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


def case_cue_iso_wav(d):
    out, at, gaps = conv(make_ref_cue(d / "ref"), d / "o", "x")
    assert (at, gaps) == (5, 150), (at, gaps)
    b = (out / "x.bin").read_bytes()
    assert len(b) == 5 * SECTOR
    assert b[SECTOR + 16:SECTOR + 16 + USER] == USER_DATA
    assert b[SECTOR + 12:SECTOR + 16] == bytes((0, 2, 1, 1))
    assert b[2 * SECTOR:3 * SECTOR] == b"\x11\x22\x33\x44" * 588
    assert b[3 * SECTOR:3 * SECTOR + 2800] == b"\x55\x66\x77\x88" * 700
    assert b[3 * SECTOR + 2800:] == bytes(2 * SECTOR - 2800)
    assert (out / "x.cue").read_text().splitlines() == REF_CUE
    same_disc((out,))


def mixed_cue(d):
    """One BIN of 2,048-byte data and audio, as chdman writes the CHD of an ISO."""
    d.mkdir(parents=True, exist_ok=True)
    (d / "m.bin").write_bytes(bytes(USER) + USER_DATA + ref_bin()[2 * SECTOR:])
    (d / "m.cue").write_text('FILE "m.bin" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:00:00\n'
                             '  TRACK 02 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 00:00:02\n'
                             '  TRACK 03 AUDIO\n    INDEX 00 00:00:03\n    INDEX 01 00:00:04\n')
    return d / "m.cue"


def case_shared_bin(d):
    # One BIN of 2,352-byte sectors comes out as it went in, not once per track
    out = conv(make_ref_cue(d / "ref"), d / "o", "x")[0]
    same_disc(conv(out / "x.cue", d / "o1", "x"))
    # Times in a BIN of 2,048-byte data and audio count sectors, not bytes
    same_disc(conv(mixed_cue(d / "m"), d / "o2", "x"))


def case_refusals(d):
    # A BIN shorter than its CUE, and a WAV shared by two tracks
    m = mixed_cue(d / "m")
    (d / "m/m.bin").write_bytes(bytes(USER))
    assert raises(ConvertError, conv, m, d / "o3", "x")
    make_ref_cue(d)
    (d / "w.cue").write_text('FILE "b.wav" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n')
    assert raises(ConvertError, conv, d / "w.cue", d / "o4", "x")


def case_chd(d):
    # A CHD of each form gives the same disc. Not from the WAV set: creating a CHD drops the part of a WAV's last
    # sector, which is chdman's and happens before this tool sees it
    chdman = find_tool("chdman")
    if not chdman:
        print("selftest: no chdman, CHD not checked")
        return
    ref = conv(make_ref_cue(d / "ref"), d / "o", "x")[0] / "x.cue"
    for n, source in enumerate((mixed_cue(d / "m"), ref)):
        chd = d / f"s{n}.chd"
        subprocess.run([chdman, "createcd", "-i", str(source), "-o", str(chd)], check=True, capture_output=True)
        same_disc(conv(chd, d / f"c{n}", "x"))
        assert [p.name for p in (d / f"c{n}").iterdir()] == ["x"], "a temporary file stayed"
    if os.name == "nt":
        # A Redump name in a deep folder, over chdman's 260 characters, read and written through junctions
        deep = Path(str(d.resolve()) + "/" + "f" * 120) / ("g" * 60)
        try:
            deep.mkdir(parents=True)
        except OSError:
            print("selftest: Windows long paths are off here, long CHD paths not checked")
        else:
            chd = deep / ("Bakumatsu Roman Daini Maku - Gekka no Kenshi - Tsuki ni Saku Hana, Chiri Yuku Hana ~ "
                          "The Last Blade 2 (Japan) (En,Ja,Es,Pt).chd")
            shutil.copyfile(d / "s1.chd", chd)
            assert len(str(chd)) > 260
            same_disc(conv(chd, deep / "out", "x"))
            assert [p.name for p in (deep / "out").iterdir()] == ["x"], "a temporary file stayed"
            long_name = chd.with_name("n" * 230 + ".chd")       # past 260 even through a junction
            chd.rename(long_name)
            assert raises(ConvertError, conv, long_name, deep / "out2", "x"), "a name chdman cannot open was taken"
    (d / "bad.chd").write_bytes(bytes(100))
    assert raises(ConvertError, conv, d / "bad.chd", d / "c9", "x"), "a bad CHD was taken"


def case_source_overwrite(d):
    # An output on top of its source would truncate the source before reading it
    (d / "same/z").mkdir(parents=True)
    (d / "same/z/z.bin").write_bytes(bytes(SECTOR))
    (d / "same/z/z.cue").write_text('FILE "z.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    assert raises(ConvertError, conv, d / "same/z/z.cue", d / "same", "z")
    assert (d / "same/z/z.bin").stat().st_size == SECTOR, "the source was overwritten"


def case_partial_and_skip(d):
    src = make_ref_cue(d / "ref")
    r = cdconv.convert(src, d / "out", "x")
    assert not r.skipped and (d / "out/x/x.bin").exists()
    assert not any(p.name.startswith(".") for p in (d / "out").iterdir())
    assert cdconv.convert(src, d / "out", "x").skipped
    (d / "out/x/x.cue").write_text("changed")
    assert not cdconv.convert(src, d / "out", "x", overwrite=True).skipped
    assert (d / "out/x/x.cue").read_text() != "changed"


def case_failure_leaves_nothing(d):
    bad = d / "bad.cue"
    bad.write_text('FILE "missing.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    assert raises(ConvertError, cdconv.convert, bad, d / "out", "bad")
    assert list((d / "out").iterdir()) == []          # no NAME/, no .NAME.partial


def case_cancel(d):
    ev = threading.Event()
    ev.set()
    assert raises(Cancelled, cdconv.convert, make_ref_cue(d / "ref"), d / "out", "x", cancel=ev)
    assert list((d / "out").iterdir()) == []


def case_progress(d):
    seen = []
    cdconv.convert(make_ref_cue(d / "ref"), d / "out", "x", progress=seen.append)
    assert seen and seen[-1] == 1.0 and seen == sorted(seen), seen


def case_stale_partial(d):
    (d / "out/.x.partial").mkdir(parents=True)
    (d / "out/.x.partial/junk").write_bytes(b"1")
    cdconv.convert(make_ref_cue(d / "ref"), d / "out", "x")
    assert sorted(p.name for p in (d / "out").iterdir()) == ["x"]


def case_names(d):
    assert default_name(Path("Metal Slug (1996)(SNK)(Jp-US)[!].cue")) == "Metal Slug"
    assert default_name(Path("Samurai Shodown RPG: Part 2? (Japan).cue")) == "Samurai Shodown RPG Part 2"
    assert safe_name(" Game.. ") == "Game"
    assert raises(ConvertError, safe_name, " ..:? ")
    assert raises(ConvertError, cdconv.convert, make_ref_cue(d / "ref"), d / "out", "<>")
    got = cdconv.assign_names([Path("a/Game (Japan).cue"), Path("b/Game (USA).cue"), Path("c/Other.cue")])
    assert [n for _, n, _ in got] == ["Game", "Game", "Other"]
    assert got[0][2] is None and got[1][2] == "same name as a/Game (Japan).cue" and got[2][2] is None
    got = cdconv.assign_names([Path("a.cue"), Path("b.cue")], ["One", "one"])
    assert got[1][2] == "same name as a.cue"


def case_find_discs(d):
    for f in ("A/a.cue", "A/a.ccd", "B/b.ccd", "C/c.chd", "C/c.txt"):
        (d / f).parent.mkdir(parents=True, exist_ok=True)
        (d / f).write_bytes(b"")
    assert [p.relative_to(d).as_posix() for p in cdconv.find_discs([d])] == ["A/a.cue", "B/b.ccd", "C/c.chd"]
    assert cdconv.find_discs([d / "C/c.txt"]) == [d / "C/c.txt"]      # a file is taken as given
    assert cdconv.needs(d / "C/c.chd") == {"chdman"} and cdconv.needs(d / "A/a.cue") == set()


def case_unknown_extension(d):
    (d / "x.txt").write_bytes(b"")
    assert raises(ConvertError, cdconv.convert, d / "x.txt", d / "out", "x")
    assert list((d / "out").iterdir()) == []


def case_chd_failure_cleans(d):
    # A CHD of zeros fails in the extraction
    if not find_tool("chdman"):
        print("selftest: no chdman, CHD clean-up not checked")
        return
    (d / "bad.chd").write_bytes(bytes(100))
    assert raises(ConvertError, cdconv.convert, d / "bad.chd", d / "out", "bad")
    assert list((d / "out").iterdir()) == []


def swap16(data):
    out = bytearray(data)
    out[0::2], out[1::2] = data[1::2], data[0::2]
    return bytes(out)


def case_motorola(d):
    make_ref_cue(d)
    (d / "b.bin").write_bytes(swap16(b"\x11\x22\x33\x44" * 588))
    (d / "c.bin").write_bytes(swap16(b"\x55\x66\x77\x88" * 700))
    (d / "m.cue").write_text((d / "x.cue").read_text().replace('"b.wav" WAVE', '"b.bin" MOTOROLA')
                             .replace('"c.wav" WAVE', '"c.bin" MOTOROLA'))
    same_disc(conv(d / "m.cue", d / "o", "x"))


def case_case_insensitive(d):
    make_ref_cue(d)
    (d / "u.cue").write_text((d / "x.cue").read_text().replace("a.iso", "A.ISO").replace("b.wav", "B.Wav"))
    same_disc(conv(d / "u.cue", d / "o", "x"))


def case_encodings(d):
    make_ref_cue(d)
    text = (d / "x.cue").read_text()
    (d / "bom.cue").write_bytes(b"\xef\xbb\xbf" + text.encode())
    same_disc(conv(d / "bom.cue", d / "o1", "x"))
    # Latin-1 and Shift-JIS file names, as European and Japanese sets have them
    for enc, stem in (("latin-1", "été"), ("cp932", "メタル")):
        (d / f"{stem}.iso").write_bytes((d / "a.iso").read_bytes())
        (d / f"{enc}.cue").write_bytes(text.replace("a.iso", f"{stem}.iso").encode(enc))
        same_disc(conv(d / f"{enc}.cue", d / f"o-{enc}", "x"))


def case_compressed(d):
    import os
    ffmpeg = find_tool("ffmpeg")
    if not ffmpeg:
        print("selftest: no ffmpeg, compressed audio not checked")
        return
    make_ref_cue(d)
    for s in "bc":
        subprocess.run([ffmpeg, "-v", "error", "-i", str(d / f"{s}.wav"), str(d / f"{s}.flac")], check=True)
    (d / "f.cue").write_text((d / "x.cue").read_text().replace(".wav", ".flac"))
    assert cdconv.needs(d / "f.cue") == {"ffmpeg"} and cdconv.needs(d / "x.cue") == set()
    same_disc(conv(d / "f.cue", d / "o", "x"))
    # No ffmpeg anywhere: not on the PATH, nor in the Unix folders searched besides it
    from cdconv import disc
    path, extra = os.environ["PATH"], disc.EXTRA_DIRS
    os.environ["PATH"], disc.EXTRA_DIRS = "", ()
    try:
        try:
            cdconv.convert(d / "f.cue", d / "o2", "x", tools={"ffmpeg": None})
            raise AssertionError("converted without ffmpeg")
        except ConvertError as e:
            assert "ffmpeg" in str(e), e
    finally:
        os.environ["PATH"], disc.EXTRA_DIRS = path, extra
    assert list((d / "o2").iterdir()) == []


def case_bad_wav(d):
    make_ref_cue(d)
    write_wav(d / "b.wav", bytes(4 * 588), rate=48000)
    try:
        conv(d / "x.cue", d / "o", "x")
        raise AssertionError("a 48 kHz WAV was taken")
    except ConvertError as e:
        assert "b.wav: WAV is 48000 Hz, needs 44100" in str(e), e


def case_mode2(d):
    (d / "m.bin").write_bytes(bytes(SECTOR))
    (d / "m.cue").write_text('FILE "m.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')
    try:
        conv(d / "m.cue", d / "o", "x")
        raise AssertionError("a MODE2 track was taken")
    except ConvertError as e:
        assert "MODE2" in str(e), e


def tone(sectors, seed):
    """Audio that is not the same read in either byte order."""
    return bytes((i * 5 + seed + i // SECTOR) & 0xFF for i in range(sectors * SECTOR))


def ref_tracks():
    """The disc every image format fixture encodes: (audio, pregap, 2,352-byte sectors, indices from the track's start).

    Track 2's two-second pregap is stored, as INDEX 00, since raw images keep it; track 3 has one sector of INDEX 00.
    """
    data = b"".join(mode1_sector(lba, bytes((lba + i) & 0xFF for i in range(USER))) for lba in range(20))
    return [(False, 0, data, {1: 0}),
            (True, 0, bytes(150 * SECTOR) + tone(10, 1), {0: 0, 1: 150}),
            (True, 0, tone(10, 2), {0: 0, 1: 1})]


def ref_image(d):
    """The reference disc as one BIN and CUE; returns the CUE's path."""
    d.mkdir(parents=True, exist_ok=True)
    lines, at = ['FILE "ref.bin" BINARY'], 0
    for no, (audio, pregap, data, indices) in enumerate(ref_tracks(), 1):
        lines.append(f"  TRACK {no:02d} {'AUDIO' if audio else 'MODE1/2352'}")
        lines += [f"    INDEX {i:02d} {msf_text(at + v)}" for i, v in sorted(indices.items())]
        at += len(data) // SECTOR
    (d / "ref.bin").write_bytes(b"".join(t[2] for t in ref_tracks()))
    (d / "ref.cue").write_text("\n".join(lines) + "\n")
    return d / "ref.cue"


def same_as_ref(d, image):
    """The image converts to what the reference BIN and CUE convert to."""
    want = conv(ref_image(d / "refimg"), d / "want", "x")[0]
    got = conv(image, d / "got", "x")[0]
    assert (got / "x.cue").read_text() == (want / "x.cue").read_text(), (got / "x.cue").read_text()
    assert (got / "x.bin").read_bytes() == (want / "x.bin").read_bytes()


def case_ref_image(d):
    out = conv(ref_image(d), d / "o", "x")[0]
    assert (out / "x.bin").read_bytes() == (d / "ref.bin").read_bytes()
    assert (out / "x.cue").read_text().splitlines()[3:] == ["  TRACK 02 AUDIO", "    INDEX 00 00:00:20",
                                                             "    INDEX 01 00:02:20", "  TRACK 03 AUDIO",
                                                             "    INDEX 00 00:02:30", "    INDEX 01 00:02:31"]


def ref_layout():
    """Each reference track's first sector (INDEX 00 or 01) and its INDEX LBAs, and the lead-out."""
    out, lba = [], 0
    for audio, _, data, indices in ref_tracks():
        out.append((lba, {i: lba + v for i, v in indices.items()}))
        lba += len(data) // SECTOR
    return out, lba


def make_ccd(d, sessions=1, mode=None):
    """The reference disc as CloneCD writes it: .ccd text laid out as cue2ccd's dataplusaudio fixture, .img, empty .sub."""
    d.mkdir(parents=True, exist_ok=True)
    layout, leadout = ref_layout()

    def msf(lba):
        lba += 150
        return lba // 4500, lba // 75 % 60, lba % 75
    entries = [(0xA0, 4, (1, 0, 0), 4350), (0xA1, 0, (3, 0, 0), 13350), (0xA2, 0, msf(leadout), leadout)]
    entries += [(no, 0 if t[0] else 4, msf(layout[no - 1][1][1]), layout[no - 1][1][1])
                for no, t in enumerate(ref_tracks(), 1)]
    text = ["[CloneCD]", "Version=3", "[Disc]", f"TocEntries={len(entries)}", f"Sessions={sessions}",
            "DataTracksScrambled=0", "CDTextLength=0", "[Session 1]", "PreGapMode=1", "PreGapSubC=0"]
    for n, (point, control, (m, s, f), plba) in enumerate(entries):
        text += [f"[Entry {n}]", "Session=1", f"Point=0x{point:02x}", "ADR=0x01", f"Control=0x{control:02x}",
                 "TrackNo=0", "AMin=0", "ASec=0", "AFrame=0", "ALBA=-150", "Zero=0",
                 f"PMin={m}", f"PSec={s}", f"PFrame={f}", f"PLBA={plba}"]
    for no, (t, (start, indices)) in enumerate(zip(ref_tracks(), layout), 1):
        text += [f"[TRACK {no}]", f"MODE={mode if mode is not None and not t[0] else (0 if t[0] else 1)}"]
        text += [f"INDEX {i}={v}" for i, v in sorted(indices.items())]
    (d / "ref.ccd").write_bytes(("\r\n".join(text) + "\r\n").encode("ascii"))       # CR LF, as CloneCD writes
    (d / "ref.img").write_bytes(b"".join(t[2] for t in ref_tracks()))
    (d / "ref.sub").write_bytes(b"")
    return d / "ref.ccd"


def case_clonecd(d):
    same_as_ref(d, make_ccd(d / "img"))


def case_clonecd_rejects(d):
    for n, (kw, word) in enumerate((({"sessions": 2}, "session"), ({"mode": 2}, "MODE2"))):
        try:
            conv(make_ccd(d / f"img{n}", **kw), d / f"o{n}", "x")
            raise AssertionError(f"taken: {kw}")
        except ConvertError as e:
            assert word in str(e), e


def with_sub(data, sub):
    """2,352-byte sectors with 96 bytes of subchannel after each when sub, filled with 0xA5 so a stride bug shows."""
    if not sub:
        return data
    return b"".join(data[n:n + SECTOR] + b"\xA5" * 96 for n in range(0, len(data), SECTOR))


def make_mds(d, sub=False, version=1, mode=None, sessions=1, stored=True, name="*.mdf"):
    """The reference disc as Alcohol 120% writes it, laid out as Aaru's Alcohol 120% writer does: a header, one session
    block at 0x60, entries A0, A1, A2 then the tracks, an extra block per track, the filename block naming *.mdf."""
    import struct
    d.mkdir(parents=True, exist_ok=True)
    layout, leadout = ref_layout()
    size = 2448 if sub else SECTOR
    tracks = ref_tracks()

    def msf(lba):
        lba += 150
        return lba // 4500, lba // 75 % 60, lba % 75
    entries_at = 0x60 + 24
    extra_at = entries_at + 80 * (3 + len(tracks))
    names_at = extra_at + 8 * len(tracks)
    blocks, extras, mdf = [], b"", b""
    for point, pmsf in ((0xA0, (1, 0, 0)), (0xA1, (len(tracks), 0, 0)), (0xA2, msf(leadout))):
        blocks.append(struct.pack("<BBBBB3BB3B", 0, 0, 0x14, 0, point, 0, 0, 0, 0, *pmsf).ljust(80, b"\0"))
    for no, ((audio, _, data, _), (start, indices)) in enumerate(zip(tracks, layout), 1):
        one = indices[1]
        pregap = 150 if no == 1 else one - indices.get(0, one)
        nxt = layout[no][0] if no < len(tracks) else leadout
        mode_byte = 0xA9 if audio else (mode or 0xAA)
        if not stored:
            data = data[(one - start) * SECTOR:]
        at = len(mdf) + (one - start if stored else 0) * size      # INDEX 01's byte in the .mdf
        mdf += with_sub(data, sub)
        block = struct.pack("<BBBBB3BB3BIH", mode_byte, 8 if sub else 0, 0x10 if audio else 0x14, 0, no, 0, 0, 0, 0,
                            *msf(one), extra_at + 8 * (no - 1), size).ljust(36, b"\0")
        block += struct.pack("<IQII", one, at, 1, names_at).ljust(44, b"\0")
        blocks.append(block)
        extras += struct.pack("<II", pregap, nxt - one)
    name = name.encode("utf-16-le") + b"\0\0"
    head = b"MEDIA DESCRIPTOR" + bytes((version, 5)) + struct.pack("<HH", 0, sessions)
    head = head.ljust(80, b"\0") + struct.pack("<II", 0x60, 0)
    session = struct.pack("<iiHBBHHII", -150, leadout, 1, 3 + len(tracks), 3, 1, len(tracks), 0, entries_at)
    mds = head.ljust(0x60, b"\0") + session + b"".join(blocks) + extras
    mds += struct.pack("<IIII", names_at + 16, 1, 0, 0) + name
    (d / "ref.mds").write_bytes(mds)
    (d / "ref.mdf").write_bytes(mdf)
    return d / "ref.mds"


def case_alcohol(d):
    same_as_ref(d, make_mds(d / "img"))


def case_alcohol_sub(d):
    same_as_ref(d, make_mds(d / "img", sub=True))


def case_alcohol_names_and_gaps(d):
    # A literal UTF-16 name whose characters have a zero byte on either side, and pregaps left out of the .mdf
    img = make_mds(d / "img", name="@Ā.mdf")
    (d / "img/ref.mdf").rename(d / "img/@Ā.mdf")
    same_as_ref(d / "named", img)
    out = conv(make_mds(d / "gaps", stored=False), d / "o", "x")[0]
    assert (out / "x.cue").read_text().splitlines()[3:] == ["  TRACK 02 AUDIO", "    PREGAP 00:02:00",
                                                             "    INDEX 01 00:00:20", "  TRACK 03 AUDIO",
                                                             "    PREGAP 00:00:01", "    INDEX 01 00:00:30"]
    ref = (d / "named/want/x/x.bin").read_bytes()
    assert (out / "x.bin").read_bytes() == ref[:20 * SECTOR] + ref[170 * SECTOR:180 * SECTOR] + ref[181 * SECTOR:]


def case_alcohol_rejects(d):
    for n, (kw, word) in enumerate((({"version": 2}, "version 2"), ({"mode": 0xAB}, "MODE2"),
                                    ({"sessions": 2}, "session"))):
        try:
            conv(make_mds(d / f"img{n}", **kw), d / f"o{n}", "x")
            raise AssertionError(f"taken: {kw}")
        except ConvertError as e:
            assert word in str(e), e


def make_nrg(d, version=2, tao=False, sessions=1, iso=False):
    """The reference disc as Nero writes it: track data from byte 0, then big-endian chunks (CUES/CUEX, DAOI/DAOX or
    ETNF/ETN2, SINF, MTYP, END!) and the NERO or NER5 footer. A DAO image keeps track 1's 150-sector pregap and every
    later pregap in the file; iso stores the data track as 2,048-byte sectors (mode 0x00). TAO keeps no pregap."""
    import struct
    d.mkdir(parents=True, exist_ok=True)
    layout, leadout = ref_layout()
    wide = version == 2
    q = "Q" if wide else "I"
    body, rows, cue = b"", [], [struct.pack(">BBBBi", 0x41, 0, 0, 0, -150)]
    for no, ((audio, _, data, _), (start, indices)) in enumerate(zip(ref_tracks(), layout), 1):
        size = USER if iso and not audio else SECTOR
        if not audio and iso:
            data = b"".join(data[n + 16:n + 16 + USER] for n in range(0, len(data), SECTOR))
        if tao and no > 1:
            data = data[(indices[1] - start) * SECTOR:]
        pregap = bytes(150 * size) if no == 1 and not tao else b""
        zero = len(body)
        body += pregap + data
        one = len(body) - len(data) + (0 if tao else (indices[1] - start) * size)
        mode = 0x07 if audio else (0x00 if iso else 0x05)
        rows.append((size, mode, zero, one, len(body), indices[1]))
        bcd = int(str(no), 16)
        cue += [struct.pack(">BBBBi", 0x01 if audio else 0x41, bcd, 0, 0, indices.get(0, indices[1]) - (150 if no == 1 else 0)),
                struct.pack(">BBBBi", 0x01 if audio else 0x41, bcd, 1, 0, indices[1])]
    cue.append(struct.pack(">BBBBi", 0x01, 0xAA, 1, 0, leadout))

    def chunk(name, data):
        return name + struct.pack(">I", len(data)) + data
    chunks = b""
    if tao:
        etn = b""
        for size, mode, zero, one, end, lba in rows:
            etn += struct.pack(f">{q}{q}II", one, end - one, mode, lba)
            etn += struct.pack(">II", 0, (end - one) // size) if wide else struct.pack(">I", 0)
        chunks += chunk(b"ETN2" if wide else b"ETNF", etn)
    else:
        dao = struct.pack(">I", 0) + bytes(13) + bytes((0, 0, 1, 1, len(rows)))
        for size, mode, zero, one, end, _ in rows:
            dao += bytes(12) + struct.pack(f">HBBH{q}{q}{q}", size, mode, 0, 1, zero, one, end)
        dao = struct.pack(">I", len(dao)) + dao[4:]
        chunks += chunk(b"CUEX" if wide else b"CUES", b"".join(cue)) + chunk(b"DAOX" if wide else b"DAOI", dao)
    for _ in range(sessions):
        chunks += chunk(b"SINF", struct.pack(">I", len(rows)))
    chunks += chunk(b"MTYP", struct.pack(">I", 1)) + chunk(b"END!", b"")
    footer = b"NER5" + struct.pack(">Q", len(body)) if wide else b"NERO" + struct.pack(">I", len(body))
    (d / "ref.nrg").write_bytes(body + chunks + footer)
    return d / "ref.nrg"


def case_nero_v1_dao(d):
    same_as_ref(d, make_nrg(d / "img", version=1, iso=True))


def case_nero_v2_dao(d):
    same_as_ref(d, make_nrg(d / "img", version=2))


def case_nero_v2_tao(d):
    # Track at once keeps no pregap in the image: each later track gets the two seconds as a PREGAP
    for version in (1, 2):
        out = conv(make_nrg(d / f"img{version}", version=version, tao=True), d / f"o{version}", "x")[0]
        assert (out / "x.cue").read_text().splitlines()[3:] == ["  TRACK 02 AUDIO", "    PREGAP 00:02:00",
                                                                 "    INDEX 01 00:00:20", "  TRACK 03 AUDIO",
                                                                 "    PREGAP 00:02:00", "    INDEX 01 00:00:30"]
        ref = b"".join(t[2] for t in ref_tracks())
        assert (out / "x.bin").read_bytes() == ref[:20 * SECTOR] + ref[170 * SECTOR:180 * SECTOR] + ref[181 * SECTOR:]


def case_nero_rejects(d):
    try:
        conv(make_nrg(d / "img", sessions=2), d / "o", "x")
        raise AssertionError("two sessions taken")
    except ConvertError as e:
        assert "session" in str(e), e
    (d / "junk.nrg").write_bytes(bytes(64))
    assert raises(ConvertError, conv, d / "junk.nrg", d / "o2", "x")


CDI_VERSIONS = {2: 0x80000004, 3: 0x80000005, 35: 0x80000006}


def make_cdi(d, version=35, iso=False, sub=False, sessions=1, word=None):
    """The reference disc as DiscJuggler writes it: the tracks back to back from byte 0, each behind its stored
    pregap (track 1's 150 sectors too), then the descriptor and an 8-byte footer (version word, header offset:
    absolute in 2 and 3, from the end in 3.5). The descriptor's bytes follow cdirip's reading order; its filler
    bytes are those libmirage's v3.5 framing names (sector count of the disc, medium 0x98, two indices)."""
    import struct
    d.mkdir(parents=True, exist_ok=True)
    layout, leadout = ref_layout()
    tracks = ref_tracks()
    body, descs = b"", []
    for no, ((audio, _, data, _), (start, indices)) in enumerate(zip(tracks, layout), 1):
        size = USER if iso and not audio else (2448 if sub else SECTOR)
        code = {USER: 0, SECTOR: 2, 2448: 4}[size]
        if iso and not audio:
            data = b"".join(data[n + 16:n + 16 + USER] for n in range(0, len(data), SECTOR))
        else:
            data = with_sub(data, sub)
        pregap = 150 if no == 1 else indices[1] - start
        if no == 1:
            data = bytes(150 * size) + data
        total = len(data) // size
        body += data
        name = b"ref.cdi"
        t = struct.pack("<I", 0) + b"\0\0\x01\0\0\0\xff\xff\xff\xff" * 2 + b"\0\0\0" + bytes((len(tracks),))
        t += bytes((len(name),)) + name + bytes(11) + b"\x02" + bytes(7)
        t += struct.pack("<IIHHHII", 0x80000000, leadout, 0, 0x98, 2, pregap, total - pregap)
        t += struct.pack("<IH", 0, 0) + struct.pack("<I", 0 if audio else 1)
        t += struct.pack("<III", 0, 0, no - 1) + struct.pack("<II", indices[1] + 150 - pregap, total) + bytes(16)
        t += struct.pack("<I", code) + struct.pack("<I", 0 if audio else 4) + bytes(25)
        if version != 2:
            t += b"\0" + b"\xff" * 8 + bytes(78)
        descs.append(t)
    head = struct.pack("<HH", sessions, len(tracks) - (sessions > 1))
    desc = head + b"".join(descs[:len(tracks) - (sessions > 1)])
    if sessions > 1:
        desc += bytes(12 if version == 2 else 13) + struct.pack("<H", 1) + descs[-1]
    desc += bytes(12 if version == 2 else 13) + bytes(14) + bytes(40)       # trailer, empty session, disc block
    footer_at = len(body) + len(desc)
    where = footer_at + 8 - len(body) if version == 35 else len(body)
    (d / "ref.cdi").write_bytes(body + desc + struct.pack("<II", word or CDI_VERSIONS[version], where))
    return d / "ref.cdi"


def case_cdi_v2(d):
    same_as_ref(d, make_cdi(d / "img", version=2, iso=True))


def case_cdi_v3(d):
    same_as_ref(d, make_cdi(d / "img", version=3))


def case_cdi_v35(d):
    same_as_ref(d, make_cdi(d / "img", version=35, sub=True))


def case_cdi_rejects(d):
    for n, (kw, word) in enumerate((({"word": 0x80000007}, "0x80000007"), ({"sessions": 2}, "session"))):
        try:
            conv(make_cdi(d / f"img{n}", **kw), d / f"o{n}", "x")
            raise AssertionError(f"taken: {kw}")
        except ConvertError as e:
            assert word in str(e), e


def case_gui_helpers(d):
    import os
    from cdconv.disc import install_hint
    for tool in ("ffmpeg", "chdman"):
        for system in ("Windows", "Darwin", "Linux"):
            assert install_hint(tool, system), (tool, system)
    try:
        import tkinter  # noqa: F401
    except ImportError:
        print("selftest: no tkinter, the window's helpers not checked")
        return
    import cd_convert_gui as gui
    p = Path("E:/")
    assert gui.sd_dest(p, True) == Path("E:/Assets/ngcd/common") and gui.sd_dest(p, False) == p
    keys = ("APPDATA", "XDG_CONFIG_HOME", "HOME", "USERPROFILE")
    saved = {k: os.environ.get(k) for k in keys}
    try:
        for k in keys:
            os.environ[k] = str(d)
        tail = Path("NeoMillieCD/converter.json")
        assert gui.config_path("Windows") == d / tail
        assert gui.config_path("Darwin") == d / "Library/Application Support" / tail
        assert gui.config_path("Linux") == d / tail
        del os.environ["XDG_CONFIG_HOME"]
        assert gui.config_path("Linux") == d / ".config" / tail
        os.environ["XDG_CONFIG_HOME"] = str(d)
        assert gui.load_config() == {}
        gui.save_config({"dest": "E:/", "ffmpeg": "C:/ff/ffmpeg.exe"})
        assert gui.load_config() == {"dest": "E:/", "ffmpeg": "C:/ff/ffmpeg.exe"}
        gui.config_path().write_text("{not json")
        assert gui.load_config() == {}
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def case_python38_write_text(d):
    # Path.write_text takes newline= only from Python 3.10: a conversion must work with 3.8's signature
    orig = Path.write_text

    def old(self, data, encoding=None, errors=None):
        return orig(self, data, encoding, errors)
    Path.write_text = old
    try:
        conv(ref_image(d / "img"), d / "o", "x")
    finally:
        Path.write_text = orig
    assert b"\r" not in (d / "o/x/x.cue").read_bytes()


def case_noisy_ffmpeg(d):
    # A damaged MP3 makes ffmpeg write far more errors than a pipe holds: the conversion must still end
    import struct
    ffmpeg = find_tool("ffmpeg")
    if not ffmpeg:
        print("selftest: no ffmpeg, a damaged MP3 not checked")
        return
    x, noise = 1, bytearray()
    for _ in range(44100 * 20 * 2):
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        noise += struct.pack("<h", (x >> 16) - 16384)
    write_wav(d / "n.wav", bytes(noise))
    subprocess.run([ffmpeg, "-v", "error", "-i", str(d / "n.wav"), str(d / "n.mp3")], check=True)
    b = bytearray((d / "n.mp3").read_bytes())
    for n in range(4096, len(b) - 64, 150):
        b[n:n + 48] = bytes((n * 7 + k) & 0xFF for k in range(48))
    (d / "n.mp3").write_bytes(b)
    (d / "n.cue").write_text('FILE "n.mp3" MP3\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n')
    done = []

    def run():
        try:
            conv(d / "n.cue", d / "o", "x")
        except ConvertError:
            pass
        done.append(1)
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(60)
    assert done, "the conversion of a damaged MP3 did not end"


def case_shift_jis_0x85(d):
    # 0x85 is the second byte of many Shift-JIS characters, and U+0085 is a line break to str.splitlines
    make_ref_cue(d)
    stem = "ニュー"
    assert b"\x85" in stem.encode("cp932")
    (d / f"{stem}.iso").write_bytes((d / "a.iso").read_bytes())
    (d / "s.cue").write_bytes((d / "x.cue").read_text().replace("a.iso", f"{stem}.iso").encode("cp932"))
    same_disc(conv(d / "s.cue", d / "o", "x"))


def case_bad_sheets(d):
    # Damaged sheets and files fail as ConvertError, which the CLI and the window report, not as a traceback
    make_ref_cue(d)
    bad = {"noindex": 'FILE "a.iso" BINARY\n  TRACK 01 MODE1/2048\n',
           "msf": 'FILE "a.iso" BINARY\n  TRACK 01 MODE1/2048\n    INDEX 01 00:xx:00\n',
           "order": 'FILE "a.iso" BINARY\n    INDEX 01 00:00:00\n  TRACK 01 MODE1/2048\n',
           "riff": 'FILE "a.iso" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n'}
    for name, text in bad.items():
        (d / f"{name}.cue").write_text(text)
        assert raises(ConvertError, conv, d / f"{name}.cue", d / f"o-{name}", "x"), name
        assert cdconv.needs(d / f"{name}.cue") == set()
    assert raises(ConvertError, conv, d / "nothing.cue", d / "o-nothing", "x")


def case_tool_search(d):
    # Tools a macOS .app cannot see on its PATH: Homebrew's folders are searched too
    import os
    from cdconv import disc
    (d / "bin").mkdir()
    tool = d / "bin" / ("chdman.exe" if os.name == "nt" else "chdman")
    tool.write_bytes(b"")
    tool.chmod(0o755)
    path, extra = os.environ["PATH"], disc.EXTRA_DIRS
    os.environ["PATH"] = ""
    try:
        disc.EXTRA_DIRS = (str(d / "bin"),)
        assert find_tool("chdman") and Path(find_tool("chdman")).parent == d / "bin"
    finally:
        os.environ["PATH"], disc.EXTRA_DIRS = path, extra


def case_app_icon(d):
    # The window's and the executables' icon: NeoMillieCD's Millie and disc as PNG, ICO and ICNS
    import struct
    import zlib
    import make_logo
    p = make_logo.png(True, 36)
    assert p[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", p[16:24]) == (36, 36)
    raw = zlib.decompress(p[p.index(b"IDAT") + 4:p.index(b"IEND") - 8])
    assert len(raw) == 36 * (1 + 36 * 4)
    rows = make_logo.art(True)
    x, y = rows[12].index("*"), 12         # an eye's glint, white
    at = y * (1 + 36 * 4) + 1 + x * 4
    assert raw[at:at + 4] == bytes((255, 255, 255, 255)), raw[at:at + 4]
    assert raw[1:5] == bytes(4)            # the top left corner is outside her: transparent
    big = make_logo.png(True, 256)
    assert struct.unpack(">II", big[16:24]) == (256, 256)
    ico = make_logo.ico(True)
    count, = struct.unpack_from("<H", ico, 4)
    assert ico[:4] == b"\0\0\1\0" and count >= 4
    for n in range(count):
        w, size, offset = ico[6 + 16 * n], *struct.unpack_from("<II", ico, 6 + 16 * n + 8)
        assert ico[offset:offset + 8] == b"\x89PNG\r\n\x1a\n" and offset + size <= len(ico)
        assert struct.unpack(">I", ico[offset + 16:offset + 20])[0] == (w or 256)
    icns = make_logo.icns(True)
    assert icns[:4] == b"icns" and struct.unpack(">I", icns[4:8])[0] == len(icns) and b"ic09" in icns


FORMATS = {"Cue Bin": lambda p: ref_image(p), "CloneCD": make_ccd, "Alcohol": make_mds,
           "Alcohol Sub": lambda p: make_mds(p, sub=True), "Nero 1": lambda p: make_nrg(p, version=1, iso=True),
           "Nero 2": make_nrg, "DiscJuggler 2": lambda p: make_cdi(p, version=2, iso=True),
           "DiscJuggler 3": lambda p: make_cdi(p, version=3), "DiscJuggler 35": lambda p: make_cdi(p, version=35, sub=True)}


def all_formats(d):
    """A folder of discs: the reference disc in every image format, each under its own name, a CUE whose BIN is
    missing ("Broken"), and two copies of the reference CUE whose names give one name ("Same"). Returns the folder."""
    src = d / "discs"
    for name, build in FORMATS.items():
        image = build(src / name)
        for f in list(image.parent.iterdir()):
            if f.stem == "ref" and f.suffix != ".bin":      # the CUE's BIN keeps the name its CUE gives
                f.rename(f.with_name(name + f.suffix))
    (src / "Broken").mkdir()
    (src / "Broken/Broken.cue").write_text('FILE "missing.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')
    for folder, stem in (("Same A", "Same (Japan)"), ("Same B", "Same (USA)")):
        ref_image(src / folder).rename(src / folder / f"{stem}.cue")
    return src


def check_all_formats(out, d):
    """Every good disc of all_formats converted in out, each the reference disc under its name."""
    want = conv(ref_image(d / "want-src"), d / "want", "x")[0]
    for name in list(FORMATS) + ["Same"]:
        got = out / name
        assert (got / f"{name}.bin").read_bytes() == (want / "x.bin").read_bytes(), name
        assert (got / f"{name}.cue").read_text() == (want / "x.cue").read_text().replace("x.bin", f"{name}.bin"), name
    assert sorted(p.name for p in out.iterdir()) == sorted(list(FORMATS) + ["Same"]), sorted(p.name for p in out.iterdir())


def run_cli(*args):
    """cd_convert.main with its printed lines and exit code."""
    import contextlib
    import io
    import cd_convert
    text = io.StringIO()
    with contextlib.redirect_stdout(text), contextlib.redirect_stderr(io.StringIO()):
        code = cd_convert.main([str(a) for a in args])
    return code, text.getvalue().splitlines()


def case_cli_all_formats(d):
    src = all_formats(d)
    code, lines = run_cli(src, d / "out")
    assert code == 1 and len(lines) == len(FORMATS) + 3, lines         # the broken disc and the second "Same" fail
    assert sum("sectors in the BIN" in line for line in lines) == len(FORMATS) + 1, lines
    assert any(line.endswith("Broken.cue: missing.bin not found") for line in lines), lines
    assert any(line.endswith("same name as " + (src / "Same A/Same (Japan).cue").as_posix()) for line in lines), lines
    check_all_formats(d / "out", d)
    code, lines = run_cli(src, d / "out")
    assert sum(line.endswith(": already there") for line in lines) == len(FORMATS) + 1, lines
    (d / "out/Nero 2/Nero 2.cue").write_text("changed")
    code, lines = run_cli(src, d / "out", "--overwrite")
    assert sum("sectors in the BIN" in line for line in lines) == len(FORMATS) + 1, lines
    check_all_formats(d / "out", d)


def case_gui_all_formats(d):
    # The window as a person uses it: add the folder, SD card layout on, Convert; again; then Cancel
    import os
    import time
    try:
        import tkinter as tk
        import cd_convert_gui as gui
    except ImportError:
        print("selftest: no tkinter, the window not checked")
        return
    keys = ("APPDATA", "XDG_CONFIG_HOME", "HOME", "USERPROFILE")
    saved = {k: os.environ.get(k) for k in keys}
    for k in keys:
        os.environ[k] = str(d / "home")        # the owner's converter.json stays as it is
    try:
        try:
            app = gui.App()
        except tk.TclError as e:
            print(f"selftest: no display ({e}), the window not checked")
            return
        try:
            def convert(cancel=False):
                app.start()
                if cancel:
                    app.cancel.set()
                t = time.time()
                while app.worker is not None or not app.events.empty():
                    app.update()
                    time.sleep(0.01)
                    assert time.time() - t < 120, "the window's conversion did not end"
                app.update()
                return [(app.tree.set(i, "name"), app.tree.set(i, "status")) for i in app.tree.get_children()]
            app.dest.set(str(d / "sd"))
            app.sd_layout.set(True)
            app.add([all_formats(d)])
            rows = convert()
            assert len(rows) == len(FORMATS) + 3, rows
            done = [n for n, s in rows if s == "done"]
            assert sorted(done) == sorted(list(FORMATS) + ["Same"]), rows
            assert ("Broken", "error: Broken.cue: missing.bin not found") in rows, rows
            assert sum(s.startswith("error: same name as") for _, s in rows) == 1, rows
            common = d / "sd/Assets/ngcd/common"
            check_all_formats(common, d)
            again = convert()
            assert all(s2 == ("already there" if s == "done" else s) for (_, s), (_, s2) in zip(rows, again)), again
            for p in common.iterdir():
                shutil.rmtree(p)
            rows = convert(cancel=True)
            assert all(s in ("cancelled", "done") or s.startswith("error") for _, s in rows), rows
            assert all(not p.name.startswith(".") for p in common.iterdir()), list(common.iterdir())
            assert len(list(common.iterdir())) == sum(s == "done" for _, s in rows)
            assert json.loads(gui.config_path().read_text())["dest"] == str(d / "sd")     # under d / "home" on each system
        finally:
            app.destroy()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def case_cue_file_paths(d):
    # FILE lines as other tools write them: a path of another PC, backslashes, a folder in another case, no quotes
    make_ref_cue(d)
    text = (d / "x.cue").read_text()
    (d / "abs.cue").write_text(text.replace('"a.iso"', '"C:\\Rips\\Metal Slug\\a.iso"'))
    same_disc(conv(d / "abs.cue", d / "o1", "x"))
    (d / "Sub").mkdir()
    (d / "Sub/a.iso").write_bytes((d / "a.iso").read_bytes())
    (d / "sub.cue").write_text(text.replace('"a.iso"', '"SUB\\A.ISO"'))
    same_disc(conv(d / "sub.cue", d / "o2", "x"))
    (d / "bare.cue").write_text(text.replace('"a.iso"', "a.iso").replace('"b.wav"', "b.wav"))
    same_disc(conv(d / "bare.cue", d / "o3", "x"))


def case_reserved_and_empty_names(d):
    # Windows refuses CON, NUL, AUX, PRN, COM1 to COM9 and LPT1 to LPT9 as folder names, with any extension
    for n in ("CON", "nul", "Aux", "COM1", "lpt9", "CON.x"):
        assert safe_name(n).upper() not in ("CON", "NUL", "AUX", "COM1", "LPT9", "CON.X") and safe_name(n), n
    assert safe_name("Console") == "Console"
    # A name that is empty before its first bracket keeps the whole stem
    assert default_name(Path("[BIOS] Neo Geo CD.cue")) == "[BIOS] Neo Geo CD"


def case_clonecd_negative_index(d):
    # A sheet that gives track 1 an INDEX 0 before LBA 0 (its unstored pregap) prints no negative time
    ccd = make_ccd(d / "img")
    text = ccd.read_bytes().replace(b"[TRACK 1]\r\nMODE=1\r\n", b"[TRACK 1]\r\nMODE=1\r\nINDEX 0=-150\r\n")
    assert b"INDEX 0=-150" in text
    ccd.write_bytes(text)
    same_as_ref(d, ccd)


def case_overwrite_other_case(d):
    # --overwrite into a folder that differs from the source's only in case must not delete the source
    import os
    src = ref_image(d / "out/game")
    probe = d / "out/GAME"
    if not probe.exists() or not os.path.samefile(probe, d / "out/game"):
        print("selftest: a case-sensitive file system, the overwrite of a folder in another case not checked")
        return
    assert raises(ConvertError, cdconv.convert, src, d / "out", "Game", overwrite=True)
    assert src.exists() and (d / "out/game/ref.bin").exists()


def case_discjuggler_not_in_memory(d):
    # A .cdi is read from its end: its tracks (hundreds of MB) are never read whole into memory
    image = make_cdi(d / "img")
    orig = Path.read_bytes

    def refuse(self):
        if self.suffix == ".cdi":
            raise AssertionError("the whole .cdi was read into memory")
        return orig(self)
    Path.read_bytes = refuse
    try:
        same_as_ref(d, image)
    finally:
        Path.read_bytes = orig


def case_sd_layout_once(d):
    try:
        import tkinter  # noqa: F401
        import cd_convert_gui as gui
    except ImportError:
        print("selftest: no tkinter, the SD card layout not checked")
        return
    common = Path("E:/Assets/ngcd/common")
    assert gui.sd_dest(common, True) == common and gui.sd_dest(Path("E:/assets/NGCD/Common"), True).parts[-1] == "Common"


def case_cli(d):
    import contextlib
    import io
    import cd_convert
    src = make_ref_cue(d / "ref")
    (d / "bad").mkdir()
    (d / "bad/bad.cue").write_text('FILE "missing.bin" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n')

    def cli(*args):
        text = io.StringIO()
        with contextlib.redirect_stdout(text), contextlib.redirect_stderr(io.StringIO()):
            code = cd_convert.main([str(a) for a in args])
        return code, text.getvalue()
    assert cli(src, d / "o", "--name", "Y") == (0, f"Y: 5 sectors in the BIN, 155 on the disc, {5 * SECTOR} bytes\n")
    assert cli(src, d / "o", "--name", "Y") == (0, "Y: already there\n")
    code, text = cli(d / "ref", d / "bad", d / "o")
    assert code == 1 and text.splitlines() == ["x: 5 sectors in the BIN, 155 on the disc, 11760 bytes",
                                               f"{d / 'bad/bad.cue'}: bad.cue: missing.bin not found"], text
    assert raises(SystemExit, cli, d / "ref", d / "bad", d / "o", "--name", "Z")
    # A missing source and a DEST that is a file are reported per disc, not as a traceback
    (d / "file").write_bytes(b"")
    code, text = cli(d / "nothing.cue", d / "o")
    assert code == 1 and text.startswith(str(d / "nothing.cue")), text
    code, text = cli(src, d / "file")
    assert code == 1 and text.startswith(str(src)), text


def run():
    with tempfile.TemporaryDirectory() as root:
        for name, case in [(k, v) for k, v in globals().items() if k.startswith("case_")]:
            d = Path(root) / name
            d.mkdir()
            case(d)
    print("selftest ok")
