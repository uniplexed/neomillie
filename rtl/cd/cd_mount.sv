// SPDX-License-Identifier: GPL-3.0-only
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3 of the License only.
//
// The TOC arithmetic is that of cdd_t::LoadCUE in megacdd.cpp of MiSTer's Main (GPL-3), as vendored in
// sim/cdd/mister/megacdd.cpp:177-231.

// The disc mount, at the bridge clock: what MiSTer's ARM does in cdd_t::Load. On cd_mount_req, sniff the
// picked file (slot 2), parse it if it is a CUE, open its BIN in slot 3 and build the TOC that cdd_drive
// reads. disc_loading is high from cd_mount_req to the end; disc_present only on success; a new cd_mount_req
// drops disc_present at once and starts again, after a command in flight has been answered.
//
// 1. Wait SWEEP_CLKS, two of apf_loader's data table sweeps, before sampling disc_size: cd_mount_req comes
//    one sweep before the size (apf_loader.sv:290-319). 0 is no disc.
// 2. Read the first min(disc_size, 2352) bytes of slot 2 into bank slot 0. MODE1 sync (00 FF x10 00) at
//    byte 0: a raw BIN, one data track of file 0 from 0 to disc_size / 2352. Else if the first 64 bytes are
//    printable ASCII, tab, CR or LF: a CUE. Else no disc (an ISO of 2,048-byte sectors, an audio BIN).
// 3. A CUE longer than MAX_CUE_BYTES, the bank's 4 x 2,352, is no disc. The rest is read in pieces of
//    min(disc_size - offset, 2352) into bank slots 1 to 3: byte i of the CUE is then bank word i / 4, lane
//    i % 4 of {b0, b1, b2, b3}. A read past the file's end is expected to fail, so none is asked for.
// 4. Parse, a line at a time, CR or LF ending a line, the last line ending with the file:
//      FILE "name" BINARY      (or an unquoted name) a second FILE, or another type, is no disc
//      TRACK nn MODE1/2352     nn must be the tracks so far + 1 and come after FILE; MODE1/2048 or any
//      TRACK nn AUDIO          other type is no disc
//      INDEX 00 mm:ss:ff       ends the track before, at mm:ss:ff + PREGAP so far, if it has no end yet
//      INDEX 01 mm:ss:ff       starts the TRACK above it: start = mm:ss:ff + PREGAP so far, file_lba =
//                              mm:ss:ff as written; ends the track before at start, if it has no end yet
//      PREGAP mm:ss:ff         adds to PREGAP so far: on the disc, not in the BIN
//    Any other line, an INDEX other than 00 and 01, and an INDEX or PREGAP line whose numbers do not parse,
//    are skipped. At most 99 tracks, all in file 1.
// 5. getfile slot 2: the picked CUE's path. Its part up to the last '/', then the FILE name, NUL-padded,
//    flags 0 and size 0, are the 66 words of the parameter struct. openfile slot 3; an error is no disc.
// 6. The last track ends at the BIN's sectors + PREGAP so far, as LoadCUE does; the BIN's sectors come from
//    a binary search of 2,352-byte reads of slot 3 for the last readable sector, 20 reads, up to 2^20 - 1
//    sectors (2.4 GB, so that offsets stay in 32 bits). A partial last sector is not counted. disc_bin_size
//    is not used: apf_loader captures it at every table sweep that shows slot 3, and the RTL cannot tell a
//    fresh size from a stale one. It is kept for the debug dump of Task 12.
//
// The TOC RAM: 128 entries of toc_entry_t, written here at clk_74a while disc_loading holds cdd_drive at
// TRAY, read at CLK_48M with one clock of latency. A sector of a PREGAP gap belongs to the track before and
// reads on in the BIN, so into the next track's start, as MiSTer does with one BIN: heard if an audio track has a PREGAP.
// rst must not rise with a cd_host command in flight unless cd_host is reset too.
`include "cd_defs.svh"

module cd_mount import cd_defs::*; #(
    parameter int MAX_CUE_BYTES = 9408,
    parameter int SWEEP_CLKS    = 512
) (
    input             clk_74a,
    input             rst,
    input             mount_req,            // apf_loader's cd_mount_req, a pulse
    input      [31:0] disc_size,
    input      [31:0] disc_bin_size,        // unused, see above
    // cd_host's mount client and path buffer
    output reg        mr_req = 0,
    output reg  [1:0] mr_kind = 0,
    output reg [15:0] mr_slot = 0,
    output reg [31:0] mr_offset = 0,
    output reg [31:0] mr_len = 0,
    output reg  [1:0] mr_bank_slot = 0,
    input             mr_done,
    input       [2:0] mr_err,
    output reg  [7:0] path_addr = 0,
    output reg        path_wr = 0,
    output reg [31:0] path_wdata = 0,
    input      [31:0] path_q,
    output reg [11:0] bank_rd_addr_74 = 0,
    input      [31:0] bank_rd_q_74,
    // results
    output reg        disc_loading = 0,
    output reg        disc_present = 0,
    output reg  [6:0] track_count = 0,
    output reg [23:0] disc_end = 0,
    // TOC RAM
    input             CLK_48M,
    input       [6:0] toc_rd_track,
    output toc_entry_t toc_rd_entry,
    output      [3:0] dbg_reason            // why the last mount ended, reason_t below: the wait counter's file
);

localparam int SECTOR      = 2352;
localparam int PROBE_BITS  = 20;
localparam logic [1:0] K_READ = 0, K_GETFILE = 1, K_OPENFILE = 2;

typedef enum logic [4:0] {
    M_IDLE, M_SWEEP, M_FIRST, M_BYTE_WAIT, M_SNIFF, M_RAW_DIV, M_PIECE, M_PARSE_RD, M_PARSE_CH,
    M_ACT1, M_ACT2, M_PARSE_END, M_GETFILE, M_SCAN, M_BUILD, M_BUILD_WR, M_OPEN, M_PROBE, M_PROBE_RD,
    M_PROBE_RES, M_FINISH, M_FAIL, M_ISSUE, M_CMD
} mstate_t;

typedef enum logic [3:0] {
    P_LINE, P_KW, P_SKIP, P_FSP, P_FQ, P_FU, P_FT0, P_FT, P_NUM, P_TT0, P_TT, P_MSF
} pstate_t;

typedef enum logic [1:0] { L_FILE, L_TRACK, L_INDEX, L_PREGAP } line_t;

// For the bench and the debug dump: why the last mount ended
typedef enum logic [3:0] {
    R_NONE, R_OK, R_EMPTY, R_READ, R_NOT_CUE, R_TOO_LONG, R_SYNTAX, R_FILES, R_TRACK, R_NO_TRACK,
    R_GETFILE, R_PATH, R_OPEN, R_PROBE, R_RAW
} reason_t;

mstate_t   state = M_IDLE, ret = M_IDLE, after_byte = M_IDLE;
pstate_t   pstate = P_LINE;
line_t     line = L_FILE;
reason_t   reason = R_NONE;
assign dbg_reason = reason;

reg        again = 0;               // a mount request not yet started
reg [31:0] size = 0;
reg [13:0] i = 0;                   // byte of the CUE, of the response, of the probe count
reg        eof = 0;
reg  [2:0] cmd_err = 0;
reg [15:0] wait_cnt = 0;

// Sniff
reg        sync_ok = 0, printable = 0;

// Parse
reg [79:0] kw = 0;                  // the last 10 characters of a token
reg  [3:0] kw_len = 0;              // 11 or more: too long for any keyword
reg  [9:0] num = 0;
reg  [1:0] nd = 0;                  // digits so far, 3 at most
reg  [1:0] fi = 0;                  // field of mm:ss:ff
reg  [9:0] mm = 0, ss = 0, idx_no = 0;
reg        resume_eol = 0;
reg [13:0] name_off = 0;
reg  [8:0] name_len = 0;
reg        files = 0;
reg  [6:0] ntracks = 0;
reg        track_open = 0, tr_audio = 0;
reg [23:0] pregap = 0;
reg [23:0] lba_r = 0;
// The track before, waiting for its end
reg        p_valid = 0, p_audio = 0, p_stop_set = 0;
reg [23:0] p_start = 0, p_stop = 0, p_file_lba = 0;

// Path
reg  [8:0] plen = 0, prefix = 0;
reg  [6:0] w = 0;                   // parameter struct word
reg  [1:0] k = 0;                   // byte in the word
reg [31:0] wacc = 0;
reg        from_resp = 0;

// Probe and raw division
reg [PROBE_BITS:0] lo = 0, hi = 0, mid = 0;
reg [31:0] quot = 0, rem = 0;
reg  [5:0] bit_n = 0;

// TOC RAM write port
reg        toc_we = 0;
reg  [6:0] toc_wa = 0;
toc_entry_t toc_wd = '0;

function automatic [7:0] lane(input [31:0] q, input [1:0] n);
    return q[31 - 8 * n -: 8];
endfunction

wire [7:0] bank_byte = lane(bank_rd_q_74, i[1:0]);
wire [7:0] resp_byte = lane(path_q, i[1:0]);

// The character being parsed: the bank's byte, or the LF that ends the file
wire  [7:0] c    = eof ? 8'h0A : bank_byte;
wire        sp   = c == 8'h20 || c == 8'h09;
wire        eol  = c == 8'h0D || c == 8'h0A;
wire        sep  = sp || eol;
wire        dg   = c >= "0" && c <= "9";
wire [79:0] kwn  = {kw[71:0], c};
wire  [9:0] num_next = (num << 3) + (num << 1) + 10'(c - "0");      // num * 10 + digit

// mm:ss:ff as an LBA, mm * 4500 + ss * 75 + ff in shifts and adds
wire [23:0] mm24 = 24'(mm), ss24 = 24'(ss);
wire [23:0] msf_lba = (mm24 << 12) + (mm24 << 8) + (mm24 << 7) + (mm24 << 4) + (mm24 << 2) +
                      (ss24 << 6) + (ss24 << 3) + (ss24 << 1) + ss24 + 24'(num);

// x * 2352 = x * 2048 + x * 256 + x * 32 + x * 16
function automatic [31:0] times_sector(input [31:0] x);
    return (x << 11) + (x << 8) + (x << 5) + (x << 4);
endfunction
// The offset of the next CUE piece, registered: i is steady on the way into M_PIECE, and the subtract and the
// compare behind it are a clock's work at clk_74a already (Slow 0C failed by 0.3 ns with it combinational)
reg  [31:0] next_piece = 0;
always @(posedge clk_74a) next_piece <= times_sector(32'(i) + 1'd1);
wire [31:0] probe_off  = times_sector(32'(mid) - 1'd1);    // sector mid - 1 of the BIN

// The byte of the new path being built: the response's below prefix, the name from the CUE, then 0
wire [13:0] name_src  = name_off + (i - 14'(prefix));
wire        in_name   = 9'(i) - prefix < name_len;
wire  [7:0] build_byte = w >= 64 ? 8'd0 : from_resp ? resp_byte : in_name ? lane(bank_rd_q_74, name_src[1:0]) : 8'd0;

wire [23:0] last_stop = p_stop_set ? p_stop : 24'(lo) + pregap;
wire        raw_ok    = quot != 0 && quot[31:24] == 0;

always @(posedge clk_74a) begin
    toc_we  <= 0;
    path_wr <= 0;

    case (state)
        M_IDLE: ;

        M_SWEEP:
            if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'd1;
            else begin
                size <= disc_size;
                if (disc_size == 0) begin
                    reason <= R_EMPTY;
                    state  <= M_FAIL;
                end
                else begin
                    mr_kind      <= K_READ;
                    mr_slot      <= 16'd2;
                    mr_offset    <= 0;
                    mr_len       <= disc_size < SECTOR ? disc_size : SECTOR;
                    mr_bank_slot <= 0;
                    ret          <= M_FIRST;
                    state        <= M_ISSUE;
                end
            end

        // The first piece is in bank slot 0: look at its first 64 bytes
        M_FIRST:
            if (cmd_err != 0) begin
                reason <= R_READ;
                state  <= M_FAIL;
            end
            else begin
                sync_ok         <= size >= 12;
                printable       <= 1;
                i               <= 0;
                bank_rd_addr_74 <= 0;
                after_byte      <= M_SNIFF;
                state           <= M_BYTE_WAIT;
            end

        // One clock for the RAM to answer the address set with the state before
        M_BYTE_WAIT: state <= after_byte;

        M_SNIFF: begin
            if (i < 12 && bank_byte != ((i == 0 || i == 11) ? 8'h00 : 8'hFF)) sync_ok <= 0;
            if (!((bank_byte >= 8'h20 && bank_byte <= 8'h7E) || bank_byte == 8'h09 || bank_byte == 8'h0A || bank_byte == 8'h0D))
                printable <= 0;
            if (i == 63 || 32'(i) + 1 == size) begin
                after_byte <= M_PIECE;  // decided there, with this byte counted, and next_piece of this i
                state      <= M_BYTE_WAIT;
                i          <= 0;
            end
            else begin
                i               <= i + 1'd1;
                bank_rd_addr_74 <= 12'((i + 1'd1) >> 2);
                state           <= M_BYTE_WAIT;
            end
        end

        // Decide, then read the CUE's pieces after the first
        M_PIECE:
            if (i == 0 && sync_ok) begin
                quot  <= 0;
                rem   <= 0;
                bit_n <= 6'd31;
                state <= M_RAW_DIV;
            end
            else if (i == 0 && !printable) begin
                reason <= R_NOT_CUE;
                state  <= M_FAIL;
            end
            else if (i == 0 && size > MAX_CUE_BYTES) begin
                reason <= R_TOO_LONG;
                state  <= M_FAIL;
            end
            else if (i != 0 && cmd_err != 0) begin
                reason <= R_READ;
                state  <= M_FAIL;
            end
            else if (next_piece < size) begin
                i            <= i + 1'd1;
                mr_kind      <= K_READ;
                mr_slot      <= 16'd2;
                mr_offset    <= next_piece;
                mr_len       <= size - next_piece < SECTOR ? size - next_piece : SECTOR;
                mr_bank_slot <= 2'(i + 1'd1);
                ret          <= M_PIECE;
                state        <= M_ISSUE;
            end
            else begin
                i          <= 0;
                eof        <= 0;
                pstate     <= P_LINE;
                files      <= 0;
                ntracks    <= 0;
                track_open <= 0;
                pregap     <= 0;
                p_valid    <= 0;
                state      <= M_PARSE_RD;
            end

        // disc_size / 2352, restoring, a bit a clock
        M_RAW_DIV: begin
            if ({rem[30:0], size[bit_n]} >= SECTOR) begin
                rem  <= {rem[30:0], size[bit_n]} - SECTOR;
                quot <= {quot[30:0], 1'b1};
            end
            else begin
                rem  <= {rem[30:0], size[bit_n]};
                quot <= {quot[30:0], 1'b0};
            end
            if (bit_n != 0) bit_n <= bit_n - 1'd1;
            else state <= M_FINISH;
        end

        // ---- The CUE, a character at a time ----
        M_PARSE_RD:
            if (32'(i) == size) begin
                eof   <= 1;             // the file ends the last line, as an LF
                state <= M_PARSE_CH;
            end
            else begin
                bank_rd_addr_74 <= 12'(i >> 2);
                after_byte      <= M_PARSE_CH;
                state           <= M_BYTE_WAIT;
            end

        // The next state is set first: a fail or the end of an INDEX line below overrides it
        M_PARSE_CH: begin
            state <= eof ? M_PARSE_END : M_PARSE_RD;
            i     <= i + 1'd1;
            case (pstate)
                P_LINE:
                    if (!sep) begin
                        kw     <= {72'd0, c};
                        kw_len <= 1;
                        pstate <= P_KW;
                    end

                P_KW:
                    if (!sep) begin
                        kw     <= kwn;
                        kw_len <= kw_len == 4'd15 ? kw_len : kw_len + 1'd1;
                    end
                    else if (kw_len == 4 && kw[31:0] == "FILE") begin
                        line   <= L_FILE;
                        pstate <= P_FSP;
                        if (eol) begin
                            reason <= R_SYNTAX;
                            state  <= M_FAIL;
                        end
                    end
                    else if (kw_len == 5 && kw[39:0] == "TRACK") begin
                        line   <= L_TRACK;
                        num    <= 0;
                        nd     <= 0;
                        pstate <= P_NUM;
                        if (eol) begin
                            reason <= R_SYNTAX;
                            state  <= M_FAIL;
                        end
                    end
                    else if (kw_len == 5 && kw[39:0] == "INDEX") begin
                        line   <= L_INDEX;
                        num    <= 0;
                        nd     <= 0;
                        pstate <= eol ? P_LINE : P_NUM;
                    end
                    else if (kw_len == 6 && kw[47:0] == "PREGAP") begin
                        line   <= L_PREGAP;
                        num    <= 0;
                        nd     <= 0;
                        fi     <= 0;
                        pstate <= eol ? P_LINE : P_MSF;
                    end
                    else pstate <= (eol ? P_LINE : P_SKIP);

                P_SKIP: if (eol) pstate <= P_LINE;

                // FILE: the name, quoted or not, then its type
                P_FSP:
                    if (eol) begin
                        reason <= R_SYNTAX;
                        state  <= M_FAIL;
                    end
                    else if (c == "\"") begin
                        name_off <= i + 1'd1;
                        name_len <= 0;
                        pstate   <= P_FQ;
                    end
                    else if (!sp) begin
                        name_off <= i;
                        name_len <= 1;
                        pstate   <= P_FU;
                    end

                P_FQ, P_FU:
                    if (eol || name_len == 9'd255) begin
                        reason <= R_SYNTAX;
                        state  <= M_FAIL;
                    end
                    else if (pstate == P_FQ ? c == "\"" : sp) pstate <= P_FT0;
                    else name_len <= name_len + 1'd1;

                P_FT0, P_TT0:
                    if (eol) begin
                        reason <= R_SYNTAX;
                        state  <= M_FAIL;
                    end
                    else if (!sp) begin
                        kw     <= {72'd0, c};
                        kw_len <= 1;
                        pstate <= pstate == P_FT0 ? P_FT : P_TT;
                    end

                P_FT:
                    if (!sep) begin
                        kw     <= kwn;
                        kw_len <= kw_len == 4'd15 ? kw_len : kw_len + 1'd1;
                    end
                    else if (!(kw_len == 6 && kw[47:0] == "BINARY")) begin
                        reason <= R_SYNTAX;
                        state  <= M_FAIL;
                    end
                    else if (files) begin
                        reason <= R_FILES;
                        state  <= M_FAIL;
                    end
                    else begin
                        files  <= 1;
                        pregap <= 0;
                        pstate <= (eol ? P_LINE : P_SKIP);
                    end

                // TRACK nn or INDEX nn
                P_NUM:
                    if (dg) begin
                        num <= nd == 3 ? num : num_next;
                        nd  <= nd == 3 ? nd : nd + 1'd1;
                    end
                    else if (!(sp && nd == 0)) begin
                        if (nd == 0 || !sep) begin
                            if (line == L_TRACK) begin
                                reason <= R_SYNTAX;
                                state  <= M_FAIL;
                            end
                            else pstate <= (eol ? P_LINE : P_SKIP);
                        end
                        else if (line == L_TRACK) begin
                            if (!files || num != 10'(ntracks) + 1'd1 || eol) begin
                                reason <= R_TRACK;
                                state  <= M_FAIL;
                            end
                            else pstate <= P_TT0;
                        end
                        else begin
                            idx_no <= num;
                            num    <= 0;
                            nd     <= 0;
                            fi     <= 0;
                            pstate <= eol ? P_LINE : P_MSF;
                        end
                    end

                P_TT:
                    if (!sep) begin
                        kw     <= kwn;
                        kw_len <= kw_len == 4'd15 ? kw_len : kw_len + 1'd1;
                    end
                    else if (kw_len == 10 && kw == "MODE1/2352") begin
                        track_open <= 1;
                        tr_audio   <= 0;
                        pstate     <= (eol ? P_LINE : P_SKIP);
                    end
                    else if (kw_len == 5 && kw[39:0] == "AUDIO") begin
                        track_open <= 1;
                        tr_audio   <= 1;
                        pstate     <= (eol ? P_LINE : P_SKIP);
                    end
                    else begin
                        reason <= R_TRACK;
                        state  <= M_FAIL;
                    end

                // mm:ss:ff
                P_MSF:
                    if (dg) begin
                        num <= nd == 3 ? num : num_next;
                        nd  <= nd == 3 ? nd : nd + 1'd1;
                    end
                    else if (c == ":" && nd != 0 && fi != 2) begin
                        if (fi == 0) mm <= num;
                        else ss <= num;
                        fi  <= fi + 1'd1;
                        num <= 0;
                        nd  <= 0;
                    end
                    else if (sp && nd == 0 && fi == 0) ;
                    else if (sep && nd != 0 && fi == 2) begin
                        resume_eol <= eol;
                        state      <= M_ACT1;
                    end
                    else pstate <= (eol ? P_LINE : P_SKIP);

                default: pstate <= P_LINE;
            endcase
        end

        // An INDEX or PREGAP line is complete: num is ff
        M_ACT1: begin
            lba_r <= msf_lba;
            state <= M_ACT2;
        end

        M_ACT2: begin
            pstate <= resume_eol ? P_LINE : P_SKIP;
            state  <= eof ? M_PARSE_END : M_PARSE_RD;
            if (line == L_PREGAP) pregap <= pregap + lba_r;
            else if (idx_no == 0) begin
                if (p_valid && !p_stop_set) begin
                    p_stop     <= lba_r + pregap;
                    p_stop_set <= 1;
                end
            end
            else if (idx_no == 1) begin
                if (!track_open || ntracks == 7'd99) begin
                    reason <= R_TRACK;
                    state  <= M_FAIL;
                end
                else begin
                    if (p_valid) begin
                        toc_we <= 1;
                        toc_wa <= ntracks - 1'd1;
                        toc_wd <= {p_audio, 7'd1, p_start, p_stop_set ? p_stop : lba_r + pregap, p_file_lba};
                    end
                    p_valid    <= 1;
                    p_audio    <= tr_audio;
                    p_start    <= lba_r + pregap;
                    p_file_lba <= lba_r;
                    p_stop_set <= 0;
                    ntracks    <= ntracks + 1'd1;
                    track_open <= 0;
                end
            end
        end

        M_PARSE_END:
            if (!files) begin
                reason <= R_FILES;
                state  <= M_FAIL;
            end
            else if (!p_valid) begin
                reason <= R_NO_TRACK;
                state  <= M_FAIL;
            end
            else begin
                mr_kind <= K_GETFILE;
                mr_slot <= 16'd2;
                ret     <= M_GETFILE;
                state   <= M_ISSUE;
            end

        // ---- The BIN's path ----
        M_GETFILE:
            if (cmd_err != 0) begin
                reason <= R_GETFILE;
                state  <= M_FAIL;
            end
            else begin
                i          <= 0;
                prefix     <= 0;
                path_addr  <= 8'h80;
                after_byte <= M_SCAN;
                state      <= M_BYTE_WAIT;
            end

        // Find the NUL and the last '/' of the response
        M_SCAN:
            if (resp_byte == 0) begin
                plen  <= 9'(i);
                state <= M_BUILD;
                w     <= 0;
                k     <= 0;
                i     <= 0;
                if (10'(prefix) + 10'(name_len) > 10'd255) begin
                    reason <= R_PATH;
                    state  <= M_FAIL;
                end
            end
            else if (i == 14'd511) begin
                reason <= R_PATH;
                state  <= M_FAIL;
            end
            else begin
                if (resp_byte == "/") prefix <= 9'(i + 1'd1);
                i          <= i + 1'd1;
                path_addr  <= {1'b1, 7'((i + 1'd1) >> 2)};
                after_byte <= M_SCAN;
                state      <= M_BYTE_WAIT;
            end

        // Byte i of the new path: the response's below prefix, then the name from the CUE in the bank, then 0.
        // The source's address goes out here, its byte is taken in M_BUILD_WR
        M_BUILD: begin
            from_resp <= 0;
            if (w < 64 && 9'(i) < prefix) begin
                from_resp <= 1;
                path_addr <= {1'b1, 7'(i >> 2)};
            end
            else if (w < 64 && in_name)
                bank_rd_addr_74 <= 12'(name_src >> 2);
            after_byte <= M_BUILD_WR;
            state      <= M_BYTE_WAIT;
        end

        M_BUILD_WR: begin
            wacc  <= {wacc[23:0], build_byte};
            i     <= i + 1'd1;
            k     <= k + 1'd1;
            state <= M_BUILD;
            if (k == 3) begin
                path_addr  <= {1'b0, w};
                path_wdata <= {wacc[23:0], build_byte};
                path_wr    <= 1;
                w          <= w + 1'd1;
                if (w == 7'd65) begin
                    mr_kind <= K_OPENFILE;
                    mr_slot <= 16'd3;
                    ret     <= M_OPEN;
                    state   <= M_ISSUE;
                end
            end
        end

        M_OPEN:
            if (cmd_err != 0) begin
                reason <= R_OPEN;
                state  <= M_FAIL;
            end
            else begin
                lo    <= 0;
                hi    <= {1'b1, {PROBE_BITS{1'b0}}};
                state <= M_PROBE;
            end

        // ---- The BIN's sectors: lo readable for sure, hi not ----
        M_PROBE:
            if (hi - lo <= 1) begin
                if (lo == 0) begin
                    reason <= R_PROBE;
                    state  <= M_FAIL;
                end
                else state <= M_FINISH;
            end
            else begin
                mid   <= (lo + hi) >> 1;
                state <= M_PROBE_RD;
            end

        // Sector mid - 1
        M_PROBE_RD: begin
            mr_kind      <= K_READ;
            mr_slot      <= 16'd3;
            mr_offset    <= probe_off;
            mr_len       <= SECTOR;
            mr_bank_slot <= 0;
            ret          <= M_PROBE_RES;
            state        <= M_ISSUE;
        end

        M_PROBE_RES: begin
            if (cmd_err == 0) lo <= mid;
            else hi <= mid;
            state <= M_PROBE;
        end

        // ---- Results ----
        M_FINISH: begin
            toc_we <= 1;
            state  <= M_IDLE;
            reason <= R_OK;
            if (sync_ok && ntracks == 0) begin
                // A raw BIN: file 0 is the picked file itself
                toc_wa       <= 0;
                toc_wd       <= {1'b0, 7'd0, 24'd0, quot[23:0], 24'd0};
                track_count  <= 1;
                disc_end     <= quot[23:0];
                disc_present <= raw_ok;
                disc_loading <= 0;
                if (!raw_ok) begin
                    reason <= R_RAW;
                    state  <= M_FAIL;
                end
            end
            else begin
                toc_wa       <= ntracks - 1'd1;
                toc_wd       <= {p_audio, 7'd1, p_start, last_stop, p_file_lba};
                track_count  <= ntracks;
                disc_end     <= last_stop;
                disc_present <= 1;
                disc_loading <= 0;
            end
        end

        M_FAIL: begin
            disc_present <= 0;
            disc_loading <= 0;
            track_count  <= 0;
            disc_end     <= 0;
            state        <= M_IDLE;
        end

        // ---- A cd_host command: mr_done has fallen since the last one ----
        M_ISSUE:
            if (!mr_done) begin
                mr_req <= 1;
                state  <= M_CMD;
            end

        M_CMD:
            if (mr_done) begin
                cmd_err <= mr_err;
                mr_req  <= 0;
                state   <= ret;
            end

        default: state <= M_IDLE;
    endcase

    // A new request: drop the disc now, start once no command is in flight
    if (mount_req) begin
        again        <= 1;
        disc_present <= 0;
        disc_loading <= 1;
    end
    // Not in M_ISSUE either: it may raise mr_req on this very clock, which the restart would leave high
    if ((again || mount_req) && !mr_req && state != M_CMD && state != M_ISSUE) begin
        again        <= 0;
        disc_present <= 0;
        disc_loading <= 1;
        sync_ok      <= 0;
        ntracks      <= 0;
        reason       <= R_NONE;
        wait_cnt     <= 16'(SWEEP_CLKS);
        state        <= M_SWEEP;
    end

    if (rst) begin
        state        <= M_IDLE;
        again        <= 0;
        mr_req       <= 0;
        disc_present <= 0;
        disc_loading <= 0;
        track_count  <= 0;
        disc_end     <= 0;
    end
end

// ---- TOC RAM ----
(* ramstyle = "MLAB, no_rw_check" *) toc_entry_t toc [0:127];

always @(posedge clk_74a) if (toc_we) toc[toc_wa] <= toc_wd;
always @(posedge CLK_48M) toc_rd_entry <= toc[toc_rd_track];

endmodule
