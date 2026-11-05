//
// User core top-level
//
// Instantiated by the real top-level: apf_top
//
// Two parts, under different terms. Analogue's, under its EULA: the port list, the pin tie-offs and the host
// command wiring with the core_bridge_cmd instance, from core_top.v of its core template v1.3.0 (the template's
// src/fpga/apf files name the EULA). This project's: the edits among those, and all from "// Clocks" on, which
// join the PLL, loader, Neo Geo core, video and audio, are free software under the GNU General Public License, v3 or later.
//

`default_nettype none

module core_top #(
    parameter RESET_HOLD_CLKS = 37125000    // of apf_loader, 0.5 s of clk_74a; benches shorten it
) (

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

// tie off the rest of the pins we are not using
assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// Host commands and the data table, as the template

    wire            reset_n;
    wire    [31:0]  cmd_bridge_rd_data;

    wire            clk_96m, clk_48m, clk_pix, clk_pix_90, pll_locked, pll_reconfiguring;
    wire            pll_locked_s;
synch_3 s01(pll_locked, pll_locked_s, clk_74a);

    // The host starts writing data slots after setup is done. Hold that until the PLL has taken the
    // reset value of mvs and the SDRAM has left its 125 us startup after lock (2^15 clocks): the
    // loader has no way to wait. Both flags stay up once set: core_bridge_cmd.v sends "ready to run"
    // on every rising edge of setup done, and an MVS/AES relock with a game running must not.
    reg     [15:0]  setup_cnt = 0;
    reg             status_boot_done = 0;
    reg             status_setup_done = 0;
always @(posedge clk_74a) begin
    if (!pll_locked_s || pll_reconfiguring) setup_cnt <= 0;
    else if (!setup_cnt[15]) setup_cnt <= setup_cnt + 1'b1;
    if (pll_locked_s) status_boot_done <= 1;
    if (setup_cnt[15]) status_setup_done <= 1;
end
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
`ifdef NEOGEO_CD
    // cd_host owns the target commands (rtl/cd/cd_host.sv), the wait counter's slot write included
    wire            target_dataslot_read, target_dataslot_write, target_dataslot_getfile, target_dataslot_openfile;
    wire    [15:0]  target_dataslot_id;
    wire    [31:0]  target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
    wire    [31:0]  target_buffer_param_struct, target_buffer_resp_struct;
`else
    wire    [31:0]  target_buffer_param_struct = 0;
    wire    [31:0]  target_buffer_resp_struct = 0;
`endif

`ifdef NEOGEO_WAIT_COUNTER
    wire            wait_save_now;
`endif

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
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

`ifdef NEOGEO_CD
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
`else
    .target_dataslot_read       ( 1'b0 ),
`ifdef NEOGEO_WAIT_COUNTER
    .target_dataslot_write      ( wait_save_now ),
`else
    .target_dataslot_write      ( 1'b0 ),
`endif
    .target_dataslot_getfile    ( 1'b0 ),
    .target_dataslot_openfile   ( 1'b0 ),
`endif

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

`ifdef NEOGEO_CD
    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),
`elsif NEOGEO_WAIT_COUNTER
    .target_dataslot_id         ( 16'h0103 ),
    .target_dataslot_slotoffset ( 32'd0 ),
    .target_dataslot_bridgeaddr ( 32'h8000_0000 ),
    .target_dataslot_length     ( 32'd256 ),
`else
    .target_dataslot_id         ( 16'd0 ),
    .target_dataslot_slotoffset ( 32'd0 ),
    .target_dataslot_bridgeaddr ( 32'd0 ),
    .target_dataslot_length     ( 32'd0 ),
`endif

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )
);

// Clocks

    wire            mvs;

pll_pocket pll (
    .refclk        ( clk_74a ),
    .rst           ( 1'b0 ),
    .mvs           ( mvs ),
    .CLK_96M       ( clk_96m ),
    .CLK_48M       ( clk_48m ),
    .CLK_PIX       ( clk_pix ),
    .CLK_PIX_90    ( clk_pix_90 ),
    .locked        ( pll_locked ),
    .reconfiguring ( pll_reconfiguring )
);

// The loader: slots, settings, saves, controls and RTC

    wire            ioctl_wr, ioctl_download, sram_wr, memcard_wr, apf_core_reset, width320, prom1_conflict;
    wire    [26:0]  ioctl_addr;
    wire    [15:0]  ioctl_dout, save_din, joystick_0, joystick_1, joystick_2, joystick_3;
    wire    [7:0]   ioctl_idx;
    wire    [63:0]  status;
    wire    [31:0]  cfg, loader_rd_data;
    wire    [64:0]  rtc;
    wire    [23:0]  v2_offset, v2rom_mask;
    wire    [14:0]  sram_addr;
    wire    [11:0]  memcard_addr;
    wire    [2:0]   video_slot;
    wire    [15:0]  sram_buff_dout, card_buff_dout;
`ifdef NEOGEO_CD
    wire            cd_mount_req;
    wire    [31:0]  disc_size;
`ifdef NEOGEO_WAIT_COUNTER
    wire    [31:0]  disc_bin_size;
`endif
`endif

`ifdef NEOGEO_CD
apf_loader #(.RESET_HOLD_CLKS(RESET_HOLD_CLKS), .CD_BUILD(1)) loader (
`else
apf_loader #(.RESET_HOLD_CLKS(RESET_HOLD_CLKS)) loader (
`endif
    .clk_74a(clk_74a), .CLK_96M(clk_96m),
    .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
    .bridge_rd(bridge_rd), .bridge_rd_data(loader_rd_data),
    .reset_n(reset_n), .dataslot_allcomplete(dataslot_allcomplete), .reconfiguring(pll_reconfiguring),
    .dataslot_update(dataslot_update), .dataslot_update_id(dataslot_update_id), .dataslot_update_size(dataslot_update_size),
    .rtc_valid(rtc_valid), .rtc_date_bcd(rtc_date_bcd), .rtc_time_bcd(rtc_time_bcd),
    .datatable_addr(datatable_addr), .datatable_wren(datatable_wren), .datatable_data(datatable_data),
    .datatable_q(datatable_q),
    .cont1_key(cont1_key), .cont2_key(cont2_key), .cont3_key(cont3_key), .cont4_key(cont4_key),
    .ioctl_download(ioctl_download), .ioctl_index(ioctl_idx), .ioctl_wr(ioctl_wr),
    .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .joystick_0(joystick_0), .joystick_1(joystick_1), .joystick_2(joystick_2), .joystick_3(joystick_3),
    .status(status), .cfg(cfg), .rtc(rtc), .v2_offset(v2_offset), .v2rom_mask(v2rom_mask),
    .width320(width320), .video_slot(video_slot), .mvs(mvs),
    .apf_core_reset(apf_core_reset), .prom1_conflict(prom1_conflict),
    .sram_addr(sram_addr), .sram_wr(sram_wr), .memcard_addr(memcard_addr), .memcard_wr(memcard_wr),
    .sd_buff_dout(save_din), .sram_buff_dout(sram_buff_dout), .card_buff_dout(card_buff_dout)
`ifdef NEOGEO_CD
    , .disc_size(disc_size), .cd_mount_req(cd_mount_req)
`ifdef NEOGEO_WAIT_COUNTER
    , .disc_bin_size(disc_bin_size)
`endif
`endif
);

`ifdef NEOGEO_CD
// The target commands: the disc's data-slot reads for cd_mount and for cd_fetch (in the core), the wait counter's
// slot write. rst stays low: core_bridge_cmd.v has no reset, see cd_host.sv
    wire    [31:0]  cd_host_rd_data, fr_offset, bank_rd_q;
    wire            fr_req, fr_done, fr_err, mr_req, mr_done, path_wr;
    wire    [15:0]  fr_slot, mr_slot;
    wire    [1:0]   fr_bank_slot, mr_kind, mr_bank_slot;
    wire    [31:0]  mr_offset, mr_len, path_wdata, path_q, bank_rd_q_74;
    wire    [2:0]   mr_err;
    wire    [7:0]   path_addr;
    wire    [11:0]  bank_rd_addr, bank_rd_addr_74;
    wire            disc_present, disc_loading;
    wire    [6:0]   track_count, toc_rd_track;
    wire    [23:0]  disc_end;
    wire    [79:0]  toc_rd_entry;
    wire    [3:0]   disc_reason;
`ifdef NEOGEO_WAIT_COUNTER
    wire            wait_save_done;
    wire    [2:0]   wait_save_err;
`endif
cd_host cd_host (
    .clk_74a(clk_74a), .CLK_48M(clk_48m), .rst(1'b0),
    .target_dataslot_read(target_dataslot_read), .target_dataslot_getfile(target_dataslot_getfile),
    .target_dataslot_openfile(target_dataslot_openfile), .target_dataslot_write(target_dataslot_write),
    .target_dataslot_ack(target_dataslot_ack), .target_dataslot_done(target_dataslot_done),
    .target_dataslot_err(target_dataslot_err),
    .target_dataslot_id(target_dataslot_id), .target_dataslot_slotoffset(target_dataslot_slotoffset),
    .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr), .target_dataslot_length(target_dataslot_length),
    .target_buffer_param_struct(target_buffer_param_struct), .target_buffer_resp_struct(target_buffer_resp_struct),
    .bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
    .bridge_rd(bridge_rd), .bridge_rd_data(cd_host_rd_data),
    .mr_req(mr_req), .mr_kind(mr_kind), .mr_slot(mr_slot), .mr_offset(mr_offset), .mr_len(mr_len), .mr_bank_slot(mr_bank_slot),
    .mr_done(mr_done), .mr_err(mr_err),
    .fr_req(fr_req), .fr_slot(fr_slot), .fr_offset(fr_offset), .fr_bank_slot(fr_bank_slot), .fr_done(fr_done), .fr_err(fr_err),
`ifdef NEOGEO_WAIT_COUNTER
    .ws_req(wait_save_now), .ws_done(wait_save_done), .ws_err(wait_save_err),
`endif
    .bank_rd_addr(bank_rd_addr), .bank_rd_q(bank_rd_q), .bank_rd_addr_74(bank_rd_addr_74), .bank_rd_q_74(bank_rd_q_74),
    .path_addr(path_addr), .path_wr(path_wr), .path_wdata(path_wdata), .path_q(path_q)
);

cd_mount cdmount (
    .clk_74a(clk_74a), .rst(1'b0),
    .mount_req(cd_mount_req), .disc_size(disc_size), .disc_bin_size(32'd0),
    .mr_req(mr_req), .mr_kind(mr_kind), .mr_slot(mr_slot), .mr_offset(mr_offset), .mr_len(mr_len), .mr_bank_slot(mr_bank_slot),
    .mr_done(mr_done), .mr_err(mr_err),
    .path_addr(path_addr), .path_wr(path_wr), .path_wdata(path_wdata), .path_q(path_q),
    .bank_rd_addr_74(bank_rd_addr_74), .bank_rd_q_74(bank_rd_q_74),
    .disc_loading(disc_loading), .disc_present(disc_present), .track_count(track_count), .disc_end(disc_end),
    .CLK_48M(clk_48m), .toc_rd_track(toc_rd_track), .toc_rd_entry(toc_rd_entry),
    .dbg_reason(disc_reason)
);
    wire    [31:0]  pocket_rd_data = bridge_addr[31:24] == 8'h71 ? cd_host_rd_data : loader_rd_data;
`else
    wire    [31:0]  pocket_rd_data = loader_rd_data;
`endif

`ifdef NEOGEO_WAIT_COUNTER
    wire    [31:0]  wait_rd_data;
assign bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_bridge_rd_data :
                        bridge_addr[31:28] == 4'h8  ? wait_rd_data : pocket_rd_data;
`else
assign bridge_rd_data = bridge_addr[31:24] == 8'hF8 ? cmd_bridge_rd_data : pocket_rd_data;
`endif

// The core

    wire    [15:0]  snd_left, snd_right;
    wire            ce_pix, hs, vs, core_hblank, core_vblank, dl_overflow;
    wire    [7:0]   r, g, b;

`ifdef NEOGEO_WAIT_COUNTER
    wire    [4:0]   dbg_wait;
`ifdef NEOGEO_CD
    wire   [113:0]  dbg_cdd;
    wire    [33:0]  dbg_cd2;
    wire   [319:0]  dbg_fetch;
    wire   [383:0]  dbg_dma;
`endif
`ifndef NEOGEO_RD_WAIT
`define NEOGEO_RD_WAIT 8
`endif
// The file's layout number: how the owner codes read (rtl/test/wait_counter.sv, tools/check_wait_save.py)
`ifdef NEOGEO_CD
`define WAIT_LAYOUT 3
`else
`define WAIT_LAYOUT 1
`endif
wait_counter #(.RD_WAIT(`NEOGEO_RD_WAIT), .LAYOUT(`WAIT_LAYOUT)) wait_ctr (
    .clk_48m(clk_48m), .nRESET(dbg_wait[0]), .nAS(dbg_wait[1]), .rom_zone(dbg_wait[2]), .at_req(dbg_wait[4:3]),
    .vblank(core_vblank), .c1_wait(cfg[30:28]),
    .clk_74a(clk_74a), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_rd_data(wait_rd_data),
    .run(reset_n & dataslot_allcomplete), .save_now(wait_save_now),
`ifdef NEOGEO_CD
    .save_done(wait_save_done), .save_err(wait_save_err),
    .cdd(dbg_cdd), .disc_bin_size(disc_bin_size), .disc_reason(disc_reason),
    .cd2(dbg_cd2), .fetch(dbg_fetch), .dma(dbg_dma)
`else
    .save_done(target_dataslot_done), .save_err(target_dataslot_err),
    .cdd(114'd0), .disc_bin_size(32'd0), .disc_reason(4'd0),
    .cd2(34'd0), .fetch(320'd0), .dma(384'd0)
`endif
);
`endif

neogeo_pocket neogeo (
    .CLK_96M(clk_96m), .CLK_48M(clk_48m), .pll_locked(pll_locked), .RESET(~pll_locked),
    .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
    .ioctl_download(ioctl_download), .ioctl_idx(ioctl_idx),
    .joystick_0(joystick_0), .joystick_1(joystick_1), .joystick_2(joystick_2), .joystick_3(joystick_3),
    .status_in(status), .cfg(cfg), .rtc(rtc), .v2_offset(v2_offset), .v2rom_mask(v2rom_mask),
    .sram_addr(sram_addr), .sram_wr(sram_wr), .memcard_addr(memcard_addr), .memcard_wr(memcard_wr),
    .sd_buff_dout(save_din), .sram_buff_dout(sram_buff_dout), .card_buff_dout(card_buff_dout),
    .snd_left(snd_left), .snd_right(snd_right),
    .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hs(hs), .vs(vs), .hblank(core_hblank), .vblank(core_vblank),
    .dl_overflow(dl_overflow),
`ifdef NEOGEO_WAIT_COUNTER
    .dbg_wait(dbg_wait),
`ifdef NEOGEO_CD
    .dbg_cdd(dbg_cdd), .dbg_cd2(dbg_cd2), .dbg_fetch(dbg_fetch), .dbg_dma(dbg_dma),
`endif
`endif
`ifdef NEOGEO_CD
    .fr_req(fr_req), .fr_slot(fr_slot), .fr_offset(fr_offset), .fr_bank_slot(fr_bank_slot), .fr_done(fr_done), .fr_err(fr_err),
    .bank_rd_addr(bank_rd_addr), .bank_rd_q(bank_rd_q),
    .disc_present(disc_present), .disc_loading(disc_loading), .track_count(track_count), .disc_end(disc_end),
    .toc_rd_track(toc_rd_track), .toc_rd_entry(toc_rd_entry),
`endif
    .dram_dq(dram_dq), .dram_a(dram_a), .dram_dqm(dram_dqm), .dram_ba(dram_ba), .dram_we_n(dram_we_n),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_cke(dram_cke), .dram_clk(dram_clk),
    .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_wait(cram0_wait), .cram0_clk(cram0_clk),
    .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre), .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
    .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n), .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
    .cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_wait(cram1_wait), .cram1_clk(cram1_clk),
    .cram1_adv_n(cram1_adv_n), .cram1_cre(cram1_cre), .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
    .cram1_oe_n(cram1_oe_n), .cram1_we_n(cram1_we_n), .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n),
    .sram_a(sram_a), .sram_dq(sram_dq), .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
    .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
);

// Video and audio

    wire            fifo_err;

video_out video (
    // Held through every relock: the FIFO seeds its pointers only after a reset
    .rst(~pll_locked | pll_reconfiguring | apf_core_reset),
    .CLK_48M(clk_48m), .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hs(hs), .vs(vs),
    .hblank(core_hblank), .vblank(core_vblank),
    .width320(width320), .slot(video_slot), .pal(status[3]),
    .CLK_PIX(clk_pix), .CLK_PIX_90(clk_pix_90),
    .video_rgb(video_rgb), .video_rgb_clock(video_rgb_clock), .video_rgb_clock_90(video_rgb_clock_90),
    .video_de(video_de), .video_hs(video_hs), .video_vs(video_vs), .video_skip(video_skip),
    .fifo_err(fifo_err)
);

audio_i2s audio (
    .clk_74a(clk_74a), .clk_48m(clk_48m), .rst(1'b0), .l(snd_left), .r(snd_right),
    .audio_mclk(audio_mclk), .audio_lrck(audio_lrck), .audio_dac(audio_dac)
);

endmodule
`default_nettype wire
