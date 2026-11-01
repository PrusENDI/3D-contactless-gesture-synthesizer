// Independent V2 top-level boundary.
//
// The legacy mgc3130_uart_top remains the V1 baseline. This top owns the V2
// clock/reset, byte protocol endpoint, input/calibration/cursor path, separate
// LIVE and LOOP event paths, voice engine, reduced FX and I2S transmitter.
// USE_MGC_READER=0 is the deterministic simulation/P&R diagnostic mode; the
// board build enables the existing MGC3130 reader through the parameter.
module mgc3130_v2_top #(
    parameter integer USE_MGC_READER = 0,
    parameter integer UART_BAUD = 1_000_000,
    // Loop commit waits for a musical boundary but must not remain queued
    // forever. The contract allows 34 seconds at 100 MHz; short overrides are
    // used by simulation to exercise the timeout path quickly.
    parameter [31:0] BOUNDARY_TIMEOUT_CYCLES = 32'd3_400_000_000,
    // The board build uses the explicit GW5A DPB state bank. A portable
    // simulation can override this to 0 and exercise the same engine with
    // the RTL memory model.
    parameter integer USE_GOWIN_RAM = 1,
    // Read-only debug CSRs for the wavetable uploader (0x80..0x90).  Set to 0 in a
    // shipping build to let synthesis prune them.
    parameter integer V2_DEBUG_CSR = 1,
    // The full Potts implementation is verified standalone. The default top
    // probe keeps it out of Gowin's 2000-iteration parser limit; a final build
    // must enable it after replacing the unbounded combinational scan with the
    // measured bounded implementation.
    parameter integer USE_POTTS = 0,
    // Timing-only structural probe option. Production/board builds leave it
    // disabled, so UART mode control remains the sole LOOP run source.
    parameter integer PRESERVE_LOOP_PLANE = 0,
    // Timing-only deterministic sensor activity. Production/board builds
    // leave this disabled and use the actual MGC3130 reader.
    parameter integer PRESERVE_INPUT_PLANE = 0,
    parameter integer PRESERVE_INPUT_VALID = 0,
    // Timing-probe-only Potts activity. Production builds keep this disabled;
    // COMMIT through the V2 UART remains the normal start source.
    parameter integer PRESERVE_POTTS_PLANE = 0,
    parameter integer POTTS_HORIZON = 128,
    // Reduced FX is a build-time default until the application CSR is
    // promoted into the audio configuration plane. The board probe enables
    // this path so P&R cannot silently sweep it away.
    parameter integer FX_ENABLE = 0,
    parameter integer FX_LEVEL = 0
) (
    input  wire clk_50m,
    inout  wire mgc_sda,
    inout  wire mgc_scl,
    inout  wire mgc_ts,
    inout  wire mgc_mclr,
    input  wire uart_rx,
    output wire uart_tx,
    output wire pcm5102a_bck,
    output wire pcm5102a_lrck,
    output wire pcm5102a_din
);
    import v2_contract_pkg::*;

    logic clk_sys_100m, pll_locked, rst_sys_n;
    v2_clock_gen u_clock(.clk_in(clk_50m), .rst_n(1'b1),
                         .clk_sys_100m(clk_sys_100m), .pll_locked(pll_locked));
    logic [3:0] por_count = 4'd0;
    wire por_n = &por_count;
    always_ff @(posedge clk_sys_100m or negedge pll_locked) begin
        if (!pll_locked) por_count <= 4'd0;
        else if (!por_n) por_count <= por_count + 1'b1;
    end
    v2_reset_sync u_reset(.clk_sys_100m(clk_sys_100m), .rst_n(por_n),
                          .pll_locked(pll_locked), .rst_sys_n(rst_sys_n));

    logic sample_ce;
    logic [31:0] sample_index;
    v2_sample_scheduler u_scheduler(.clk_sys(clk_sys_100m), .rst_n(rst_sys_n),
                                    .sample_ce(sample_ce), .sample_index(sample_index));

    logic report_valid, xyz_valid, touch_valid, report_error, reader_busy;
    logic [31:0] touch_info;
    logic [15:0] x_position, y_position, z_position;
    logic [7:0] gesture_code, reader_error_code;
    logic [31:0] reader_debug_context;
    logic [15:0] reader_debug_mask;
    logic [7:0] reader_debug_size;
logic [5:0] reader_state;

    wire mgc_mclr_drive_low, mgc_ready;
    assign mgc_mclr = mgc_mclr_drive_low ? 1'b0 : 1'bz;

    // Sensor power-on sequence: hold MCLR low, then give the sensor time to boot.
    // The reader stays in reset until mgc_ready, which is what the working
    // reference design did; without it the sensor never asserts TS.
    mgc3130_reset_seq #(.CLK_HZ(80_000_000), .RESET_LOW_MS(250), .STARTUP_WAIT_MS(2000))
    u_reset_seq (.clk(clk_sys_100m), .mclr_drive_low(mgc_mclr_drive_low), .ready(mgc_ready));

    generate
        if (USE_MGC_READER) begin : g_sensor
            mgc3130_reader #(.CLK_HZ(80_000_000), .I2C_HZ(100_000), .I2C_ADDR(7'h42))
            u_reader (
                .clk(clk_sys_100m), .rst_n(rst_sys_n), .i2c_sda(mgc_sda), .i2c_scl(mgc_scl),
                .mgc_ts(mgc_ts), .report_valid(report_valid), .xyz_valid(xyz_valid),
                .touch_valid(touch_valid), .touch_info(touch_info), .x_position(x_position),
                .y_position(y_position), .z_position(z_position), .gesture_code(gesture_code),
                .report_error(report_error), .error_code(reader_error_code), .busy(reader_busy),
                .debug_error_context(reader_debug_context), .debug_output_mask(reader_debug_mask),
                .debug_message_size(reader_debug_size), .debug_state(reader_state)
            );
        end else begin : g_sensor_stub
            assign mgc_sda = 1'bz; assign mgc_scl = 1'bz; assign mgc_ts = 1'bz;
            if (PRESERVE_INPUT_PLANE) begin : g_input_probe
                assign report_valid = (sample_index[2:0] == 3'd0);
                // Exercise transport/touch metadata. The structural timing
                // probe normally keeps this invalid; a separate valid-input
                // diagnostic can enable the parameter explicitly.
                assign xyz_valid = PRESERVE_INPUT_VALID ? 1'b1 : 1'b0;
                assign touch_valid = report_valid;
                assign report_error = 1'b0;
                assign touch_info = {28'd0, sample_index[3:0]};
                assign x_position = 16'h8000 + sample_index[15:0];
                assign y_position = 16'h8000 + {8'd0, sample_index[7:0]};
                assign z_position = 16'h4000 + {8'd0, sample_index[7:0]};
                assign gesture_code = sample_index[7:0];
            end else begin : g_input_idle
                assign report_valid = 1'b0; assign xyz_valid = 1'b0;
                assign touch_valid = 1'b0; assign report_error = 1'b0;
                assign touch_info = 32'd0; assign x_position = 16'd0;
                assign y_position = 16'd0; assign z_position = 16'd0;
                assign gesture_code = 8'd0;
            end
            assign reader_error_code = 8'd0;
            assign reader_state = 6'd0;
            assign reader_busy = 1'b0; assign reader_debug_context = 32'd0;
            assign reader_debug_mask = 16'd0; assign reader_debug_size = 8'd0;
        end
    endgenerate
    assign mgc_mclr = 1'bz;

    logic input_valid, input_xyz_valid, input_report_valid, input_report_error;
    logic input_touch_valid;
    logic [31:0] input_touch_info;
    logic [15:0] input_x, input_y, input_z, input_sequence;
    logic [7:0] input_gesture, input_epoch;
    logic signed [16:0] raw_x, raw_y;
    logic [16:0] raw_z;
    logic frame_valid, frame_gap, frame_saturated, frame_touch, frame_presence;
    logic frame_xyz_valid, frame_report_error, frame_touch_field_valid;
    logic [31:0] input_timestamp;
    logic [31:0] v2_touch_info;
    mgc3130_input_latch u_input_latch (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .report_valid(report_valid),
        .xyz_valid(xyz_valid), .report_error(report_error), .x_position(x_position),
        .y_position(y_position), .z_position(z_position), .gesture_code(gesture_code),
        .input_valid(input_valid), .xyz_valid_latched(input_xyz_valid), .x_latched(input_x),
        .y_latched(input_y), .z_latched(input_z), .gesture_latched(input_gesture),
        .touch_info(touch_info), .touch_valid(touch_valid),
        .report_valid_latched(input_report_valid), .report_error_latched(input_report_error),
        .touch_valid_latched(input_touch_valid), .touch_info_latched(input_touch_info),
        .v2_sequence(input_sequence), .v2_timestamp_ticks(input_timestamp), .v2_raw_x(raw_x),
        .v2_raw_y(raw_y), .v2_raw_z(raw_z), .v2_frame_valid(frame_valid), .v2_gap(frame_gap),
        .v2_saturated(frame_saturated), .v2_calibration_epoch(input_epoch), .v2_touch(frame_touch),
        .v2_presence(frame_presence), .v2_xyz_valid(frame_xyz_valid),
        .v2_report_error(frame_report_error), .v2_touch_field_valid(frame_touch_field_valid),
        .v2_touch_info(v2_touch_info), .v2_saturated_in(1'b0), .v2_sequence_valid(1'b0),
        .v2_sequence_in(16'd0)
    );

    logic profile_shadow_we, profile_commit;
    logic [2:0] profile_init;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin profile_init <= 0; profile_shadow_we <= 0; profile_commit <= 0; end
        else begin
            profile_shadow_we <= 1'b0; profile_commit <= 1'b0;
            if (profile_init == 0) begin profile_shadow_we <= 1'b1; profile_init <= 1; end
            else if (profile_init == 1) begin profile_commit <= 1'b1; profile_init <= 2; end
        end
    end

    logic signed [31:0] calibrated_x, calibrated_y, calibrated_z;
    logic [15:0] calibrated_sequence;
    logic [31:0] calibrated_timestamp;
    logic calibrated_touch, calibrated_presence, calibrated_valid, calibrated_saturated, calibrated_gap;
    logic [7:0] calibrated_epoch, calibration_reason;
    logic [7:0] active_epoch;
    logic active_profile_valid, calibration_strobe;
    logic signed [31:0] frame_cal_x, frame_cal_y, frame_cal_z;
    logic [15:0] frame_cal_sequence;
    logic [31:0] frame_cal_timestamp;
    logic [7:0] frame_cal_reason;
    logic frame_cal_valid;
    v2_input_calibration u_calibration (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(frame_valid),
        .raw_x(raw_x), .raw_y(raw_y), .raw_z(raw_z), .sequence_id(input_sequence),
        .timestamp_ticks(input_timestamp), .valid_xyz(frame_xyz_valid), .saturated(frame_saturated),
        .gap(frame_gap), .calibration_epoch_in(input_epoch), .touch(frame_touch),
        .presence(frame_presence), .profile_shadow_we(profile_shadow_we), .profile_commit(profile_commit),
        .shadow_neutral_x(0), .shadow_neutral_y(0), .shadow_neutral_z(0),
        .shadow_coupling_x(0), .shadow_coupling_y(0), .shadow_gain_x(32'sd65536),
        .shadow_gain_y(32'sd65536), .shadow_gain_z(32'sd65536),
        .shadow_ws_x_min(0), .shadow_ws_x_max(32'sd65535),
        .shadow_ws_y_min(0), .shadow_ws_y_max(32'sd65535),
        .shadow_ws_z_min(0), .shadow_ws_z_max(32'sd65535), .shadow_epoch(8'd0),
        .calibrated_x(calibrated_x), .calibrated_y(calibrated_y), .calibrated_z(calibrated_z),
        .output_sequence(calibrated_sequence), .output_timestamp_ticks(calibrated_timestamp),
        .output_touch(calibrated_touch), .output_presence(calibrated_presence),
        .output_valid(calibrated_valid), .output_saturated(calibrated_saturated),
        .output_gap(calibrated_gap), .output_calibration_epoch(calibrated_epoch),
        .calibration_reason(calibration_reason), .active_epoch(active_epoch),
        .active_profile_valid(active_profile_valid), .frame_output_strobe(calibration_strobe),
        .frame_calibrated_x(frame_cal_x), .frame_calibrated_y(frame_cal_y),
        .frame_calibrated_z(frame_cal_z), .frame_output_sequence(frame_cal_sequence),
        .frame_output_timestamp_ticks(frame_cal_timestamp), .frame_output_reason(frame_cal_reason),
        .frame_output_valid(frame_cal_valid)
    );

    logic valid_frame, lost_frame, degraded_frame, note_permitted;
    logic [15:0] gap_count;
    logic [7:0] valid_reason;
    v2_position_validity u_validity (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(calibration_strobe),
        .valid_xyz(frame_cal_valid), .saturated(calibrated_saturated), .gap(calibrated_gap),
        .sequence_id(frame_cal_sequence), .calibration_epoch(calibrated_epoch),
        .active_epoch(active_epoch), .active_profile_valid(active_profile_valid),
        .calibration_reason_in(frame_cal_reason), .frame_valid(valid_frame), .lost(lost_frame),
        .degraded(degraded_frame), .gap_count(gap_count), .calibration_reason(valid_reason),
        .note_permitted(note_permitted)
    );

    logic signed [31:0] cursor_x, cursor_y, cursor_z;
    logic [15:0] cursor_pitch, cursor_velocity, cursor_depth;
    logic [1:0] cursor_state;
logic [4:0] cursor_fsm_state;
// Latched on every accepted frame: a declaration initialiser runs once at time 0
// and would freeze the value, which is exactly what an earlier probe misread.
logic signed [31:0] cursor_last_z;
    logic cursor_point_valid, cursor_rebased, cursor_stable_valid;
    logic signed [31:0] audio_cursor_x, audio_cursor_y, audio_cursor_z;
    logic [15:0] audio_pitch, audio_velocity, audio_depth, audio_sequence;
    logic audio_cursor_valid;
    logic [31:0] audio_timestamp;
    logic cursor_frame_done;
    v2_cursor_filter_timed u_cursor (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(valid_frame),
        .frame_x(frame_cal_x), .frame_y(frame_cal_y), .frame_z(frame_cal_z),
        .frame_valid(valid_frame), .frame_saturated(calibrated_saturated), .frame_gap(calibrated_gap),
        .frame_degraded(degraded_frame), .calibration_reason(valid_reason),
        .frame_sequence(frame_cal_sequence), .frame_timestamp(frame_cal_timestamp),
        .left_edge(1'b1), .sample_ce(sample_ce), .dbg_fsm_state(cursor_fsm_state), .cursor_x(cursor_x), .cursor_y(cursor_y),
        .cursor_z(cursor_z), .normalized_pitch(cursor_pitch), .velocity_control(cursor_velocity),
        .depth_control(cursor_depth), .state(cursor_state), .point_valid(cursor_point_valid),
        .rebased(cursor_rebased), .stable_valid(cursor_stable_valid), .audio_cursor_x(audio_cursor_x),
        .audio_cursor_y(audio_cursor_y), .audio_cursor_z(audio_cursor_z), .audio_pitch(audio_pitch),
        .audio_velocity(audio_velocity), .audio_depth(audio_depth), .audio_valid(audio_cursor_valid),
        .audio_sequence(audio_sequence), .audio_timestamp(audio_timestamp), .frame_output_valid(cursor_frame_done)
    );

    logic [95:0] live_event_data, record_event_data /* synthesis syn_keep=1 */;
    logic voice_event_ready;
    logic live_event_valid /* synthesis syn_keep=1 */;
    logic live_event_ready;
    logic record_event_ready /* synthesis syn_keep=1 */;
    logic [3:0] live_event_type; logic [7:0] live_event_note, live_event_velocity;
    logic [15:0] live_event_count; logic [7:0] live_fault;
    logic live_left_edge, live_gate, live_active; logic [7:0] live_active_note;
    logic [31:0] mode_reg;
    // THRESHOLDS[7:0] is the WT_PLAY test note (0 keeps the legacy 46.875 Hz walk)
    // THRESHOLDS[23] selects the LIVE rule: 0 = frame-level tracking, 1 = step arpeggiator.
    // Host writes 0x0180_00NN to enable it (low half below the high half keeps the
    // contract's THRESHOLDS validity rule satisfied).
    logic [31:0] thresholds_reg;
    logic [15:0] bpm_reg;
    // X axis drives the arpeggiator tempo in LIVE: cursor_x 0..65535 -> 30..59 BPM.
    // The mapping lives in v2_live_tempo because it must update on cursor frames,
    // not on UART command arrival (it used to sit inside the command gate and the
    // divider kept its 120 BPM reset value forever).
    logic [15:0] bpm_auto_q;
    logic        bpm_auto_we;
    v2_live_tempo u_live_tempo (
        .clk(clk_sys_100m), .rst_n(rst_sys_n),
        .frame_done(cursor_frame_done), .x(cursor_x[15:0]),
        .bpm(bpm_auto_q), .bpm_we(bpm_auto_we)
    );
    logic        bpm_we_q;
    wire         bpm_write;
    logic        tick_pulse;
    logic [6:0]  tick_now;
    logic [23:0] samples_per_tick;
    wire mode_live = (mode_reg == LIVE);
    // The tempo mapping runs in every mode, so its single write pulse usually
    // happens while IDLE masks bpm_auto_we away from the divider.  Entering LIVE
    // must therefore reprogram the divider once with the already-settled tempo.
    logic mode_live_q;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) mode_live_q <= 1'b0;
        else            mode_live_q <= mode_live;
    end
    wire bpm_sel_we = (mode_live ? bpm_auto_we : bpm_we_q) || (mode_live && !mode_live_q);
    wire mode_record = (mode_reg == RECORD);
    wire mode_play = (mode_reg == PLAY);
wire mode_wt_play = (mode_reg == WT_PLAY);
// Cursor engagement as a level, not a pulse: point_valid lasts one cycle and must not
// be used as a per-frame validity or gate.
wire cursor_engaged = (cursor_state == 2'd1) || (cursor_state == 2'd2);
logic [9:0] wt_play_index;
logic signed [15:0] wt_play_sample;
logic wt_play_valid;
logic [9:0] wt_read_index_sel;
    v2_live_rule_engine #(.PIPELINE_NOTE(1)) u_live (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .frame_in_valid(cursor_frame_done),
        .frame_valid(cursor_frame_done && cursor_engaged), .frame_degraded(degraded_frame),
        .frame_gap(calibrated_gap), .rebased(cursor_rebased), .left_edge(1'b1),
        .x(cursor_x[15:0]), .y(cursor_y[15:0]), .z(cursor_z[15:0]),
        .touch(cursor_engaged), .bow(cursor_engaged), .tick(sample_index),
        .arp_mode(thresholds_reg[23]), .tick_pulse(tick_pulse), .mtick(tick_now),
        .velocity_in(cursor_velocity[7:0]), .brightness_in(cursor_depth), .gain_in(16'hffff),
        .event_valid(live_event_valid), .event_ready(live_event_ready), .event_data(live_event_data),
        .event_type(live_event_type), .event_note(live_event_note), .event_velocity(live_event_velocity),
        .event_count(live_event_count), .fault_code(live_fault), .left_edge_armed(live_left_edge),
        .gate_state(live_gate), .active(live_active), .active_note(live_active_note)
    );

    logic record_start, record_stop, record_abort;
    logic record_write_valid /* synthesis syn_keep=1 */;
    logic record_write_ready /* synthesis syn_keep=1 */;
    logic [15:0] record_count /* synthesis syn_keep=1 */;
    logic [5:0] record_track_count [0:5] /* synthesis syn_keep=1 */;
    logic [7:0] record_fault /* synthesis syn_keep=1 */;
    logic record_left_edge, record_gate;
    logic recording /* synthesis syn_keep=1 */;
    logic [2:0] selected_track;
    logic loop_ctrl_valid, loop_ctrl_ready, loop_ctrl_done;
    logic [2:0] loop_ctrl_op, loop_ctrl_track;
    logic loop_ctrl_pending;
    logic [2:0] loop_ctrl_pending_op;
    wire loop_probe_run = (PRESERVE_LOOP_PLANE != 0) ? sample_index[0] : mode_play;
    wire loop_probe_record_start = (PRESERVE_LOOP_PLANE != 0) && (sample_index == 32'd16);
    wire loop_probe_record_stop = (PRESERVE_LOOP_PLANE != 0) && (sample_index == 32'd32);
    logic [95:0] recorder_event_data;
    logic [4:0] recorder_write_slot;
    assign recorder_event_data = {live_event_data[95:91], selected_track,
                                  live_event_data[87:0]};
    // The recorder increments track_event_count when it fills its holding
    // register. The store still needs the pre-increment slot number.
    assign recorder_write_slot = record_track_count[record_event_data[90:88]][4:0]
                               - (record_write_valid ? 5'd1 : 5'd0);
    (* keep_hierarchy = "yes" *)
    (* syn_noprune = 1 *)
    v2_loop_event_recorder u_recorder (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .record_start(record_start),
        .record_stop(record_stop), .abort(record_abort), .event_valid(live_event_valid),
        .event_ready(record_event_ready), .event_data(recorder_event_data),
        .event_tick(sample_index), .write_ready(record_write_ready),
        .loop_write_valid(record_write_valid), .loop_write_data(record_event_data),
        .read_req(1'b0), .read_track(3'd0), .read_index(5'd0), .read_valid(), .read_data(),
        .event_count(record_count), .track_event_count(record_track_count),
        .fault_code(record_fault), .left_edge_armed(record_left_edge),
        .gate_state(record_gate), .recording(recording)
    );
    assign live_event_ready = mode_live ? voice_event_ready : mode_record ? record_event_ready : 1'b0;

    logic [95:0] loop_event_data /* synthesis syn_keep=1 */;
    logic loop_event_valid /* synthesis syn_keep=1 */;
    logic loop_event_ready;
    logic loop_read_enable /* synthesis syn_keep=1 */;
    logic loop_read_valid /* synthesis syn_keep=1 */;
    logic loop_read_slot_valid /* synthesis syn_keep=1 */;
    logic [2:0] loop_read_track; logic [4:0] loop_read_index;
    logic [95:0] loop_read_data;
    logic loop_boundary /* synthesis syn_keep=1 */;
    logic loop_commit_pending /* synthesis syn_keep=1 */;
    logic loop_commit_ack, loop_busy;
    logic loop_commit_timeout;
    logic [31:0] loop_commit_wait_cycles;
    logic [35:0] loop_record_count /* synthesis syn_keep=1 */;
    logic [5:0] loop_overflow /* synthesis syn_keep=1 */;
    logic loop_active_valid /* synthesis syn_keep=1 */;
    // The store's single write port belongs to the recorder, except while a
    // commit streams the Potts result into the shadow lead track.
    logic potts_commit_kick, potts_commit_run, potts_commit_done, potts_commit_req;
    logic [5:0] potts_commit_count;
    logic potts_writer_start, potts_writer_ready, potts_writer_valid;
    logic [4:0] potts_writer_slot;
    logic loop_write_valid, loop_write_ready;
    logic [4:0] loop_write_slot;
    logic [2:0] loop_write_track;
    logic [95:0] loop_write_data;

    (* keep_hierarchy = "yes" *)
    v2_loop_event_store_dpb #(.BOUNDARY_TIMEOUT_CYCLES(BOUNDARY_TIMEOUT_CYCLES)) u_store (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .abort(record_abort), .loop_boundary(loop_boundary),
        .ctrl_valid(loop_ctrl_valid), .ctrl_ready(loop_ctrl_ready), .ctrl_op(loop_ctrl_op),
        .ctrl_track(loop_ctrl_track), .ctrl_done(loop_ctrl_done),
        .write_valid(loop_write_valid), .write_ready(loop_write_ready),
        .write_track(loop_write_track),
        .write_slot(loop_write_slot),
        .write_data(loop_write_data), .read_enable(loop_read_enable), .read_track(loop_read_track),
        .read_index(loop_read_index), .read_valid(loop_read_valid), .read_slot_valid(loop_read_slot_valid),
        .read_data(loop_read_data), .active_bank(), .shadow_bank(), .commit_pending(loop_commit_pending),
        .commit_ack(loop_commit_ack), .busy(loop_busy), .record_count(loop_record_count),
        .overflow(loop_overflow), .active_valid(loop_active_valid),
        .commit_timeout(loop_commit_timeout), .commit_wait_cycles(loop_commit_wait_cycles)
    );
    (* keep_hierarchy = "yes" *)
    v2_loop_scheduler #(.LOOP_TICKS(32)) u_loop_sched (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .run(loop_probe_run), .stop(!loop_probe_run), .flush(1'b0),
        .tick_start(tick_pulse),
        .selected_track(selected_track), .loop_tick(tick_now), .read_valid(loop_read_valid),
        .read_slot_valid(loop_read_slot_valid), .read_data(loop_read_data),
        .read_enable(loop_read_enable), .read_track(loop_read_track), .read_index(loop_read_index),
        .event_valid(loop_event_valid), .event_ready(loop_event_ready), .event_data(loop_event_data),
        .fault_valid(), .loop_boundary(loop_boundary)
    );

    // Keep a narrow, low-fanout observability point for the independent V2
    // loop plane.  The production top does not route this signature to a
    // board pin; the timing probe observes it hierarchically.  Registering
    // the signature makes the recorder/store/scheduler state part of the
    // retained sequential cone without preserving the wide mode/control
    // buses that caused the timed19 fanout regression.
    (* keep = "true", syn_keep = 1, syn_noprune = 1 *)
    logic [17:0] v2_loop_debug_signature;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            v2_loop_debug_signature <= 18'd0;
        end else begin
            v2_loop_debug_signature <= {
                loop_ctrl_pending, loop_ctrl_valid, loop_ctrl_ready,
                loop_busy, loop_commit_pending, loop_active_valid,
                loop_boundary, loop_event_valid, loop_read_valid,
                loop_read_slot_valid, loop_read_enable,
                recording, record_write_valid, record_write_ready,
                record_left_edge, record_gate, (|record_count),
                (|loop_record_count), (|loop_overflow)
            };
        end
    end

    logic signed [15:0] potts_contour [0:127];
    logic [127:0] potts_rest_mask;
    logic potts_busy, potts_done, potts_overflow, potts_backtrace_valid;
    logic potts_event_valid, potts_event_ready; logic [95:0] potts_event_data; logic [5:0] potts_event_count;
    logic [15:0] potts_lambda;
    integer contour_i;

    // The contour is sampled once per musical tick from the cursor, not tapped
    // off the LIVE event stream: the two paths are independent, and the event
    // tick field is only valid in arpeggiator mode.
    logic potts_capture_arm, potts_capture_full;
    logic [31:0] potts_valid, potts_purified;
    logic [15:0] potts_samples [0:31];
    logic [4:0] contour_rd_index;
    logic [15:0] contour_rd_data;
    logic potts_purify_start, potts_purify_busy, potts_purify_done, potts_purify_done_seen;

    v2_loop_contour_capture #(.K(32)) u_contour (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .arm(potts_capture_arm),
        .tick_pulse(tick_pulse), .mtick(tick_now),
        .y(cursor_y[15:0]), .engaged(cursor_engaged),
        .rd_index(contour_rd_index), .rd_data(contour_rd_data),
        .samples(potts_samples), .valid_mask(potts_valid), .full(potts_capture_full)
    );

    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) potts_purify_done_seen <= 1'b0;
        else if (potts_capture_arm) potts_purify_done_seen <= 1'b0;
        else if (potts_purify_done) potts_purify_done_seen <= 1'b1;
    end
    // The purifier must run for every commit, not only after a full capture:
    // an early COMMIT still has to absorb the short runs of whatever was
    // captured, otherwise the DP sees a stale mask from the previous take.
    assign potts_purify_start = !potts_purify_done_seen &&
                                (potts_capture_full || potts_commit_kick);

    // Absorb rest runs shorter than the DP's minimum segment length, otherwise
    // a two-tick hand-off leaves the DP with no valid segmentation at all.
    v2_loop_rest_purify #(.K(32)) u_purify (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .start(potts_purify_start),
        .raw_valid(potts_valid), .purified_valid(potts_purified),
        .busy(potts_purify_busy), .done(potts_purify_done)
    );

    always_comb begin
        for (contour_i = 0; contour_i < 128; contour_i = contour_i + 1)
            potts_contour[contour_i] = (contour_i < 32)
                ? $signed({6'd0, potts_samples[contour_i]})
                : 16'sd0;
    end
    assign potts_rest_mask = {{96{1'b1}}, ~potts_purified};

    generate if (USE_POTTS) begin : g_potts
    // Hold the DP until the purifier has produced the mask it will read.
    wire potts_run_start = (PRESERVE_POTTS_PLANE != 0)
        ? (sample_index == 32'd64)
        : potts_writer_start;
    v2_potts_commit_fsm #(.HORIZON(POTTS_HORIZON)) u_potts (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .start(potts_run_start), .lambda_q16(potts_lambda),
        .rest_mask(potts_rest_mask), .contour(potts_contour), .busy(potts_busy), .progress(), .done(potts_done),
        .overflow(potts_overflow), .backtrace_valid(potts_backtrace_valid), .event_valid(potts_event_valid),
        .event_ready(potts_event_ready), .event_data(potts_event_data), .event_count(potts_event_count)
    );
    end else begin : g_potts_stub
        assign potts_busy = 1'b0; assign potts_done = 1'b0; assign potts_overflow = 1'b0;
        assign potts_backtrace_valid = 1'b0; assign potts_event_valid = 1'b0;
        assign potts_event_data = 96'd0; assign potts_event_count = 6'd0;
    end endgenerate

    // While the writer runs, the Potts event stream owns the store's single
    // write port and targets the lead track; otherwise the recorder keeps it.
    assign loop_write_valid = potts_commit_run ? potts_writer_valid : record_write_valid;
    assign loop_write_track = potts_commit_run ? 3'd0 : record_event_data[90:88];
    assign loop_write_slot  = potts_commit_run ? potts_writer_slot : recorder_write_slot;
    assign loop_write_data  = potts_commit_run ? potts_event_data : record_event_data;
    assign record_write_ready = potts_commit_run ? 1'b0 : loop_write_ready;

    v2_loop_commit_writer u_commit_writer (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .kick(potts_commit_kick),
        .dp_ready(potts_purify_done_seen),
        .potts_start(potts_writer_start), .potts_busy(potts_busy), .potts_done(potts_done),
        .potts_event_valid(potts_event_valid), .potts_event_ready(potts_writer_ready),
        .potts_event_data(potts_event_data), .store_write_ready(loop_write_ready),
        .store_write_valid(potts_writer_valid), .store_write_slot(potts_writer_slot),
        .commit_request(potts_commit_req), .run(potts_commit_run),
        .done(potts_commit_done), .count(potts_commit_count));

    logic voice_event_valid /* synthesis syn_keep=1 */, voice_overflow;
    logic [95:0] voice_event_data /* synthesis syn_keep=1 */;
    logic signed [15:0] voice_sample; logic voice_sample_valid;
    logic [31:0] voice_bitmap; logic [5:0] active_voice_count; logic [7:0] revoice_count;
    logic [15:0] voice_steal_count;
    // The Potts result never goes to the voice engine directly: it is written
    // into the shadow track first and only heard after the bank swap.
    assign voice_event_valid = mode_live ? live_event_valid : mode_play ? loop_event_valid : 1'b0;
    assign voice_event_data = mode_live ? live_event_data : loop_event_data;
    assign loop_event_ready = mode_play ? voice_event_ready : 1'b0;
    assign potts_event_ready = potts_writer_ready;
    // Held in reset outside LIVE/PLAY so no note can survive a mode change.
    wire voice_rst_n = rst_sys_n && (mode_live || mode_play);

    v2_voice_engine_banked #(.VOICES(32), .USE_GOWIN_RAM(USE_GOWIN_RAM)) u_voice (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .event_valid(voice_event_valid), .event_ready(voice_event_ready),
        .event_data(voice_event_data), .vibrato_hz_q8_8(16'd0), .vibrato_cents_q8_8(16'd0),
        .mixed_sample(voice_sample), .sample_valid(voice_sample_valid),
        .active_bitmap(voice_bitmap), .voice_overflow(voice_overflow),
        .voice_steal_count(voice_steal_count), .revoice_count(revoice_count),
        .active_voice_count(active_voice_count), .vibrato_phase(), .vibrato_delta_cents()
    );

    logic signed [15:0] fx_sample; logic [1:0] fx_status; logic fx_clip;
    logic signed [15:0] test_sample;
    logic test_sample_valid, test_active, test_fault;
    logic [31:0] test_active_bitmap, test_sample_counter;
    logic test_csr_valid, test_csr_write, test_csr_ready, test_csr_rvalid;
    logic [7:0] test_csr_addr;
    logic [31:0] test_csr_wdata, test_csr_rdata;
    logic i2s_sample_valid;
    logic signed [15:0] i2s_sample;
    v2_fx_lite #(.USE_GOWIN_RAM(1)) u_fx (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce), .audio_in(voice_sample),
        .audio_out(fx_sample), .fx_enable(FX_ENABLE != 0), .fx_level(FX_LEVEL[1:0]), .fx_gain_q16(18'h10000),
        .fx_cutoff_q16(16'hffff), .fx_delay_samples(10'd0), .fx_feedback_q15(16'd0),
        .fx_reverb_mix_q15(16'd0), .fx_status_level(fx_status), .fx_clip(fx_clip)
    );
    assign i2s_sample_valid = (mode_wt_play || mode_live) ? wt_play_valid : test_active ? test_sample_valid : voice_sample_valid;
    // The voice path has no volume control yet; -12 dB keeps a sustained note at a
// listenable level while the gain register is still missing.
wire signed [15:0] fx_quiet = fx_sample >>> 2;
// Same -12 dB the voice path uses: a full-scale table is far too loud, and
    // there is no gain register yet.
    wire signed [15:0] wt_quiet = (wt_play_sample >>> 3) - (wt_play_sample >>> 6) - (wt_play_sample >>> 7);  // = 0.1016x = -19.9 dB
    // Per-note envelope for the single-voice LIVE path. An arpeggiator step is a
    // NOTE_ON event, so the envelope must restart on the EVENT, not on the gate:
    // a gate-driven envelope leaves repeated same-pitch notes as one long tone.
    wire live_note_hit = live_event_valid && (live_event_type == V2_EV_NOTE_ON);
    logic hit_sticky, wt_env_gate;
    logic [15:0] wt_env;
    logic signed [31:0] wt_env_prod;
    localparam logic [15:0] ENV_ATT = 16'd96, ENV_DEC = 16'd8, ENV_SUS = 16'd45875;
    assign wt_env_gate = mode_live && live_gate;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) hit_sticky <= 1'b0;
        else if (live_note_hit) hit_sticky <= 1'b1;
        else if (sample_ce) hit_sticky <= 1'b0;
    end
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) wt_env <= 16'd0;
        else if (sample_ce) begin
            if (hit_sticky)                     wt_env <= 16'd0;
            else if (!wt_env_gate)              wt_env <= (wt_env > 16'd16) ? (wt_env - 16'd16) : 16'd0;
            else if (wt_env < ENV_SUS)          wt_env <= wt_env + ENV_ATT;
            else if (wt_env > ENV_SUS)          wt_env <= wt_env - ENV_DEC;
        end
    end
    assign wt_env_prod = wt_quiet * $signed({1'b0, wt_env});
    wire signed [15:0] wt_live_sample = wt_env_prod[31:16];
    assign i2s_sample = mode_wt_play ? wt_quiet : mode_live ? wt_live_sample : test_active ? test_sample : fx_quiet;
    i2s_pcm5102a_tx #(.CLK_HZ(80_000_000), .SAMPLE_HZ(48_000), .ACC_WIDTH(24)) u_i2s (
        .clk(clk_sys_100m), .rst(!rst_sys_n), .sample_valid(i2s_sample_valid),
        .sample_in(i2s_sample), .i2s_bck(pcm5102a_bck), .i2s_lrck(pcm5102a_lrck),
        .i2s_din(pcm5102a_din)
    );

    logic uart_byte_valid, uart_byte_error; logic [7:0] uart_byte;
    logic uart_tx_start, uart_tx_busy;
    logic uart_mux_valid;
    logic [7:0] uart_mux_byte;
    logic tlm_capture_valid, tlm_capture_ready, tlm_frame_valid, tlm_frame_ready, tlm_frame_last;
logic [31:0] tlm_control;
logic [31:0] tlm_div;
    logic [7:0] tlm_frame_byte, tlm_dropped;
    uart_rx #(.CLK_HZ(80_000_000), .BAUD(UART_BAUD)) u_uart_rx (
        .clk(clk_sys_100m), .rst(!rst_sys_n), .rx(uart_rx), .valid(uart_byte_valid),
        .ready(1'b1), .data(uart_byte), .framing_error(uart_byte_error)
    );
    logic cmd_valid, cmd_ready, rsp_valid, rsp_ready;
    logic [7:0] cmd_op, cmd_address, cmd_sequence, rsp_sequence, rsp_status, rsp_error;
    logic [31:0] cmd_data, rsp_data;
    logic rsp_terminal, v2_tx_valid, v2_tx_ready; logic [7:0] v2_tx_byte, protocol_error;
    v2_uart_link u_v2_uart (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .rx_valid(uart_byte_valid), .rx_byte(uart_byte),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_op(cmd_op), .cmd_address(cmd_address),
        .cmd_sequence(cmd_sequence), .cmd_data(cmd_data), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_sequence(rsp_sequence), .rsp_status(rsp_status), .rsp_error(rsp_error), .rsp_data(rsp_data),
        .rsp_terminal(rsp_terminal), .tx_valid(v2_tx_valid), .tx_ready(v2_tx_ready), .tx_byte(v2_tx_byte),
        .rx_busy(), .tx_busy(), .protocol_error(protocol_error)
    );

    // Indexed PATCH CSR state.  Selector and expected CRC/version registers
    // live at the top-level command boundary; the bank owns shadow/active
    // storage and its asynchronous APPLY/CRC state machine.
    logic [1:0] patch_select_family;
    logic [2:0] patch_select_track;
    logic [7:0] patch_select_index;
    logic [15:0] patch_expected_crc, patch_apply_version;
    logic patch_write_valid, patch_write_ready;
    logic signed [31:0] patch_write_value, patch_active_value, patch_shadow_value;
    logic patch_crc_valid, patch_apply_valid, patch_apply_ready;
    logic [15:0] patch_active_version;
    logic patch_shadow_dirty, patch_crc_ok, patch_apply_busy;
    logic [7:0] patch_last_error;
    // P1: one-shot CSR side effects are registered one cycle so the destination
    // register (wt_expected_crc / wt_select_index / patch_expected_crc / apply payload)
    // already holds the new value when the loader or patch bank samples the strobe.
    // WT_DATA is deliberately NOT delayed: it relies on same-cycle ready/valid.
    // NOTE: these must be declared before the instances that consume them.
    logic wt_crc_valid_src, wt_index_load_src, patch_crc_valid_src, wt_apply_valid_src;
    logic wt_crc_valid_q, wt_index_load_q, patch_crc_valid_q, wt_apply_valid_q;
    logic [15:0] wt_apply_payload_q;
    logic [15:0] patch_crc_payload_q;

    v2_patch_bank #(.USE_GOWIN_RAM(USE_GOWIN_RAM)) u_patch_bank (
        .clk(clk_sys_100m), .rst_n(rst_sys_n),
        .select_family(patch_select_family), .select_track(patch_select_track),
        .select_index(patch_select_index), .write_valid(patch_write_valid),
        .write_ready(patch_write_ready), .write_value(patch_write_value),
        .active_value(patch_active_value), .shadow_value(patch_shadow_value),
        .crc_valid(patch_crc_valid_q),
        .expected_crc(patch_crc_payload_q),
        .apply_valid(patch_apply_valid), .apply_ready(patch_apply_ready),
        .expected_version(patch_apply_valid ? cmd_data[15:0] : patch_apply_version),
        .idle((mode_reg == IDLE) && !recording), .loop_boundary(loop_boundary),
        .active_version(patch_active_version), .shadow_dirty(patch_shadow_dirty),
        .crc_ok(patch_crc_ok), .apply_busy(patch_apply_busy), .last_error(patch_last_error)
    );

    // Wavetable CSR state is wired in the same boundary.  The audio path does
    // not consume these tables yet; the loader remains independently
    // addressable for upload/readback/APPLY smoke and future voice hookup.
    logic [1:0] wt_select_table;
    logic wt_morph_en;
    logic [22:0] wt_lfo_step;
    logic [9:0] wt_select_index;
    logic [31:0] wt_note_increment, wt_increment;
logic wt_index_load;   // one-clock pulse when the host writes WT_INDEX
logic [9:0]  dbg_wt_ptr;
logic [5:0]  dbg_wt_covered_count;
logic [31:0] dbg_wt_covered;
logic        dbg_wt_shadow_open, dbg_wt_table_complete, dbg_wt_active_bank;
logic [31:0] dbg_wt_accepted;
logic [4:0]  dbg_wt_last_low5;
logic [1:0]  dbg_wt_table;
logic [1:0]  dbg_state;
logic        dbg_apply_busy, dbg_crc_error;
logic [1:0]  dbg_read_table;
logic [2:0]  dbg_bank_bits;
logic [9:0]  dbg_read_index;
logic [31:0] dbg_rejected;
// Input-path liveness counters (read at 0xD0..0xD8).  A counter that never moves
// proves the sensor never reported; a report counter that moves while the cursor
// counter stays put points at the validity/cursor stage instead.
logic [31:0] dbg_report_count, dbg_error_count, dbg_cursor_valid_count;
logic [15:0] live_event_count_dbg;
assign live_event_count_dbg = live_event_count;
// Stage counters: which gate rejects the frame.
logic [31:0] dbg_xyz_count, dbg_frame_count, dbg_point_count, dbg_degraded_count;
logic [15:0] dbg_crc_final_captured, dbg_expected_crc_captured, dbg_apply_version_seen;
logic [1:0]  dbg_apply_reject_reason;
assign wt_index_load_src = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                          (cmd_address == V2_CSR_WT_INDEX);
    logic signed [15:0] wt_write_sample, wt_read_sample;
    logic [15:0] wt_length, wt_expected_crc, wt_apply_version;
    logic wt_write_valid, wt_write_ready, wt_crc_valid, wt_apply_valid, wt_apply_ready;
    logic wt_active_valid, wt_shadow_valid, wt_apply_busy, wt_crc_error;
    logic [15:0] wt_active_version;
logic wt_apply_done, wt_apply_ok;
logic [1:0] wt_apply_reason;
    logic [1:0] wt_active_table;
// P1 pulse staging.  Each source pulse lasts exactly one clock and is followed by
// one quiet cycle; cmd_ready below holds off the next command during that cycle so
// two staged commands can never overlap.
always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
    if (!rst_sys_n) begin
        wt_crc_valid_q   <= 1'b0;
        wt_index_load_q  <= 1'b0;
        patch_crc_valid_q<= 1'b0;
        wt_apply_valid_q <= 1'b0;
        wt_apply_payload_q <= 16'd0;
        patch_crc_payload_q <= 16'd0;
    end else begin
        wt_crc_valid_q    <= wt_crc_valid_src;
        wt_index_load_q   <= wt_index_load_src;
        patch_crc_valid_q <= patch_crc_valid_src;
        wt_apply_valid_q <= wt_apply_valid_src;   // one-cycle pulse: the commit bit is in the APPLY word, not here
        if (wt_apply_valid_src)
            wt_apply_payload_q <= cmd_data[15:0];
        if (patch_crc_valid_src)
            patch_crc_payload_q <= cmd_data[15:0];
    end
end


    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            dbg_report_count       <= 32'd0;
            dbg_xyz_count          <= 32'd0;
            dbg_frame_count        <= 32'd0;
            dbg_point_count        <= 32'd0;
            dbg_degraded_count     <= 32'd0;
            dbg_error_count        <= 32'd0;
            dbg_cursor_valid_count <= 32'd0;
        end else begin
            if (report_valid && dbg_report_count != 32'hFFFF_FFFF)
                dbg_report_count <= dbg_report_count + 32'd1;
            if (report_error && dbg_error_count != 32'hFFFF_FFFF)
                dbg_error_count <= dbg_error_count + 32'd1;
            if (audio_cursor_valid && dbg_cursor_valid_count != 32'hFFFF_FFFF)
                dbg_cursor_valid_count <= dbg_cursor_valid_count + 32'd1;
            if (frame_xyz_valid && dbg_xyz_count != 32'hFFFF_FFFF)
                dbg_xyz_count <= dbg_xyz_count + 32'd1;
            if (valid_frame && dbg_frame_count != 32'hFFFF_FFFF)
                dbg_frame_count <= dbg_frame_count + 32'd1;
            if (cursor_point_valid && dbg_point_count != 32'hFFFF_FFFF)
                dbg_point_count <= dbg_point_count + 32'd1;
            if (degraded_frame && dbg_degraded_count != 32'hFFFF_FFFF)
                dbg_degraded_count <= dbg_degraded_count + 32'd1;
        end
    end
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) cursor_last_z <= 32'sd0;
        else if (calibration_strobe) cursor_last_z <= frame_cal_z;
    end

    // Wavetable playback: WT_PLAY hands the uploader's read port to this engine and
    // routes its output straight to I2S, so the audio path is the table itself.
    assign wt_read_index_sel = (mode_wt_play || mode_live) ? wt_play_index : wt_select_index;

    // The test note selects the phase increment; 0 keeps the legacy fixed walk
    // (one table point per sample = 46.875 Hz) so the old acceptance still holds.
    v2_tick_gen u_tick_gen (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .bpm(mode_live ? bpm_auto_q : bpm_reg),
        .bpm_we(bpm_sel_we),
        .restart(!mode_live),   // LIVE auto tempo must not restart the bar
        .tick_pulse(tick_pulse), .tick(tick_now), .samples_per_tick(samples_per_tick)
    );
    v2_note_increment_rom u_wt_note_increment(.note(thresholds_reg[7:0]), .increment(wt_note_increment));
    // Single-voice LIVE table path: the note from the rule engine drives the same
    // phase increment the WT_PLAY test note uses.
    logic [31:0] live_note_increment;
    v2_note_increment_rom u_live_note_increment(.note(live_active_note), .increment(live_note_increment));
    assign wt_increment = mode_live ? live_note_increment :
                          (thresholds_reg[7:0] == 8'd0) ? 32'd4194304 : wt_note_increment;

    // Wavetable position LFO.  It runs only on the audible single-voice paths so
    // the position does not creep while the board sits in IDLE or PLAY.
    logic [25:0] wt_pos;
    logic [1:0]  wt_frame_a, wt_frame_b;
    logic [7:0]  wt_frac;
    v2_wt_position u_wt_position (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .morph_en(wt_morph_en && (mode_wt_play || mode_live)), .step(wt_lfo_step),
        .pos(wt_pos), .frame_a(wt_frame_a), .frame_b(wt_frame_b), .frac(wt_frac)
    );

    // Frame crossfade.  The loader's samples lag the frame select by one cycle
    // (registered select), so frac must be delayed by the same cycle or the mix
    // reverts to the previous frame for one sample at every pair crossing.
    logic signed [15:0] wt_sample_a, wt_sample_b, wt_mix_out;
    logic wt_rd_valid0, wt_rd_valid1;
    logic [7:0] wt_frac_q;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) wt_frac_q <= 8'd0;
        else            wt_frac_q <= wt_frac;
    end
    v2_wt_mix u_wt_mix (
        .a(wt_sample_a), .b(wt_sample_b), .frac(wt_frac_q), .out(wt_mix_out)
    );
    logic signed [15:0] wt_table_sample;
    // Either frame may be a table that was never APPLYed; use whichever frame is
    // valid and only crossfade when both are, so the sweep never blends an
    // uninitialised DPB word.
    assign wt_table_sample = !wt_morph_en          ? wt_sample_a :
                             (wt_rd_valid0 && wt_rd_valid1) ? wt_mix_out :
                             wt_rd_valid0          ? wt_sample_a :
                             wt_rd_valid1          ? wt_sample_b : 16'sd0;

    // The two read channels follow position in WT_PLAY/LIVE; everywhere else they
    // read the host-selected table so the CSR readback path is untouched.
    logic [1:0] wt_play_table_a, wt_play_table_b;
    assign wt_play_table_a = (wt_morph_en && (mode_wt_play || mode_live))
                             ? wt_frame_a : wt_select_table;
    assign wt_play_table_b = (wt_morph_en && (mode_wt_play || mode_live))
                             ? wt_frame_b : wt_select_table;

    v2_wt_playback u_wt_playback (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .enable(mode_wt_play || (mode_live && live_gate)), .increment(wt_increment), .index(wt_play_index),
        .sample(wt_table_sample), .out(wt_play_sample), .valid(wt_play_valid)
    );
    v2_wavetable_loader #(.TABLES(3), .SAMPLES(1024), .USE_GOWIN_RAM(USE_GOWIN_RAM)) u_wavetable_loader (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .wt_write_valid(wt_write_valid),
        .wt_write_ready(wt_write_ready), .wt_table(wt_select_table), .wt_index(wt_select_index), .wt_index_load(wt_index_load_q),
        .wt_write_sample(wt_write_sample), .wt_crc_valid(wt_crc_valid_q),
        .wt_expected_crc(wt_expected_crc), .wt_apply_valid(wt_apply_valid_q),
        .wt_apply_ready(wt_apply_ready), .wt_apply_table(wt_select_table),
        .wt_apply_version(wt_apply_payload_q), .wt_version_reg(wt_apply_version), .loop_boundary(loop_boundary),
        .idle((mode_reg == IDLE) && !recording), .wt_read_table(wt_select_table),
        .wt_read_index(wt_read_index_sel), .wt_read_sample(wt_read_sample),
        // Morph channels: position selects the pair, the phase index is shared.
        .wt_rd_table0(wt_play_table_a), .wt_rd_index0(wt_read_index_sel),
        .wt_rd_table1(wt_play_table_b), .wt_rd_index1(wt_read_index_sel),
        .wt_rd_sample0(wt_sample_a), .wt_rd_sample1(wt_sample_b),
        .wt_rd_valid0(wt_rd_valid0), .wt_rd_valid1(wt_rd_valid1),
        .wt_active_valid(wt_active_valid), .wt_shadow_valid(wt_shadow_valid),
        .wt_apply_busy(wt_apply_busy), .wt_crc_error(wt_crc_error),
        .wt_active_version(wt_active_version), .wt_active_table(wt_active_table),
        .dbg_wr_ptr(dbg_wt_ptr), .dbg_covered_count(dbg_wt_covered_count),
        .dbg_covered(dbg_wt_covered), .dbg_shadow_open(dbg_wt_shadow_open),
        .dbg_table_complete(dbg_wt_table_complete), .dbg_accepted(dbg_wt_accepted),
        .dbg_last_low5(dbg_wt_last_low5), .dbg_wt_table(dbg_wt_table),
        .dbg_active_bank(dbg_wt_active_bank),
        .dbg_state(dbg_state), .dbg_apply_busy(dbg_apply_busy), .dbg_crc_error(dbg_crc_error),
        .dbg_read_table(dbg_read_table), .dbg_bank_bits(dbg_bank_bits),
        .dbg_read_index(dbg_read_index), .dbg_rejected(dbg_rejected),
        .dbg_crc_final_captured(dbg_crc_final_captured),
        .dbg_apply_reject_reason(dbg_apply_reject_reason),
        .dbg_expected_crc_captured(dbg_expected_crc_captured),
        .dbg_apply_version_seen(dbg_apply_version_seen),
        .wt_apply_done(wt_apply_done), .wt_apply_ok(wt_apply_ok), .wt_apply_reason(wt_apply_reason)
    );

    assign patch_write_value = $signed(cmd_data);
    assign wt_write_sample = $signed(cmd_data[15:0]);
    assign patch_write_valid = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                               (cmd_address == V2_CSR_PATCH_SHADOW_DATA);
    assign patch_crc_valid_src = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                                 (cmd_address == V2_CSR_PATCH_CRC);
    assign patch_apply_valid = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                               (cmd_address == V2_CSR_PATCH_APPLY);
    assign wt_write_valid = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                            (cmd_address == V2_CSR_WT_DATA);
    assign wt_crc_valid_src = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                          (cmd_address == V2_CSR_WT_CRC);
    assign wt_apply_valid_src = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) &&
                            (cmd_address == V2_CSR_WT_APPLY);
    // The current implementation owns TEST_SELECT_0 only.  Other A0..AF
    // channels remain reserved for future diagnostic blocks.
    assign test_csr_valid = cmd_valid && cmd_ready &&
                            (cmd_address == V2_CSR_TEST_SELECT);
    assign test_csr_write = (cmd_op == V2_OP_WRITE);
    assign test_csr_addr = cmd_address;
    assign test_csr_wdata = cmd_data;
    (* syn_preserve = 1 *) v2_test_mode u_test_mode (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .sample_ce(sample_ce),
        .csr_valid(test_csr_valid), .csr_write(test_csr_write),
        .csr_addr(test_csr_addr), .csr_wdata(test_csr_wdata),
        .csr_ready(test_csr_ready), .csr_rvalid(test_csr_rvalid),
        .csr_rdata(test_csr_rdata), .mixed_sample(test_sample),
        .sample_valid(test_sample_valid), .active_bitmap(test_active_bitmap),
        .sample_counter(test_sample_counter), .test_active(test_active),
        .fault(test_fault)
    );
    // Keep commands queued while a loop control operation or table APPLY is
    // busy.  Reads remain available during APPLY so software can observe the
    // status; writes are held until the owning bank returns to S_IDLE.
    assign cmd_ready = !loop_ctrl_pending &&
                       !((cmd_op == V2_OP_WRITE) &&
                         (patch_apply_busy || wt_apply_busy)) &&
                       // Hold off one cycle after a staged one-shot so two staged
                       // commands can never overlap (P1 non-overlap argument).
                       !(wt_crc_valid_q || wt_index_load_q || patch_crc_valid_q || wt_apply_valid_q);
    assign bpm_write = cmd_valid && cmd_ready && (cmd_op == V2_OP_WRITE) && (cmd_address == V2_CSR_BPM);
    wire status_fault = (protocol_error != V2_ERR_NONE) || (record_fault != 8'd0) ||
                        loop_commit_timeout || test_fault;
    logic test_response_pending;
    logic [7:0] test_response_sequence;
    logic csr_read_pending;
    logic [7:0] csr_read_sequence, csr_read_address;
    logic patch_apply_response_pending;
    logic [7:0] patch_apply_response_sequence;
    logic patch_apply_response_valid;
    logic wt_apply_response_pending;
    logic [7:0] wt_apply_response_sequence;
    logic wt_apply_response_valid;
    always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            mode_reg <= IDLE; rsp_valid <= 0; rsp_sequence <= 0; rsp_status <= 0;
            rsp_error <= V2_ERR_NONE; rsp_data <= 0; rsp_terminal <= 1'b1;
            record_start <= 0; record_stop <= 0; record_abort <= 0; potts_capture_arm <= 0; potts_commit_kick <= 0;
            selected_track <= 3'd0;
            patch_select_family <= 2'd0; patch_select_track <= 3'd0;
            patch_select_index <= 8'd0; patch_expected_crc <= 16'hffff;
            patch_apply_version <= 16'd0;
            wt_select_table <= 2'd0; wt_morph_en <= 1'b0; wt_lfo_step <= 23'd0;
            wt_select_index <= 10'd0; wt_length <= 16'd1024;
            wt_expected_crc <= 16'hffff; wt_apply_version <= 16'd0;
            thresholds_reg <= 32'd0;
            potts_lambda <= 16'd21600;
            bpm_reg <= 16'd120; bpm_we_q <= 1'b0;
            loop_ctrl_valid <= 1'b0; loop_ctrl_op <= 3'd0; loop_ctrl_track <= 3'd0;
            loop_ctrl_pending <= 1'b0; loop_ctrl_pending_op <= 3'd0;
            test_response_pending <= 1'b0; test_response_sequence <= 8'd0;
            csr_read_pending <= 1'b0; csr_read_sequence <= 8'd0; csr_read_address <= 8'd0;
            patch_apply_response_pending <= 1'b0; patch_apply_response_sequence <= 8'd0;
            patch_apply_response_valid <= 1'b0;
            wt_apply_response_pending <= 1'b0; wt_apply_response_sequence <= 8'd0;
            wt_apply_response_valid <= 1'b0;
        end else begin
            rsp_valid <= 1'b0; record_start <= 1'b0; record_stop <= 1'b0;
            record_abort <= 1'b0; potts_capture_arm <= 1'b0; potts_commit_kick <= 1'b0;
            loop_ctrl_valid <= loop_ctrl_pending;
            // The commit writer asks for the bank swap only after the DP result
            // has been written into the shadow track.
            if (potts_commit_req && !loop_ctrl_pending) begin
                loop_ctrl_op <= 3'd3;
                loop_ctrl_track <= 3'd0;
                loop_ctrl_pending_op <= 3'd3;
                loop_ctrl_pending <= 1'b1;
            end
            if (test_csr_rvalid && test_response_pending) begin
                rsp_valid <= 1'b1;
                rsp_sequence <= test_response_sequence;
                rsp_status <= V2_ACK_ACCEPTED;
                rsp_error <= V2_ERR_NONE;
                rsp_data <= test_csr_rdata;
                rsp_terminal <= 1'b1;
                test_response_pending <= 1'b0;
            end
            // All CSR reads are returned on the cycle after acceptance.  The
            // table memories are synchronous, so this prevents a read reply
            // from exposing the previous address/data word.
            if (csr_read_pending) begin
                rsp_valid <= 1'b1;
                rsp_sequence <= csr_read_sequence;
                rsp_status <= V2_ACK_ACCEPTED;
                rsp_error <= V2_ERR_NONE;
                rsp_terminal <= 1'b1;
                // Reading the contour window advances its pointer, so the host
                // dumps 32 samples with 32 reads and no index writes.
                if (csr_read_address == V2_CSR_CONTOUR_DATA)
                    contour_rd_index <= contour_rd_index + 1'b1;
                case (csr_read_address)
                    V2_CSR_STATUS: rsp_data <= {22'd0, status_fault, loop_active_valid,
                                                 5'd0, mode_reg[2:0]};
                    V2_CSR_PATCH_SELECT: rsp_data <= {16'd0, patch_select_index, 3'd0,
                                                       patch_select_track, patch_select_family};
                    V2_CSR_PATCH_SHADOW_DATA: rsp_data <= patch_shadow_value;
                    V2_CSR_PATCH_ACTIVE_DATA: rsp_data <= patch_active_value;
                    V2_CSR_PATCH_STATUS: rsp_data <= {patch_last_error, 5'd0,
                                                       patch_apply_busy, patch_crc_ok,
                                                       patch_shadow_dirty, patch_active_version};
                    V2_CSR_PATCH_CRC: rsp_data <= {16'd0, patch_expected_crc};
                    V2_CSR_PATCH_APPLY: rsp_data <= 32'd0;
                    V2_CSR_BPM: rsp_data <= {16'd0, bpm_reg};
                    V2_CSR_THRESHOLDS: rsp_data <= thresholds_reg;
                    V2_CSR_CONTOUR_DATA: rsp_data <= {16'd0, contour_rd_data};
                    V2_CSR_POTTS_STATUS: rsp_data <= {27'd0, potts_capture_full, loop_commit_timeout,
                                                      potts_overflow, potts_busy, potts_commit_done};
                    V2_CSR_POTTS_LAMBDA: rsp_data <= {16'd0, potts_lambda};
                    V2_CSR_WT_SELECT: rsp_data <= {wt_lfo_step, wt_morph_en,
                                                    6'd0, wt_select_table};
                    V2_CSR_WT_INDEX: rsp_data <= {22'd0, wt_select_index};
                    V2_CSR_WT_DATA: rsp_data <= {16'd0, wt_read_sample};
                    // In WT_PLAY the read port is owned by the playback engine, so a
                    // WT_DATA read returns the sample currently being played; keep the
                    // host readback in IDLE, where the port follows WT_INDEX.
                    V2_CSR_WT_LENGTH: rsp_data <= {16'd0, wt_length};
                    V2_CSR_WT_CRC: rsp_data <= {16'd0, wt_expected_crc};
                    V2_CSR_WT_VERSION: rsp_data <= {16'd0, wt_apply_version};
                    V2_CSR_WT_APPLY: rsp_data <= 32'd0;
                    // Read-only debug observability (V2_DEBUG_CSR), one quantity per register.
                    //   0xB0 const 0x5A5A_0003   0xB4 state[1:0]
                    //   0xB8 accepted[31:0]      0xBC covered[31:0]
                    //   0xC0 covered_count[5:0]  0xC4 wr_ptr[9:0]
                    //   0xC8 rejected[31:0]      0xCC crc_final_captured[15:0]
                    //   0xA4 apply_reject_reason[1:0]
                    //   0xA8 expected_crc_captured[15:0]
                    //   0xAC apply_version_seen[15:0]
                    8'hB0: rsp_data <= (V2_DEBUG_CSR != 0) ? 32'h5A5A_0003 : 32'd0;
                    8'hB4: rsp_data <= (V2_DEBUG_CSR != 0) ? {30'd0, dbg_state} : 32'd0;
                    8'hB8: rsp_data <= (V2_DEBUG_CSR != 0) ? dbg_wt_accepted : 32'd0;
                    8'hBC: rsp_data <= (V2_DEBUG_CSR != 0) ? dbg_wt_covered : 32'd0;
                    8'hC0: rsp_data <= (V2_DEBUG_CSR != 0) ? {26'd0, dbg_wt_covered_count} : 32'd0;
                    8'hC4: rsp_data <= (V2_DEBUG_CSR != 0) ? {22'd0, dbg_wt_ptr} : 32'd0;
                    8'hC8: rsp_data <= (V2_DEBUG_CSR != 0) ? dbg_rejected : 32'd0;
                    8'hCC: rsp_data <= (V2_DEBUG_CSR != 0) ? {16'd0, dbg_crc_final_captured} : 32'd0;
                    8'hD0: rsp_data <= (V2_DEBUG_CSR != 0) ? dbg_report_count : 32'd0;
                    8'hD4: rsp_data <= (V2_DEBUG_CSR != 0) ? {16'd0, live_event_count} : 32'd0;
                    8'hD8: rsp_data <= (V2_DEBUG_CSR != 0) ? {16'd0, cursor_y[15:0]} : 32'd0;
                    8'hDC: rsp_data <= (V2_DEBUG_CSR != 0) ? raw_x : 32'd0;      // raw sensor X (signed)
                    8'hE0: rsp_data <= (V2_DEBUG_CSR != 0) ? cursor_last_z : 32'd0;
                    8'hE4: rsp_data <= (V2_DEBUG_CSR != 0) ? {27'd0, cursor_fsm_state} : 32'd0;
                    8'hE8: rsp_data <= (V2_DEBUG_CSR != 0) ? {4'd0, wt_pos[25:8], live_active, live_gate, live_active_note} : 32'd0;
                    8'hEC: rsp_data <= (V2_DEBUG_CSR != 0) ? dbg_frame_count : 32'd0;
                    8'hF0: rsp_data <= (V2_DEBUG_CSR != 0) ? {16'd0, cursor_x[15:0]} : 32'd0;
                    8'hF4: rsp_data <= (V2_DEBUG_CSR != 0) ? {26'd0, reader_state} : 32'd0;
                    8'hF8: rsp_data <= (V2_DEBUG_CSR != 0) ? dbg_point_count : 32'd0;
                    8'hFC: rsp_data <= (V2_DEBUG_CSR != 0) ? raw_y : 32'd0;      // raw sensor Y (signed)
                    8'hA4: rsp_data <= (V2_DEBUG_CSR != 0) ? {30'd0, dbg_apply_reject_reason} : 32'd0;
                    8'hA8: rsp_data <= (V2_DEBUG_CSR != 0) ? {16'd0, dbg_expected_crc_captured} : 32'd0;
                    8'hAC: rsp_data <= (V2_DEBUG_CSR != 0) ? {16'd0, dbg_apply_version_seen} : 32'd0;
                    V2_CSR_TLM_CONTROL: rsp_data <= tlm_control;
                    V2_CSR_WT_STATUS: rsp_data <= {wt_crc_error ? V2_ERR_WT_CRC : 8'd0, 6'd0, wt_apply_busy, wt_shadow_valid,
                                                    wt_active_version};
                    default: rsp_data <= 32'd0;
                endcase
                csr_read_pending <= 1'b0;
            end
            if (patch_apply_response_pending) begin
                rsp_valid <= 1'b1;
                rsp_sequence <= patch_apply_response_sequence;
                rsp_status <= V2_ACK_ACCEPTED;
                rsp_error <= !patch_apply_response_valid ? V2_ERR_BAD_DATA :
                             ((patch_last_error != V2_ERR_NONE) ? patch_last_error : V2_ERR_NONE);
                rsp_data <= 32'd0;
                rsp_terminal <= 1'b1;
                patch_apply_response_pending <= 1'b0;
                patch_apply_response_valid <= 1'b0;
            end
            if (wt_apply_response_pending && wt_apply_done) begin
                rsp_valid <= 1'b1;
                rsp_sequence <= wt_apply_response_sequence;
                rsp_status <= V2_ACK_ACCEPTED;
                // Answer with this transaction's outcome, not the sticky wt_crc_error
                // flag: reason 3 means the CRC engine ran and disagreed, 1/2 mean the
                // apply was refused before the engine started.
                rsp_error <= 1'b0 ? V2_ERR_BAD_DATA :
                             (wt_apply_reason == 2'd3 ? V2_ERR_WT_CRC : V2_ERR_NONE);
                rsp_data <= 32'd0;
                rsp_terminal <= 1'b1;
                wt_apply_response_pending <= 1'b0;
                wt_apply_response_valid <= 1'b0;
            end
            if (loop_probe_record_start) record_start <= 1'b1;
            if (loop_probe_record_stop) record_stop <= 1'b1;
            if (loop_ctrl_pending && loop_ctrl_ready) begin
                loop_ctrl_pending <= 1'b0;
                loop_ctrl_valid <= 1'b1;
            end
            if (loop_ctrl_done && (loop_ctrl_pending_op == 3'd5)) begin
                record_start <= 1'b1;
                mode_reg <= RECORD;
            end
            if (cmd_valid && cmd_ready) begin
                if (test_csr_valid && (cmd_op == V2_OP_READ)) begin
                    test_response_pending <= 1'b1;
                    test_response_sequence <= cmd_sequence;
                end else if (cmd_op == V2_OP_READ) begin
                    csr_read_pending <= 1'b1;
                    csr_read_sequence <= cmd_sequence;
                    csr_read_address <= cmd_address;
                end else if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_PATCH_APPLY) begin
                    patch_apply_response_pending <= 1'b1;
                    patch_apply_response_sequence <= cmd_sequence;
                    patch_apply_response_valid <= patch_apply_ready;
                end else if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_WT_APPLY) begin
                    wt_apply_response_pending <= 1'b1;
                    wt_apply_response_sequence <= cmd_sequence;
                    wt_apply_response_valid <= wt_apply_ready;
                end else begin
                    rsp_valid <= 1'b1; rsp_sequence <= cmd_sequence; rsp_status <= V2_ACK_ACCEPTED;
                    rsp_error <= ((cmd_address == V2_CSR_PATCH_SHADOW_DATA) && !patch_write_ready) ||
                                 ((cmd_address == V2_CSR_WT_DATA) && !wt_write_ready)
                                 ? V2_ERR_BAD_DATA : V2_ERR_NONE;
                    rsp_data <= (cmd_address == V2_CSR_STATUS) ?
                                {22'd0, status_fault, loop_active_valid, 5'd0, mode_reg[2:0]} : 0;
                    rsp_terminal <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_PATCH_SELECT) begin
                    patch_select_family <= cmd_data[1:0];
                    patch_select_track <= cmd_data[4:2];
                    patch_select_index <= cmd_data[15:8];
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_PATCH_CRC)
                    patch_expected_crc <= cmd_data[15:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_PATCH_APPLY)
                    patch_apply_version <= cmd_data[15:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_WT_SELECT) begin
                    wt_select_table <= cmd_data[1:0];
                    wt_morph_en <= cmd_data[8];
                    wt_lfo_step <= cmd_data[31:9];
                end
            if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_BPM)
                    bpm_reg <= cmd_data[15:0];
                bpm_we_q <= bpm_write;
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_THRESHOLDS)
                    thresholds_reg <= cmd_data;
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_WT_INDEX)
                    wt_select_index <= cmd_data[9:0];
                else if (wt_write_valid && wt_write_ready)
                    // The contract advances the index on every WT_DATA write; this
                    // mirror feeds WT_INDEX readback and stays in step with the
                    // uploader's own pointer.
                    wt_select_index <= wt_select_index + 10'd1;
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_WT_LENGTH)
                    wt_length <= cmd_data[15:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_TLM_CONTROL)
                    tlm_control <= cmd_data & V2_CSR_TLM_CONTROL_WRITE_MASK;
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_WT_CRC)
                    wt_expected_crc <= cmd_data[15:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_WT_VERSION)
                    wt_apply_version <= cmd_data[15:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_TRACK)
                    selected_track <= cmd_data[2:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_MODE) begin
                    mode_reg <= cmd_data[2:0];
                    if (cmd_data[2:0] == RECORD) record_start <= 1'b1;
                    if (cmd_data[2:0] != RECORD) record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_RECORD) begin
                    loop_ctrl_op <= 3'd5;
                    loop_ctrl_track <= selected_track;
                    loop_ctrl_pending_op <= 3'd5;
                    loop_ctrl_pending <= 1'b1;
                    record_stop <= 1'b1;
                    // Arming rides on PREPARE_RECORD: the capture waits for the
                    // next tick 0 and fills the 32 contour samples in order.
                    potts_capture_arm <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_CONTOUR_DATA)
                    contour_rd_index <= cmd_data[4:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_POTTS_LAMBDA)
                    potts_lambda <= cmd_data[15:0];
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_OVERDUB) begin
                    loop_ctrl_op <= 3'd0;
                    loop_ctrl_track <= selected_track;
                    loop_ctrl_pending_op <= 3'd0;
                    loop_ctrl_pending <= 1'b1;
                    record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_CLEAR_TRACK) begin
                    loop_ctrl_op <= 3'd1;
                    loop_ctrl_track <= cmd_data[2:0];
                    loop_ctrl_pending_op <= 3'd1;
                    loop_ctrl_pending <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_CLEAR_ALL) begin
                    loop_ctrl_op <= 3'd2;
                    loop_ctrl_track <= 3'd0;
                    loop_ctrl_pending_op <= 3'd2;
                    loop_ctrl_pending <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_STOP) begin
                    mode_reg <= IDLE; record_abort <= 1'b1;
                    loop_ctrl_op <= 3'd4;
                    loop_ctrl_track <= 3'd0;
                    loop_ctrl_pending_op <= 3'd4;
                    loop_ctrl_pending <= 1'b1;
                    record_stop <= 1'b1;
                end
                if (cmd_op == V2_OP_WRITE && cmd_address == V2_CSR_COMMIT) potts_commit_kick <= 1'b1;
            end
        end
    end
    // ACK/NACK response bytes have priority over telemetry.  The telemetry
    // snapshot advances only when the physical UART has accepted its current
    // byte, so the 22-byte frame remains tear-free under baud backpressure.
    assign v2_tx_ready = !uart_tx_busy;
    assign tlm_frame_ready = !uart_tx_busy && !v2_tx_valid;
    assign uart_mux_valid = v2_tx_valid || tlm_frame_valid;
    assign uart_mux_byte = v2_tx_valid ? v2_tx_byte : tlm_frame_byte;
    assign uart_tx_start = uart_mux_valid && !uart_tx_busy;
    uart_tx #(.CLK_HZ(80_000_000), .BAUD(UART_BAUD)) u_uart_tx (
        .clk(clk_sys_100m), .rst(!rst_sys_n), .start(uart_tx_start), .data(uart_mux_byte),
        .tx(uart_tx), .busy(uart_tx_busy)
    );

    v2_telemetry_snapshot u_telemetry (
        .clk(clk_sys_100m), .rst_n(rst_sys_n), .capture_valid(tlm_capture_valid),
        .capture_ready(tlm_capture_ready), .capture_type(8'd1), .capture_sequence(audio_sequence),
        .capture_x(cursor_x[15:0]), .capture_y(cursor_y[15:0]),
        .capture_z(cursor_z[15:0]), .capture_note(live_active_note),
        .capture_flags({1'b0, recording, loop_active_valid, loop_commit_pending, cursor_rebased,
                        calibrated_presence, record_fault[1:0]}), .capture_tick(sample_index[7:0]),
        .capture_voice_bitmap(voice_bitmap), .capture_fifo_level(record_count[7:0]),
        .capture_fault_code(protocol_error | record_fault),
        .frame_valid(tlm_frame_valid), .frame_ready(tlm_frame_ready), .frame_byte(tlm_frame_byte),
        .frame_last(tlm_frame_last), .dropped_captures(tlm_dropped)
    );
    // TLM_CONTROL: bit0 enables the snapshot stream, [31:16] is the capture period in
// audio samples (48 kHz), so a period of 2400 gives about 20 frames per second.
// Without the divider the stream is 22 bytes x 48 kHz, forty times the UART rate.
wire [31:0] tlm_period = (tlm_control[31:16] == 16'd0) ? 32'd2400 : {16'd0, tlm_control[31:16]};
always_ff @(posedge clk_sys_100m or negedge rst_sys_n) begin
    if (!rst_sys_n) tlm_div <= 32'd0;
    else if (sample_ce) tlm_div <= (tlm_div >= tlm_period - 32'd1) ? 32'd0 : tlm_div + 32'd1;
end
assign tlm_capture_valid = tlm_control[0] && sample_ce && audio_cursor_valid && (tlm_div == 32'd0);
endmodule