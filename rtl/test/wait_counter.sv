// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// What the memory costs the 68K in a real game. Debug builds only (NEOGEO_WAIT_COUNTER): core_top reads
// nothing back from it but the bridge, and it only watches the core's signals, so it cannot change what
// the core does.
//
// A ROM zone read with no wait state keeps nAS low for 10 CLK_48M. Clocks past 10 are what the 68K
// waited on PROM_DATA_READY; each wait state is 4 of them. The sums go to the bucket of what CRAM0 was
// doing when the read's request reached the mux, in the mux's owner code: 0 loader, 1 idle, 2 fix, 3 Z80.
//
// The CD build counts the BIOS and PROG RAM, reads and writes (rom_zone, neogeo_pocket.sv), and not
// the holds of FIX, SPR and PCM transfers. A write with no wait state is 10 as well (measured, sim/topcd). A TAS
// on PROG RAM is a read and a write in one nAS, 34, and counts 24 lost: the BIOS's few are in the noise.
// The owner codes read: 0 the CD write queue (the loader only while the 68K is in reset, when nothing is
// counted), 1 idle, and 2 and 3 never happen, as the CD build has no fix read or Z80 read on CRAM0. A write,
// with no 68K read request of its own, keeps the code of the last request that had one: the sums and the
// worst frame are exact, the split by code is not for those.
//
// ponytail: a game whose JSON sets the C1 ROM or port wait is 14 or more on the real console too, and
// its wait states count here as if the memory caused them. Word 1 carries the setting, the checker warns.
//
// 64-bit sums at 48 MHz do not overflow. At each frame tick, a sequencer copies them word by word into a
// dual clock RAM the bridge reads, so the bridge never sees a counter move. A carry into a sum's upper
// word between the two copies, or a file read that straddles a copy, gives one wrong file only if
// the file is read in that very frame: 105 clocks in about 800,000. Words 2 and 22 show the second case.
//
// File, big endian 32-bit words, read the way memtest_bridge answers (tools/check_wait_save.py), layout 3. A record is
// 512 bytes. The checker still reads layouts 1 and 2, of 256, from older files.
//    0 magic, 1 {RD_WAIT, C1 wait setting, layout}, 2 frames, 3 worst frame's lost clocks,
//    4 total clocks (hi, lo), 6 reads by code (4 x hi, lo), 14 lost clocks by code (4 x hi, lo),
//   22 frames again, 31 {last error of a save, saves done}, 48-63 and 127 counting pattern for the read lag
// Words 23 to 30, to see how far the BIOS got without a screen to look at:
//   23 {writes to FIX: 24 bits, the last CDD_COMMAND_DATA's hi 8 bits}, 24 its lo,
//   25 {writes to SPR: 24 bits, the last CDD_STATUS's hi 8 bits}, 26 its lo,
//   27 {why the last mount ended, cd_mount's reason, 4 bits; cur_status 4 bits; cur_lba 24 bits},
//   28 {writes to PCM: 24 bits, failed sectors: 8 bits}, 29 {writes to the Z80, exchanges: 16 bits each}, 30 disc_bin_size
// A write is a rising edge of the transfer area's strobe, the 68K's or a DMA's: its strobe falls between words
// (sim/topcd counts both). The transfers' counts are wide because a BIOS and a game move whole blocks: at 10 bits, as
// they first were, 128 KB of FIX reads 0. The 68K's own command and status words are read in the clock of the
// copy: a change in those 31 clocks tears one word, and the next frame's file is whole.
//
// At each frame's copy:
//   32 {in reset, lid debug status[15], CD_REGION 2, cd_speed 2, FF011C bit 12, SYSTEM_CDZ}, sampled live,
//   33 {resets: 8 bits, the frame of the last reset release: 24 bits},
//   34-37 the 68K at the last 4 VBlanks out of reset, newest first: {a write in that frame, its bus cycles / 256 up to
//         255, A[23:1]}: a running 68K has cycles and moving addresses, a stuck one neither,
//   38-45 cd_fetch: data and audio sectors requested, hits and misses in the bank, the worst host read in CLK_48M,
//         requests on a busy fetch, polls that found the last request unanswered, polls that found the sink full,
//   46, 47 the frame of the first failed sector, and of the first late one: {valid, frame},
//   64, 65 cd_fetch: requests that found the sink full, streams abandoned by a reset,
//   66-69 words a DMA wrote to PROG, FIX, SPR, PCM, 70-73 their worst stall in CLK_96M, 74, 75 queue-full events of the
//         68K and of a DMA, 76 writes lost by a strobe that left a full queue, 77 resets that emptied the queue,
//   78 DMA writes that reached no memory, 79 cache bank changes during a DMA,
//   80 drive commands other than IDLE and TOC, 81-104 the last 8 of them, newest first, three words each:
//         {frame modulo 65536, command 39:32, its answer 39:32}, command 31:0, answer 31:0.
// A BIOS polls TOC every frame while it plays, so those would push out the seek a stop needs explained.
// The ring takes a command when drive.v sends it and its answer at the next status latch: an answer of 0 is a command
// still unanswered. A reset's own answer, to no command, stays out. Nothing here is cleared by a reset, so within one
// opening of the core a run's counts include the runs before it; the frame of its start is in word 33.
//
// Runs: the file is 8 records of 512 bytes as above, so a run that fails and the run after it can be compared
// with no trip to the PC. Word 105 of a record is its run number, 0 for an empty record. A run is what follows a release
// of nRESET, and takes record (run number modulo 8), the oldest. The numbering goes on from the highest number in the file the host
// loads as the core opens. This RAM holds the whole file, as the host writes all of it back when the core stops. A record
// stops changing when nRESET falls, so it keeps the last frame of its run. Word 31 of a record is that frame's.
//
// Saves: the host reads a nonvolatile slot when the core stops: Quit, sleep or turning off. As that is
// not done on a hard power off or a hang, the core also asks for a slot write (0x0184) about every 7 s, and
// when nRESET falls with the core running, as Reset Core is what follows a failure.
module wait_counter #(
    parameter [7:0]  RD_WAIT = 8
) (
    input             clk_48m,
    input             nRESET,
    input             nAS,
    input             rom_zone,
    input       [1:0] at_req,       // CLK_96M, same PLL; steady long before a cycle ends
    input             vblank,
    input       [2:0] c1_wait,      // cfg: clk_74a, written once by the game JSON

    input             clk_74a,
    input      [31:0] bridge_addr,
    input             bridge_rd,
    output reg [31:0] bridge_rd_data = 0,
    input             bridge_wr,    // the host loading the file
    input      [31:0] bridge_wr_data,
    input             run,          // clk_74a: the host has let the core run
    output            save_now,     // rising edge asks for the slot write
    input             save_done,
    input       [2:0] save_err,

    input     [113:0] cdd,          // CLK_48M: {fetch_err; writes Z80, PCM, SPR, FIX; status latch; cur_lba; cur_status; status; command}
    input      [31:0] disc_bin_size,// clk_74a: static once the disc is mounted
    input       [3:0] disc_reason,  // clk_74a: likewise
    input      [53:0] cd2,        // neogeo_pocket.sv's dbg_cd2, CLK_48M and CLK_96M, the same PLL
    input     [319:0] fetch,        // cd_fetch.sv's dbg_fetch, CLK_48M
    input     [383:0] dma,          // pocket_mem_mux.sv's dbg_dma, CLK_96M, the same PLL
    input      [36:0] sect,         // cd.sv's DBG_SECT, CLK_48M
    input      [48:0] dmab,         // CLK_48M: {DMA running, DMA write to PROG RAM, DMA read from PROG RAM,
                                    //   DMA_ADDR_OUT[23:1], DMA_ADDR_IN[23:1]}
    input      [17:0] bus68,        // CLK_48M: {nUDS, nLDS, the 68K's write data}
    input      [25:0] dreq          // CLK_48M: the drive's request of a sector: {toggle, audio, LBA}
);

localparam [31:0] MAGIC = 32'h4E47_5754;    // NGWT
localparam [7:0]  IDEAL_LEN = 8'd10;
localparam [15:0] LAYOUT = 16'd3;    // the file's layout, word 1
localparam [6:0]  WORDS = 7'd127;
// Word 1 bits 23:19: what words 106-126 hold. 0 up to 0.5.3: the hold's times and its run-outs; 1 (0.5.4): the
// sectors and the last lost; 2 (0.5.5): the sectors, and the reads of PROG RAM ahead of any write since the reset; 3: the
// CDZ BIOS's protection variables (0.5.6 first build); 4: the BIOS's sector read variables and the last sector offered;
// 5: the BIOS's command queue and read variables up to the music's PLAY; 6: an event timeline per CD/CDZ setting, past the records
localparam [4:0]  REV = 5'd6;
localparam int    ADDR_W = 10;    // 8 records of 128 words

// ---- The sums, CLK_48M. Same rules as the bench's monitor, sim/top/tb_top.sv ----

reg [63:0]      total = 0;
reg [3:0][63:0] reads = 0, lost = 0;
reg [31:0]      frames = 0, frame_lost = 0, worst = 0;
reg             in_cycle = 0, zone = 0, vblank_d = 0;
reg [7:0]       len = 0;

wire       cycle_end = nRESET & in_cycle & nAS & zone;
wire [7:0] over = (cycle_end && len > IDEAL_LEN) ? len - IDEAL_LEN : 8'd0;
wire       tick = vblank & ~vblank_d;

always @(posedge clk_48m) begin
    vblank_d <= vblank;
    if (nRESET) total <= total + 1'd1;

    if (!nRESET) in_cycle <= 0;
    else if (!nAS && !in_cycle) begin
        in_cycle <= 1;
        len      <= 1;
        zone     <= rom_zone;
    end else if (in_cycle) begin
        len  <= len + 1'd1;
        zone <= zone | rom_zone;
        if (nAS) in_cycle <= 0;
    end

    // Not reads[at_req]: Quartus makes that a RAM clocked from the mux's side, which is no use here
    for (int i = 0; i < 4; i++) if (cycle_end && at_req == 2'(i)) begin
        reads[i] <= reads[i] + 1'd1;
        lost[i]  <= lost[i] + over;
    end

    frame_lost <= (tick ? 32'd0 : frame_lost) + over;
    if (tick) begin
        if (frame_lost > worst) worst <= frame_lost;
        if (nRESET) frames <= frames + 1'd1;
    end
end

// ---- The copy the bridge reads ----

(* ramstyle = "M10K, no_rw_check" *) reg [31:0] copy [0:(1 << ADDR_W) - 1];
(* ramstyle = "M10K, no_rw_check" *) reg [31:0] tl [0:1023];    // the timelines, the file's second 4 KB

reg [6:0] wi = WORDS;

// The run. loaded_run is steady long before nRESET first rises: the host loads the file before it lets the core run
reg  [31:0] run_no = 0, loaded_run = 0;
reg         started = 0, nreset_run_d = 0;
wire [2:0]  record = run_no[2:0];

always @(posedge clk_48m) begin
    nreset_run_d <= nRESET;
    if (nRESET && !nreset_run_d) begin
        run_no  <= (started ? run_no : loaded_run) + 1'd1;
        started <= 1;
    end
end

wire [31:0] save_word;          // 31
wire [0:7][31:0]  cd_words;     // 23-30
wire [0:15][31:0] cd_more;      // 32-47
wire [0:40][31:0] cd_last;      // 64-104
wire [0:20][31:0] cd_hold;     // 106-126
wire [0:126][31:0] words = {MAGIC, RD_WAIT, REV, c1_wait, LAYOUT, frames, worst, total,
                            reads[0], reads[1], reads[2], reads[3],
                            lost[0], lost[1], lost[2], lost[3], frames, cd_words,
                            save_word, cd_more, 512'd0, cd_last, run_no, cd_hold};

reg [15:0] n_exch = 0, n_z80 = 0;
reg [23:0] n_fix = 0, n_spr = 0, n_pcm = 0;
reg  [7:0] n_ferr = 0;
reg  [5:0] seen = 0;
always @(posedge clk_48m) begin
    seen <= cdd[113:108];
    if (cdd[108] & ~seen[0]) n_exch <= n_exch + 1'd1;
    if (cdd[109] & ~seen[1]) n_fix  <= n_fix + 1'd1;
    if (cdd[110] & ~seen[2]) n_spr  <= n_spr + 1'd1;
    if (cdd[111] & ~seen[3]) n_pcm  <= n_pcm + 1'd1;
    if (cdd[112] & ~seen[4]) n_z80  <= n_z80 + 1'd1;
    if (cdd[113] & ~seen[5]) n_ferr <= n_ferr + 1'd1;
end

assign cd_words = {{n_fix, cdd[39:32]}, cdd[31:0], {n_spr, cdd[79:72]}, cdd[71:40],
                   {disc_reason, cdd[83:80], cdd[107:84]}, {n_pcm, n_ferr}, {n_z80, n_exch},
                   disc_bin_size};

wire [0:9][31:0]  fw = fetch;
wire [0:11][31:0] dw = dma;
wire       cmd_send = cd2[7];
wire [6:0] settings = cd2[6:0];

reg  [7:0] resets = 0;
reg [23:0] released = 0;
reg        nreset_d = 0;

reg [3:0][31:0] samples = 0;    // [0] the newest
reg [15:0] cycles = 0;
reg        wrote = 0;

reg [31:0] first_fail = 0, first_late = 0;

// The 2x hold in cd.sv, which keeps a sector from the decoder while its interrupt is masked, for 50 ms at most. cd2[35]
// is up while a sector is held, and cd2[36] toggles when a hold runs out: the program kept the interrupt masked for 50 ms
reg [31:0] n_holds = 0, n_expired = 0;
reg        hold_d = 0, exp_d = 0;
// Each sector the decoder offered, as cd.sv's DBG_SECT has it at the next flip: sect[36] toggles for one DMA'd from the
// cache, sect[35] for one skipped (STAT3 read, no DMA), sect[34] for one lost (neither). The DMA'd ones are counted
reg [31:0] n_taken = 0;
reg [15:0] n_late = 0;          // STAT3 reads with the decoder on that found the status no longer valid: sect[33]
reg  [1:0] sect_d = 0;

reg [15:0] n_nowhere = 0, n_swap = 0;
reg        nowhere_d = 0;

reg [7:0][95:0] ring = 0;       // [0] the newest
reg [23:0] n_cmds = 0;
reg        answer_due = 0;

always @(posedge clk_48m) begin
    nreset_d <= nRESET;
    if (nRESET && !nreset_d) begin
        resets   <= resets + 1'd1;
        released <= frames[23:0];
    end

    // At the tick's clock a cycle may begin uncounted: this is for telling 0 from thousands
    if (tick) begin
        cycles <= 0;
        wrote  <= 0;
        if (nRESET) samples <= {samples[2:0], {wrote, cycles[15:8], cd2[30:8]}};
    end
    else begin
        if (nRESET && !nAS && !in_cycle && !(&cycles)) cycles <= cycles + 1'd1;
        if (!nAS && !cd2[31]) wrote <= 1;
    end

    if (!first_fail[31] && n_ferr != 0)  first_fail <= {1'b1, frames[30:0]};
    if (!first_late[31] && fw[6] != 0)   first_late <= {1'b1, frames[30:0]};

    hold_d <= cd2[35];
    exp_d  <= cd2[36];
    if (cd2[35] && !hold_d) n_holds <= n_holds + 1'd1;
    if (cd2[36] != exp_d) n_expired <= n_expired + 1'd1;

    sect_d <= {sect[36], sect[33]};
    if (sect[36] != sect_d[1]) n_taken <= n_taken + 1'd1;
    if (sect[33] != sect_d[0] && !(&n_late)) n_late <= n_late + 1'd1;

    nowhere_d <= cd2[32];
    if (cd2[32] && !nowhere_d) n_nowhere <= n_nowhere + 1'd1;
    if (cd2[33]) n_swap <= n_swap + 1'd1;

    if (!nRESET) answer_due <= 0;
    else if (cmd_send) answer_due <= cdd[3:0] != 0 && cdd[3:0] != 4'd2;
    else if (cdd[108]) answer_due <= 0;

    if (cmd_send && cdd[3:0] != 0 && cdd[3:0] != 4'd2) begin
        ring   <= {ring[6:0], {frames[15:0], cdd[39:32], 8'd0, cdd[31:0], 32'd0}};
        n_cmds <= n_cmds + 1'd1;
    end
    else if (cdd[108] && answer_due && nRESET) begin
        ring[0][71:64] <= cdd[79:72];
        ring[0][31:0]  <= cdd[71:40];
    end
end

// The event timeline, one per CD/CDZ setting, in the file's second 4 KB: 255 entries of two words, {type, time} and a
// payload, in a ring from the release of nRESET. Samurai Shodown RPG's music, the first PLAY to 60:58:21, is the
// trigger: 96 more entries after it and that setting's timeline stops, for this opening of the core, so a Reset Core
// after a failure does not overwrite it. Entry 0 is {"TL", wrapped, the next entry} and the run, once it has stopped.
// Time is the 68K clock counter in units of 1,024 clocks, 21 us. Types: 0 a drive command, {its digits, code}, IDLE and
// TOC left out; 1 a sector the drive asked for, {audio, its LBA}, only the first of a run of audio ones; 2, 3, 4 a sector
// offered, DMA'd, skipped or lost, its header; 5 a change the 68K made to a BIOS variable, {which, strobes, data}; 6 the
// drive's status changed, {status, LBA}. Variables, A5 = $108000: 0 $7651 the queue's tail (its head, $7650, moves all
// the time and stays out), 1 the queue's entries, 2 $7688 sectors to come, 3 $76B6/7 reading and stage, 4 $76C8 position
// sought, 5 $7EC4 loading, 6 $76F6 the CDDA request, 7 $7E04.
reg [22:0] w_a = 0;
reg [15:0] w_d = 0;
reg  [1:0] w_ds = 0;
reg        w_rd = 1;
reg  [7:0][17:0] last = 0;              // per word: {strobes, data} of its last write
reg [31:0] n_bios = 0;
wire       w_end = nRESET && in_cycle && nAS && !w_rd && w_ds != 0;
reg  [2:0] w_sel;
reg        w_hit;
always @* begin
    w_hit = 1;
    case (w_a)
        23'h87B28: w_sel = 3'd0;
        23'h87A39, 23'h87A3A, 23'h87A3B, 23'h87A3C, 23'h87A3D, 23'h87A3E, 23'h87A3F, 23'h87A40: w_sel = 3'd1;
        23'h87B44: w_sel = 3'd2;
        23'h87B5B: w_sel = 3'd3;
        23'h87B64: w_sel = 3'd4;
        23'h87F62: w_sel = 3'd5;
        23'h87B7B: w_sel = 3'd6;
        23'h87F02: w_sel = 3'd7;
        default: begin w_sel = 3'd0; w_hit = 0; end
    endcase
end

wire       is_music = cmd_send && cdd[35:0] == 36'h0_1285_0603;
wire       log_cmd  = cmd_send && cdd[3:0] != 0 && cdd[3:0] != 4'd2;
wire       changed  = w_end && w_hit && (w_sel == 3'd1 || last[w_sel] != {w_ds, w_d});
wire       log_bios = changed && !(w_sel == 3'd0 && w_ds == 2'b10);

reg  [1:0] tl_done = 0;
reg        tl_sel = 0, tl_on = 0, tl_trig = 0, tl_wrap = 0, tl_ph = 0, tl_clear = 0, dreq_d = 0, audio_d = 0;
reg  [1:0] tl_meta = 0;                 // 1, 2: entry 0's two words
reg  [7:0] tl_head = 1;
reg  [6:0] tl_post = 0;
reg  [2:0] fate_d = 0;
reg  [3:0] stat_d = 0, ty_sect = 0;
reg  [4:0] p = 0;                       // pending: {status, sector, BIOS, request, command}
reg [31:0] d_cmd = 0, d_req = 0, d_bios = 0, d_sect = 0, d_stat = 0, ev_pay = 0;

wire [3:0]  next_ty  = p[0] ? 4'd0 : p[1] ? 4'd1 : p[2] ? 4'd5 : p[3] ? ty_sect : 4'd6;
wire [31:0] next_pay = p[0] ? d_cmd : p[1] ? d_req : p[2] ? d_bios : p[3] ? d_sect : d_stat;

reg        tl_we;
reg  [9:0] tl_wa;
reg [31:0] tl_wd;
always @* begin
    tl_we = 0;
    tl_wa = {tl_sel, tl_head, tl_ph};
    tl_wd = tl_ph ? ev_pay : {next_ty, total[37:10]};
    if (tl_clear) begin
        tl_we = 1;
        tl_wa = {tl_sel, 9'd0};
        tl_wd = 0;
    end
    else if (tl_meta == 2'd1) begin
        tl_we = 1;
        tl_wa = {tl_sel, 9'd0};
        tl_wd = {16'h544C, 7'd0, tl_wrap, tl_head};
    end
    else if (tl_meta == 2'd2) begin
        tl_we = 1;
        tl_wa = {tl_sel, 9'd1};
        tl_wd = run_no;
    end
    else if (tl_ph || (tl_on && p != 0)) tl_we = 1;
end

always @(posedge clk_48m) begin
    if (tl_we) tl[tl_wa] <= tl_wd;
    if (!nAS) begin
        if (!in_cycle) w_ds <= 0;
        w_a  <= cd2[30:8];
        w_rd <= cd2[31];
        if (!bus68[17] || !bus68[16]) begin
            w_d  <= bus68[15:0];
            w_ds <= ~bus68[17:16];
        end
    end
    if (changed) begin
        last[w_sel] <= {w_ds, w_d};
        n_bios      <= n_bios + 1'd1;
    end

    // One entry at a time; sources are many clocks apart
    if (tl_clear) tl_clear <= 0;
    else if (tl_meta == 2'd1) tl_meta <= 2'd2;
    else if (tl_meta == 2'd2) tl_meta <= 0;
    else if (tl_ph) begin
        tl_ph   <= 0;
        tl_head <= tl_head == 8'd255 ? 8'd1 : tl_head + 1'd1;
        if (tl_head == 8'd255) tl_wrap <= 1;
        if (tl_trig) begin
            tl_post <= tl_post + 1'd1;
            if (tl_post == 7'd95) begin
                tl_on            <= 0;
                tl_done[tl_sel]  <= 1;
                tl_meta          <= 2'd1;
            end
        end
    end
    else if (tl_on && p != 0) begin
        tl_ph  <= 1;
        ev_pay <= next_pay;
        p      <= p & (p - 1'd1);
    end

    dreq_d <= dreq[25];
    fate_d <= sect[36:34];
    stat_d <= cdd[83:80];
    if (dreq[25] != dreq_d) audio_d <= dreq[24];
    if (tl_on) begin
        if (is_music) tl_trig <= 1;
        if (log_cmd) begin
            p[0]  <= 1;
            d_cmd <= {cdd[35:8], cdd[3:0]};
        end
        if (dreq[25] != dreq_d && (!dreq[24] || !audio_d)) begin
            p[1]  <= 1;
            d_req <= {dreq[24], 7'd0, dreq[23:0]};
        end
        if (log_bios) begin
            p[2]   <= 1;
            d_bios <= {11'd0, w_sel, w_ds, w_d};
        end
        if (sect[36:34] != fate_d) begin
            p[3]    <= 1;
            ty_sect <= sect[36] != fate_d[2] ? 4'd2 : sect[35] != fate_d[1] ? 4'd3 : 4'd4;
            d_sect  <= sect[31:0];
        end
        if (cdd[83:80] != stat_d) begin
            p[4]   <= 1;
            d_stat <= {cdd[83:80], 4'd0, cdd[107:84]};
        end
    end

    if (nRESET && !nreset_d) begin
        tl_sel <= cd2[0];
        tl_on  <= !tl_done[cd2[0]];
        if (!tl_done[cd2[0]]) begin
            tl_head  <= 8'd1;
            tl_post  <= 0;
            tl_trig  <= 0;
            tl_wrap  <= 0;
            tl_ph    <= 0;
            tl_clear <= 1;
            p        <= 0;
        end
    end
end

assign cd_hold = {{n_holds[15:0], n_expired[15:0]}, n_bios, n_taken, sect[31:0], 512'd0, {n_late, 13'd0, tl_done, sect[32]}};
assign cd_more = {{7'd0, cd2[53:37], ~nRESET, settings}, {resets, released}, samples[0], samples[1], samples[2], samples[3],
                  fw[0], fw[1], fw[2], fw[3], fw[4], fw[5], fw[6], fw[7], first_fail, first_late};
assign cd_last = {fw[8], fw[9], dw, {16'd0, n_nowhere}, {16'd0, n_swap}, {8'd0, n_cmds},
                  ring[0], ring[1], ring[2], ring[3], ring[4], ring[5], ring[6], ring[7]};

always @(posedge clk_48m) begin
    if (tick && nRESET) wi <= 0;
    else if (wi != WORDS) begin
        copy[ADDR_W'({record, wi})] <= words[wi];
        wi <= wi + 1'd1;
    end
end

// ---- Bridge and the slot write, clk_74a ----

wire  [6:0] idx = bridge_addr[8:2];
wire        is_pattern = idx[6:4] == 3'd3 || idx == 7'd127;
wire        tl_file = bridge_addr[12];
wire        file_wr = bridge_wr && bridge_addr[31:28] == 4'h8;
reg  [31:0] copy_q = 0, tl_q = 0;
reg  [28:0] timer = 0;              // 2^29 clocks, 7.2 s, a rising edge
reg  [15:0] saves = 0;
reg   [2:0] last_err = 0;
reg         done_d = 0;
reg   [2:0] nreset_74 = 0;          // two flops, and one to see it fall
reg         save_pulse = 0;

assign save_now  = save_pulse;
assign save_word = {13'd0, last_err, saves};    // crosses unsynchronized: a debug count, torn at worst for one frame

always @(posedge clk_74a) begin
    // The address is on the bus well before the strobe
    if (file_wr && !tl_file) copy[ADDR_W'(bridge_addr[11:2])] <= bridge_wr_data;
    if (file_wr && tl_file) tl[bridge_addr[11:2]] <= bridge_wr_data;
    copy_q <= copy[ADDR_W'(bridge_addr[11:2])];
    tl_q   <= tl[bridge_addr[11:2]];
    // A new file from the host is all ones, which is no run number
    if (file_wr && !tl_file && idx == 7'd105 && bridge_wr_data != 32'hFFFF_FFFF && bridge_wr_data > loaded_run) loaded_run <= bridge_wr_data;
    if (bridge_rd) bridge_rd_data <= tl_file ? tl_q : is_pattern ? 32'h5A00_0000 | idx : copy_q;
    timer  <= run ? timer + 1'd1 : 29'd0;
    nreset_74  <= {nreset_74[1:0], nRESET};
    save_pulse <= run && ((timer[27:0] == '1 && !timer[28]) || (nreset_74[2] && !nreset_74[1]));
    done_d <= save_done;
    if (save_done && !done_d) begin
        saves    <= saves + 1'd1;
        last_err <= save_err;
    end
end

endmodule
