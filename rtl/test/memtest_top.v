// SPDX-License-Identifier: GPL-3.0-or-later
//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//
// Port list and tie-offs from Analogue's core template. The rest is the Pocket memory self-test,
// see memtest.sv: this program is free software under the GNU General Public License, version 3 or
// later. The data table size loop follows apf_io.sv of Mazamars312's Neo Geo Overdrive.
//

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  wire    [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// the work RAM SRAM is not under test
assign sram_a = 'h0;
assign sram_dq = {16{1'bZ}};
assign sram_oe_n  = 1;
assign sram_we_n  = 1;
assign sram_ub_n  = 1;
assign sram_lb_n  = 1;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

`ifndef MEMTEST_RD_WAIT
`define MEMTEST_RD_WAIT 8
`endif
localparam RD_WAIT = `MEMTEST_RD_WAIT;

// host/target command handler, as in the template
    wire            reset_n;
    wire    [31:0]  cmd_bridge_rd_data;

    // The host starts writing data slots after setup is done. Hold that until the SDRAM has left
    // its 125 us startup after lock, 2^15 clocks here: the loader port has no way to wait.
    reg     [15:0]  setup_cnt = 0;
    wire            pll_locked, pll_locked_s;
synch_3 s01(pll_locked, pll_locked_s, clk_74a);
always @(posedge clk_74a) begin
    if (!pll_locked_s) setup_cnt <= 0;
    else if (!setup_cnt[15]) setup_cnt <= setup_cnt + 1'b1;
end

    wire            status_boot_done = pll_locked_s;
    wire            status_setup_done = setup_cnt[15];
    wire            status_running = reset_n;

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;

    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported = 0;
    wire    [31:0]  savestate_addr = 0;
    wire    [31:0]  savestate_size = 0;
    wire    [31:0]  savestate_maxloadsize = 0;

    wire            savestate_start;
    wire            savestate_start_ack = 0;
    wire            savestate_start_busy = 0;
    wire            savestate_start_ok = 0;
    wire            savestate_start_err = 0;

    wire            savestate_load;
    wire            savestate_load_ack = 0;
    wire            savestate_load_busy = 0;
    wire            savestate_load_ok = 0;
    wire            savestate_load_err = 0;

    wire            osnotify_inmenu;

    wire            target_dataslot_ack;
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;
    wire    [31:0]  target_buffer_param_struct = 0;
    wire    [31:0]  target_buffer_resp_struct = 0;

    reg     [9:0]   datatable_addr = 0;
    reg             datatable_wren = 0;
    reg     [31:0]  datatable_data = 0;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (
    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( 1'b0 ),
    .target_dataslot_write      ( 1'b0 ),
    .target_dataslot_getfile    ( 1'b0 ),
    .target_dataslot_openfile   ( 1'b0 ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( 16'd0 ),
    .target_dataslot_slotoffset ( 32'd0 ),
    .target_dataslot_bridgeaddr ( 32'd0 ),
    .target_dataslot_length     ( 32'd0 ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )
);

// The save slot has no exact size, so the file's size is what the data table says when leaving
// the core: find the slot's id in the table and keep its size written, as apf_io.sv does.
localparam SAVE_ID   = 32'h101;
localparam SAVE_SIZE = 32'd4096;
reg [1:0] dt_wait = 0;
always @(posedge clk_74a) begin
    datatable_wren <= 0;
    dt_wait <= dt_wait + 1'b1;
    if (dt_wait == 2'd3) begin
        if (datatable_addr[0]) datatable_addr <= datatable_addr + 1'b1;
        else if (datatable_q == SAVE_ID) begin
            datatable_addr <= datatable_addr + 1'b1;
            datatable_data <= SAVE_SIZE;
            datatable_wren <= 1;
        end else datatable_addr <= datatable_addr >= 10'd126 ? 10'd0 : datatable_addr + 2'd2;
    end
end

// clocks

    wire    clk_96m, clk_48m, clk_pix, clk_pix_90, pll_reconfiguring;

pll_pocket pll (
    .refclk        ( clk_74a ),
    .rst           ( 1'b0 ),
    .mvs           ( 1'b0 ),        // AES clock, the shortest period: the worst case for the memories
    .CLK_96M       ( clk_96m ),
    .CLK_48M       ( clk_48m ),
    .CLK_PIX       ( clk_pix ),
    .CLK_PIX_90    ( clk_pix_90 ),
    .locked        ( pll_locked ),
    .reconfiguring ( pll_reconfiguring )
);

// pocket.sdc constrains the 48 MHz output, so it has to exist
reg clk_48m_alive /* synthesis noprune */ = 0;
always @(posedge clk_48m) clk_48m_alive <= ~clk_48m_alive;

// the test

    wire    [159:0] res_err, res_addr;
    wire    [79:0]  res_pass, res_got, res_exp;
    wire    [31:0]  lat, seconds;
    wire    [15:0]  loops;
    wire    [2:0]   running;
    wire            dl_overflow, bw_tog;
    wire    [31:0]  bw_addr, bw_data, save_rd_data, rfsh_count;
    wire    [15:0]  rfsh_max;
    wire    [1:0]   seq_answer;
    wire    [3:0]   seq_mask;
    wire            diag_we;
    wire    [2:0]   diag_ptr;
    wire    [255:0] diag_data;
    wire    [31:0]  last_addr;
    wire    [15:0]  last_got, last_exp, last_sec;

memtest #(.RD_WAIT(RD_WAIT)) test (
    .clk(clk_96m), .mem_init(~pll_locked), .start(dataslot_allcomplete & reset_n),
    .bw_tog(bw_tog), .bw_addr(bw_addr), .bw_data(bw_data),
    .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
    .lat(lat), .loops(loops), .seconds(seconds), .running(running), .dl_overflow(dl_overflow),
    .rfsh_count(rfsh_count), .rfsh_max(rfsh_max), .seq_answer(seq_answer), .seq_mask(seq_mask),
    .diag_we(diag_we), .diag_ptr(diag_ptr), .diag_data(diag_data),
    .last_addr(last_addr), .last_got(last_got), .last_exp(last_exp), .last_sec(last_sec),
    .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
    .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk),
    .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
    .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
    .cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_wait(cram1_wait), .cram1_clk(cram1_clk),
    .cram1_adv_n(cram1_adv_n), .cram1_cre(cram1_cre), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
    .cram1_oe_n(cram1_oe_n), .cram1_we_n(cram1_we_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n)
);

memtest_bridge #(.RD_WAIT(RD_WAIT)) bridge (
    .clk(clk_74a), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_rd_data(save_rd_data),
    .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
    .bw_tog(bw_tog), .bw_addr(bw_addr), .bw_data(bw_data),
    .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
    .lat(lat), .loops(loops), .seconds(seconds), .dl_overflow(dl_overflow),
    .rfsh_count(rfsh_count), .rfsh_max(rfsh_max), .seq_answer(seq_answer), .seq_mask(seq_mask),
    .diag_clk(clk_96m), .diag_we(diag_we), .diag_ptr(diag_ptr), .diag_data(diag_data)
);

assign bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_bridge_rd_data : save_rd_data;

memtest_screen #(.RD_WAIT(RD_WAIT)) screen (
    .clk(clk_pix),
    .res_err(res_err), .res_addr(res_addr), .res_pass(res_pass), .res_got(res_got), .res_exp(res_exp),
    .lat(lat), .loops(loops), .seconds(seconds), .running(running), .dl_overflow(dl_overflow),
    .rfsh_count(rfsh_count), .rfsh_max(rfsh_max), .seq_answer(seq_answer), .seq_mask(seq_mask),
    .last_addr(last_addr), .last_got(last_got), .last_exp(last_exp), .last_sec(last_sec),
    .video_rgb(video_rgb), .video_de(video_de), .video_vs(video_vs), .video_hs(video_hs)
);

assign video_rgb_clock = clk_pix;
assign video_rgb_clock_90 = clk_pix_90;
assign video_skip = 0;

//
// audio i2s silence generator, from the template
//

assign audio_mclk = audgen_mclk;
assign audio_dac = audgen_dac;
assign audio_lrck = audgen_lrck;

// generate MCLK = 12.288mhz with fractional accumulator
    reg         [21:0]  audgen_accum = 0;
    reg                 audgen_mclk = 0;
    parameter   [20:0]  CYCLE_48KHZ = 21'd122880 * 2;
always @(posedge clk_74a) begin
    audgen_accum <= audgen_accum + CYCLE_48KHZ;
    if(audgen_accum >= 21'd742500) begin
        audgen_mclk <= ~audgen_mclk;
        audgen_accum <= audgen_accum - 21'd742500 + CYCLE_48KHZ;
    end
end

// generate SCLK = 3.072mhz by dividing MCLK by 4
    reg [1:0]   aud_mclk_divider = 0;
    wire        audgen_sclk = aud_mclk_divider[1] /* synthesis keep*/;
always @(posedge audgen_mclk) begin
    aud_mclk_divider <= aud_mclk_divider + 1'b1;
end

// 32 total bits per channel, no data
    reg     [4:0]   audgen_lrck_cnt = 0;
    reg             audgen_lrck = 0;
    reg             audgen_dac = 0;
always @(negedge audgen_sclk) begin
    audgen_dac <= 1'b0;
    audgen_lrck_cnt <= audgen_lrck_cnt + 1'b1;
    if(audgen_lrck_cnt == 31) begin
        audgen_lrck <= ~audgen_lrck;
    end
end

endmodule
`default_nettype wire
