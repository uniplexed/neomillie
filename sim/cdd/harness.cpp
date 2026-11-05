// SPDX-License-Identifier: GPL-3.0-only
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3 of the License only.

// The golden trace: MiSTer's cdd_t, untouched, driven by commands.txt the way neogeocd.cpp drives it.
// harness <commands.txt> prints to stdout, for each line of the file:
//   cmd <40-bit hex>   neocd_poll's command path: the reset check, SetCommand, CommandExec, its return ignored
//   tick               Update
//   reset              the command MiSTer's FPGA sends when nRESET falls: cmd 00000000ff
//   disc <0..4>        neocd_set_image with a scripted TOC, prints nothing
// The state after each line, as <status word> <latency> <isData> <status>, follows that line's
// send <index> <len> <lba> lines. Update leaves stat[] alone, so GetStatus at the end of a tick line gives
// what neocd_poll sent before it.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

// What the vendored files need of the MiSTer program. Their includes of file_io.h, libchdr/chd.h and
// mister_chd.h find the empty files prepare.py leaves. No file is ever open: the trace is the position,
// not the sectors
struct fileTYPE {
    long long size;
    int opened() { return 0; }
};
static int FileOpen(fileTYPE *, const char *) { return 0; }
static void FileClose(fileTYPE *) {}
static int FileSeek(fileTYPE *, long long, int) { return 1; }
static int FileReadAdv(fileTYPE *, void *, int) { return 0; }
static int FileLoad(const char *, void *, int) { return 0; }
static const char *getFullPath(const char *name) { return name; }

struct chd_file;
typedef int chd_error;
#define CHDERR_NONE 0
#define CD_MAX_SECTOR_DATA 2352
static void chd_close(chd_file *) {}
static const char *chd_error_string(chd_error) { return ""; }
static chd_error mister_load_chd(const char *, void *) { return 1; }
static chd_error mister_chd_read_sector(chd_file *, int, uint32_t, uint32_t, int, uint8_t *, uint8_t *, int *) { return 1; }

// TOC 5 of track 00 reads toc.tracks[-1], 360 bytes in front of cdd: undefined in the C++. MinGW's layout
// happens to have zeros there, which is what cdd_drive.sv answers (a track past the last, start 0); a Linux
// link has libc's data there. On Linux, cdd goes in a section of its own behind 1 KB of zeros, in that order
// by prepare.py's --sort-section=name. The Windows build is left as it was.
#if !defined(_WIN32)
class cdd_t;
extern cdd_t cdd __attribute__((section(".bss.cdd_1")));
__attribute__((used, section(".bss.cdd_0"))) static char before_cdd[1024];
#endif

// Only for this file's reach into the TOC and the position: cdd_t's logic stays as it is
#define private public
#include "support/megacd/megacdd.cpp"
#undef private

static const int CRC_START = 5;
static int need_reset = 0;

static int send_data(uint8_t *, int len, uint8_t index)
{
    printf("send %d %d %d\n", index, len, cdd.lba);
    return 1;
}

// Three tracks in one file, one data track, data and an audio track with a pregap, or 12 tracks: a data
// track and 11 of audio, 40 sectors each, as tracks numbered 10 and over have two BCD digits
static void set_disc(int n)
{
    struct { TrackType type; int start, end; } t[3][3] = {
        { { TT_MODE1, 0, 1000 }, { TT_CDDA, 1000, 2000 }, { TT_CDDA, 2000, 3000 } },
        { { TT_MODE1, 0, 500 } },
        { { TT_MODE1, 0, 1000 }, { TT_CDDA, 1150, 2000 } },
    };

    cdd.Unload();
    if (n == 0) {
        cdd.status = CD_STAT_NO_DISC;   // a Load that fails
    } else if (n == 4) {
        cdd.toc.last = 12;
        cdd.toc.tracks[0].type = TT_MODE1;
        cdd.toc.tracks[0].start = 0;
        cdd.toc.tracks[0].end = 1000;
        cdd.toc.tracks[0].sector_size = 2352;
        for (int i = 1; i < 12; i++) {
            cdd.toc.tracks[i].type = TT_CDDA;
            cdd.toc.tracks[i].start = 1000 + (i - 1) * 40;
            cdd.toc.tracks[i].end = 1000 + i * 40;
            cdd.toc.tracks[i].sector_size = 2352;
        }
        cdd.toc.end = cdd.toc.tracks[11].end;
        cdd.toc.tracks[12].start = cdd.toc.end;
        cdd.sectorSize = 2352;
        cdd.loaded = 1;
        cdd.status = CD_STAT_STOP;
        cdd.latency = 10;
    } else {
        cdd.toc.last = n == 1 ? 3 : n == 2 ? 1 : 2;
        for (int i = 0; i < cdd.toc.last; i++) {
            cdd.toc.tracks[i].type = t[n - 1][i].type;
            cdd.toc.tracks[i].start = t[n - 1][i].start;
            cdd.toc.tracks[i].end = t[n - 1][i].end;
            cdd.toc.tracks[i].sector_size = 2352;
        }
        cdd.toc.end = cdd.toc.tracks[cdd.toc.last - 1].end;
        cdd.toc.tracks[cdd.toc.last].start = cdd.toc.end;   // as Load
        cdd.sectorSize = 2352;
        cdd.loaded = 1;
        cdd.status = CD_STAT_STOP;
        cdd.latency = 10;
    }
    need_reset = 1;
}

static void command(uint64_t c)
{
    if (need_reset || (c & 0xFFFF) == 0xFF) {
        need_reset = 0;
        cdd.Reset();
    }
    cdd.SetCommand(c, CRC_START);
    cdd.CommandExec();
}

int main(int argc, char **argv)
{
    FILE *f = argc > 1 ? fopen(argv[1], "r") : NULL;
    if (!f) {
        fprintf(stderr, "usage: harness <commands.txt>\n");
        return 2;
    }
    cdd.SendData = send_data;

    char line[128];
    for (int n = 1; fgets(line, sizeof(line), f); n++) {
        uint64_t c;
        int d;
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') continue;
        if (sscanf(line, "disc %d", &d) == 1) {
            set_disc(d);
            continue;
        }
        if (sscanf(line, "cmd %" SCNx64, &c) == 1) command(c);
        else if (!strncmp(line, "reset", 5)) command(0xFF);
        else if (!strncmp(line, "tick", 4)) cdd.Update();
        else {
            fprintf(stderr, "commands.txt:%d: %s", n, line);
            return 2;
        }
        printf("%010" PRIx64 " %u %u %x\n", cdd.GetStatus(CRC_START), cdd.latency, cdd.isData, cdd.status);
    }
    return 0;
}
