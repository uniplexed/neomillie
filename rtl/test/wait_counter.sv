// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// What the memory costs the 68K in a real game. Debug builds only (NEOGEO_WAIT_COUNTER, revisions
// neogeo_wait and neogeo8_wait): core_top reads nothing back from it but the bridge, and it only
// watches the core's signals, so it cannot change what the core does.
//
// A ROM zone read with no wait state keeps nAS low for 10 CLK_48M. Clocks past 10 are what the 68K
// waited on PROM_DATA_READY; each wait state is 4 of them. The sums go to the bucket of what CRAM0 was
// doing when the read's request reached the mux, in the mux's owner code: 0 loader, 1 idle, 2 fix, 3 Z80.
//
// The CD build (LAYOUT 3) counts the BIOS and PROG RAM, reads and writes (rom_zone, neogeo_pocket.sv), and not
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
// File, big endian 32-bit words, read the way memtest_bridge answers (tools/check_wait_save.py). 256 bytes in layout 1
// and in layout 2, the CD core up to 0.3.1, and 512 in layout 3:
//    0 magic, 1 {RD_WAIT, C1 wait setting, layout}, 2 frames, 3 worst frame's lost clocks,
//    4 total clocks (hi, lo), 6 reads by code (4 x hi, lo), 14 lost clocks by code (4 x hi, lo),
//   22 frames again, 31 {last error of a save, saves done}, 32-63 counting pattern for the read lag
// Layout 3 (the CD core) also fills 23 to 30, to see how far the BIOS got without a screen to look at:
//   23 {writes to FIX: 24 bits, the last CDD_COMMAND_DATA's hi 8 bits}, 24 its lo,
//   25 {writes to SPR: 24 bits, the last CDD_STATUS's hi 8 bits}, 26 its lo,
//   27 {why the last mount ended, cd_mount's reason, 4 bits; cur_status 4 bits; cur_lba 24 bits},
//   28 {writes to PCM: 24 bits, failed sectors: 8 bits}, 29 {writes to the Z80, exchanges: 16 bits each}, 30 disc_bin_size
// A write is a rising edge of the transfer area's strobe, the 68K's or a DMA's: its strobe falls between words
// (sim/topcd counts both). The transfers' counts are wide because a BIOS and a game move whole blocks: at 10 bits, as
// they first were, 128 KB of FIX reads 0. The 68K's own command and status words are read in the clock of the
// copy: a change in those 31 clocks tears one word, and the next frame's file is whole.
//
// Layout 3 moves the pattern to 48-63, with one more at 127 for the file's end, and adds, at each frame's copy:
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
// still unanswered. A reset's own answer, to no command, stays out. Nothing here is cleared by a reset.
//
// Saves: the host reads a nonvolatile slot when the core stops: Quit, sleep or turning off. As that is
// not done on a hard power off or a hang, the core also asks for a slot write (0x0184) about every 7 s.
module wait_counter #(
    parameter [7:0]  RD_WAIT = 8,
    parameter [15:0] LAYOUT = 1         // 1 the cartridge core, 3 the CD core: what the owner codes mean, and the file
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
    input             run,          // clk_74a: the host has let the core run
    output            save_now,     // rising edge asks for the slot write
    input             save_done,
    input       [2:0] save_err,

    input     [113:0] cdd,          // layout 3 only, CLK_48M: {fetch_err; writes Z80, PCM, SPR, FIX; status latch; cur_lba; cur_status; status; command}
    input      [31:0] disc_bin_size,// layout 3 only, clk_74a: static once the disc is mounted
    input       [3:0] disc_reason,  // layout 3 only, clk_74a: likewise
    input      [33:0] cd2,          // layout 3 only: neogeo_pocket.sv's dbg_cd2, CLK_48M and CLK_96M, the same PLL
    input     [319:0] fetch,        // layout 3 only: cd_fetch.sv's dbg_fetch, CLK_48M
    input     [383:0] dma           // layout 3 only: pocket_mem_mux.sv's dbg_dma, CLK_96M, the same PLL
);

localparam [31:0] MAGIC = 32'h4E47_5754;    // NGWT
localparam [7:0]  IDEAL_LEN = 8'd10;
localparam [6:0]  WORDS = LAYOUT == 3 ? 7'd105 : 7'd23;

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

(* ramstyle = "M10K, no_rw_check" *) reg [31:0] copy [0:127];

reg [6:0] wi = WORDS;

wire [0:7][31:0]  cd_words;     // 23-30
wire [0:15][31:0] cd_more;      // 32-47
wire [0:40][31:0] cd_last;      // 64-104
wire [0:104][31:0] words = {MAGIC, RD_WAIT, 5'd0, c1_wait, LAYOUT, frames, worst, total,
                            reads[0], reads[1], reads[2], reads[3],
                            lost[0], lost[1], lost[2], lost[3], frames, cd_words,
                            32'd0, cd_more, 512'd0, cd_last};

generate if (LAYOUT == 3) begin : g_cd
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

    assign cd_more = {{24'd0, ~nRESET, settings}, {resets, released}, samples[0], samples[1], samples[2], samples[3],
                      fw[0], fw[1], fw[2], fw[3], fw[4], fw[5], fw[6], fw[7], first_fail, first_late};
    assign cd_last = {fw[8], fw[9], dw, {16'd0, n_nowhere}, {16'd0, n_swap}, {8'd0, n_cmds},
                      ring[0], ring[1], ring[2], ring[3], ring[4], ring[5], ring[6], ring[7]};
end else begin : g_no_cd
    assign cd_words = '0;
    assign cd_more = '0;
    assign cd_last = '0;
end endgenerate

always @(posedge clk_48m) begin
    if (tick) wi <= 0;
    else if (wi != WORDS) begin
        copy[wi] <= words[wi];
        wi <= wi + 1'd1;
    end
end

// ---- Bridge and the slot write, clk_74a ----

wire  [6:0] idx = bridge_addr[8:2];
wire        is_pattern = LAYOUT == 3 ? idx[6:4] == 3'd3 || idx == 7'd127 : idx[5];
reg  [31:0] copy_q = 0;
reg  [28:0] timer = 0;              // 2^29 clocks, 7.2 s, a rising edge
reg  [15:0] saves = 0;
reg   [2:0] last_err = 0;
reg         done_d = 0;

assign save_now = timer[28];

always @(posedge clk_74a) begin
    copy_q <= copy[idx];            // the address is on the bus well before the strobe
    if (bridge_rd) bridge_rd_data <= is_pattern ? 32'h5A00_0000 | idx :
                                     idx == 7'd31 ? {13'd0, last_err, saves} : copy_q;
    timer  <= run ? timer + 1'd1 : 29'd0;
    done_d <= save_done;
    if (save_done && !done_d) begin
        saves    <= saves + 1'd1;
        last_err <= save_err;
    end
end

endmodule
