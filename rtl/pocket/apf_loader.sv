// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Settings register map, reset action, data table size loop and save read path after apf_io.sv of
// Mazamars312's Neo Geo Overdrive for Pocket ("Free of use"), adapted. The ROM conversions are
// fix_convert and spr_convert_dbl of MiSTer's neogeo_loader.cpp (GPL), done here in hardware.

// Stands in for MiSTer's hps_io and its ARM-side loader: APF bridge traffic becomes the ioctl stream,
// settings, saves, controls and RTC that neogeo_pocket expects. See apf_regs.svh for the slots.
//
// Load path. Each bridge word goes into a ring in one M10K, behind a header {index, file offset} for
// its block: one word for raw slots and LO, 8 for fix, 32 for sprites. A block counts only when its
// last word is in, so a block left open is simply overwritten. The read side, on CLK_96M, takes
// whole blocks and emits them in destination order, out[i] = in[f(i)], one word per DL_PERIOD clocks.
// There is no ioctl_wait on the Pocket and none is needed: at DL_PERIOD 12 a sprite block takes 768
// clocks against the 3,666 of CLK_96M its 32 bridge words take to arrive (88 clocks of 74.25 MHz
// each, io_bridge_peripheral.v:49), so the ring never holds more than one block and the 6 or 7 words
// behind it. Nothing checks for overflow, and the bridge alone cannot cause it. If CLK_96M stopped
// during a load, the 4-bit block count would wrap after 16 raw blocks, about 19 us. That does not
// happen: Analogue's docs restore persistent values on boot immediately before Reset Exit (0x0011),
// after the slots, and no game JSON writes 0x00C or 0x108, so a saved AES setting relocks the PLL with
// the ROMs already in. At power-up the top holds the load off with status_setup_done until the PLL
// has taken the reset value of mvs.
//
//   fix_convert      out[i] = in[f(i)] on bytes, 32 byte blocks,  f(i) = {~i1, i0, i4, i3, i2}
//   spr_convert_dbl  out[i] = in[g(i)] on words, 64 word blocks,  g(i) = {~i1, i5, i4, i3, i2, ~i0}
//
// ioctl_* semantics are MiSTer's: ioctl_addr is the file's byte offset and steps by 2, and a word is
// {b1, b0}. They are registers on CLK_96M, and ioctl_wr is two clocks wide, so clk_sys (CLK_48M, same
// PLL at phase 0) sees it exactly once and neogeo_pocket's edge detector makes one DL_WR. Address and
// data stay still for DL_PERIOD, past that DL_WR, 4 clocks after ioctl_wr rises at the latest.
// DL_PERIOD 12 is what ran on the Pocket in the memory test; the mux's contract is 10 on CRAM, 9 on
// SDRAM. Below 9 the steps of R_WORD overlap. Keep it even: clk_sys samples ioctl_wr, so with an odd
// period the DL_WR gaps alternate one clock either side of it (9 gives 8 and 10).
//
// ioctl_download rises with the first emitted block of a slot, not at its first bridge word: nothing
// reads it before ioctl_wr. It falls after SILENCE_CLKS with nothing to emit, or for a slot change.
//
// apf_core_reset = ~reset_n | ~dataslot_allcomplete | first slot write | timer, in one down counter:
// all of these reload it, so it expires RESET_HOLD_CLKS after the last of them. A slot write reloading
// it is first_write_active: a reload without Reset Enter sends no other sign that it ended. A write to
// 0x108, or to the CD build's CD/CDZ, reloads it only if the bit changes, as the host may write menu items
// again with no change.
//
// That reset reaches MiSTer in two ways. Until it first falls it is status[0], "loading": the rising
// edge clears the ROM masks and the level smears them (neogeo.sv). After that it is status[14], the
// manual reset, which leaves them alone: Reset Core, an MVS/AES change or a BIOS reload must not lose
// them, and only a full load could rebuild them. Changing game reloads the bitstream (slot 0
// parameters 0x1D3, bits 7 and 8), so first_load is set again for each game.
//
// Saves: a bridge access to 0x6 or 0x7 runs two 16-bit accesses on port B of memcard.v or backup.v,
// {b1, b0} then {b3, b2}. A read is started by the strobe and its word appears about 150 ns later.
// io_bridge_peripheral.v:209-226 samples bridge_rd_data 4 clocks after the address and before the
// strobe, so the word of address N is in the transaction for N + 1, at least 1.18 us later. The host
// has to allow for that: the memory test's file came back with no lag from the same scheme.
//
// The APF menu reads a setting, changes its bits and writes it back, so 0x108, 0x200 and 0x20C read
// back, the same way: a register loaded by the strobe (apf_io.sv:779-821). 0x100 and the rest read 0.
//
// Clock crossings, source to destination:
//   reset_n, dataslot_allcomplete (core_bridge_cmd.v, clk_74a), reconfiguring (pll_mvs_cfg.sv,
//     clk_74a): same domain as the timer, which registers the result; no synchroniser there.
//   core reset, SYSTEM_TYPE, video_mode, memory_card_enable, DIPSW, APF_Video_ratio, cont*_key
//     (clk_74a) to CLK_96M: two flops per bit. Each bit stands alone.
//   rtc_valid (clk_74a) to CLK_96M: two flops, rtc[64]. rtc[63:0] is a function of registers held by
//     core_bridge_cmd.v since before rtc_valid rose, and the host sends them once: no flops.
//   Block count (clk_74a) to CLK_96M: Gray coded, two flops, steps one at a time. The ring's words
//     are written before the count moves and read by CLK_96M only after.
//   Save access (clk_74a) to CLK_96M: toggle, two flops. Address and data are held until the next
//     access, 1.18 us later at least.
//   Save read word (CLK_96M) to clk_74a: no flops, it is stable from 150 ns after the strobe until
//     the next one, and the bridge samples it inside that window.
//   cfg, v2_offset, v2rom_mask (clk_74a): no flops, written by the game JSON and quiet before reset ends.
//   mvs, prom1_conflict: stay in clk_74a. pll_mvs_cfg.sv takes mvs from any domain.
// CLK_96M to clk_sys is synchronous: same PLL, no false path.
module apf_loader #(
    parameter int DL_PERIOD       = 12,         // CLK_96M clocks per ioctl word
    parameter int SILENCE_CLKS    = 6187,       // 64 us of CLK_96M
    parameter int RESET_HOLD_CLKS = 37125000,   // 0.5 s of clk_74a; the Overdrive holds 2^26, 0.9 s
    parameter bit CD_BUILD        = 0           // the Neo Geo CD core: cfg[31], the CD settings, the disc slots
) (
    input             clk_74a,
    input             CLK_96M,

    input      [31:0] bridge_addr,
    input             bridge_wr,
    input      [31:0] bridge_wr_data,
    input             bridge_rd,
    output     [31:0] bridge_rd_data,       // the top muxes in core_bridge_cmd for 0xF8xxxxxx

    input             reset_n,
    input             dataslot_allcomplete,
    input             reconfiguring,        // pll_pocket
    input             dataslot_update,      // core_bridge_cmd.v: the host (re)loaded a slot
    input      [15:0] dataslot_update_id,
    input      [31:0] dataslot_update_size,
    input             rtc_valid,
    input      [31:0] rtc_date_bcd,
    input      [31:0] rtc_time_bcd,
    output reg  [9:0] datatable_addr = 0,
    output reg        datatable_wren = 0,
    output reg [31:0] datatable_data = 0,
    input      [31:0] datatable_q,
    input      [31:0] cont1_key,
    input      [31:0] cont2_key,
    input      [31:0] cont3_key,
    input      [31:0] cont4_key,

    output reg        ioctl_download = 0,
    output reg  [7:0] ioctl_index = 0,
    output reg        ioctl_wr = 0,
    output reg [26:0] ioctl_addr = 0,
    output reg [15:0] ioctl_dout = 0,

    output     [15:0] joystick_0,           // MiSTer order: 0 R, 1 L, 2 D, 3 U, 4-7 A-D, 8 Start,
    output     [15:0] joystick_1,           // 9 Select, 10 Coin
    output     [15:0] joystick_2,
    output     [15:0] joystick_3,

    output     [63:0] status,
    output     [31:0] cfg,
    output     [64:0] rtc,
    output     [23:0] v2_offset,
    output     [23:0] v2rom_mask,
    output            width320,
    output      [2:0] video_slot,
    output            mvs,                  // pll_pocket: clk_74a
    output            apf_core_reset,
    output            prom1_conflict,       // clk_74a

    // CD build, clk_74a: the sizes of slots 2 and 3 in the data table, and a mount request pulse
    output     [31:0] disc_size,
    output reg [31:0] disc_bin_size = 0,
    output reg        cd_mount_req = 0,

    // Port B of backup.v and memcard.v
    output     [14:0] sram_addr,
    output reg        sram_wr = 0,
    output     [11:0] memcard_addr,
    output reg        memcard_wr = 0,
    output reg [15:0] sd_buff_dout = 0,
    input      [15:0] sram_buff_dout,
    input      [15:0] card_buff_dout
);

`include "apf_regs.svh"

// ---- Settings, clk_74a ----

reg  [2:0] dipsw = 3'b111;      // {DIPSW[7:6], DIPSW[0]}
reg        system_type = 1;
reg        memory_card_enable = 0;
reg        video_mode = 0;
reg  [2:0] apf_video_ratio = 0;
reg        pchip_main = 0;
reg  [2:0] pchip_sub = 0;
reg        use_pcm_ovd = 0;     // the inverse of MiSTer's use_pcm
reg  [1:0] cmc_chip = 0, cart_chip = 0;
reg  [2:0] c1_wait = 0;
reg        ms5p = 0, xram = 0, adpcma_ext = 0;
reg [23:0] v2_offset_r = 0, v2rom_mask_r = 0;
reg        cd_type = 0;         // CD build: 1 = CDZ
reg  [1:0] cd_region = 0, cd_speed = 0;
reg        cd_lid = 0;

wire settings_wr = bridge_wr && bridge_addr[31:12] == 20'hF0000;

always @(posedge clk_74a) if (settings_wr)
    case (bridge_addr[11:0])
        REG_DIPSW_OLD, REG_DIPSW:             dipsw              <= {bridge_wr_data[7:6], bridge_wr_data[0]};
        REG_SYSTEM_TYPE_OLD, REG_SYSTEM_TYPE: system_type        <= bridge_wr_data[0];
        REG_MEMCARD_OLD, REG_MEMCARD:         memory_card_enable <= bridge_wr_data[0];
        REG_VIDEO_MODE:                       video_mode         <= bridge_wr_data[0];
        REG_VIDEO_RATIO:                      apf_video_ratio    <= bridge_wr_data[2:0];
        REG_PCHIP_MAIN_OLD, REG_PCHIP_MAIN:   pchip_main         <= bridge_wr_data[0];
        REG_PCHIP_SUB_OLD, REG_PCHIP_SUB:     pchip_sub          <= bridge_wr_data[2:0];
        REG_USE_PCM_OLD, REG_USE_PCM:         use_pcm_ovd        <= bridge_wr_data[0];
        REG_CMC_CHIP_OLD, REG_CMC_CHIP:       cmc_chip           <= bridge_wr_data[1:0];
        REG_CART_CHIP_OLD, REG_CART_CHIP:     cart_chip          <= bridge_wr_data[1:0];
        REG_C1_WAIT_OLD, REG_C1_WAIT:         c1_wait            <= bridge_wr_data[2:0];
        REG_V2_OFFSET_OLD, REG_V2_OFFSET:     v2_offset_r        <= bridge_wr_data[23:0];
        REG_V2_MASK_OLD, REG_V2_MASK:         v2rom_mask_r       <= bridge_wr_data[23:0];
        REG_MS5P:                             ms5p               <= bridge_wr_data[0];
        REG_XRAM:                             xram               <= bridge_wr_data[0];
        REG_ADPCMA_EXT:                       adpcma_ext         <= bridge_wr_data[0];
        default: ;
    endcase

// The CD core's own settings, MiSTer's status[2], [11:10], [30:29] and [15]
always @(posedge clk_74a) if (CD_BUILD && settings_wr)
    case (bridge_addr[11:0])
        REG_CD_TYPE:   cd_type   <= bridge_wr_data[0];
        REG_CD_REGION: cd_region <= bridge_wr_data[1:0];
        REG_CD_SPEED:  cd_speed  <= bridge_wr_data[1:0];
        REG_CD_LID:    cd_lid    <= bridge_wr_data[0];
        default: ;
    endcase

wire [2:0] cart_pchip = pchip_main ? 3'd2 : (pchip_sub >= 3'd1 && pchip_sub <= 3'd5) ? 3'd2 + pchip_sub : 3'd0;

assign cfg = {1'(CD_BUILD), c1_wait[1:0], c1_wait[2], cmc_chip, cart_chip, ~use_pcm_ovd, cart_pchip,
              adpcma_ext, xram, ms5p, 17'd0};
assign v2_offset  = v2_offset_r;
assign v2rom_mask = v2rom_mask_r;
assign mvs        = system_type & ~CD_BUILD;

// ---- Slot decode, clk_74a ----

reg        slot_hit;
reg  [4:0] w_index;
reg [25:0] w_off;

always_comb begin
    slot_hit = bridge_addr[27:26] == 0;
    w_off    = bridge_addr[25:0];
    w_index  = IDX_V;
    case (bridge_addr[31:28])
        4'h1: begin
            slot_hit = bridge_addr[27:24] == 0;
            w_off    = {6'd0, bridge_addr[19:0]};
            casez (bridge_addr[23:19])
                5'b0????,
                5'b100??: begin w_index = IDX_P; w_off = {2'd0, bridge_addr[23:0]}; end
                5'b1010?: w_index = IDX_BIOS;
                5'b1100?: w_index = IDX_SROM;
                5'b1101?: w_index = IDX_SFIX;
                5'b11111: begin w_index = IDX_M1; w_off = {7'd0, bridge_addr[18:0]}; end
                default:  slot_hit = 0;
            endcase
        end
        4'h2: w_index = IDX_V;
        4'h4: w_index = IDX_CROM;
        4'h5: begin
            w_index  = IDX_LO;
            slot_hit = bridge_addr[27:16] == 0;     // as MiSTer, which loads only 0x10000 of a larger file
        end
        default: slot_hit = 0;
    endcase
end

wire slot_wr = bridge_wr && slot_hit;

// ---- Core reset, clk_74a ----

reg [25:0] reset_timer = 26'(RESET_HOLD_CLKS);
reg        core_reset_74 = 1;
reg        first_load = 1;

wire reset_restart = ~reset_n | ~dataslot_allcomplete | reconfiguring | slot_wr
                   | (settings_wr && bridge_addr[11:0] == REG_CORE_RESET && bridge_wr_data[0])
                   | (settings_wr && bridge_addr[11:0] == REG_SYSTEM_TYPE && bridge_wr_data[0] != system_type)
                   | (CD_BUILD && settings_wr && bridge_addr[11:0] == REG_CD_TYPE && bridge_wr_data[0] != cd_type);

always @(posedge clk_74a) begin
    if (reset_restart) reset_timer <= 26'(RESET_HOLD_CLKS);
    else if (reset_timer != 0) reset_timer <= reset_timer - 1'd1;
    core_reset_74 <= reset_restart || reset_timer != 0;
    if (!core_reset_74) first_load <= 0;
end

// ---- Settings the menu reads back, clk_74a ----

reg [2:0] settings_rd = 0;

always @(posedge clk_74a) if (bridge_rd && bridge_addr[31:12] == 20'hF0000)
    case (bridge_addr[11:0])
        REG_SYSTEM_TYPE: settings_rd <= {2'd0, system_type};
        REG_VIDEO_MODE:  settings_rd <= {2'd0, video_mode};
        REG_VIDEO_RATIO: settings_rd <= apf_video_ratio;
        REG_CD_TYPE:     settings_rd <= {2'd0, cd_type};
        REG_CD_REGION:   settings_rd <= {1'd0, cd_region};
        REG_CD_SPEED:    settings_rd <= {1'd0, cd_speed};
        REG_CD_LID:      settings_rd <= {2'd0, cd_lid};
        default:         settings_rd <= 0;
    endcase

// ---- Save slots in the data table, clk_74a. As memtest_top.v, with the second slot ----
// The CD build also reads the size words of the disc slots, which the host fills in when it loads them.

reg [1:0] dt_wait = 0;
reg [1:0] dt_take = 0;      // the size word at this address is slot 2's or slot 3's
reg [31:0] table_size = 0;
reg [31:0] picked_size = 0;
// A pick's own command carries the size, and the order of that command and the table's word is not known
assign disc_size = picked_size != 0 ? picked_size : table_size;
always @(posedge clk_74a) begin
    if (CD_BUILD && dataslot_update && dataslot_update_id == 16'(SLOT_DISC)) picked_size <= dataslot_update_size;
    datatable_wren <= 0;
    dt_wait <= dt_wait + 1'b1;
    if (dt_wait == 2'd3) begin
        if (datatable_addr[0]) begin
            datatable_addr <= datatable_addr + 1'b1;
            dt_take <= 0;
            if (dt_take[0]) table_size    <= datatable_q;
            if (dt_take[1]) disc_bin_size <= datatable_q;
        end
        else if (CD_BUILD && (datatable_q == SLOT_DISC || datatable_q == SLOT_DISC_BIN)) begin
            datatable_addr <= datatable_addr + 1'b1;
            dt_take <= {datatable_q == SLOT_DISC_BIN, datatable_q == SLOT_DISC};
        end
        else if (datatable_q == SLOT_MEMCARD || datatable_q == SLOT_BACKUP) begin
            datatable_addr <= datatable_addr + 1'b1;
            datatable_data <= datatable_q == SLOT_MEMCARD ? SIZE_MEMCARD : SIZE_BACKUP;
            datatable_wren <= 1;
        end
`ifdef NEOGEO_WAIT_COUNTER
        else if (datatable_q == 32'h103) begin      // wait_counter.sv
            datatable_addr <= datatable_addr + 1'b1;
            datatable_data <= CD_BUILD ? 32'd512 : 32'd256;     // layout 3 or layout 1
            datatable_wren <= 1;
        end
`endif
        else datatable_addr <= datatable_addr >= 10'd126 ? 10'd0 : datatable_addr + 2'd2;
    end
end

// ---- Mount request, clk_74a: the host loaded slot 2, or finished a load with a disc in ----

reg allcomplete_d = 0;
always @(posedge clk_74a) begin
    allcomplete_d <= dataslot_allcomplete;
    cd_mount_req  <= CD_BUILD && ((dataslot_update && dataslot_update_id == 16'(SLOT_DISC))
                                  || (dataslot_allcomplete && !allcomplete_d && disc_size != 0));
end

// ---- The ring, write side, clk_74a ----

(* ramstyle = "M10K, no_rw_check" *) reg [31:0] ring [0:255];

wire       w_is_fix = w_index == IDX_SROM || w_index == IDX_SFIX;
wire [4:0] w_mask   = w_index == IDX_CROM ? 5'd31 : w_is_fix ? 5'd7 : 5'd0;     // bridge words per block, minus 1
wire [4:0] w_pos    = w_off[6:2] & w_mask;
wire       w_first  = w_pos == 0;

reg  [7:0] wp = 0, wp_commit = 0;
reg  [3:0] blocks = 0, blocks_gray = 0;
reg        open = 0, data_due = 0, last_due = 0;
reg  [4:0] open_index = 0;
reg [25:0] next_off = 0;
reg [31:0] data_r = 0;
reg        prom_past_8m = 0, prom1_alone = 0, reset_n_d = 0;

wire       w_seq  = w_index == open_index && w_off == next_off;
wire       w_cont = open && w_seq;

wire [3:0] blocks_next = blocks + 1'd1;
wire [7:0] wp_next     = wp + 1'd1;

// The header at the first word, the word a clock later: bridge writes are 88 clocks apart
wire        ring_hdr = slot_wr && w_first;
wire  [7:0] ring_wa  = ring_hdr ? wp_commit : wp;
wire [31:0] ring_wd  = ring_hdr ? {1'b0, w_index, w_off} : data_r;

always @(posedge clk_74a) if (ring_hdr || data_due) ring[ring_wa] <= ring_wd;

always @(posedge clk_74a) begin
    if (slot_wr) begin
        open       <= w_first || w_cont;
        open_index <= w_index;
        next_off   <= w_off + 26'd4;
        if (w_first || w_cont) begin
            data_due <= 1;
            last_due <= w_pos == w_mask;
            data_r   <= bridge_wr_data;
        end
        if (w_first) wp <= wp_commit + 1'd1;
    end

    if (data_due) begin
        data_due <= 0;
        wp       <= wp_next;
        if (last_due) begin
            wp_commit   <= wp_next;
            blocks      <= blocks_next;
            blocks_gray <= blocks_next ^ (blocks_next >> 1);
        end
    end

    // A file reaching 0x800000 runs on from below it; prom1 starts there on its own
    reset_n_d <= reset_n;
    if (slot_wr && w_index == IDX_P && w_off == 26'h800000) begin
        if (w_seq) prom_past_8m <= 1;
        else       prom1_alone  <= 1;
    end
    if (reset_n_d && !reset_n) begin
        prom_past_8m <= 0;
        prom1_alone  <= 0;
    end
end

assign prom1_conflict = prom_past_8m & prom1_alone;

// ---- Save access, clk_74a ----

reg        sv_tog = 0, sv_we = 0, sv_backup = 0;
reg [13:0] sv_addr = 0;     // in 32-bit words
reg [31:0] sv_data = 0;

always @(posedge clk_74a)
    if ((bridge_wr || bridge_rd) && bridge_addr[31:29] == 3'b011) begin
        sv_tog    <= ~sv_tog;
        sv_we     <= bridge_wr;
        sv_backup <= bridge_addr[28];
        sv_addr   <= bridge_addr[15:2];
        sv_data   <= bridge_wr_data;
    end

// ---- Crossing to CLK_96M ----

function automatic [9:0] pick_keys(input [31:0] k);
    pick_keys = {k[15:14], k[7:0]};
endfunction

localparam int SYNC_W = 3 + 40 + 3 + 3 + 3 + 4 + 1 + 6;

wire [SYNC_W-1:0] sync_in = {core_reset_74, first_load, rtc_valid, pick_keys(cont4_key), pick_keys(cont3_key),
                             pick_keys(cont2_key), pick_keys(cont1_key), apf_video_ratio, dipsw,
                             memory_card_enable, video_mode, system_type, blocks_gray, sv_tog,
                             cd_type, cd_region, cd_speed, cd_lid};
reg  [SYNC_W-1:0] sync_1 = 0, sync_2 = 0;

always @(posedge CLK_96M) begin
    sync_1 <= sync_in;
    sync_2 <= sync_1;
end

wire        core_reset_s, first_load_s, rtc_valid_s, memory_card_s, video_mode_s, system_type_s, sv_tog_s;
wire        cd_type_s, cd_lid_s;
wire  [1:0] cd_region_s, cd_speed_s;
wire  [9:0] key4_s, key3_s, key2_s, key1_s;
wire  [2:0] ratio_s, dipsw_s;
wire  [3:0] blocks_s;
assign {core_reset_s, first_load_s, rtc_valid_s, key4_s, key3_s, key2_s, key1_s, ratio_s, dipsw_s,
        memory_card_s, video_mode_s, system_type_s, blocks_s, sv_tog_s,
        cd_type_s, cd_region_s, cd_speed_s, cd_lid_s} = sync_2;

function automatic [15:0] joy(input [9:0] k);   // {Start, Select, Y, X, B, A, R, L, D, U} of the APF map
    joy = {5'd0, k[8], k[8], k[9], k[7:4], k[0], k[1], k[2], k[3]};
endfunction

assign joystick_0 = joy(key1_s);
assign joystick_1 = joy(key2_s);
assign joystick_2 = joy(key3_s);
assign joystick_3 = joy(key4_s);

assign apf_core_reset = core_reset_s;
assign width320       = ratio_s[2];
assign video_slot     = ratio_s;

// MiSTer's bits: 0 = loading, 1 = MVS, 3 = PAL, 4 = card unplugged (neogeo.sv:1311), 14 = manual reset
// (neogeo.sv:170), 16 = 304 wide (neogeo.sv:159)
// The CD build adds 2 CD/CDZ, 10-11 region, 15 lid open and 29-30 speed (cd.sv)
assign status = {33'd0, cd_speed_s, 12'd0, ~ratio_s[2], cd_lid_s, core_reset_s & ~first_load_s, 2'd0, cd_region_s,
                 ~dipsw_s[2:1], ~dipsw_s[0], 2'd0, memory_card_s, video_mode_s, cd_type_s, system_type_s,
                 core_reset_s & first_load_s};

// uPD4990 layout (upd4990.v:51). APF words, from the 0x0090 command in Analogue's developer docs:
// date 0xYYYYMMDD, time [27:24] weekday 0-6, [23:0] 0xHHMMSS. The docs do not say which word holds
// the weekday or which day is 0: not confirmed, see docs/hw-tests.md.
assign rtc = {rtc_valid_s, 13'd0, rtc_time_bcd[26:24] + 3'd1, rtc_date_bcd[23:16],
              3'd0, rtc_date_bcd[12:8], 2'd0, rtc_date_bcd[5:0],
              2'd0, rtc_time_bcd[21:16], 1'b0, rtc_time_bcd[14:8], 1'b0, rtc_time_bcd[6:0]};

// ---- The ring, read side, CLK_96M ----

localparam [1:0] R_IDLE = 0, R_HDR = 1, R_SLOT = 2, R_WORD = 3;

reg  [1:0] st = R_IDLE;
reg  [3:0] t = 0;
reg  [7:0] rp = 0, ra = 0;
reg  [3:0] blocks_rd = 0;
reg [31:0] rd_q = 0;
reg  [4:0] h_index = 0;
reg [25:0] h_base = 0;
reg  [5:0] i = 0;           // output word of the block
reg  [1:0] sel = 0;
reg  [7:0] lo = 0, hi = 0;
reg [12:0] silence = 0;

wire pending = (blocks_rd ^ (blocks_rd >> 1)) != blocks_s;

wire is_fix = h_index == IDX_SROM || h_index == IDX_SFIX;
wire is_spr = h_index == IDX_CROM;
wire is_lo  = h_index == IDX_LO;

wire [5:0] last_i = is_spr ? 6'd63 : is_fix ? 6'd15 : is_lo ? 6'd3 : 6'd1;
wire [7:0] rp_step = is_spr ? 8'd33 : is_fix ? 8'd9 : 8'd2;

// The byte of the block for this output word: t[1] is 0 for its low byte, 1 for its high byte
wire [4:0] fix_k = {i[3:0], t[1]};
wire [6:0] src = is_fix ? {2'd0, ~fix_k[1], fix_k[0], fix_k[4], fix_k[3], fix_k[2]}
               : is_spr ? {~i[1], i[5], i[4], i[3], i[2], ~i[0], t[1]}
               : is_lo  ? {5'd0, i[1:0]}
               :          {5'd0, i[0], t[1]};

wire [7:0] rd_byte = sel == 0 ? rd_q[31:24] : sel == 1 ? rd_q[23:16] : sel == 2 ? rd_q[15:8] : rd_q[7:0];

always @(posedge CLK_96M) begin
    rd_q <= ring[ra];

    case (st)
        R_IDLE:
            if (pending) begin
                ra <= rp;
                t  <= 0;
                st <= R_HDR;
            end else if (ioctl_download) begin
                silence <= silence + 1'd1;
                if (silence == 13'(SILENCE_CLKS - 1)) ioctl_download <= 0;
            end

        R_HDR: begin
            t <= t + 1'd1;
            if (t == 1) begin
                h_index <= rd_q[30:26];
                h_base  <= rd_q[25:0];
                i       <= 0;
                t       <= 0;
                st      <= ioctl_download && ioctl_index == 8'(rd_q[30:26]) ? R_WORD : R_SLOT;
            end
        end

        // MiSTer takes the index a clk_sys later, so each edge gets time to settle
        R_SLOT: begin
            t <= t + 1'd1;
            case (t)
                0:  ioctl_download <= 0;
                4:  ioctl_index    <= 8'(h_index);
                8:  ioctl_download <= 1;
                12: begin
                    t  <= 0;
                    st <= R_WORD;
                end
                default: ;
            endcase
        end

        // Two reads per word, a clock to load rd_q and one to see it
        default: begin
            t <= t + 1'd1;
            if (t == 0 || t == 2) begin
                ra  <= rp + 8'd1 + 8'(src[6:2]);
                sel <= src[1:0];
            end
            if (t == 2) lo <= rd_byte;
            if (t == 4) hi <= rd_byte;
            if (t == 5) begin
                ioctl_addr <= (is_lo ? {h_base, 1'b0} : {1'b0, h_base}) | {20'd0, i, 1'b0};
                ioctl_dout <= is_lo ? {8'h00, lo} : {hi, lo};
            end
            if (t == 6) ioctl_wr <= 1;
            if (t == 8) ioctl_wr <= 0;
            if (t == 4'(DL_PERIOD - 1)) begin
                t <= 0;
                i <= i + 1'd1;
                if (i == last_i) begin
                    rp        <= rp + rp_step;
                    blocks_rd <= blocks_rd + 1'd1;
                    silence   <= 0;
                    st        <= R_IDLE;
                end
            end
        end
    endcase
end

// ---- Saves, CLK_96M. Port B clocks at clk_sys: each step leaves it two clocks of CLK_96M ----

reg        sv_tog_d = 0, sv_busy = 0, sv_half = 0;
reg  [3:0] sv_t = 0;
reg [31:0] sv_rd_word = 0;

wire [15:0] sv_q = sv_backup ? sram_buff_dout : card_buff_dout;

assign sram_addr      = {sv_addr, sv_half};
assign memcard_addr   = {sv_addr[10:0], sv_half};
assign bridge_rd_data = bridge_addr[31:28] == 4'hF ? {29'd0, settings_rd} : sv_rd_word;

always @(posedge CLK_96M) begin
    sv_tog_d <= sv_tog_s;
    if (sv_tog_d != sv_tog_s) begin
        sv_busy <= 1;
        sv_half <= 0;
        sv_t    <= 0;
    end else if (sv_busy) begin
        sv_t <= sv_t + 1'd1;
        case (sv_t)
            0, 6: sd_buff_dout <= sv_half ? {sv_data[7:0], sv_data[15:8]} : {sv_data[23:16], sv_data[31:24]};
            1, 7: begin
                sram_wr    <= sv_we & sv_backup;
                memcard_wr <= sv_we & ~sv_backup;
            end
            3, 9: begin
                sram_wr    <= 0;
                memcard_wr <= 0;
            end
            5: begin
                if (!sv_we) sv_rd_word[31:16] <= {sv_q[7:0], sv_q[15:8]};
                sv_half <= 1;
            end
            11: begin
                if (!sv_we) sv_rd_word[15:0] <= {sv_q[7:0], sv_q[15:8]};
                sv_busy <= 0;
            end
            default: ;
        endcase
    end
end

endmodule
