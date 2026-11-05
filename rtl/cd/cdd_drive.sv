// SPDX-License-Identifier: GPL-3.0-only
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3 of the License only.

// The drive's microcontroller, in hardware: cdd_t of megacdd.cpp in MiSTer's Main, driven as neocd_poll of
// neogeocd.cpp drives it, proved line by line against the C++ by sim/cdd. Where it is not the C++:
// - The status word goes out when its command is done, not at the next poll. The word is the same, as Update
//   does not touch stat[], and drive.v takes it for the same exchange: its interrupts are 15.6 ms apart.
// - A request carries no length. MiSTer's first audio send after a seek is 4,704 bytes, a FIFO detail of
//   its SPI path; here it is one sector like the others.
// - The TOC past the last track is not read from the RAM: tracks[last].start is toc.end and the rest are 0.
// - neogeocd.cpp ignores SetCommand's answer, so a bad check nibble executes as any other. It is not looked at.
// - lid_open and disc_loading hold status at OPEN and TRAY. When they fall the drive does what neocd_set_image
//   does after Load: STOP with 10 of latency, or NO_DISC, and a reset at the next command. MiSTer has
//   neither here: its lid only goes to cd_sys, and its status is written directly while mounting.
// - Positions below the disc are requested as they are: req_lba goes negative in two's complement. MiSTer's
//   send carries no data then, and cd_fetch's read of it fails, which delivers nothing.
// - tracks[-1] and tracks[100 and past], undefined in the C++, read as tracks past the last.
// - MiSTer sends 0xFF when nRESET falls and keeps polling through the reset; this holds and answers at the rise,
//   reporting STOP for about 100 ms with no disc where MiSTer would report NO_DISC.
//
// Multiplies and divides are sequential, on one register and a table of constants: the drive has milliseconds
// and CLK_48M has no slack to give.
// LBA to BCD MSF subtracts 10 minutes, a minute, 10 seconds, a second and 10 frames, counting each digit; BCD
// MSF to LBA adds the same back; |lba - cur_lba| * 120 / 270000 subtracts 2,250 while it can. No multiplier.
// A seek takes under 8,000 clocks at any distance.
//
// A sector request never blocks anything. PLAY only sends when the last request is done and the sink is
// ready, and otherwise the tick passes, as CanSendData false does: if req_done never comes the position stops
// and commands are still answered, so the BIOS times out.
//
// nRESET is the core's reset only, as MiSTer, which sends megacdd its 0xFF reset command when nRESET falls.
// FF0181 is not in it, whatever an earlier interface comment says: that register resets drive.v inside
// cd_sys, the bus to the host, and there it stays.
// status_play means status is PLAY with no latency left: cdd_tick's speed counts only then.
`include "cd_defs.svh"

module cdd_drive import cd_defs::*; #(parameter int CLK_HZ = 48335658) (
    input             clk,
    input             nRESET,               // the core's reset only, see above
    input             tick,                 // one-clock pulse per poll interval (cdd_tick)
    input      [39:0] CDD_COMMAND_DATA,
    input             CDD_COMMAND_SEND,
    output reg [39:0] CDD_STATUS = 0,
    output reg        CDD_STATUS_LATCH = 0,
    input       [1:0] CD_SPEED,
    input             lid_open,             // TRAY_OPEN behaviour forced (debug setting)
    input             disc_present,
    input             disc_loading,
    input       [6:0] track_count,
    input      [23:0] disc_end,
    output reg  [6:0] toc_rd_track = 0,
    input toc_entry_t toc_rd_entry,         // one-clock read latency
    output reg [23:0] req_lba = 0,
    output reg        req_audio = 0,
    output reg  [6:0] req_file = 0,
    output reg [23:0] req_file_lba = 0,
    output reg        req_valid = 0,
    input             req_done,             // toggles; a new request only when equal
    input             sink_ready,           // CanSendData: CD_DATA_WR_READY or CDDA_WR_READY by req_audio
    output            status_play,          // PLAY with no latency left. Also for the bench and debug
    output            is_data,
    output     [23:0] cur_lba,
    output      [3:0] cur_status
);

typedef enum logic [4:0] {
    S_IDLE, S_CMD, S_TOC_WAIT, S_POS, S_CONV, S_DIGITS, S_TRACK5, S_ANSWER,
    S_ADD, S_TRACK_PLAY, S_SEEK, S_SEEK_DIV, S_SEEK_FIND,
    S_PLAY_A, S_PLAY_B, S_SCAN, S_SCAN_NEXT, S_SCAN_PREV
} state_t;

// The members of cdd_t that are state
reg         [3:0] status = CD_STAT_NO_DISC;
reg        [12:0] latency = 10;
reg               is_data_r = 1;
reg         [6:0] index = 0;
reg signed [23:0] lba = 0;
reg               scan_back = 0;
reg    [8:0][3:0] stat = 36'hB;     // stat[9] is computed
reg        [39:0] comm = 0;

// neocd_poll's
reg need_reset = 0, cmd_pending = 0, tick_pending = 0, mount_pending = 0, tray_old = 0;

state_t state = S_IDLE, ret = S_IDLE;
reg  [2:0] kind = 0;                // what TOC or IDLE answers: the TOC sub-command
reg [23:0] rem = 0;                 // the one number being worked on
reg  [2:0] phase = 0;               // which constant it is being worked on with
reg [5:0][3:0] dig = 0;             // m tens, m units, s tens, s units, f tens, f units

assign status_play = status == CD_STAT_PLAY && latency == 0;
assign is_data     = is_data_r;
assign cur_lba     = lba;
assign cur_status  = status;

// An unloaded cdd_t has an empty TOC
wire        loaded = disc_present;
wire  [6:0] last = loaded ? track_count : 7'd0;
wire [23:0] toc_end = loaded ? disc_end : 24'd0;

// tracks[toc_rd_track]
wire        beyond   = toc_rd_track >= last;
wire        e_audio  = beyond || toc_rd_entry.audio;    // type 0, also the empty entries
wire [23:0] e_start  = !beyond ? toc_rd_entry.start : toc_rd_track == last ? toc_end : 24'd0;
wire [23:0] e_stop   = beyond ? 24'd0 : toc_rd_entry.stop;

wire [15:0] k = phase == 0 ? 16'd45000 : phase == 1 ? 16'd4500 : phase == 2 ? 16'd750 : phase == 3 ? 16'd75 :
                phase == 4 ? 16'd10 : phase == 5 ? 16'd1 : 16'd2250;
wire [24:0] rem_sub = {1'b0, rem} - {9'd0, k};
wire        rem_ge  = !rem_sub[24];

localparam logic [23:0] LEAD_IN_24 = LEAD_IN, SCAN_24 = CD_SCAN_SPEED;
wire [23:0] lba_u = lba;
wire signed [23:0] seek_diff = $signed(rem) - lba;
wire signed [23:0] lba_inc = lba + 1'd1;
wire signed [23:0] e_start_s = $signed(e_start), e_stop_s = $signed(e_stop), rem_s = $signed(rem);

// comm[n] * 10 + comm[n + 1]: of the track of TOC 5, or of TRACK_PLAY
wire [3:0] trk_hi = comm[3:0] == CD_COMM_TOC ? comm[19:16] : comm[11:8];
wire [3:0] trk_lo = comm[3:0] == CD_COMM_TOC ? comm[23:20] : comm[15:12];
wire [7:0] track  = {1'b0, trk_hi, 3'd0} + {3'd0, trk_hi, 1'b0} + {4'd0, trk_lo};

// The formula of GetStatus. It keeps the low nibble, so 4 bits are enough
function automatic logic [3:0] status_check(input logic [35:0] s);
    logic [3:0] sum;
    sum = CRC_START;
    for (int i = 0; i < 9; i++) sum = sum + s[4 * i +: 4];
    return ~sum;
endfunction

// Reset
task do_reset;
    latency   <= 10;
    index     <= 0;
    lba       <= 0;
    scan_back <= 0;
    is_data_r <= 1;
    status    <= CD_STAT_STOP;
    stat      <= 0;
endtask

task read_toc(input logic [6:0] track_index, input state_t then_state);
    toc_rd_track <= track_index;
    ret          <= then_state;
    state        <= S_TOC_WAIT;
endtask

// To BCD digits from the digit of the first phase on, into dig: phase 0 for LBAToMSF, 4 for BCD
task convert(input logic [23:0] value, input logic [2:0] first_phase, input state_t then_state);
    rem   <= value;
    dig   <= 0;
    phase <= first_phase;
    ret   <= then_state;
    state <= S_CONV;
endtask

// The TOC sub-commands
task start_kind(input logic [2:0] sub);
    kind <= sub;
    case (sub)
        0, 1: read_toc(index, S_POS);
        2: convert({17'd0, index} + 1'd1, 3'd4, S_DIGITS);
        3: convert(toc_end + LEAD_IN_24, 3'd0, S_DIGITS);
        4: convert({17'd0, last}, 3'd4, S_DIGITS);
        5: read_toc(track[6:0] - 1'd1, S_POS);
        default: begin
            stat[8:2] <= 0;
            state     <= S_ANSWER;
        end
    endcase
endtask

// PLAY, SEEK: MSFToLBA, from a start that subtracts the lead-in, then SeekToLBA
task start_msf;
    rem   <= 24'd0 - LEAD_IN_24;
    dig   <= comm[31:8];
    phase <= 0;
    state <= S_ADD;
endtask

always @(posedge clk) begin
    CDD_STATUS_LATCH <= 0;

    case (state)
        S_IDLE:
            if (mount_pending) begin
                mount_pending <= 0;
                need_reset    <= 1;
                status        <= loaded ? CD_STAT_STOP : CD_STAT_NO_DISC;
                if (loaded) latency <= 10;
            end
            else if (cmd_pending) begin
                cmd_pending <= 0;
                state       <= S_CMD;
                if (need_reset || comm[15:0] == 16'h00FF) begin
                    need_reset <= 0;
                    do_reset;
                end
            end
            else if (tick_pending) begin
                // Update
                tick_pending <= 0;
                case (status)
                    CD_STAT_STOP, CD_STAT_TRAY, CD_STAT_OPEN:
                        if (latency != 0) latency <= latency - 1'd1;
                        else if (!loaded) status <= CD_STAT_NO_DISC;
                    CD_STAT_SEEK:
                        if (latency != 0) latency <= latency - 1'd1;
                        else status <= CD_STAT_PAUSE;
                    CD_STAT_PLAY:
                        if (latency != 0) latency <= latency - 1'd1;
                        else if (index >= last) status <= CD_STAT_END;
                        else if (req_valid == req_done) read_toc(index, S_PLAY_A);
                    CD_STAT_SCAN: begin
                        rem <= scan_back ? lba_u - SCAN_24 : lba_u + SCAN_24;
                        read_toc(index, S_SCAN);
                    end
                    default: ;
                endcase
            end

        // CommandExec
        S_CMD: begin
            state <= S_ANSWER;
            case (comm[3:0])
                CD_COMM_IDLE:
                    if (latency <= 3) begin
                        stat[0] <= status;
                        if (stat[1] == 4'hF) stat[1] <= 0;
                        if (stat[1] == 4'hF || stat[1] <= 2) start_kind(stat[1] == 4'hF ? 3'd0 : stat[1][2:0]);
                    end
                CD_COMM_STOP: begin
                    status    <= CD_STAT_STOP;
                    is_data_r <= 1;
                    stat      <= 0;
                end
                CD_COMM_TOC: begin
                    if (status == CD_STAT_STOP) status <= CD_STAT_TOC;
                    if (comm[15:12] <= 6) begin
                        stat[0] <= status == CD_STAT_STOP ? CD_STAT_TOC : status;
                        stat[1] <= comm[15:12];
                        start_kind(comm[14:12]);
                    end
                end
                CD_COMM_PLAY, CD_COMM_SEEK: start_msf;
                CD_COMM_PAUSE, CD_COMM_TRACK_MOVE: begin
                    is_data_r <= 1;
                    status    <= CD_STAT_PAUSE;
                    stat[0]   <= CD_STAT_PAUSE;
                end
                CD_COMM_RESUME: begin
                    status  <= CD_STAT_PLAY;
                    stat[0] <= CD_STAT_PLAY;
                end
                CD_COMM_FW_SCAN, CD_COMM_RW_SCAN: begin
                    scan_back <= comm[0];
                    status    <= CD_STAT_SCAN;
                    stat[0]   <= CD_STAT_SCAN;
                end
                CD_COMM_TRACK_PLAY: read_toc(track == 0 ? 7'd0 : track[6:0] - 1'd1, S_TRACK_PLAY);
                CD_COMM_TRAY_CLOSE: begin
                    is_data_r <= 1;
                    status    <= loaded ? CD_STAT_TOC : CD_STAT_NO_DISC;
                    stat[0]   <= CD_STAT_STOP;
                end
                CD_COMM_TRAY_OPEN: begin
                    is_data_r <= 1;
                    status    <= CD_STAT_OPEN;
                    stat[0]   <= CD_STAT_OPEN;
                end
                default: stat[0] <= status;
            endcase
        end

        S_TOC_WAIT: state <= ret;       // toc_rd_entry follows toc_rd_track by a clock

        S_POS: convert(kind == 0 ? lba_u + LEAD_IN_24 :
                       kind == 1 ? (lba < e_start_s ? e_start - lba_u : lba_u - e_start) :
                                   e_start + LEAD_IN_24, 3'd0, S_DIGITS);

        S_CONV:
            if (phase == 5) begin
                dig[5] <= rem[3:0];
                state  <= ret;
            end
            else if (rem_ge) begin
                rem        <= rem_sub[23:0];
                dig[phase] <= dig[phase] + 1'd1;
            end
            else phase <= phase + 1'd1;

        S_DIGITS: begin
            state <= S_ANSWER;
            case (kind)
                0, 1, 3: begin
                    stat[7:2] <= dig;
                    stat[8]   <= kind != 3 && !e_audio ? 4'h4 : 4'h0;
                end
                2: begin
                    stat[2] <= index < last ? dig[4] : 4'hA;
                    stat[3] <= index < last ? dig[5] : 4'hA;
                    if (comm[3:0] == CD_COMM_TOC) stat[8:4] <= 0;
                end
                4: stat[8:2] <= {12'd0, dig[5], dig[4], 4'd1, 4'd0};
                default: begin              // 5
                    stat[7:2] <= dig;
                    stat[6]   <= dig[4] | (e_audio ? 4'h0 : 4'h8);
                    convert({16'd0, track}, 3'd4, S_TRACK5);
                end
            endcase
        end

        S_TRACK5: begin
            stat[8] <= dig[5];
            state   <= S_ANSWER;
        end

        S_ANSWER: begin
            CDD_STATUS       <= {status_check(stat), stat};
            CDD_STATUS_LATCH <= 1;
            state            <= S_IDLE;
        end

        S_ADD:
            if (dig[phase] != 0) begin
                rem        <= rem + k;
                dig[phase] <= dig[phase] - 1'd1;
            end
            else if (phase == 5) state <= S_SEEK;
            else phase <= phase + 1'd1;

        S_TRACK_PLAY: begin
            rem   <= e_start;
            state <= S_SEEK;
        end

        // SeekToLBA: rem is the new position
        S_SEEK: begin
            lba     <= rem_s;
            rem     <= seek_diff[23] ? -seek_diff : seek_diff;
            latency <= comm[3:0] == CD_COMM_SEEK ? 13'd0 : 13'd11;
            phase   <= 6;
            state   <= S_SEEK_DIV;
        end

        S_SEEK_DIV:
            if (rem_ge) begin
                rem     <= rem_sub[23:0];
                latency <= latency + 1'd1;
            end
            else begin
                index <= 0;
                read_toc(7'd0, S_SEEK_FIND);
            end

        S_SEEK_FIND:
            if (index < last && e_stop_s <= lba) begin
                index <= index + 1'd1;
                read_toc(index + 1'd1, S_SEEK_FIND);
            end
            else begin
                is_data_r <= 1;
                status    <= comm[3:0] == CD_COMM_SEEK ? CD_STAT_SEEK : CD_STAT_PLAY;
                stat      <= {28'd0, 4'hF, CD_STAT_SEEK};
                state     <= S_ANSWER;
            end

        // Update, PLAY. req_audio picks what sink_ready means, so it goes first
        S_PLAY_A: begin
            req_audio <= e_audio;
            state     <= S_PLAY_B;
        end

        S_PLAY_B: begin
            state <= S_IDLE;
            if (sink_ready) begin
                if (e_audio && lba >= e_start_s) is_data_r <= 0;
                req_lba      <= lba_u;
                req_file     <= toc_rd_entry.file;
                req_file_lba <= lba_u - e_start + toc_rd_entry.file_lba;
                req_valid    <= ~req_valid;
                lba          <= lba_inc;
                if (lba_inc >= e_stop_s) begin
                    index     <= index + 1'd1;
                    is_data_r <= 1;
                end
            end
        end

        // Update, SCAN: rem is the new position
        S_SCAN: begin
            state <= S_IDLE;
            if (rem_s >= e_stop_s) begin
                index <= index + 1'd1;
                if (index + 1'd1 < last) read_toc(index + 1'd1, S_SCAN_NEXT);
                else begin
                    lba       <= $signed(toc_end);
                    status    <= CD_STAT_END;
                    is_data_r <= 1;
                end
            end
            else if (rem_s < e_start_s) begin
                if (index != 0) begin
                    index <= index - 1'd1;
                    read_toc(index - 1'd1, S_SCAN_PREV);
                end
                else begin
                    lba       <= 0;
                    is_data_r <= !e_audio;
                end
            end
            else begin
                lba       <= rem_s;
                is_data_r <= !e_audio;
            end
        end

        S_SCAN_NEXT: begin
            lba       <= e_start_s;
            is_data_r <= !e_audio;
            state     <= S_IDLE;
        end

        S_SCAN_PREV: begin
            lba       <= e_stop_s;
            is_data_r <= !e_audio;
            state     <= S_IDLE;
        end

        default: state <= S_IDLE;
    endcase

    // These come whatever the state is doing
    if (CDD_COMMAND_SEND) begin
        comm        <= CDD_COMMAND_DATA;
        cmd_pending <= 1;
    end
    if (tick) tick_pending <= 1;
    tray_old <= lid_open | disc_loading;
    if (tray_old && !(lid_open | disc_loading)) mount_pending <= 1;

    // The 0xFF that MiSTer sends when nRESET falls runs as a command, and answers
    if (!nRESET) begin
        do_reset;
        state         <= S_IDLE;
        comm          <= 40'hFF;
        cmd_pending   <= 1;
        tick_pending  <= 0;
        mount_pending <= 0;
        need_reset    <= 0;
        req_valid     <= req_done;
    end

    if (lid_open) begin
        status    <= CD_STAT_OPEN;
        is_data_r <= 1;
    end
    else if (disc_loading) status <= CD_STAT_TRAY;
end

endmodule

// The poll interval of neogeocd.cpp: 10 ms, and by the CD speed setting 10, 5, 4 or 2 ms while fast
module cdd_tick #(parameter int CLK_HZ = 48335658) (
    input            clk,
    input            nRESET,
    input      [1:0] speed,
    input            fast,      // is_data & status_play: speed counts only for data with no latency left
    output reg       tick = 0
);

localparam int P_10MS = CLK_HZ / 100, P_5MS = CLK_HZ / 200, P_4MS = CLK_HZ / 250, P_2MS = CLK_HZ / 500;

reg  [$clog2(P_10MS)-1:0] cnt = 0;
wire [$clog2(P_10MS)-1:0] last = !fast || speed == 0 ? P_10MS - 1 : speed == 1 ? P_5MS - 1 :
                                 speed == 2 ? P_4MS - 1 : P_2MS - 1;

always @(posedge clk) begin
    tick <= 0;
    if (!nRESET) cnt <= 0;
    else if (cnt >= last) begin
        cnt  <= 0;
        tick <= 1;
    end
    else cnt <= cnt + 1'd1;
end

endmodule
