//============================================================================
//  SNK NeoGeo for MiSTer
//
//  Copyright (C) 2018 Sean 'Furrtek' Gonsalves
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
//
//  Pocket port: copy of neogeo.sv of NeoGeo_MiSTer with its boundaries replaced for the Analogue
//  Pocket. Every edit is tagged POCKET. The combined work is distributed under GPL-3 (GNU General
//  Public License, version 3 or later).
//============================================================================
// Current status:
// Neo CD CD check ok but crashes when loading. No more video glitches.

// How about not using a cache at all and DMAing directly from the data fed by the HPS ?
// The "sector ready" IRQ could be triggered just when a sector is requested, and the actual transfer
// could be done when the system ROM starts up the DMA transfer ?

// Neo CD times 12/05/2019:
// SECTOR_READY goes high at SECTOR_TIMER == 430631
// So it takes 600000-430631=169369 ticks to get a sector from HPS
// 169369/120M=1.41ms (1451 kB/s)
// DMA copy: 215 ticks for 10 bytes
// So 215/120M/10=179.17ns per byte (5450 kB/s)

// Neo CD times 11/05/2019:
// DMA copy: 616 ticks for 10 bytes
// So 215/120M/10=513.3ns per byte (1902 kB/s)

// POCKET: explicit port list instead of sys/emu_ports.vh. hps_io, sdram_mux, sdram, ddram, cpram,
// video_mixer, video_freak, pll and pll_cfg are gone; the pins belong to pocket_mem_mux and sram_ctrl, or
// cd_fix_sram in the CD build.
module neogeo_pocket
(
	input         CLK_96M,
	input         CLK_48M,
	input         pll_locked,
	input         RESET,            // ~pll_locked only, never the loader's reset (see got_rom_write)

	// Formerly hps_io, now the loader
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	input         ioctl_download,
	input   [7:0] ioctl_idx,
	input  [15:0] joystick_0,       // 21--HNLS DCBAUDLR  (1=A+B, 2=C+D combos)
	input  [15:0] joystick_1,
	input  [15:0] joystick_2,
	input  [15:0] joystick_3,
	input  [63:0] status_in,
	input  [31:0] cfg,
	input  [64:0] rtc,
	input  [23:0] v2_offset,        // R5: from the game JSON
	input  [23:0] v2rom_mask,       // R5: used for V2ROM_MASK when non-zero

	// Saves: second ports of backup and memcard, in clk_sys
	input  [14:0] sram_addr,
	input         sram_wr,
	input  [11:0] memcard_addr,
	input         memcard_wr,
	input  [15:0] sd_buff_dout,
	output [15:0] sram_buff_dout,
	output [15:0] card_buff_dout,

`ifdef NEOGEO_CD
	// POCKET: formerly hps_ext: cd_host's fetch client and bank, and the drive's side of the disc: cd_mount's, at clk_74a
	output        fr_req,
	output [15:0] fr_slot,
	output [31:0] fr_offset,
	output  [1:0] fr_bank_slot,
	input         fr_done,
	input         fr_err,
	output [11:0] bank_rd_addr,
	input  [31:0] bank_rd_q,
	input         disc_present,
	input         disc_loading,
	input   [6:0] track_count,
	input  [23:0] disc_end,
	output  [6:0] toc_rd_track,
	input  [79:0] toc_rd_entry,     // cd_defs::toc_entry_t
`endif

	output [15:0] snd_left,
	output [15:0] snd_right,

	// Video, in CLK_48M with ce_pix
	output reg    ce_pix,
	output  [7:0] r,
	output  [7:0] g,
	output  [7:0] b,
	output        hs,
	output        vs,
	output        hblank,
	output        vblank,

	output        dl_overflow,
`ifdef NEOGEO_WAIT_COUNTER
	output  [4:0] dbg_wait,		// wait_counter.sv: {CRAM0 at the 68K's request, ROM zone, nAS, nRESET}
`ifdef NEOGEO_CD
	output [113:0] dbg_cdd,		// wait_counter.sv, layout 3: the CD side, see the assign below
	output  [53:0] dbg_cd2,		// wait_counter.sv, layout 3: settings, 68K, DMA, hold, see the assign below
	output  [36:0] dbg_sect,	// wait_counter.sv, layout 3: cd.sv's DBG_SECT, what became of each sector
	output  [48:0] dbg_dmab,	// wait_counter.sv, layout 3: the CD DMA's PROG RAM accesses, see the assign below
	output  [17:0] dbg_bus68,	// wait_counter.sv, layout 3: {nUDS, nLDS, the 68K's write data}
	output  [25:0] dbg_dreq,	// wait_counter.sv, layout 3: the drive's request of a sector: {toggle, audio, LBA}
	output [319:0] dbg_fetch,	// cd_fetch.sv's counts
	output [383:0] dbg_dma,		// pocket_mem_mux.sv's counts
`endif
`endif

	// Pocket pins
	inout  [15:0] dram_dq,
	output [12:0] dram_a,
	output  [1:0] dram_dqm,
	output  [1:0] dram_ba,
	output        dram_we_n,
	output        dram_ras_n,
	output        dram_cas_n,
	output        dram_cke,
	output        dram_clk,

	output[21:16] cram0_a,
	inout  [15:0] cram0_dq,
	input         cram0_wait,
	output        cram0_clk,
	output        cram0_adv_n,
	output        cram0_cre,
	output        cram0_ce0_n,
	output        cram0_ce1_n,
	output        cram0_oe_n,
	output        cram0_we_n,
	output        cram0_ub_n,
	output        cram0_lb_n,

	output[21:16] cram1_a,
	inout  [15:0] cram1_dq,
	input         cram1_wait,
	output        cram1_clk,
	output        cram1_adv_n,
	output        cram1_cre,
	output        cram1_ce0_n,
	output        cram1_ce1_n,
	output        cram1_oe_n,
	output        cram1_we_n,
	output        cram1_ub_n,
	output        cram1_lb_n,

	output [16:0] sram_a,
	inout  [15:0] sram_dq,
	output        sram_oe_n,
	output        sram_we_n,
	output        sram_ub_n,
	output        sram_lb_n
);

// POCKET: work RAM clear. rst_n is synchronous, busy is a register in sram_ctrl, and status[14] holds
// MiSTer's reset stretch until the clear has ended (core_reset = ~rst_n | busy). It must not go through
// status[0], whose rising edge clears the ROM masks: that one is the loader's alone, on the first load.
// The CD build has no clear to wait for: its SRAM is FIX RAM, which the BIOS uploads, so sram_busy is 0.
reg  wram_rst_n = 0;
wire sram_busy;
always @(posedge CLK_48M) wram_rst_n <= ~(status_in[0] | status_in[14]);
wire [63:0] status = {status_in[63:15], status_in[14] | ~wram_rst_n | sram_busy, status_in[13:0]};

// POCKET: audio goes out unhalved in the cart build, see audio_i2s. Mix and aspect logic removed.

// status bit definition:
// 31       23       15       7
// --AA-PSS -------- L--CGGDD DEEMVTTR
//  :	status[0]		System Reset, used by the HPS, keep it there
// T:	status[2:1]		System type, 0=Console, 1=Arcade, 2=CD, 3=CDZ
// V:	status[3]		Video mode
// M:	status[4]		Memory card presence
// E:	status[6:5]		Stereo mix
// D:	status[9:7]		DIP switches
// G:	status[11:10]	Neo CD region
// C:	status[12]		Save memory card & backup RAM
// L:	status[12]		CD lid state (DEBUG)
//  :	status[14]		Manual Reset
//  :	status[20:15]  OSD options
// 0123456789 ABCDEFGHIJKLMNO

// Conditional modification of the CONF strings chaining according to chosen system type
// Con Arc CD CDz
// 00  01  10 11
// F   F   +  +  ~SYSTEM_CDx;
// +   +   S  S  SYSTEM_CDx;
// O   O   +  +  ~SYSTEM_CDx;
// +   O   +  +  SYSTEM_MVS;
// +   +   O  O  SYSTEM_CDx;

// Status Bit Map:
//             Upper                             Lower              
// 0         1         2         3          4         5         6   
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXXXXXX XXX XXXXX XXXXXXX  XXXXXXXXXXXXX            XXXXXX 

// POCKET: CONF_STR and build_id.v removed, the menu lives in interact.json.

////////////////////   CLOCKS   ///////////////////

// POCKET: pll_pocket is in core_top.
wire locked = pll_locked;
wire CLK_VIDEO = CLK_48M;
wire clk_sys = CLK_48M;

reg CLK_EN_24M_N, CLK_EN_24M_P;
always @(posedge CLK_48M) begin
	CLK_EN_24M_N <= ~CLK_EN_24M_N;
	CLK_EN_24M_P <= CLK_EN_24M_N;
end

reg [14:0] TRASH_ADDR;
reg SYSTEM_TYPE, SYSTEM_CD_TYPE;

reg nRESET_CORE;
always @(posedge CLK_48M) begin
	reg rst_n;
	reg got_rom_write = 0;

	// POCKET: no clear on RESET: a PLL relock with a game running gets no new ROM write, and the
	// reset below would then never end.
`ifdef NEOGEO_CD
	// POCKET: the BIOS's last word: the CD has no other ROM to wait for, and a short file must not run
	if (ioctl_download & ioctl_wr & (ioctl_index == INDEX_SPROM) & (&ioctl_addr[18:1])) got_rom_write <= 1;
`else
	if (ioctl_download & ioctl_wr) got_rom_write <= 1;
`endif

	nRESET_CORE <= rst_n;
	rst_n <= &TRASH_ADDR;
	if(CLK_EN_24M_N && ~&TRASH_ADDR) TRASH_ADDR <= TRASH_ADDR + 1'b1;

	// POCKET: buttons and bk_loading removed
	if (status[0] | status[14] | RESET | ~got_rom_write) begin
		TRASH_ADDR <= 0;
		SYSTEM_TYPE <= status[1];	// Latch the system type on reset
		SYSTEM_CD_TYPE <= status[2];
	end
end

// POCKET: hps_io and the osd_btn stretch removed. Inputs nothing drives on the Pocket are tied off.
wire  [8:0] spinner_0 = 0, spinner_1 = 0;
wire [24:0] ps2_mouse = 0;

wire SYSTEM_MVS = SYSTEM_TYPE & ~cd_en;
wire SYSTEM_CDx = cd_en;
wire SYSTEM_CDZ = SYSTEM_CDx & SYSTEM_CD_TYPE;

reg [7:0] ioctl_index;
always @(posedge clk_sys) ioctl_index <= ioctl_idx;

wire dbg_menu = 0;     // POCKET: no keyboard

//////////////////   Her Majesty   ///////////////////

// POCKET: cfg is an input, memcp is gone

wire nRESET, nRESETP, nSYSTEM, CARD_WE, SHADOW, nVEC, nREGEN, nSRAMWEN, PALBNK;
wire CD_nRESET_Z80;

// Clocks
wire CLK_EN_12M, CLK_EN_12M_N, CLK_68KCLK, CLK_68KCLKB, CLK_EN_6MB, CLK_EN_1HB, CLK_EN_4M_P, CLK_EN_4M_N, CLK_EN_68K_P, CLK_EN_68K_N;

// 68k stuff
wire [15:0] M68K_DATA;
wire [23:1] M68K_ADDR;
wire A22Z, A23Z;
wire M68K_RW, nAS, nLDS, nUDS, nDTACK, nHALT, nBR, nBG, nBGACK;
wire [15:0] M68K_DATA_BYTE_MASK;
wire [15:0] FX68K_DATAIN;
wire [15:0] FX68K_DATAOUT;
wire IPL0, IPL1;
wire FC0, FC1, FC2;
reg [3:0] P_BANK;

// RTC stuff
wire RTC_DOUT, RTC_DIN, RTC_CLK, RTC_STROBE, RTC_TP;

// OEs and WEs
wire nSROMOEL, nSROMOEU, nSROMOE;
wire nROMOEL, nROMOEU;
wire nPORTOEL, nPORTOEU, nPORTWEL, nPORTWEU, nPORTADRS;
wire nSRAMOEL, nSRAMOEU, nSRAMWEL, nSRAMWEU;
wire nWRL, nWRU, nWWL, nWWU;
wire nLSPOE, nLSPWE;
wire nPAL, nPAL_WE;
wire nBITW0, nBITW1, nBITWD0, nDIPRD0, nDIPRD1;
wire nSDROE, nSDPOE;

// RAM outputs
wire [7:0] WRAML_OUT;
wire [7:0] WRAMU_OUT;
wire [15:0] SRAM_OUT;
wire [7:0] CD_Z80_RAM_OUT;

wire [14:0] WRAM_ADDR;
wire [7:0] WRAML_DATA, WRAMU_DATA;
wire WRAML_WREN, WRAMU_WREN;

// Memory card stuff
wire [23:0] CDA;
wire [2:0] BNK;
wire [7:0] CDD;
wire nCD1, nCD2;
wire nCRDO, nCRDW, nCRDC;
wire nCARDWEN, CARDWENB;

// Z80 stuff
wire [7:0] SDD_IN, SDD_OUT, Z80_SDD_OUT;
wire [7:0] SDD_RD_C1;
wire [15:0] SDA, Z80_SDA;
wire nSDRD, nSDWR, nMREQ, nIORQ, nBUSAK;
wire Z80_nSDRD, Z80_nSDWR, Z80_nMREQ;
wire Z80_nINT, Z80_nNMI, nSDW, nSDZ80R, nSDZ80W, nSDZ80CLR;
wire nSDROM, nSDMRD, nSDMWR, SDRD0, SDRD1, nZRAMCS;
wire n2610CS, n2610RD, n2610WR;

// Graphics stuff
wire [23:0] PBUS;
wire [7:0] LO_ROM_DATA;
wire nPBUS_OUT_EN;

wire [19:0] C_LATCH;
reg   [3:0] C_LATCH_EXT;
wire [63:0] CR_DOUBLE;
wire [26:0] CROM_ADDR;

wire [1:0] FIX_BANK;
wire [15:0] S_LATCH;
wire [7:0] FIXD;
wire [10:0] FIXMAP_ADDR;

wire CWE, BWE, BOE;

wire [14:0] SLOW_VRAM_ADDR;
reg [15:0] SLOW_VRAM_DATA_IN;
wire [15:0] SLOW_VRAM_DATA_OUT;

wire [10:0] FAST_VRAM_ADDR;
wire [15:0] FAST_VRAM_DATA_IN;
wire [15:0] FAST_VRAM_DATA_OUT;

wire [11:0] PAL_RAM_ADDR;
wire [15:0] PAL_RAM_DATA;
reg [15:0] PAL_RAM_REG;

wire PCK1, PCK2, EVEN1, EVEN2, LOAD, H;
wire PCK1_EN_P, PCK2_EN_P;
wire PCK1_EN_N, PCK2_EN_N;
wire DOTA, DOTB;
wire CA4, S1H1, S2H1;
wire CHBL, nBNKB, VCS;
wire CHG, LD1, LD2, SS1, SS2;
wire [3:0] GAD;
wire [3:0] GBD;
wire [3:0] WE;
wire [3:0] CK;

wire CD_VIDEO_EN, CD_FIX_EN, CD_SPR_EN;

// SDRAM multiplexing stuff
wire [15:0] SROM_DATA;
wire [15:0] PROM_DATA;

parameter INDEX_SPROM = 0;
parameter INDEX_LOROM = 1;
parameter INDEX_SFIXROM = 2;
parameter INDEX_P1ROM_A = 4;
parameter INDEX_P1ROM_B = 5;
parameter INDEX_P2ROM = 6;
parameter INDEX_S1ROM = 8;
parameter INDEX_M1ROM = 9;
parameter INDEX_MEMCP = 10;
parameter INDEX_CROM0 = 15;
parameter INDEX_VROMS = 16;
parameter INDEX_CROMS = 64;

wire video_mode = status[3];

`ifdef NEOGEO_CD
// POCKET: a CD has no cartridge, so these chips go at synthesis: neo_pvc, neo_sma, neo_cmc, XRAML/U, COM,
// ZMC2DOT. neo_273 stays: it is every build's S_LATCH and C_LATCH. adpcma_ext and use_pcm stay cfg's. SYSTEM_CDx
// makes them dead at their only uses at run time: it is cfg[31], not a constant in this file, and that synthesis
// sees through apf_loader's port and removes them is its own doing, not something to rely on.
wire       ms5p_bank  = 1'b0;
wire       xram       = 1'b0;
wire       adpcma_ext = cfg[19];
wire [2:0] cart_pchip = 3'd0;
wire       use_pcm    = cfg[23];
wire [1:0] cart_chip  = 2'd0;
wire [1:0] cmc_chip   = 2'd0;
`else
wire       ms5p_bank  = cfg[17];
wire       xram       = cfg[18];
wire       adpcma_ext = cfg[19];
wire [2:0] cart_pchip = cfg[22:20];
wire       use_pcm    = cfg[23];
wire [1:0] cart_chip  = cfg[25:24]; // legacy option: 0 - none, 1 - PRO-CT0, 2 - Link MCU
wire [1:0] cmc_chip   = cfg[27:26]; // type 1/2
`endif
wire       rom_wait   = cfg[28];    // ROMWAIT from cart. 0 - Full speed, 1 - 1 wait cycle
wire [1:0] p_wait     = cfg[30:29]; // PWAIT from cart. 0 - Full speed, 1 - 1 wait cycle, 2 - 2 cycles
`ifdef NEOGEO_CD
wire       cd_en      = cfg[31];    // Neo CD
`else
wire       cd_en      = 1'b0;       // POCKET: cart build
`endif

// POCKET: the bk_* save path is gone (R7). Saves reach backup and memcard through the ports above.

wire [2:0] CD_TR_AREA;	// Transfer area code
wire [15:0] CD_TR_WR_DATA;
wire [19:1] CD_TR_WR_ADDR;
wire [1:0] CD_BANK_SPR;

wire CD_TR_WR_SPR, CD_TR_WR_PCM, CD_TR_WR_Z80, CD_TR_WR_FIX;
wire CD_TR_RD_SPR, CD_TR_RD_FIX, CD_TR_RD_Z80, CD_TR_RD_PCM;
wire CD_USE_SPR, CD_USE_FIX, CD_USE_Z80, CD_USE_PCM;
wire CD_UPLOAD_EN;
wire CD_BANK_PCM;
wire CD_IRQ;
wire CD_VBLANK_IRQ_EN, CD_TIMER_IRQ_EN;
wire DMA_RUNNING, DMA_WR_OUT, DMA_RD_OUT;
wire [15:0] DMA_DATA_OUT;
wire [23:0] DMA_ADDR_IN;
wire [23:0] DMA_ADDR_OUT;

// POCKET: cd.sv's TR_ZONE looks at DMA_ADDR_OUT alone, so a DMA from PROG RAM into the PCM window has CD_TR_RD_PCM up
// with CD_EXT_RD, and MiSTer takes ADPCMA_DOUT for its source: a fault to report upstream. The source is PROG RAM.
wire [15:0] DMA_DATA_IN = (CD_TR_RD_PCM & ~CD_EXT_RD) ? { 8'h00, ADPCMA_DOUT } : PROM_DATA;

wire DMA_SDRAM_BUSY;
wire PROM_DATA_READY;
wire CD_EXT_WR_READY;
wire CD_PCM_DTACK;

wire [15:0] CD_AUDIO_L, CD_AUDIO_R;

`ifdef NEOGEO_CD     // POCKET: cd_sys, hps_ext and CEGen are compiled out of the cart build
wire [1:0] CD_REGION;
always @(status[11:10])
begin
	// CD Region code remap:
	// status[11:10] remap
	// 00            10 US
	// 01            01 EU
	// 10            11 JP
	// 11            00 ASIA
	case(status[11:10])
		 2'b00: CD_REGION = 2'b10;
		 2'b01: CD_REGION = 2'b01;
		 2'b10: CD_REGION = 2'b11;
		 2'b11: CD_REGION = 2'b00;
	endcase
end

wire [39:0] CDD_STATUS;
wire [39:0] CDD_COMMAND_DATA;
wire [23:0] dbg_cur_lba;        // POCKET: read by the wait counter's CD file only
wire  [3:0] dbg_cur_status;
wire CDD_COMMAND_SEND;
wire CDD_STATUS_LATCH;
`ifdef NEOGEO_WAIT_COUNTER
wire [1:0] cd_speed = status[30:29];
`else
// POCKET: a release has no CD Speed item: 1x with CD/CDZ off, 2x with it on, as a CDZ's drive
wire [1:0] cd_speed = {1'b0, SYSTEM_CDZ};
`endif

// POCKET: cdd_drive is megacdd of MiSTer's ARM side, and cd_dl_* the HPS channel. FF0181's reset stays
// inside cd_sys, on drive.v: megacdd gets its reset command on nRESET only, and so does this.
localparam CD_MCLK = 48335658;

// POCKET: cd_mount is at clk_74a, and this is the one view of it at CLK_48M, for cdd_drive and cd_fetch alike.
// disc_loading crosses in two flops. cd_mount drops disc_present only with disc_loading high, and holds the rest
// while it is low, so the rest is taken once as it falls, in that clock, and disc_present goes as it rises: the
// drive never sees the end of a mount with the disc of before it. A mount lasts far longer than a clock.
reg  [1:0] disc_loading_ff = 0;
reg        disc_loading_s = 0, disc_present_s = 0;
reg  [6:0] track_count_s = 0;
reg [23:0] disc_end_s = 0;
always @(posedge CLK_48M) begin
	disc_loading_ff <= {disc_loading_ff[0], disc_loading};
	disc_loading_s  <= disc_loading_ff[1];
	if (disc_loading_ff[1]) disc_present_s <= 0;
	else if (disc_loading_s) begin
		disc_present_s <= disc_present;
		track_count_s  <= track_count;
		disc_end_s     <= disc_end;
	end
end

wire CD_DATA_WR_READY, CDDA_WR_READY;
wire [23:0] req_lba, req_file_lba;
wire  [6:0] req_file;
wire req_audio, req_valid, req_done;
wire cd_dl_download, cd_dl_audio, cd_dl_wr, fetch_err;
wire [11:1] cd_dl_addr;
wire [15:0] cd_dl_data;
`ifdef NEOGEO_WAIT_COUNTER
wire dbg_poll;
`endif

cd_fetch CD_FETCH
(
	.CLK_48M(CLK_48M),
	.nRESET(nRESET),
	.disc_present(disc_present_s),
	.req_lba(req_lba), .req_audio(req_audio), .req_file(req_file), .req_file_lba(req_file_lba),
	.req_valid(req_valid), .req_done(req_done),
	.fr_req(fr_req), .fr_slot(fr_slot), .fr_offset(fr_offset), .fr_bank_slot(fr_bank_slot), .fr_done(fr_done), .fr_err(fr_err),
	.bank_rd_addr(bank_rd_addr), .bank_rd_q(bank_rd_q),
	.cd_dl_download(cd_dl_download), .cd_dl_audio(cd_dl_audio), .cd_dl_wr(cd_dl_wr),
	.cd_dl_addr(cd_dl_addr), .cd_dl_data(cd_dl_data),
	.cd_data_ready(CD_DATA_WR_READY), .cdda_ready(CDDA_WR_READY),
`ifdef NEOGEO_WAIT_COUNTER
	.dbg_poll(dbg_poll), .dbg_fetch(dbg_fetch),
`endif
	.fetch_err(fetch_err)
);

wire cdd_poll, cdd_is_data, cdd_status_play;

cdd_tick #(.CLK_HZ(CD_MCLK)) CDD_TICK
(
	.clk(CLK_48M),
	.nRESET(nRESET),
	.speed(cd_speed),
	.fast(cdd_is_data & cdd_status_play),
	.tick(cdd_poll)
);

cdd_drive #(.CLK_HZ(CD_MCLK)) CDD_DRIVE
(
	.clk(CLK_48M),
	.nRESET(nRESET),
	.tick(cdd_poll),
	.CDD_COMMAND_DATA(CDD_COMMAND_DATA), .CDD_COMMAND_SEND(CDD_COMMAND_SEND),
	.CDD_STATUS(CDD_STATUS), .CDD_STATUS_LATCH(CDD_STATUS_LATCH),
	.CD_SPEED(cd_speed),
	.lid_open(status[15]),
	.disc_present(disc_present_s), .disc_loading(disc_loading_s), .track_count(track_count_s), .disc_end(disc_end_s),
	.toc_rd_track(toc_rd_track), .toc_rd_entry(toc_rd_entry),
	.req_lba(req_lba), .req_audio(req_audio), .req_file(req_file), .req_file_lba(req_file_lba),
	.req_valid(req_valid), .req_done(req_done),
	.sink_ready(req_audio ? CDDA_WR_READY : CD_DATA_WR_READY),
	.status_play(cdd_status_play), .is_data(cdd_is_data), .cur_lba(dbg_cur_lba), .cur_status(dbg_cur_status)
);

//extend ioctl_wr for 16 cycles
reg  ioctl_wr_x;
always @(posedge clk_sys) begin
	reg [3:0] cnt = 0;

	if (cd_dl_wr) begin     // POCKET: was ioctl_wr
		cnt <= 4'd15;
		ioctl_wr_x <= 1;
	end
	else if (cnt) begin
		cnt <= cnt - 1'd1;
	end
	else begin
		ioctl_wr_x <= 0;
	end
end

// POCKET: CEGen.vhd as an accumulator, so the CD build adds no VHDL. CDDA_RD takes its rising edge
reg CDDA_CLK = 0;
always @(posedge CLK_48M) begin
	reg [25:0] sum = 0;

	CDDA_CLK <= 0;
	if (!nRESET) sum <= 0;
	else if (sum + 26'd44100 >= 26'(CD_MCLK)) begin
		sum <= sum + 26'd44100 - 26'(CD_MCLK);
		CDDA_CLK <= 1;
	end
	else sum <= sum + 26'd44100;
end

wire CD_DATA_DOWNLOAD = cd_dl_download & ~cd_dl_audio;     // POCKET: was ioctl_index 2
wire CD_DATA_WR = ioctl_wr_x & CD_DATA_DOWNLOAD;

wire CDDA_DOWNLOAD = cd_dl_download & cd_dl_audio;         // POCKET: was ioctl_index 4
wire CDDA_WR = ioctl_wr_x & CDDA_DOWNLOAD;

wire [2:0] dbg_hold;     // POCKET: cd.sv's hold, for the wait counter only
wire [36:0] dbg_sect_cd; // POCKET: cd.sv's sectors, likewise
wire cd_lid_bit = !SYSTEM_CDZ ^ status[15];

cd_sys #(.MCLK(CD_MCLK)) cdsystem(
	.nRESET(nRESET),
	.clk_sys(CLK_48M), .CLK_68KCLK_EN(CLK_EN_68K_P),
	.M68K_ADDR(M68K_ADDR), .M68K_DATA(M68K_DATA), .A22Z(A22Z), .A23Z(A23Z),
	.nLDS(nLDS), .nUDS(nUDS), .M68K_RW(M68K_RW), .nAS(nAS), .nDTACK(nDTACK_ADJ),
	.nBR(nBR), .nBG(nBG), .nBGACK(nBGACK),
	.SYSTEM_CDx(SYSTEM_CDx),
	.CD_REGION(CD_REGION),
	.CD_SPEED(cd_speed),
	.CD_LID(cd_lid_bit),	// POCKET: FF011C bit 12
	.CD_VIDEO_EN(CD_VIDEO_EN), .CD_FIX_EN(CD_FIX_EN), .CD_SPR_EN(CD_SPR_EN),
	.CD_nRESET_Z80(CD_nRESET_Z80),
	.CD_TR_WR_SPR(CD_TR_WR_SPR), .CD_TR_WR_PCM(CD_TR_WR_PCM),
	.CD_TR_WR_Z80(CD_TR_WR_Z80), .CD_TR_WR_FIX(CD_TR_WR_FIX),
	.CD_TR_RD_FIX(CD_TR_RD_FIX), .CD_TR_RD_SPR(CD_TR_RD_SPR),
	.CD_TR_RD_Z80(CD_TR_RD_Z80), .CD_TR_RD_PCM(CD_TR_RD_PCM),
	.CD_USE_FIX(CD_USE_FIX), .CD_USE_SPR(CD_USE_SPR),
	.CD_USE_Z80(CD_USE_Z80), .CD_USE_PCM(CD_USE_PCM),
	.CD_TR_AREA(CD_TR_AREA),
	.CD_BANK_SPR(CD_BANK_SPR), .CD_BANK_PCM(CD_BANK_PCM),
	.CD_TR_WR_DATA(CD_TR_WR_DATA), .CD_TR_WR_ADDR(CD_TR_WR_ADDR),
	.CD_UPLOAD_EN(CD_UPLOAD_EN),
	.CD_IRQ(CD_IRQ), .IACK(IACK),
	.CD_VBLANK_IRQ_EN(CD_VBLANK_IRQ_EN), .CD_TIMER_IRQ_EN(CD_TIMER_IRQ_EN),
	.CDD_STATUS_IN(CDD_STATUS), .CDD_STATUS_LATCH(CDD_STATUS_LATCH),
	.CDD_COMMAND_DATA(CDD_COMMAND_DATA), .CDD_COMMAND_SEND(CDD_COMMAND_SEND),
	.CD_DATA_DOWNLOAD(CD_DATA_DOWNLOAD), .CD_DATA_WR(CD_DATA_WR),
	.CD_DATA_DIN(cd_dl_data),      // POCKET: was ioctl_dout
	.CD_DATA_ADDR(cd_dl_addr),     // POCKET: was ioctl_addr[11:1]
	.CD_DATA_WR_READY(CD_DATA_WR_READY),
	.CDDA_RD(CDDA_CLK), .CDDA_WR(CDDA_WR),
	.CD_AUDIO_L(CD_AUDIO_L), .CD_AUDIO_R(CD_AUDIO_R),
	.CDDA_WR_READY(CDDA_WR_READY),
	.DMA_RUNNING(DMA_RUNNING),
	.DMA_DATA_IN(DMA_DATA_IN), .DMA_DATA_OUT(DMA_DATA_OUT),
	.DMA_WR_OUT(DMA_WR_OUT), .DMA_RD_OUT(DMA_RD_OUT),
	.DMA_ADDR_IN(DMA_ADDR_IN),		// Used for reading
	.DMA_ADDR_OUT(DMA_ADDR_OUT),	// Used for writing
	.DMA_SDRAM_BUSY(DMA_SDRAM_BUSY | ADPCMA_RD_WAIT),   // POCKET: no ddram_wait, PCM writes go through the mux's queue
	.DBG_SECT(dbg_sect_cd),
	.DBG_HOLD(dbg_hold)
);
`else
assign {CD_VIDEO_EN, CD_FIX_EN, CD_SPR_EN} = 0;
assign CD_nRESET_Z80 = 1;
assign {nBR, nBGACK} = 2'b11;     // POCKET: cd_sys is the only other master; undriven, the 68000 never gets the bus
assign {CD_TR_WR_SPR, CD_TR_WR_PCM, CD_TR_WR_Z80, CD_TR_WR_FIX} = 0;
assign {CD_TR_RD_SPR, CD_TR_RD_FIX, CD_TR_RD_Z80, CD_TR_RD_PCM} = 0;
assign {CD_USE_SPR, CD_USE_FIX, CD_USE_Z80, CD_USE_PCM} = 0;
assign {CD_UPLOAD_EN, CD_BANK_PCM, CD_IRQ, CD_VBLANK_IRQ_EN, CD_TIMER_IRQ_EN} = 0;
assign {CD_TR_AREA, CD_BANK_SPR} = 0;
assign {DMA_RUNNING, DMA_WR_OUT, DMA_RD_OUT, DMA_DATA_OUT, DMA_ADDR_IN, DMA_ADDR_OUT} = 0;
assign {CD_AUDIO_L, CD_AUDIO_R} = 0;
`endif

// The P1 zone is writable on the Neo CD
// Is there a write enable register for it ?
wire CD_EXT_WR = DMA_RUNNING ? (SYSTEM_CDx & (DMA_ADDR_OUT[23:21] == 3'd0) & DMA_WR_OUT) :               // DMA writes to $000000~$1FFFFF
										 (SYSTEM_CDx & ~|{A23Z, A22Z, M68K_ADDR[21]} & ~M68K_RW & ~(nLDS & nUDS));	// CPU writes to $000000~$1FFFFF

wire nROMOE = nROMOEL & nROMOEU;
wire nPORTOE = nPORTOEL & nPORTOEU;

// CD system work ram is in SDRAM
wire CD_EXT_RD = DMA_RUNNING ? (SYSTEM_CDx & (DMA_ADDR_IN[23:21] == 3'd0) & DMA_RD_OUT) :		// DMA reads from $000000~$1FFFFF
										 (SYSTEM_CDx & (~nWRL | ~nWRU));											// CPU reads from $100000~$1FFFFF

wire [26:0] CROM_LOAD_ADDR = ({ioctl_addr[25:0], 1'b0} + {ioctl_index[7:1]-INDEX_CROMS[7:1], 18'h00000, ioctl_index[0], 1'b0});
wire [26:0] VROM_LOAD_ADDR = ({1'b0, ioctl_addr[25:0]} + {ioctl_index[7:0]-INDEX_VROMS[7:0], 19'h00000});

localparam SPROM_OFFSET   = 27'h0000000; // System ROM: $0000000~$007FFFF
localparam SFIXROM_OFFSET = 27'h0020000; // SFIX:       $0020000~$003FFFF (in sys ROM)
localparam S1ROM_OFFSET   = 27'h0080000; // S1:         $0080000~$00FFFFF
localparam P1ROM_A_OFFSET = 27'h0200000; // P1+:        $0200000~...
localparam P1ROM_B_OFFSET = 27'h0280000; // P1:         $0280000~$02FFFFF (secondary 512KB)
localparam P2ROM_OFFSET   = 27'h0300000; // P2+:        $0300000~...

wire [26:0] ioctl_addr_offset =
	(ioctl_index == INDEX_SPROM)   ?	{SPROM_OFFSET[26:19]  , ioctl_addr[18:0]} : // System ROM: $0000000~$007FFFF
	(ioctl_index == INDEX_SFIXROM) ? {SFIXROM_OFFSET[26:17], ioctl_addr[16:0]} : // SFIX:       $0020000~$003FFFF (in sys ROM)
	(ioctl_index == INDEX_S1ROM)   ?	{S1ROM_OFFSET[26:19]  , ioctl_addr[18:0]} : // S1:         $0080000~$00FFFFF
	(ioctl_index == INDEX_P1ROM_A) ?  P1ROM_A_OFFSET       + ioctl_addr        : // P1+:        $0200000~...
	(ioctl_index == INDEX_P1ROM_B) ? {P1ROM_B_OFFSET[26:19], ioctl_addr[18:0]} : // P1:         $0280000~$02FFFFF (secondary 512KB)
	(ioctl_index == INDEX_P2ROM)   ?  P2ROM_OFFSET         + ioctl_addr        : // P2+:        $0300000~...
	(ioctl_index == INDEX_CROM0)   ? {CROM_START, 20'd0}   + ioctl_addr        : // C:          end of P, consolidated CROM
	(ioctl_index >= INDEX_CROMS)   ? {CROM_START, 20'd0}   + CROM_LOAD_ADDR    : // C*:         end of P
	27'h0100000; // undefined case, use work RAM address to make sure no ROM gets overwritten

reg  [6:0] CROM_START;
reg [26:0] P2ROM_MASK, CROM_MASK, V1ROM_MASK, V2ROM_MASK, MROM_MASK;
always_ff @(posedge clk_sys) begin
	reg old_rst;
	reg old_download;

	old_rst <= status[0];

	if(status[0]) begin
		if (SYSTEM_CDx) begin
			CROM_MASK  <= 27'h3FFFFF; // 4MB
			V1ROM_MASK <= 27'hFFFFF;  // 1MB
			MROM_MASK  <= 27'hFFFF;   // 64KB
		end else begin
			P2ROM_MASK <= P2ROM_MASK | P2ROM_MASK[26:1];
			CROM_MASK  <= CROM_MASK  | CROM_MASK[26:1];
			V1ROM_MASK <= adpcma_ext ? 27'h1FFFFFF : (V1ROM_MASK | V1ROM_MASK[26:1]);
			V2ROM_MASK <= adpcma_ext ? 27'h0       : (V2ROM_MASK | V2ROM_MASK[26:1]);
			MROM_MASK  <= MROM_MASK  | MROM_MASK[26:1];
		end
	end

	if(ioctl_wr) begin
			  if(ioctl_index >= INDEX_CROMS)  CROM_MASK  <= CROM_MASK  | CROM_LOAD_ADDR;
		else if(ioctl_index >= INDEX_VROMS) begin
			if(~VROM_LOAD_ADDR[24]) 			 V1ROM_MASK <= V1ROM_MASK | VROM_LOAD_ADDR;
			else  									 V2ROM_MASK <= V2ROM_MASK | VROM_LOAD_ADDR;
		end
		else if(ioctl_index == INDEX_CROM0)  CROM_MASK  <= CROM_MASK  | ioctl_addr;
		else if(ioctl_index == INDEX_M1ROM)  MROM_MASK  <= MROM_MASK  | ioctl_addr;
		else if(ioctl_index == INDEX_P2ROM || ioctl_index == INDEX_P1ROM_A) begin
			if(ioctl_addr_offset >= P2ROM_OFFSET) P2ROM_MASK <= P2ROM_MASK | (ioctl_addr_offset - P2ROM_OFFSET);
		end
		

		if(old_download && ~ioctl_download && (ioctl_index == INDEX_P2ROM || ioctl_index == INDEX_P1ROM_A)) begin
			if(CROM_START < ioctl_addr_offset[26:20]) CROM_START <= ioctl_addr_offset[26:20];
		end
	end

	if(~old_rst & status[0]) begin
		CROM_MASK  <= 0;
		V1ROM_MASK <= 0;
		V2ROM_MASK <= 0;
		MROM_MASK  <= 0;
		P2ROM_MASK <= 0;
		CROM_START <= 3;
	end
	
	old_download <= ioctl_download;
	if(old_download && ~ioctl_download && (ioctl_index == INDEX_P2ROM || ioctl_index == INDEX_P1ROM_A)) begin
		if(CROM_START < ioctl_addr_offset[26:20]) CROM_START <= ioctl_addr_offset[26:20];
	end
end

// POCKET: DL_ADDR is the raw file offset (R3), the mux translates it; CROM_START is unused (R4)
reg        ioctl_wr_r;
always @(posedge clk_sys) ioctl_wr_r <= ioctl_wr;

reg ioctl_wr_rd, ioctl_wr_rd1;
always @(posedge CLK_96M) begin
	ioctl_wr_rd <= ioctl_wr_r;
	ioctl_wr_rd1 <= ioctl_wr_rd;
end

wire [2:0] P1_OUT, P2_OUT;

neo_d0 D0(
	.CLK(CLK_48M),
	.CLK_EN_24M_P(CLK_EN_24M_P),
	.CLK_EN_24M_N(CLK_EN_24M_N),
	.nRESET(nRESET), .nRESETP(nRESETP),
	.CLK_68KCLK(CLK_68KCLK), .CLK_68KCLKB(CLK_68KCLKB), .CLK_EN_12M(CLK_EN_12M), .CLK_EN_12M_N(CLK_EN_12M_N), .CLK_EN_6MB(CLK_EN_6MB), .CLK_EN_1HB(CLK_EN_1HB),
	.CLK_EN_68K_P(CLK_EN_68K_P), .CLK_EN_68K_N(CLK_EN_68K_N),
	.M68K_ADDR_A4(M68K_ADDR[4]),
	.M68K_DATA(M68K_DATA[5:0]),
	.nBITWD0(nBITWD0),
	.SDA_H(SDA[15:11]), .SDA_L(SDA[4:2]),
	.nSDRD(nSDRD),	.nSDWR(nSDWR), .nMREQ(nMREQ),	.nIORQ(nIORQ),
	.nZ80NMI(Z80_nNMI),
	.nSDW(nSDW), .nSDZ80R(nSDZ80R), .nSDZ80W(nSDZ80W),	.nSDZ80CLR(nSDZ80CLR),
	.nSDROM(nSDROM), .nSDMRD(nSDMRD), .nSDMWR(nSDMWR), .nZRAMCS(nZRAMCS),
	.SDRD0(SDRD0),	.SDRD1(SDRD1),
	.n2610CS(n2610CS), .n2610RD(n2610RD), .n2610WR(n2610WR),
	.P1_OUT(P1_OUT), .P2_OUT(P2_OUT),
	.BNK(BNK)
);

// Re-priority-encode the interrupt lines with the CD_IRQ one (IPL* are active-low)
//
//  IPL2 IPL1 IPL0    Cartridge        CD
//    1    1    1     No IRQ           No IRQ
//    1    1    0     Vblank    (64)   Vblank (68)
//    1    0    1     Timer     (68)   CD IRQ (54/58)
//    1    0    0     Cold boot (6C)   Timer  (64)
//
wire [1:0] CD_IPL = {IPL1,IPL0} == 2'b01 ? 2'b00     // Level 3 Timer
                    : CD_IRQ ? 2'b01                 // Level 2 CD IRQ
                    : {IPL1,IPL0} == 2'b10 ? 2'b10   // Level 1 VBlank
                    : 2'b11;

wire [1:0] IPL_OUT = ~SYSTEM_CDx ? { IPL1,IPL0 } : CD_IPL;

// Because of the SDRAM latency, nDTACK is handled differently for ROM zones
// If the address is in a ROM zone, PROM_DATA_READY is used to extend the normal nDTACK output by NEO-C1
wire nDTACK_ADJ = ~&{nSROMOE, nROMOE, nPORTOE, ~CD_EXT_RD, ~CD_TR_RD_FIX, ~CD_TR_RD_SPR} ? ~PROM_DATA_READY | nDTACK
                    : ((CD_EXT_WR | CD_TR_WR_SPR) & ~DMA_RUNNING) ? ~CD_EXT_WR_READY | nDTACK     // POCKET: posted, unless the queue is full
                    : (CD_TR_WR_PCM | CD_TR_WR_FIX) ? ~CD_PCM_DTACK | nDTACK     // POCKET: was ddram_dtack; until it is in the chip
                    : (CD_TR_RD_PCM) ? ~ADPCMA_RD_DTACK | nDTACK
                    : nDTACK;

// POCKET: the UniBIOS's SYSTEM setting always matches CD/CDZ, see cd_bios_model
wire [15:0] cpu_dataout;
`ifdef NEOGEO_CD
wire       dbg_bios_unibios;
wire [15:0] dbg_bios_requested;
cd_bios_model CD_BIOS_MODEL
(
	.clk(CLK_48M), .nRESET(nRESET),
	.nAS(nAS), .nUDS(nUDS), .nLDS(nLDS), .M68K_RW(M68K_RW), .M68K_ADDR(M68K_ADDR),
	.data_in(cpu_dataout), .system_cdz(SYSTEM_CDZ), .data_out(FX68K_DATAOUT),
	.unibios(dbg_bios_unibios), .requested(dbg_bios_requested)
);
`else
assign FX68K_DATAOUT = cpu_dataout;
`endif

cpu_68k M68KCPU(
	.CLK(CLK_48M),
	.CLK_EN_68K_P(CLK_EN_68K_P),
	.CLK_EN_68K_N(CLK_EN_68K_N),
	.nRESET(nRESET),
	.M68K_ADDR(M68K_ADDR),
	.FX68K_DATAIN(FX68K_DATAIN), .FX68K_DATAOUT(cpu_dataout),
	.nLDS(nLDS), .nUDS(nUDS), .nAS(nAS), .M68K_RW(M68K_RW),
	.nDTACK(nDTACK_ADJ),	// nDTACK
	.IPL2(1'b1), .IPL1(IPL_OUT[1]), .IPL0(IPL_OUT[0]),
	.FC2(FC2), .FC1(FC1), .FC0(FC0),
	.nBG(nBG), .nBR(nBR), .nBGACK(nBGACK),
	.SYSTEM_CDx(SYSTEM_CDx)
);

wire IACK = &{FC2, FC1, FC0};

// FX68K doesn't like byte masking with Z's, replace with 0's:
assign M68K_DATA_BYTE_MASK = (~|{nLDS, nUDS}) ? M68K_DATA :
										(~nLDS) ? {8'h00, M68K_DATA[7:0]} :
										(~nUDS) ? {M68K_DATA[15:8], 8'h00} :
										16'h0000;

assign M68K_DATA = M68K_RW ? 16'bzzzzzzzz_zzzzzzzz : FX68K_DATAOUT;
assign FX68K_DATAIN = M68K_RW ? M68K_DATA_BYTE_MASK : 16'h0000;

assign FIXD = CD_USE_FIX ? 8'bzzzz_zzzz : S2H1 ? SROM_DATA[15:8] : SROM_DATA[7:0];

// Disable ROM read in PORT zone if the game uses a special chip
assign M68K_DATA = (nROMOE & nSROMOE & ~CD_TR_RD_SPR & |{nPORTOE, cart_chip, cart_pchip, xram, CD_TR_RD_FIX}) ? 16'bzzzzzzzzzzzzzzzz : PROM_DATA;

// Output correct FIX byte
assign M68K_DATA[7:0] = ~CD_TR_RD_FIX ? 8'bzzzz_zzzz : (M68K_ADDR[4] ? PROM_DATA[15:8] : PROM_DATA[7:0]);

// POCKET: the mux's port to the SRAM of the CD build
wire        fx_req, fx_we, fx_ack;
wire [15:0] fx_word, fx_wdata, fx_rdata;
wire  [1:0] fx_be;

`ifndef NEOGEO_CD
// POCKET: 68K work RAM in the Pocket's SRAM (Task 4), instead of the WRAML/WRAMU block RAMs.
assign {fx_ack, fx_rdata} = 0;

sram_ctrl WRAM(
	.clk(CLK_48M),
	.rst_n(wram_rst_n),
	.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
	.sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n),
	.wram_addr(M68K_ADDR[15:1]),
	.wram_din(FX68K_DATAOUT),   // only the CPU writes here: the resolved bus would add a false 96 MHz path to the pins
	.wram_dout({WRAMU_OUT, WRAML_OUT}),
	.nWRL(nWRL), .nWRU(nWRU), .nWWL(nWWL), .nWWU(nWWU),
	.busy(sram_busy)
);
`else
// POCKET: the CD's work RAM is PROG RAM and WRAML/WRAMU are its Z80's, below. The SRAM holds FIX RAM.
assign sram_busy = 0;

cd_fix_sram FIXRAM(
	.clk(CLK_48M),
	.req(fx_req), .we(fx_we), .word(fx_word), .be(fx_be), .wdata(fx_wdata), .ack(fx_ack), .rdata(fx_rdata),
	.sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
	.sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
);

// Neo CD 68k work RAM is in SDRAM so we can use this for Z80 RAM instead.
// POCKET: PROG RAM is in CRAM0. These are the Z80's alone, without the mux for the 68K's use
dpram #(15) WRAML(
	.clock_a(CLK_48M),
	.address_a(SDA[15:1]),
	.data_a(SDD_OUT),
	.wren_a(~nSDMWR & ~SDA[0]),
	.q_a(WRAML_OUT),

	.clock_b(CLK_48M),
	.address_b(TRASH_ADDR),
	.data_b(TRASH_ADDR[7:0]),
	.wren_b(~nRESET_CORE)
);

dpram #(15) WRAMU(
	.clock_a(CLK_48M),
	.address_a(SDA[15:1]),
	.data_a(SDD_OUT),
	.wren_a(~nSDMWR & SDA[0]),
	.q_a(WRAMU_OUT),

	.clock_b(CLK_48M),
	.address_b(TRASH_ADDR),
	.data_b(TRASH_ADDR[7:0]),
	.wren_b(~nRESET_CORE)
);
`endif

wire [23:0] P2ROM_ADDR_PVC, P2ROM_ADDR_SMA;
wire [23:0] P2ROM_ADDR = cart_pchip ? (P2ROM_ADDR_PVC | P2ROM_ADDR_SMA) : {P_BANK, M68K_ADDR[19:1], 1'b0};

neo_pvc neo_pvc
(
	.nRESET(nRESET),
	.CLK_48M(CLK_48M),

	.ENABLE(cart_pchip == 2),

	.M68K_ADDR(M68K_ADDR),
	.M68K_DATA(M68K_DATA),
	.PROM_DATA(PROM_DATA),
	.nPORTOEL(nPORTOEL),
	.nPORTOEU(nPORTOEU),
	.nPORTWEL(nPORTWEL),
	.nPORTWEU(nPORTWEU),
	.P2_ADDR(P2ROM_ADDR_PVC)
);

neo_sma neo_sma
(
	.nRESET(nRESET),
	.CLK_48M(CLK_48M),

	.TYPE(cart_pchip),

	.M68K_ADDR(M68K_ADDR),
	.M68K_DATA(M68K_DATA),
	.PROM_DATA(PROM_DATA),
	.nPORTOEL(nPORTOEL),
	.nPORTOEU(nPORTOEU),
	.nPORTWEL(nPORTWEL),
	.nPORTWEU(nPORTWEU),
	.P2_ADDR(P2ROM_ADDR_SMA)
);

wire XRAM_CS = ~nPORTADRS && !M68K_ADDR[19:13] && xram;
wire [15:0] XRAM_OUT;
wire [15:0] xram_buff_dout;

dpram #(12) XRAML(
	.clock_a(CLK_48M),
	.address_a(M68K_ADDR[12:1]),
	.data_a(M68K_DATA[7:0]),
	.wren_a(~nPORTWEL & XRAM_CS),
	.q_a(XRAM_OUT[7:0]),

	.clock_b(clk_sys),
	.address_b(memcard_addr),
	.wren_b(memcard_wr & xram),
	.data_b(sd_buff_dout[7:0]),
	.q_b(xram_buff_dout[7:0])
);

dpram #(12) XRAMU(
	.clock_a(CLK_48M),
	.address_a(M68K_ADDR[12:1]),
	.data_a(M68K_DATA[15:8]),
	.wren_a(~nPORTWEU & XRAM_CS),
	.q_a(XRAM_OUT[15:8]),

	.clock_b(clk_sys),
	.address_b(memcard_addr),
	.wren_b(memcard_wr & xram),
	.data_b(sd_buff_dout[15:8]),
	.q_b(xram_buff_dout[15:8])
);

assign M68K_DATA[7:0]  = (XRAM_CS & ~nPORTOEL) ? XRAM_OUT[7:0]  : 8'bZ;
assign M68K_DATA[15:8] = (XRAM_CS & ~nPORTOEU) ? XRAM_OUT[15:8] : 8'bZ;

assign M68K_DATA[7:0] = (~nPORTOEL && M68K_ADDR[19] && !M68K_ADDR[18:1] && xram) ? {~joystick_0[8],1'b1,~joystick_0[9],~joystick_0[11],2'b11, ~joystick_1[10],~joystick_0[10]} : 8'bZ;

// Work RAM or CD extended RAM read
assign M68K_DATA[7:0]  = nWRL ? 8'bzzzzzzzz : SYSTEM_CDx ? PROM_DATA[7:0]  : WRAML_OUT;
assign M68K_DATA[15:8] = nWRU ? 8'bzzzzzzzz : SYSTEM_CDx ? PROM_DATA[15:8] : WRAMU_OUT;

// POCKET: save ports replace sd_buff and bk_lba

// Backup RAM
wire nBWL = nSRAMWEL | nSRAMWEN_G;
wire nBWU = nSRAMWEU | nSRAMWEN_G;

`ifndef NEOGEO_CD
backup BACKUP
(
	.CLK(CLK_48M),
	.M68K_ADDR(M68K_ADDR[15:1]),
	.M68K_DATA(M68K_DATA),
	.nBWL(nBWL), .nBWU(nBWU),
	.SRAM_OUT(SRAM_OUT),
	.clk_sys(clk_sys),
	.sram_addr(sram_addr),
	.sram_wr(sram_wr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din_sram(sram_buff_dout)
);
`else
assign SRAM_OUT = 0;
assign sram_buff_dout = 0;
`endif

// Backup RAM is only for MVS
assign M68K_DATA[7:0] = (nSRAMOEL | ~SYSTEM_MVS) ? 8'bzzzzzzzz : SRAM_OUT[7:0];
assign M68K_DATA[15:8] = (nSRAMOEU | ~SYSTEM_MVS) ? 8'bzzzzzzzz : SRAM_OUT[15:8];

// Memory card
assign {nCD1, nCD2} = {2{status[4] & ~SYSTEM_CDx}};	// Always plugged in CD systems
assign CARD_WE = (SYSTEM_CDx | (~nCARDWEN & CARDWENB)) & ~nCRDW;

wire [15:0] memcard_buff_dout;
memcard MEMCARD(
	.CLK(CLK_48M),
	.SYSTEM_CDx(SYSTEM_CDx),
	.CDA(CDA), .CDD(CDD),
	.CARD_WE(CARD_WE),
	.M68K_DATA(M68K_DATA[7:0]),
	.clk_sys(clk_sys),
	.memcard_addr(memcard_addr),
	.memcard_wr(memcard_wr),
	.memcard_din(sd_buff_dout),
	.memcard_dout(memcard_buff_dout)
);

// Feed save file writer with backup RAM data or memory card data
assign card_buff_dout = xram ? xram_buff_dout : memcard_buff_dout;

assign CROM_ADDR = {C_LATCH_EXT, C_LATCH, 3'b000} & CROM_MASK;

zmc ZMC(
	.CLK(CLK_48M),
	.nRESET(nRESET),
	.nSDRD0(SDRD0),
	.SDA_L(SDA[1:0]), .SDA_U(SDA[15:8]),
	.MA(MA)
);

// Bankswitching for the PORT zone, do all games use a 1MB window ?
// P_BANK stays at 0 for CD systems
always @(posedge CLK_48M)
begin
	reg nPORTWEL_d;
	nPORTWEL_d <= nPORTWEL;

	if (!nRESET || SYSTEM_CDx) P_BANK <= 0;
	else if (~nPORTWEL & nPORTWEL_d) begin
		if(~ms5p_bank) P_BANK <= M68K_DATA[3:0];
		else if(&M68K_ADDR[19:4] && M68K_ADDR[3:1] == 2) P_BANK <= M68K_DATA[7:4] - 1'd1;
	end
end

// PRO-CT0 used as security chip
wire [3:0] GAD_SEC;
wire [3:0] GBD_SEC;

reg nPORTWEL_D;
always @(posedge CLK_48M) nPORTWEL_D <= nPORTWEL;

zmc2_dot ZMC2DOT(
	.CLK(CLK_48M),
	.CLK_EN_12M_N(nPORTWEL_D & ~nPORTWEL),
	.EVEN(M68K_ADDR[2]), .LOAD(M68K_ADDR[1]), .H(M68K_ADDR[3]),
	.CR({
		M68K_ADDR[19], M68K_ADDR[15], M68K_ADDR[18], M68K_ADDR[14],
		M68K_ADDR[17], M68K_ADDR[13], M68K_ADDR[16], M68K_ADDR[12],
		M68K_ADDR[11], M68K_ADDR[7], M68K_ADDR[10], M68K_ADDR[6],
		M68K_ADDR[9], M68K_ADDR[5], M68K_ADDR[8], M68K_ADDR[4],
		M68K_DATA[15], M68K_DATA[11], M68K_DATA[14], M68K_DATA[10],
		M68K_DATA[13], M68K_DATA[9], M68K_DATA[12], M68K_DATA[8],
		M68K_DATA[7], M68K_DATA[3], M68K_DATA[6], M68K_DATA[2],
		M68K_DATA[5], M68K_DATA[1], M68K_DATA[4], M68K_DATA[0]
		}),
	.GAD(GAD_SEC), .GBD(GBD_SEC)
);	

assign M68K_DATA[7:0] = ((cart_chip == 1) & ~nPORTOEL) ?
								{GBD_SEC[1], GBD_SEC[0], GBD_SEC[3], GBD_SEC[2],
								GAD_SEC[1], GAD_SEC[0], GAD_SEC[3], GAD_SEC[2]} : 8'bzzzzzzzz;

neo_273 NEO273(
	.CLK(CLK_48M),
	.PBUS(PBUS[19:0]),
	.PCK1B_EN(PCK1_EN_N), .PCK2B_EN(PCK2_EN_N),
	.C_LATCH(C_LATCH), .S_LATCH(S_LATCH)
);

// 4 MSBs not handled by NEO-273
always @(posedge CLK_48M) begin
	if (PCK1_EN_N) C_LATCH_EXT <= PBUS[23:20];
end

neo_cmc neo_cmc
(
	.CLK(CLK_48M),
	.PCK2B_EN(PCK2_EN_N),
	.PBUS(PBUS[14:0]),
	.TYPE(cmc_chip),
	.ADDR(FIXMAP_ADDR),
	.BANK(FIX_BANK)
);


// Fake COM MCU
wire [15:0] COM_DOUT;

com COM(
	.nRESET(nRESET),
	.CLK_48M(CLK_48M),
	.nPORTOEL(nPORTOEL), .nPORTOEU(nPORTOEU), .nPORTWEL(nPORTWEL),
	.M68K_DIN(COM_DOUT)
);

assign M68K_DATA = (cart_chip == 2) ? COM_DOUT : 16'bzzzzzzzz_zzzzzzzz;

syslatch SL(
	.nRESET(nRESET),
	.CLK(CLK_48M),
	.CLK_EN_68K_P(CLK_EN_68K_P),
	.M68K_ADDR(M68K_ADDR[4:1]),
	.nBITW1(nBITW1),
	.SHADOW(SHADOW), .nVEC(nVEC), .nCARDWEN(nCARDWEN),	.CARDWENB(CARDWENB), .nREGEN(nREGEN), .nSYSTEM(nSYSTEM), .nSRAMWEN(nSRAMWEN), .PALBNK(PALBNK)
);

wire nSRAMWEN_G = SYSTEM_MVS ? nSRAMWEN : 1'b1;	// nSRAMWEN is only for MVS
wire nSYSTEM_G = SYSTEM_MVS ? nSYSTEM : 1'b1;	// nSYSTEM is only for MVS

neo_e0 E0(
	.M68K_ADDR(M68K_ADDR[23:1]),
	.BNK(BNK),
	.nSROMOEU(nSROMOEU),	.nSROMOEL(nSROMOEL), .nSROMOE(nSROMOE),
	.nVEC(nVEC),
	.A23Z(A23Z), .A22Z(A22Z),
	.CDA(CDA)
);

neo_f0 F0(
	.CLK(CLK_48M),
	.nRESET(nRESET),
	.nDIPRD0(nDIPRD0), .nDIPRD1(nDIPRD1),
	.nBITW0(nBITW0), .nBITWD0(nBITWD0),
	.DIPSW({~status[9:8], 5'b11111, ~status[7]}),
	.COIN1(~joystick_0[10]), .COIN2(~joystick_1[10]),
	.M68K_ADDR(M68K_ADDR[7:4]),
	.M68K_DATA(M68K_DATA[7:0]),
	.SYSTEMB(~nSYSTEM_G),
	.RTC_DOUT(RTC_DOUT), .RTC_TP(RTC_TP), .RTC_DIN(RTC_DIN), .RTC_CLK(RTC_CLK), .RTC_STROBE(RTC_STROBE),
	.SYSTEM_TYPE(SYSTEM_MVS)
);

uPD4990 RTC(
	.rtc(rtc),
	.nRESET(nRESET),
	.CLK(CLK_48M),
	.CLK_EN_12M(CLK_EN_12M),
	.DATA_CLK(RTC_CLK), .STROBE(RTC_STROBE),
	.DATA_IN(RTC_DIN), .DATA_OUT(RTC_DOUT),
	.CS(1'b1), .OE(1'b1),
	.TP(RTC_TP)
);

neo_g0 G0(
	.M68K_DATA(M68K_DATA),
	.G0(nCRDC), .G1(nPAL), .DIR(M68K_RW), .WE(nPAL_WE),
	.CDD({8'hFF, CDD}), .PC(PAL_RAM_DATA)
);

wire [11:0] joy_0a = P1_OUT[0] ? (joystick_2[11:0] | {P1_OUT[2],5'b00000}) : (joystick_0[11:0] | {P1_OUT[2],4'b0000});
wire [11:0] joy_1a = P1_OUT[0] ? (joystick_3[11:0] | {P1_OUT[2],5'b00000}) : (joystick_1[11:0] | {P1_OUT[2],4'b0000});

wire [11:0] joy_0b = ({12{P1_OUT[0]}} & joystick_0[11:0]) | ({12{P1_OUT[1]}} & joystick_2[11:0]) | {P1_OUT[2], 9'd0};
wire [11:0] joy_1b = ({12{P2_OUT[0]}} & joystick_1[11:0]) | ({12{P2_OUT[1]}} & joystick_3[11:0]) | {P2_OUT[2], 9'd0};

wire [11:0] joy_0 = status[43] ? joy_0a : status[44] ? joy_0b : joystick_0;
wire [11:0] joy_1 = status[43] ? joy_1a : status[44] ? joy_1b : joystick_1;


neo_c1 C1(
	.CLK(CLK_48M),
	.M68K_ADDR(M68K_ADDR[21:17]),
	.M68K_DATA(M68K_DATA[15:8]), .A22Z(A22Z), .A23Z(A23Z),
	.nLDS(nLDS), .nUDS(nUDS), .RW(M68K_RW), .nAS(nAS),
	.nROMOEL(nROMOEL), .nROMOEU(nROMOEU),
	.nPORTOEL(nPORTOEL), .nPORTOEU(nPORTOEU), .nPORTWEL(nPORTWEL), .nPORTWEU(nPORTWEU),
	.nPORT_ZONE(nPORTADRS),
	.nWRL(nWRL), .nWRU(nWRU), .nWWL(nWWL), .nWWU(nWWU),
	.nSROMOEL(nSROMOEL), .nSROMOEU(nSROMOEU),
	.nSRAMOEL(nSRAMOEL), .nSRAMOEU(nSRAMOEU), .nSRAMWEL(nSRAMWEL), .nSRAMWEU(nSRAMWEU),
	.nLSPOE(nLSPOE), .nLSPWE(nLSPWE),
	.nCRDO(nCRDO), .nCRDW(nCRDW), .nCRDC(nCRDC),
	.nSDW(nSDW),
	.P1_IN(~{(joy_0[9:8]|ps2_mouse[2]), {use_mouse ? ms_pos : use_sp ? {|{joy_0[7:4],ps2_mouse[1:0]},sp0} : {joy_0[7:4]|{3{~xram & joy_0[11]}}|{{2{joystick_0[13]}},{2{joystick_0[12]}}}, joy_0[0], joy_0[1], joy_0[2], joy_0[3]}}}),
	.P2_IN(~{ joy_1[9:8],               {use_mouse ? ms_btn : use_sp ? {|{joy_1[7:4]},               sp1} : {joy_1[7:4]|{3{~xram & joy_1[11]}}|{{2{joystick_1[13]}},{2{joystick_1[12]}}}, joy_1[0], joy_1[1], joy_1[2], joy_1[3]}}}),
	.nCD1(nCD1), .nCD2(nCD2),
	.nWP(0),			// Memory card is never write-protected
	.nROMWAIT(~rom_wait), .nPWAIT0(~p_wait[0]), .nPWAIT1(~p_wait[1]), .PDTACK(1),
	.SDD_WR(SDD_OUT),
	.SDD_RD(SDD_RD_C1),
	.nSDZ80R(nSDZ80R), .nSDZ80W(nSDZ80W), .nSDZ80CLR(nSDZ80CLR),
	.CLK_EN_68K_P(CLK_EN_68K_P),
	.nDTACK(nDTACK),
	.nBITW0(nBITW0), .nBITW1(nBITW1),
	.nDIPRD0(nDIPRD0), .nDIPRD1(nDIPRD1),
	.nPAL_ZONE(nPAL),
	.SYSTEM_TYPE({SYSTEM_CDx, SYSTEM_MVS})
);

reg       use_sp = 0;
reg [6:0] sp0 = 0, sp1 = 0;
always @(posedge clk_sys) begin
	reg old_sp0, old_sp1, old_ms;
	reg latch_done = 0, ms_filtered = 0;

	old_sp0 <= spinner_0[8];
	if(latch_done && (old_sp0 ^ spinner_0[8])) sp0 <= sp0 - spinner_0[6:0];
	
	// Main fires a single mouse event on cold boot in input.cpp in input_notify_mode()
	// Filter this event once to prevent accidental latching of use_sp on cold boot
	old_ms <= ps2_mouse[24];
	if(latch_done && (old_ms ^ ps2_mouse[24])) begin
		ms_filtered <= 1;
		if (ms_filtered) sp0 <= sp0 - ps2_mouse[14:8];
	end

	old_sp1 <= spinner_1[8];
	if(latch_done && (old_sp1 ^ spinner_1[8])) sp1 <= sp1 - spinner_1[6:0];

	latch_done <= 1;

	if(status[42]) use_sp <= 1;
	else if(status[41]) use_sp <= 0;
	else if(latch_done) begin
		if((old_sp0 ^ spinner_0[8]) || (old_sp1 ^ spinner_1[8]) || (ms_filtered && (old_ms ^ ps2_mouse[24]))) use_sp <= 1;
		if(joystick_0[3:0] || joystick_1[3:0]) use_sp <= 0;
	end
end

wire       use_mouse = &status[42:41];

reg        ms_xy;
reg  [7:0] ms_x, ms_y;
wire [7:0] ms_pos = ms_xy ? ms_y : ms_x;
wire [7:0] ms_btn = {2'b00, ps2_mouse[1:0], 4'b0000};

always @(posedge clk_sys) begin
	reg old_ms;

	if(!nBITW0 && !M68K_ADDR[6:3]) ms_xy <= M68K_DATA[0];

	old_ms <= ps2_mouse[24];
	if(old_ms ^ ps2_mouse[24]) begin
		ms_x <= ms_x + ps2_mouse[15:8];
		ms_y <= ms_y - ps2_mouse[23:16];
	end
end

zmc2_dot ZMC2(
	.CLK(CLK_48M),
	.CLK_EN_12M_N(CLK_EN_12M_N),
	.EVEN(EVEN1), .LOAD(LOAD), .H(H),
	.CR(CA4 ? CR_DOUBLE[63:32] : CR_DOUBLE[31:0]),
	.GAD(GAD), .GBD(GBD),
	.DOTA(DOTA), .DOTB(DOTB)
);

dpram #(16) LO(
	.clock_a(clk_sys),
	.address_a(ioctl_addr[16:1]),
	.data_a(ioctl_dout[7:0]),
	.wren_a(ioctl_download & (ioctl_index == INDEX_LOROM) & ioctl_wr),
	.clock_b(CLK_48M),
	.address_b(PBUS[15:0]),
	.q_b(LO_ROM_DATA)
);

// VCS is normally used as the LO ROM's nOE but the NeoGeo relies on the fact that the LO ROM
// will still have its output active for a short moment (~50ns) after nOE goes high
// nPBUS_OUT_EN is used internally by LSPC2 but it's broken out here to use the additional
// half mclk cycle it provides compared to VCS. This makes sure LO_ROM_DATA is valid when latched.
assign PBUS[23:16] = nPBUS_OUT_EN ? LO_ROM_DATA : 8'bzzzzzzzz;

spram #(11,16) UFV(
	.clock(CLK_48M),
	.address(FAST_VRAM_ADDR),
	.data(FAST_VRAM_DATA_OUT),
	.wren(~CWE),
	.q(FAST_VRAM_DATA_IN)
);

spram #(15,16) USV(
	.clock(CLK_48M),
	.address(SLOW_VRAM_ADDR),
	.data(SLOW_VRAM_DATA_OUT),
	.wren(~BWE),
	.q(SLOW_VRAM_DATA_IN)
);

wire [18:11] MA;
wire [7:0] Z80_RAM_DATA;

// 2KB Z80 work RAM (Cart)
spram #(11) Z80RAM(.clock(CLK_48M), .address(SDA[10:0]), .data(SDD_OUT), .wren(~(nZRAMCS | nSDMWR)), .q(Z80_RAM_DATA));

// 64KB Z80 work RAM (CD)
assign CD_Z80_RAM_OUT = SDA[0] ? WRAMU_OUT : WRAML_OUT;

assign SDD_IN = (~nSDZ80R)             ? SDD_RD_C1 :
					 (~nSDMRD & SYSTEM_CDx) ? CD_Z80_RAM_OUT :
					 (~nSDMRD & ~nSDROM)    ? M1_ROM_DATA :
					 (~nSDMRD & ~nZRAMCS)   ? Z80_RAM_DATA :
					 (~n2610CS & ~n2610RD)  ? YM2610_DOUT :
					 8'b00000000;

wire Z80_nRESET = SYSTEM_CDx ? nRESET & CD_nRESET_Z80 : nRESET;
wire CD_HAS_Z80_BUS = (CD_USE_Z80 & ~(nBUSAK & CD_nRESET_Z80));

wire [7:0] M1_ROM_DATA;
reg z80rd_req;
wire z80rd_ack;
wire z80_rom_rd = ~(nSDMRD | nSDROM | SYSTEM_CDx);
always @(posedge CLK_96M) begin   // POCKET: was DDRAM_CLK
	reg old_rd, old_rd1;
	
	old_rd <= z80_rom_rd;
	if(old_rd == z80_rom_rd) old_rd1 <= old_rd;

	// nRESET is used here because otherwise z80rd_req is toggled at core boot
	// which causes problems with DDRAM. (Z80_nSDRD is probably low for a few DDRAM_CLK
	// cycles at core boot).
	// If the core is loaded with SignalTap then DDRAM is stuck at waiting for
	// DDRAM_DOUT_READY to go high which does not happen.
	if(~old_rd1 & old_rd & nRESET) z80rd_req <= ~z80rd_req;
end

wire Z80_nWAIT = (z80rd_req == z80rd_ack);

cpu_z80 Z80CPU(
	.CLK(CLK_48M),
	.CLK4P_EN(CLK_EN_4M_P),
	.CLK4N_EN(CLK_EN_4M_N),
	.nRESET(Z80_nRESET),
	.SDA(Z80_SDA), .SDD_IN(SDD_IN), .SDD_OUT(Z80_SDD_OUT),
	.nIORQ(nIORQ),	.nMREQ(Z80_nMREQ), .nRD(Z80_nSDRD), .nWR(Z80_nSDWR),
	.nBUSRQ(~CD_USE_Z80), .nBUSAK(nBUSAK),
	.nINT(Z80_nINT), .nNMI(Z80_nNMI), .nWAIT(Z80_nWAIT)
);

assign { SDA, SDD_OUT } = ~CD_HAS_Z80_BUS ? { Z80_SDA, Z80_SDD_OUT } : DMA_RUNNING ? { DMA_ADDR_OUT[16:1], DMA_DATA_OUT[7:0] } : { M68K_ADDR[16:1], M68K_DATA[7:0] };
assign { nSDRD, nSDWR } = ~CD_HAS_Z80_BUS ? { Z80_nSDRD, Z80_nSDWR } : { ~CD_TR_RD_Z80, ~CD_TR_WR_Z80 };
assign { nMREQ }        = ~CD_HAS_Z80_BUS ? { Z80_nMREQ            } : {~(CD_TR_RD_Z80 | CD_TR_WR_Z80)};

assign M68K_DATA[7:0]   = ~(CD_HAS_Z80_BUS & CD_TR_RD_Z80) ? 8'bzzzz_zzzz : SDD_IN;

wire [19:0] ADPCMA_ADDR;
wire  [4:0] ADPCMA_BANK;
wire [23:0] ADPCMB_ADDR;

// POCKET: V ROM and M1 loads go through pocket_mem_mux (R3), so the ddram write path is gone. The CD's PCM
// writes are the mux's: CD_PCM_DTACK, where ddram_dtack was.

// The ddram request and ack signals work on either edge
// To trigger a read request, just set adpcm_rd to ~adpcm_rdack

reg ADPCMA_READ_REQ, ADPCMB_READ_REQ;
reg ADPCMA_READ_ACK, ADPCMB_READ_ACK;
reg [24:0] ADPCMA_ADDR_LATCH;	// 16MB(32MB)
reg [24:0] ADPCMB_ADDR_LATCH;	// 32MB
reg [23:0] ADPCMB_MASK;
reg [7:0] ADPCMA_ACK_COUNTER;
reg [10:0] ADPCMB_ACK_COUNTER;
wire ADPCMA_DATA_READY = ~((ADPCMA_READ_REQ ^ ADPCMA_READ_ACK) & (ADPCMA_ACK_COUNTER == 8'd0));
wire ADPCMB_DATA_READY = ~((ADPCMB_READ_REQ ^ ADPCMB_READ_ACK) & (ADPCMB_ACK_COUNTER == 11'd0));

reg OLD_CD_TR_RD_PCM;
reg ADPCMA_RD_DTACK, ADPCMA_RD_WAIT;
always @(posedge CLK_96M) begin   // POCKET: was DDRAM_CLK
	reg [1:0] ADPCMA_OE_SR;
	reg [1:0] ADPCMB_OE_SR;
	ADPCMA_OE_SR <= {ADPCMA_OE_SR[0], nSDROE};
	ADPCMA_ACK_COUNTER <= ADPCMA_ACK_COUNTER == 8'd0 ? 8'd0 : ADPCMA_ACK_COUNTER - 8'd1;
	ADPCMB_ACK_COUNTER <= ADPCMB_ACK_COUNTER == 11'd0 ? 11'd0 : ADPCMB_ACK_COUNTER - 11'd1;
	// Trigger ADPCM A data read on nSDROE falling edge
	if (ADPCMA_OE_SR == 2'b10 & ~CD_USE_PCM) begin
		ADPCMA_READ_REQ <= ~ADPCMA_READ_REQ;
		ADPCMA_ADDR_LATCH <= {ADPCMA_BANK, ADPCMA_ADDR} & V1ROM_MASK[24:0];
		// Data is needed on one previous 8MHz clk before next 666KHz clock->(96MHz/666KHz = 144)-12-4=128
		ADPCMA_ACK_COUNTER <= 8'd128;
	end
	
	ADPCMB_MASK <= use_pcm ? V1ROM_MASK[23:0] : (|v2rom_mask ? v2rom_mask : V2ROM_MASK[23:0]);   // POCKET: R5
	
	// Trigger ADPCM B data read on nSDPOE falling edge
	ADPCMB_OE_SR <= {ADPCMB_OE_SR[0], nSDPOE};
	if (ADPCMB_OE_SR == 2'b10 & ~SYSTEM_CDx) begin
		ADPCMB_READ_REQ <= ~ADPCMB_READ_REQ;
		ADPCMB_ADDR_LATCH <= {~use_pcm, ADPCMB_ADDR & ADPCMB_MASK};
		// Data is needed on one previous 8MHz clk before next 55KHz clock->(96MHz/55KHz = 1728)-144-4=1580
		ADPCMB_ACK_COUNTER <= 11'd1580;
	end

	// ADPCM A read by 68K
	OLD_CD_TR_RD_PCM <= CD_TR_RD_PCM;
	if (~OLD_CD_TR_RD_PCM & CD_TR_RD_PCM) begin
		ADPCMA_ADDR_LATCH <= { 4'b0000, CD_BANK_PCM, (DMA_RUNNING ? DMA_ADDR_IN[19:1] : M68K_ADDR[19:1]) };
		ADPCMA_READ_REQ <= ~ADPCMA_READ_REQ;
		ADPCMA_RD_WAIT <= 1;
	end else if (ADPCMA_RD_WAIT & (ADPCMA_READ_REQ == ADPCMA_READ_ACK)) begin
		ADPCMA_RD_WAIT <= 0;
		ADPCMA_RD_DTACK <= 1;
	end

	if (ADPCMA_RD_DTACK & nAS) begin
		ADPCMA_RD_DTACK <= 0;
	end
end

assign M68K_DATA[7:0] = ~CD_TR_RD_PCM ? 8'bzzzz_zzzz : ADPCMA_DOUT;

wire [7:0] ADPCMA_DOUT;
wire [7:0] ADPCMA_DATA = (CD_USE_PCM || !V1ROM_MASK) ? 8'h80 : ADPCMA_DOUT;

wire [7:0] ADPCMB_DOUT;
wire [7:0] ADPCMB_DATA = (!ADPCMB_MASK) ? 8'h80 : ADPCMB_DOUT;

// POCKET: pocket_mem_mux replaces sdram_mux, sdram and ddram. Instantiation text of sdram_mux,
// except: no DATA_TYPE, CROM_ADDR without CROM_START (R4), raw DL_ADDR and DL_EN (R3), DL_INDEX,
// v2_offset, MEM_INIT and the ddram client ports.
`ifndef NEOGEO_RD_WAIT
`define NEOGEO_RD_WAIT 8
`endif
`ifndef NEOGEO_READY_COMB
`define NEOGEO_READY_COMB 0
`endif
`ifndef NEOGEO_Z80_WORD_BUF
`define NEOGEO_Z80_WORD_BUF 0
`endif
`ifdef NEOGEO_WAIT_COUNTER
wire [1:0] dbg_at_req;
// The cart's ROM zones. The CD build adds PROG RAM and the BIOS's other half: CD_EXT_RD and CD_EXT_WR. The holds
// of FIX, SPR and PCM transfers are not counted: the gate's 2% and 4% are for this zone
`ifdef NEOGEO_CD
wire dbg_zone = ~&{nSROMOE, nROMOE, nPORTOE} | CD_EXT_RD | CD_EXT_WR;
`else
wire dbg_zone = ~&{nSROMOE, nROMOE, nPORTOE};
`endif
assign dbg_wait = {dbg_at_req, dbg_zone, nAS, nRESET};
`ifdef NEOGEO_CD
// {fetch_err; transfer writes Z80, PCM, SPR, FIX; status latch; cur_lba; cur_status; status; command}
assign dbg_cdd = {fetch_err, CD_TR_WR_Z80, CD_TR_WR_PCM, CD_TR_WR_SPR, CD_TR_WR_FIX, CDD_STATUS_LATCH, dbg_cur_lba, dbg_cur_status, CDD_STATUS, CDD_COMMAND_DATA};
assign dbg_poll = cdd_poll & cdd_status_play;
// What cd_sys's CD_LID port gets: FF011C bit 12. sim/topcd holds it against the 68K's read of FF011C
wire dbg_cd_lid = cd_lid_bit;
// The LC8951's cache changes banks: the only rise of CD_DATA_WR_READY out of reset. In a DMA reading the cache, the
// rest of the DMA reads the next sector
reg dbg_ready_d = 0;
always @(posedge CLK_48M) dbg_ready_d <= CD_DATA_WR_READY;
wire dbg_swap_in_dma = CD_DATA_WR_READY & ~dbg_ready_d & DMA_RUNNING;
// A DMA word's strobe that reaches no memory: outside the transfer window and PROG RAM, or its area not enabled
wire dbg_dma_nowhere = DMA_RUNNING & DMA_WR_OUT & ~(CD_EXT_WR | CD_TR_WR_SPR | CD_TR_WR_PCM | CD_TR_WR_FIX | CD_TR_WR_Z80);
// {hold ran out toggle, sector held, decoder interrupt masked, swap in a DMA, DMA write to nowhere, 68K R/W, 68K address, command send, lid debug, CD_REGION, cd_speed, FF011C bit 12, CDZ}
assign dbg_sect = dbg_sect_cd;
assign dbg_dreq = {req_valid, req_audio, req_lba};
assign dbg_bus68 = {nUDS, nLDS, FX68K_DATAOUT};
assign dbg_dmab = {DMA_RUNNING, DMA_WR_OUT & CD_EXT_WR, DMA_RD_OUT & CD_EXT_RD, DMA_ADDR_OUT[23:1], DMA_ADDR_IN[23:1]};
assign dbg_cd2 = {dbg_bios_unibios, dbg_bios_requested, dbg_hold, dbg_swap_in_dma, dbg_dma_nowhere, M68K_RW, M68K_ADDR[23:1], CDD_COMMAND_SEND, status[15], CD_REGION, cd_speed, dbg_cd_lid, SYSTEM_CDZ};
`endif
`endif
`ifdef NEOGEO_CD
localparam bit MUX_CD_BUILD = 1;
`else
localparam bit MUX_CD_BUILD = 0;
`endif
pocket_mem_mux #(.RD_WAIT(`NEOGEO_RD_WAIT), .READY_COMB(`NEOGEO_READY_COMB), .Z80_WORD_BUF(`NEOGEO_Z80_WORD_BUF), .CD_BUILD(MUX_CD_BUILD)) SDRAM_MUX(
	.CLK(CLK_96M),
	.MEM_INIT(~locked),
	.nRESET(nRESET),
	.nSYSTEM_G(nSYSTEM_G),
	.SYSTEM_CDx(SYSTEM_CDx),

	.M68K_ADDR(M68K_ADDR),
	.M68K_DATA(M68K_DATA),
	.nAS(nAS | (FC1 == FC0)),
	.nLDS(nLDS),
	.nUDS(nUDS),
	.nROMOE(nROMOE),
	.nPORTOE(nPORTOE),
	.nSROMOE(nSROMOE),
	.P2ROM_ADDR(P2ROM_ADDR & P2ROM_MASK),
	.PROM_DATA(PROM_DATA),
	.PROM_DATA_READY(PROM_DATA_READY),

	.CD_TR_AREA(CD_TR_AREA),
	.CD_EXT_WR(CD_EXT_WR),
	.CD_EXT_RD(CD_EXT_RD),
	.CD_EXT_WR_READY(CD_EXT_WR_READY),
	.CD_USE_FIX(CD_USE_FIX),
	.CD_TR_RD_FIX(CD_TR_RD_FIX),
	.CD_TR_WR_FIX(CD_TR_WR_FIX),
	.CD_BANK_SPR(CD_BANK_SPR),
	.CD_USE_SPR(CD_USE_SPR),
	.CD_TR_RD_SPR(CD_TR_RD_SPR),
	.CD_TR_WR_SPR(CD_TR_WR_SPR),
	.CD_TR_WR_PCM(CD_TR_WR_PCM),
	.CD_BANK_PCM(CD_BANK_PCM),
	.CD_PCM_DTACK(CD_PCM_DTACK),

	.DMA_ADDR_OUT(DMA_ADDR_OUT),
	.DMA_ADDR_IN(DMA_ADDR_IN),
	.DMA_DATA_OUT(DMA_DATA_OUT),
	.DMA_RUNNING(DMA_RUNNING),
	.DMA_SDRAM_BUSY(DMA_SDRAM_BUSY),

	.PCK1(PCK1),
	.SPR_EN(SPR_EN),
	.CROM_ADDR(CROM_ADDR),
	.CR_DOUBLE(CR_DOUBLE),

	.PCK2(PCK2),
	.S_LATCH(S_LATCH),
	.FIX_BANK(FIX_BANK),
	.FIX_EN(FIX_EN),

	.SROM_DATA(SROM_DATA),

	.DL_EN(ioctl_download & ioctl_index != INDEX_LOROM & ioctl_index != INDEX_MEMCP),
	.DL_ADDR(ioctl_addr),
	.DL_DATA(ioctl_dout),
	.DL_WR(~ioctl_wr_rd1 & ioctl_wr_rd),
	.DL_INDEX(ioctl_index),
	.dl_overflow(dl_overflow),
`ifdef NEOGEO_WAIT_COUNTER
	.dbg_at_req(dbg_at_req),
`ifdef NEOGEO_CD
	.dbg_dma(dbg_dma),
`endif
`endif

	.REFRESH_EN(RFSH),

	.adpcma_addr(ADPCMA_ADDR_LATCH),
	.adpcma_dout(ADPCMA_DOUT),
	.adpcma_req(ADPCMA_READ_REQ),
	.adpcma_ack(ADPCMA_READ_ACK),

	.adpcmb_addr(ADPCMB_ADDR_LATCH),
	.adpcmb_dout(ADPCMB_DOUT),
	.adpcmb_req(ADPCMB_READ_REQ),
	.adpcmb_ack(ADPCMB_READ_ACK),

	.v2_offset(v2_offset),

	.m1_addr({MA & MROM_MASK[18:11],SDA[10:0]}),
	.m1_dout(M1_ROM_DATA),
	.m1_req(z80rd_req),
	.m1_ack(z80rd_ack),

	.fx_req(fx_req), .fx_we(fx_we), .fx_word(fx_word), .fx_be(fx_be), .fx_wdata(fx_wdata), .fx_ack(fx_ack), .fx_rdata(fx_rdata),

	.dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
	.dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
	.cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk),
	.cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
	.cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
	.cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_wait(cram1_wait), .cram1_clk(cram1_clk),
	.cram1_adv_n(cram1_adv_n), .cram1_cre(cram1_cre), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
	.cram1_oe_n(cram1_oe_n), .cram1_we_n(cram1_we_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n)
);

wire [7:0] YM2610_DOUT;
wire [15:0] ym_left, ym_right;

reg adpcm_en;
reg [7:0] adpcma_d, adpcmb_d;
always @(posedge CLK_48M) begin
	reg en;
	en <= ADPCMA_DATA_READY & ADPCMB_DATA_READY;
	adpcm_en <= en;
	
	adpcma_d <= ADPCMA_DATA;
	adpcmb_d <= ADPCMB_DATA;
end

jt10 YM2610(
	.rst(~Z80_nRESET),
	.clk(CLK_48M), .cen((CLK_EN_4M_P | CLK_EN_4M_N) & adpcm_en),
	.addr(SDA[1:0]),
	.din(SDD_OUT), .dout(YM2610_DOUT),
	.cs_n(n2610CS), .wr_n(n2610WR),
	.irq_n(Z80_nINT),
	.adpcma_addr(ADPCMA_ADDR), .adpcma_bank(ADPCMA_BANK), .adpcma_roe_n(nSDROE), .adpcma_data(adpcma_d),
	.adpcmb_addr(ADPCMB_ADDR), .adpcmb_roe_n(nSDPOE), .adpcmb_data(SYSTEM_CDx ? 8'h08 : adpcmb_d),	// CD has no ADPCM-B
	.snd_right(ym_right), .snd_left(ym_left),     // POCKET: were the ports, see the mix below
	.snd_enable(~{4{dbg_menu}} | ~status[28:25]), .ch_enable(~status[62:57])
);

`ifdef NEOGEO_CD
wire [16:0] snd_mix_l = $signed(ym_left) + $signed(CD_AUDIO_L);
wire [16:0] snd_mix_r = $signed(ym_right) + $signed(CD_AUDIO_R);

// POCKET: halved as MiSTer's AUDIO_L and AUDIO_R, which is what keeps the sum in range
assign snd_left  = snd_mix_l[16:1];
assign snd_right = snd_mix_r[16:1];
`else
// POCKET: CD audio is tied off in the cart build, snd_left/snd_right go out directly
assign snd_left  = ym_left;
assign snd_right = ym_right;
`endif

 
// For Neo CD only
wire VIDEO_EN = SYSTEM_CDx ? CD_VIDEO_EN : 1'b1;
wire FIX_EN = SYSTEM_CDx ? CD_FIX_EN : 1'b1;
wire SPR_EN = SYSTEM_CDx ? CD_SPR_EN : 1'b1;
wire DOTA_GATED = SPR_EN & DOTA;
wire DOTB_GATED = SPR_EN & DOTB;
wire HSync; //,VSync;

lspc2_a2_sync	LSPC(
	.CLK(CLK_48M),
	.CLK_EN_24M_P(CLK_EN_24M_P),
	.CLK_EN_24M_N(CLK_EN_24M_N),
	.RESET(nRESET),
	.nRESETP(nRESETP),
	.LSPC_8M(), .LSPC_4M(),
	.LSPC_EN_4M_P(CLK_EN_4M_P), .LSPC_EN_4M_N(CLK_EN_4M_N),
	.M68K_ADDR(M68K_ADDR[3:1]), .M68K_DATA(M68K_DATA),
	.IPL0(IPL0), .IPL1(IPL1),
	.CD_VBLANK_IRQ_EN(CD_VBLANK_IRQ_EN | ~SYSTEM_CDx),
	.CD_TIMER_IRQ_EN(CD_TIMER_IRQ_EN | ~SYSTEM_CDx),
	.LSPOE(nLSPOE), .LSPWE(nLSPWE),
	.PBUS_OUT(PBUS[15:0]), .PBUS_IO(PBUS[23:16]),
	.nPBUS_OUT_EN(nPBUS_OUT_EN),
	.DOTA(DOTA_GATED), .DOTB(DOTB_GATED),
	.CA4(CA4), .S2H1(S2H1), .S1H1(S1H1),
	.LOAD(LOAD), .H(H), .EVEN1(EVEN1), .EVEN2(EVEN2),
	.PCK1(PCK1), .PCK2(PCK2),
	.PCK1_EN_N(PCK1_EN_N), .PCK2_EN_N(PCK2_EN_N),
	.PCK1_EN_P(PCK1_EN_P), .PCK2_EN_P(PCK2_EN_P),
	.CHG(CHG),
	.LD1(LD1), .LD2(LD2),
	.WE(WE), .CK(CK),	.SS1(SS1), .SS2(SS2),
	.HSYNC(HSync), //.VSYNC(VSync),
	.CHBL(CHBL), .BNKB(nBNKB),
	.VCS(VCS),
	.SVRAM_ADDR(SLOW_VRAM_ADDR),
	.SVRAM_DATA_IN(SLOW_VRAM_DATA_IN), .SVRAM_DATA_OUT(SLOW_VRAM_DATA_OUT),
	.BOE(BOE), .BWE(BWE),
	.FVRAM_ADDR(FAST_VRAM_ADDR),
	.FVRAM_DATA_IN(FAST_VRAM_DATA_IN), .FVRAM_DATA_OUT(FAST_VRAM_DATA_OUT),
	.CWE(CWE),
	.VMODE(video_mode),
	.FIXMAP_ADDR(FIXMAP_ADDR)	// Extracted for NEO-CMC
);

wire DOGE = SYSTEM_CDx ? ~CD_UPLOAD_EN : 1'b1; // UPLOAD_EN disables Watchdog?

neo_b1 B1(
	.CLK(CLK_48M),	.CLK_EN_6MB(CLK_EN_6MB), .CLK_EN_1HB(CLK_EN_1HB),
	.S1H1(S1H1),
	.A23I(A23Z), .A22I(A22Z),
	.M68K_ADDR_U(M68K_ADDR[21:17]), .M68K_ADDR_L(M68K_ADDR[12:1]),
	.nLDS(nLDS), .RW(M68K_RW), .nAS(nAS),
	.PBUS(PBUS),
	.FIXD(FIXD),
	.PCK1_EN(PCK1_EN_P), .PCK2_EN(PCK2_EN_P),
	.CHBL(CHBL), .BNKB(nBNKB),
	.GAD(GAD), .GBD(GBD),
	.WE(WE), .CK(CK),
	.TMS0(CHG), .LD1(LD1), .LD2(LD2), .SS1(SS1), .SS2(SS2),
	.PA(PAL_RAM_ADDR),
	.EN_FIX(FIX_EN),
	.DOGE(DOGE),
	.nRST(nRESET_CORE),
	.nRESET(nRESET)
);

spram #(13,16) PALRAM(
	.clock(CLK_48M), 	// Was CLK_12M
	.address({PALBNK, PAL_RAM_ADDR}),
	.data(M68K_DATA),
	.wren(~nPAL_WE),
	.q(PAL_RAM_DATA)
);

// DAC latches
// POCKET: ce_pix is a port
reg [2:0] HBlank;
reg HBlank304;
always @(posedge CLK_VIDEO) begin
	reg [9:0] pxcnt;

	ce_pix <= 0;
	if(CLK_EN_6MB) begin
		ce_pix <= 1;
		PAL_RAM_REG <= (nRESET && VIDEO_EN && ((pxcnt >= 7 && pxcnt < 311) || ~status[16])) ? PAL_RAM_DATA : 16'h8000;
	end

	if(ce_pix) begin
		HBlank <= (HBlank<<1) | CHBL;
		
		pxcnt <= pxcnt + 1'b1;
		if(HBlank[1:0] == 2'b10) pxcnt <= 0;
	end
end

//Re-create VSync as original one is barely equals to VBlank
reg VSync;
reg RFSH;
always @(posedge CLK_VIDEO) begin
	reg       old_hs;
	reg       old_vbl;
	reg [2:0] vbl;
	reg [7:0] vblcnt, vspos, rfsh_cnt;
	
	if(ce_pix) begin
		old_hs <= HSync;
		if(~old_hs & HSync) begin
			old_vbl <= nBNKB;
			
			if(~nBNKB) vblcnt <= vblcnt+1'd1;
			if(old_vbl & ~nBNKB) vblcnt <= 0;
			if(~old_vbl & nBNKB) begin
				vspos <= (vblcnt>>1) - 8'd7;
				rfsh_cnt <= vblcnt-2'd2;
			end

			{VSync,vbl} <= {vbl,1'b0};
			if(vblcnt == vspos) {VSync,vbl} <= '1;
		end
		
		RFSH <= (vblcnt < rfsh_cnt);
	end
end

wire [6:0] R6 = {1'b0, PAL_RAM_REG[11:8], PAL_RAM_REG[14], PAL_RAM_REG[11]} - PAL_RAM_REG[15];
wire [6:0] G6 = {1'b0, PAL_RAM_REG[7:4],  PAL_RAM_REG[13], PAL_RAM_REG[7] } - PAL_RAM_REG[15];
wire [6:0] B6 = {1'b0, PAL_RAM_REG[3:0],  PAL_RAM_REG[12], PAL_RAM_REG[3] } - PAL_RAM_REG[15];

wire [7:0] R8 = R6[6] ? 8'd0 : {R6[5:0],  R6[4:3]};
wire [7:0] G8 = G6[6] ? 8'd0 : {G6[5:0],  G6[4:3]};
wire [7:0] B8 = B6[6] ? 8'd0 : {B6[5:0],  B6[4:3]};

// POCKET: r, g, b, hs, vs, hblank, vblank are ports; video_mixer and scandoubler removed
video_cleaner video_cleaner
(
	.clk_vid(CLK_VIDEO),
	.ce_pix(ce_pix),

	.R(~SHADOW ? R8 : {1'b0, R8[7:1]}),
	.G(~SHADOW ? G8 : {1'b0, G8[7:1]}),
	.B(~SHADOW ? B8 : {1'b0, B8[7:1]}),

	.HSync(HSync),
	.VSync(VSync),
	.HBlank(HBlank[0]),
	.VBlank(~nBNKB),

	.VGA_R(r),
	.VGA_G(g),
	.VGA_B(b),
	.VGA_VS(vs),
	.VGA_HS(hs),
	.HBlank_out(hblank),
	.VBlank_out(vblank)
);

endmodule