// V2 32-voice engine with a deterministic GW5A state bank.
//
// The hot oscillator state is held in one simple-dual-port bank. The scan
// issues one read per cycle and the registered bank output feeds the existing
// read/compute/writeback pipeline. Events are accepted only while the scan
// pipeline is quiescent, so the bank has exactly one write owner per cycle.
module v2_voice_engine_banked #(
    parameter integer VOICES = 32,
    parameter integer USE_GOWIN_RAM = 0
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   sample_ce,
    input  logic                   event_valid,
    output logic                   event_ready,
    input  logic [95:0]            event_data,
    input  logic [15:0]            vibrato_hz_q8_8,
    input  logic [15:0]            vibrato_cents_q8_8,
    output logic signed [15:0]     mixed_sample,
    output logic                   sample_valid,
    output logic [VOICES-1:0]      active_bitmap,
    output logic                   voice_overflow,
    output logic [15:0]            voice_steal_count,
    output logic [7:0]             revoice_count,
    output logic [5:0]             active_voice_count,
    output logic [15:0]            vibrato_phase,
    output logic signed [15:0]     vibrato_delta_cents
);
    import v2_contract_pkg::*;

    localparam logic [1:0] ENV_ATTACK  = 2'd0;
    localparam logic [1:0] ENV_DECAY   = 2'd1;
    localparam logic [1:0] ENV_SUSTAIN = 2'd2;
    localparam logic [1:0] ENV_RELEASE = 2'd3;
    localparam logic [15:0] SUSTAIN_LEVEL = 16'd49152;
    localparam logic [15:0] ATTACK_STEP   = 16'd4096;
    localparam logic [15:0] DECAY_STEP    = 16'd256;
    localparam logic [15:0] RELEASE_STEP  = 16'd1024;
    // The reference advances one voice per slot inside each sample.  Keep an
    // eight-pass bounded release in the RTL by holding the victim for all
    // VOICES slot visits that make up each pass.
    localparam integer STEAL_RELEASE_PASSES = 8;
    localparam logic [15:0] STEAL_RELEASE_SAMPLES = STEAL_RELEASE_PASSES * VOICES;
    localparam logic [7:0] DEFAULT_MIX_A = 8'd128;
    localparam logic [7:0] DEFAULT_MIX_B = 8'd128;

    // Metadata is small and is only touched by the event path. All oscillator
    // state, including both glide targets, is packed in the BSRAM bank. This
    // is intentional: leaving target_a/target_b as variable-indexed arrays
    // makes Gowin infer RAMREG writeback logic and recreates the 100 MHz
    // critical path that this bank is meant to remove.
    logic [VOICES-1:0] active;
    logic [VOICES-1:0] releasing;
    logic [7:0]  note [0:VOICES-1];
    logic [7:0]  velocity [0:VOICES-1];
    logic [15:0] age [0:VOICES-1];
    logic [15:0] age_counter;
    logic        steal_pending;
    logic [4:0]  steal_slot_pending;
    // Only one voice can be in bounded steal release at a time. Keep the
    // countdown scalar and pair it with steal_slot_pending; an indexed
    // 32-entry hold array creates a large RAMREG reset/writeback fanout.
    logic [15:0] steal_hold_value;
    logic [7:0]  steal_note_pending, steal_velocity_pending;
    logic signed [15:0] steal_pitch_pending;
    logic [15:0] steal_timbre_pending;
    logic [31:0] steal_base_step_pending;
    logic [2:0]  steal_track_pending;
    logic [7:0]  steal_tick_pending, steal_duration_pending, steal_flags_pending;
    // Debug/replay view of the scalar bounded-release countdown. The engine
    // itself never reads this array; keeping the view preserves existing
    // hierarchical checks without restoring the RAMREG state array.
    logic [15:0] steal_hold [0:VOICES-1];
    // Bank word layout: phase_a, phase_b, step_a, step_b, target_a,
    // target_b, envelope, gain, mix_a, mix_b, env_stage, and reserved bits
    // (256 total = sixteen independent 16-bit DPB lanes). The upper lane
    // carries the per-voice vibrato phase; the remaining bits are reserved.
    logic [255:0] bank_rd_data;
    logic         bank_rd_en;
    logic [4:0]   bank_rd_addr;
    logic         bank_wr_en;
    logic [4:0]   bank_wr_addr;
    logic [255:0] bank_wr_data;
    v2_voice_state_bank #(.WIDTH(256), .USE_GOWIN_RAM(USE_GOWIN_RAM)) state_bank (
        .clk, .rd_en(bank_rd_en), .rd_addr(bank_rd_addr), .rd_data(bank_rd_data),
        .wr_en(bank_wr_en), .wr_addr(bank_wr_addr), .wr_data(bank_wr_data)
    );



    logic [31:0] rom_step /* synthesis syn_keep=1 */;
    (* keep_hierarchy = "yes" *)
    v2_note_increment_rom note_rom (.note(event_data[71:64]), .increment(rom_step));

    logic        scan_active;
    logic        scan_busy;
    logic [5:0]  scan_index;
    logic [5:0]  scan_base;
    logic [5:0]  scan_slot;
    logic signed [47:0] mix_acc;

    logic        bank_rd_pending;
    logic        bank_rd_last_pending;
    logic [4:0]  bank_rd_slot_pending;
    logic        rd_valid;
    logic        rd_last;
    logic        rd_active;
    logic        rd_releasing;
    logic [4:0]  rd_slot;
    logic [31:0] rd_phase_a, rd_phase_b, rd_step_a, rd_step_b;
    logic [31:0] rd_target_a, rd_target_b;
    logic [15:0] rd_envelope;
    logic [7:0]  rd_gain, rd_mix_a, rd_mix_b;
    logic [1:0]  rd_env_stage;
    logic [15:0] rd_vibrato_phase;

    logic        calc_valid;
    logic        calc_last;
    logic        calc_active;
    logic [4:0]  calc_slot;
    logic signed [47:0] calc_osc_sum;
    logic [31:0] calc_phase_a, calc_phase_b, calc_step_a, calc_step_b;
    logic [31:0] calc_target_a, calc_target_b;
    logic [15:0] calc_envelope;
    logic [7:0]  calc_gain, calc_mix_a, calc_mix_b;
    logic [1:0]  calc_env_stage;
    logic [15:0] calc_vibrato_phase;
    logic signed [15:0] calc_vibrato_delta_cents;
    logic        calc_active_next;
    logic        calc_releasing;

    integer i;
    integer count_idx;
    integer free_slot;
    integer revoice_hits;
    integer count_i;
    logic event_accept;
    logic event_note_on;
    logic revoice_pending;
    logic [7:0] revoice_note_pending;
    logic [31:0] revoice_target_a_pending, revoice_target_b_pending;
    logic direct_note_on, pending_activate;

    // Full-bank victim selection is deliberately serialized.  The metadata
    // arrays are read into one registered stage, then compared against the
    // registered candidate on the following cycle.  This removes the old
    // 32-way array-read/comparator cone from the event acceptance edge while
    // preserving released -> oldest -> velocity -> voice-ID priority.
    logic        victim_scan_active;
    logic [5:0]  victim_scan_index;
    logic        victim_scan_meta_valid;
    logic        victim_scan_meta_active;
    logic        victim_scan_meta_releasing;
    logic [15:0] victim_scan_meta_age;
    logic [7:0]  victim_scan_meta_velocity;
    logic        victim_candidate_valid;
    logic [4:0]  victim_candidate_slot;
    logic        victim_candidate_releasing;
    logic [15:0] victim_candidate_age;
    logic [7:0]  victim_candidate_velocity;
    logic        sample_pending;

    always_comb begin
        for (count_idx = 0; count_idx < VOICES; count_idx = count_idx + 1)
            steal_hold[count_idx] =
                ((steal_pending || (steal_hold_value != 0)) &&
                 (steal_slot_pending == count_idx[4:0])) ?
                steal_hold_value : 16'd0;
        count_i = 0;
        for (count_idx = 0; count_idx < VOICES; count_idx = count_idx + 1)
            count_i = count_i + (active[count_idx] ? 1 : 0);
        active_voice_count = count_i[5:0];
        active_bitmap = active;

        free_slot = -1;
        if (event_data[94:91] == V2_EV_NOTE_ON) begin
            for (count_idx = 0; count_idx < VOICES; count_idx = count_idx + 1)
                if (!active[count_idx] && free_slot < 0)
                    free_slot = count_idx;
        end

        // A command is held by its producer during the complete scan. This
        // gives the bank a single deterministic write port.
        event_ready = rst_n && !scan_busy && !revoice_pending &&
                      !steal_pending && !victim_scan_active;
        event_accept = event_valid && event_ready;
        direct_note_on = event_accept && !event_data[95] &&
                         (event_data[94:91] == V2_EV_NOTE_ON) && (free_slot >= 0);
        // The victim may become inactive in the same writeback edge that
        // completes its release.  Activate the mailbox on that edge so the
        // sample boundary exposes a full voice set, while the final victim
        // sample still uses the old state.
        pending_activate = steal_pending && !revoice_pending &&
                           ((!active[steal_slot_pending] && !scan_busy) ||
                            (calc_valid && calc_active && calc_releasing &&
                             !calc_active_next &&
                             (calc_slot == steal_slot_pending)));

        bank_rd_en = scan_active;
        bank_rd_addr = scan_slot[4:0];
        bank_wr_en = 1'b0;
        bank_wr_addr = 5'd0;
        bank_wr_data = 256'd0;
        if (pending_activate) begin
            bank_wr_en = 1'b1;
            bank_wr_addr = steal_slot_pending;
            bank_wr_data[31:0] = 32'd0;
            bank_wr_data[63:32] = 32'd0;
            bank_wr_data[95:64] = steal_base_step_pending;
            bank_wr_data[127:96] = steal_base_step_pending;
            bank_wr_data[159:128] = apply_delta(steal_base_step_pending, steal_pitch_pending);
            bank_wr_data[191:160] = apply_delta(steal_base_step_pending, -steal_pitch_pending);
            bank_wr_data[207:192] = 16'd0;
            bank_wr_data[215:208] = steal_velocity_pending;
            bank_wr_data[223:216] = (steal_timbre_pending == 16'd0) ? DEFAULT_MIX_A : steal_timbre_pending[15:8];
            bank_wr_data[231:224] = (steal_timbre_pending == 16'd0) ? DEFAULT_MIX_B : steal_timbre_pending[7:0];
            bank_wr_data[233:232] = ENV_ATTACK;
            bank_wr_data[249:234] = 16'd0;
        end else if (calc_valid && calc_active) begin
            bank_wr_en = 1'b1;
            bank_wr_addr = calc_slot;
            bank_wr_data[31:0]   = calc_phase_a;
            bank_wr_data[63:32]  = calc_phase_b;
            bank_wr_data[95:64]  = calc_step_a;
            bank_wr_data[127:96] = calc_step_b;
            bank_wr_data[159:128] = calc_target_a;
            bank_wr_data[191:160] = calc_target_b;
            bank_wr_data[207:192] = calc_envelope;
            bank_wr_data[215:208] = calc_gain;
            bank_wr_data[223:216] = calc_mix_a;
            bank_wr_data[231:224] = calc_mix_b;
            bank_wr_data[233:232] = calc_env_stage;
            bank_wr_data[249:234] = calc_vibrato_phase;
        end else if (direct_note_on) begin
            bank_wr_en = 1'b1;
            bank_wr_addr = free_slot[4:0];
            bank_wr_data[31:0]   = 32'd0;
            bank_wr_data[63:32]  = 32'd0;
            bank_wr_data[95:64]  = rom_step;
            bank_wr_data[127:96] = rom_step;
            bank_wr_data[159:128] = apply_delta(rom_step, $signed({event_data[55], event_data[55:40]}));
            bank_wr_data[191:160] = apply_delta(rom_step, -$signed({event_data[55], event_data[55:40]}));
            bank_wr_data[207:192] = 16'd0;
            bank_wr_data[215:208] = event_data[63:56];
            bank_wr_data[223:216] = (event_data[39:24] == 16'd0) ? DEFAULT_MIX_A : event_data[39:32];
            bank_wr_data[231:224] = (event_data[39:24] == 16'd0) ? DEFAULT_MIX_B : event_data[31:24];
            bank_wr_data[233:232] = ENV_ATTACK;
            bank_wr_data[249:234] = 16'd0;
        end
    end

    function automatic logic [31:0] apply_delta(
        input logic [31:0] base, input logic signed [16:0] delta
    );
        logic signed [32:0] sum;
        begin
            sum = $signed({1'b0, base}) + $signed({{16{delta[16]}}, delta});
            if (sum < 33'sd0) apply_delta = 32'd0;
            else if (sum > 33'sh0FFFFFFFF) apply_delta = 32'hFFFFFFFF;
            else apply_delta = sum[31:0];
        end
    endfunction

    function automatic logic [31:0] bounded_step(input logic [31:0] current, target);
        logic [31:0] distance;
        begin
            if (current < target) begin
                distance = target - current;
                bounded_step = current + ((distance > 32'd512) ? 32'd512 : distance);
            end else if (current > target) begin
                distance = current - target;
                bounded_step = current - ((distance > 32'd512) ? 32'd512 : distance);
            end else bounded_step = current;
        end
    endfunction

    function automatic logic [15:0] vibrato_phase_increment(input logic [15:0] hz_q8_8);
        logic [31:0] numerator;
        begin
            numerator = hz_q8_8 * 32'd65536;
            vibrato_phase_increment = numerator / 32'd12288000;
        end
    endfunction

    function automatic logic signed [15:0] vibrato_cents(
        input logic [15:0] phase, input logic [15:0] cents_q8_8
    );
        logic signed [16:0] lfo;
        logic signed [31:0] product;
        begin
            lfo = $signed({1'b0, phase[14:1]}) - 17'sd16384;
            product = lfo * $signed({1'b0, cents_q8_8});
            vibrato_cents = product >>> 14;
        end
    endfunction

    function automatic logic signed [32:0] vibrato_increment_delta(
        input logic [31:0] base, input logic signed [15:0] delta_cents_q8_8
    );
        logic signed [47:0] product;
        begin
            product = $signed({1'b0, base}) * delta_cents_q8_8;
            vibrato_increment_delta = product / 33'sd307200;
        end
    endfunction

    function automatic logic [31:0] add_signed_increment(
        input logic [31:0] base, input logic signed [32:0] delta
    );
        logic signed [33:0] sum;
        begin
            sum = $signed({1'b0, base}) + delta;
            if (sum < 0) add_signed_increment = 32'd0;
            else if (sum > 34'sh0FFFFFFFF) add_signed_increment = 32'hFFFFFFFF;
            else add_signed_increment = sum[31:0];
        end
    endfunction

    function automatic logic signed [47:0] oscillator_value(
        input logic [31:0] phase, input logic [1:0] stage,
        input logic [7:0] velocity, input logic [7:0] mix
    );
        logic signed [16:0] raw;
        integer attenuation;
        begin
            raw = $signed({1'b0, phase[31:16]}) - 17'sd32768;
            attenuation = 0;
            if (stage == ENV_ATTACK) attenuation = attenuation + 2;
            if (stage == ENV_DECAY) attenuation = attenuation + 1;
            if (stage == ENV_RELEASE) attenuation = attenuation + 3;
            if (velocity < 8'd64) attenuation = attenuation + 3;
            else if (velocity < 8'd128) attenuation = attenuation + 2;
            else if (velocity < 8'd192) attenuation = attenuation + 1;
            if (mix < 8'd64) attenuation = attenuation + 3;
            else if (mix < 8'd128) attenuation = attenuation + 2;
            else if (mix < 8'd192) attenuation = attenuation + 1;
            oscillator_value = raw >>> attenuation;
        end
    endfunction

    function automatic logic signed [15:0] saturate_sample(input logic signed [47:0] value);
        begin
            if (value > 48'sd32767) saturate_sample = 16'sh7FFF;
            else if (value < -48'sd32768) saturate_sample = -16'sd32768;
            else saturate_sample = value[15:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active <= '0;
            releasing <= '0;
            for (i = 0; i < VOICES; i = i + 1) begin
                note[i] <= 8'd0;
                velocity[i] <= 8'd0;
                age[i] <= 16'd0;
            end
            age_counter <= 16'd0;
            steal_hold_value <= 16'd0;
            steal_pending <= 1'b0;
            steal_slot_pending <= 5'd0;
            steal_note_pending <= 8'd0;
            steal_velocity_pending <= 8'd0;
            steal_pitch_pending <= 16'sd0;
            steal_timbre_pending <= 16'd0;
            steal_base_step_pending <= 32'd0;
            steal_track_pending <= 3'd0;
            steal_tick_pending <= 8'd0;
            steal_duration_pending <= 8'd0;
            steal_flags_pending <= 8'd0;
            voice_overflow <= 1'b0;
            voice_steal_count <= 16'd0;
            revoice_count <= 8'd0;
            scan_active <= 1'b0;
            scan_busy <= 1'b0;
            scan_index <= 6'd0;
            scan_base <= 6'd0;
            scan_slot <= 6'd0;
            mix_acc <= '0;
            bank_rd_pending <= 1'b0;
            bank_rd_last_pending <= 1'b0;
            bank_rd_slot_pending <= 5'd0;
            rd_valid <= 1'b0;
            rd_last <= 1'b0;
            rd_active <= 1'b0;
            rd_releasing <= 1'b0;
            rd_slot <= 5'd0;
            rd_phase_a <= 0; rd_phase_b <= 0; rd_step_a <= 0; rd_step_b <= 0;
            rd_target_a <= 0; rd_target_b <= 0; rd_envelope <= 0;
            rd_gain <= 0; rd_mix_a <= DEFAULT_MIX_A; rd_mix_b <= DEFAULT_MIX_B;
            rd_env_stage <= ENV_ATTACK; rd_vibrato_phase <= 16'd0;
            calc_valid <= 1'b0; calc_last <= 1'b0; calc_active <= 1'b0;
            calc_slot <= 5'd0; calc_osc_sum <= 0;
            calc_phase_a <= 0; calc_phase_b <= 0; calc_step_a <= 0; calc_step_b <= 0;
            calc_target_a <= 0; calc_target_b <= 0; calc_envelope <= 0;
            calc_gain <= 0; calc_mix_a <= DEFAULT_MIX_A; calc_mix_b <= DEFAULT_MIX_B;
            calc_env_stage <= ENV_ATTACK; calc_vibrato_phase <= 16'd0;
            calc_vibrato_delta_cents <= 16'sd0; calc_active_next <= 1'b0;
            calc_releasing <= 1'b0;
            mixed_sample <= 16'sd0;
            sample_valid <= 1'b0;
            vibrato_phase <= 16'd0;
            vibrato_delta_cents <= 16'sd0;
            revoice_pending <= 1'b0;
            revoice_note_pending <= 8'd0;
            revoice_target_a_pending <= 32'd0;
            revoice_target_b_pending <= 32'd0;
            victim_scan_active <= 1'b0;
            victim_scan_index <= 6'd0;
            victim_scan_meta_valid <= 1'b0;
            victim_scan_meta_active <= 1'b0;
            victim_scan_meta_releasing <= 1'b0;
            victim_scan_meta_age <= 16'd0;
            victim_scan_meta_velocity <= 8'd0;
            victim_candidate_valid <= 1'b0;
            victim_candidate_slot <= 5'd0;
            victim_candidate_releasing <= 1'b0;
            victim_candidate_age <= 16'd0;
            victim_candidate_velocity <= 8'd0;
            sample_pending <= 1'b0;
        end else begin
            sample_valid <= 1'b0;

            if (event_accept && !event_data[95]) begin
                if (event_data[94:91] == V2_EV_NOTE_ON) begin
                    if (free_slot >= 0) begin
                        active[free_slot] <= 1'b1;
                        releasing[free_slot] <= 1'b0;
                        note[free_slot] <= event_data[71:64];
                        velocity[free_slot] <= event_data[63:56];
                        age[free_slot] <= age_counter;
                        age_counter <= age_counter + 16'd1;
                    end else if (free_slot < 0) begin
                        // Keep the incoming note in the one-entry mailbox
                        // while the registered metadata scan selects a
                        // deterministic victim over several cycles.
                        steal_note_pending <= event_data[71:64];
                        steal_velocity_pending <= event_data[63:56];
                        steal_pitch_pending <= $signed(event_data[55:40]);
                        steal_timbre_pending <= event_data[39:24];
                        steal_base_step_pending <= rom_step;
                        steal_track_pending <= event_data[90:88];
                        steal_tick_pending <= event_data[87:80];
                        steal_duration_pending <= event_data[79:72];
                        steal_flags_pending <= event_data[7:0];
                        victim_scan_active <= 1'b1;
                        victim_scan_index <= 6'd0;
                        victim_scan_meta_valid <= 1'b0;
                        victim_candidate_valid <= 1'b0;
                        voice_steal_count <= voice_steal_count + 16'd1;
                    end else voice_overflow <= 1'b1;
                end else if (event_data[94:91] == V2_EV_NOTE_OFF) begin
                    for (i = 0; i < VOICES; i = i + 1)
                        if (active[i] && note[i] == event_data[71:64]) releasing[i] <= 1'b1;
                end else if (event_data[94:91] == V2_EV_REVOICE) begin
                    revoice_hits = 0;
                    for (i = 0; i < VOICES; i = i + 1)
                        if (active[i] && note[i] == event_data[71:64])
                            revoice_hits = revoice_hits + 1;
                    if (revoice_hits != 0) begin
                        // REVOICE is a mailbox command. It is applied by the
                        // next complete scan so the DPB has one serialized
                        // write owner and no event-side target array writes.
                        revoice_pending <= 1'b1;
                        revoice_note_pending <= event_data[71:64];
                        revoice_target_a_pending <= apply_delta(rom_step, $signed({event_data[55], event_data[55:40]}));
                        revoice_target_b_pending <= apply_delta(rom_step, -$signed({event_data[55], event_data[55:40]}));
                        revoice_count <= revoice_count + revoice_hits[7:0];
                    end
                end else if (event_data[94:91] == V2_EV_ALL_NOTES_OFF) begin
                    for (i = 0; i < VOICES; i = i + 1)
                        if (active[i]) releasing[i] <= 1'b1;
                end
            end

            // Read one metadata row into registers, then compare that row
            // with the registered candidate on the next cycle.  The final
            // candidate is armed only after the complete scan has drained.
            if (victim_scan_active) begin
                if (victim_scan_meta_valid && victim_scan_meta_active) begin
                    if (!victim_candidate_valid ||
                        (victim_scan_meta_releasing && !victim_candidate_releasing) ||
                        ((victim_scan_meta_releasing == victim_candidate_releasing) &&
                         ((victim_scan_meta_age < victim_candidate_age) ||
                          ((victim_scan_meta_age == victim_candidate_age) &&
                           ((victim_scan_meta_velocity < victim_candidate_velocity) ||
                            ((victim_scan_meta_velocity == victim_candidate_velocity) &&
                             (victim_scan_index - 1'b1 < victim_candidate_slot))))))) begin
                        victim_candidate_valid <= 1'b1;
                        victim_candidate_slot <= victim_scan_index - 1'b1;
                        victim_candidate_releasing <= victim_scan_meta_releasing;
                        victim_candidate_age <= victim_scan_meta_age;
                        victim_candidate_velocity <= victim_scan_meta_velocity;
                    end
                end
                if (victim_scan_index < VOICES) begin
                    victim_scan_meta_valid <= 1'b1;
                    victim_scan_meta_active <= active[victim_scan_index];
                    victim_scan_meta_releasing <= releasing[victim_scan_index];
                    victim_scan_meta_age <= age[victim_scan_index];
                    victim_scan_meta_velocity <= velocity[victim_scan_index];
                    victim_scan_index <= victim_scan_index + 6'd1;
                end else if (victim_scan_meta_valid) begin
                    victim_scan_meta_valid <= 1'b0;
                end else begin
                    victim_scan_active <= 1'b0;
                    if (victim_candidate_valid) begin
                        steal_pending <= 1'b1;
                        steal_slot_pending <= victim_candidate_slot;
                        releasing[victim_candidate_slot] <= 1'b1;
                        steal_hold_value <= STEAL_RELEASE_SAMPLES;
                    end else begin
                        voice_overflow <= 1'b1;
                    end
                end
            end

            if (calc_valid && calc_active) begin
                mix_acc <= mix_acc + calc_osc_sum;
                if (calc_releasing && (calc_slot == steal_slot_pending) &&
                    (steal_hold_value != 0))
                    steal_hold_value <= steal_hold_value - 16'd1;
                if (!calc_active_next) begin
                    active[calc_slot] <= 1'b0;
                    releasing[calc_slot] <= 1'b0;
                end
            end
            if (pending_activate) begin
                active[steal_slot_pending] <= 1'b1;
                releasing[steal_slot_pending] <= 1'b0;
                note[steal_slot_pending] <= steal_note_pending;
                velocity[steal_slot_pending] <= steal_velocity_pending;
                age[steal_slot_pending] <= age_counter;
                age_counter <= age_counter + 16'd1;
                steal_hold_value <= 16'd0;
                steal_pending <= 1'b0;
            end
            if (calc_valid && calc_last) begin
                mixed_sample <= calc_active ? saturate_sample(mix_acc + calc_osc_sum) : saturate_sample(mix_acc);
                sample_valid <= 1'b1;
                scan_index <= 6'd0;
                scan_base <= (scan_base == VOICES - 1) ? 6'd0 : scan_base + 6'd1;
                mix_acc <= 48'sd0;
                scan_busy <= 1'b0;
                revoice_pending <= 1'b0;
            end

            // Compute stage.
            calc_valid <= rd_valid;
            calc_last <= rd_last;
            calc_active <= rd_active;
            calc_slot <= rd_slot;
            calc_gain <= rd_gain;
            calc_mix_a <= rd_mix_a;
            calc_mix_b <= rd_mix_b;
            calc_target_a <= rd_target_a;
            calc_target_b <= rd_target_b;
            calc_phase_a <= rd_phase_a + rd_step_a;
            calc_phase_b <= rd_phase_b + rd_step_b;
            calc_step_a <= rd_step_a;
            calc_step_b <= rd_step_b;
            calc_target_a <= rd_target_a;
            calc_target_b <= rd_target_b;
            calc_envelope <= rd_envelope;
            calc_env_stage <= rd_env_stage;
            calc_vibrato_phase <= rd_vibrato_phase + vibrato_phase_increment(vibrato_hz_q8_8);
            calc_vibrato_delta_cents <= vibrato_cents(
                rd_vibrato_phase + vibrato_phase_increment(vibrato_hz_q8_8),
                vibrato_cents_q8_8);
            calc_active_next <= rd_active;
            calc_releasing <= rd_releasing;
            calc_osc_sum <= 48'sd0;
            if (rd_valid && rd_active) begin
                calc_osc_sum <= oscillator_value(rd_phase_a, rd_releasing ? ENV_RELEASE : rd_env_stage, rd_gain, rd_mix_a)
                              + oscillator_value(rd_phase_b, rd_releasing ? ENV_RELEASE : rd_env_stage, rd_gain, rd_mix_b);
                calc_step_a <= add_signed_increment(
                    bounded_step(rd_step_a, rd_target_a),
                    vibrato_increment_delta(
                        bounded_step(rd_step_a, rd_target_a),
                        vibrato_cents(rd_vibrato_phase + vibrato_phase_increment(vibrato_hz_q8_8), vibrato_cents_q8_8)));
                calc_step_b <= add_signed_increment(
                    bounded_step(rd_step_b, rd_target_b),
                    -vibrato_increment_delta(
                        bounded_step(rd_step_b, rd_target_b),
                        vibrato_cents(rd_vibrato_phase + vibrato_phase_increment(vibrato_hz_q8_8), vibrato_cents_q8_8)));
                if (rd_slot == 0) begin
                    vibrato_phase <= rd_vibrato_phase + vibrato_phase_increment(vibrato_hz_q8_8);
                    vibrato_delta_cents <= vibrato_cents(
                        rd_vibrato_phase + vibrato_phase_increment(vibrato_hz_q8_8),
                        vibrato_cents_q8_8);
                end
                if (rd_releasing) begin
                    calc_env_stage <= ENV_RELEASE;
                    if (rd_envelope <= RELEASE_STEP &&
                        ((rd_slot != steal_slot_pending) || (steal_hold_value == 0))) begin
                        calc_envelope <= 16'd0;
                        calc_active_next <= 1'b0;
                    end else if (rd_envelope <= RELEASE_STEP) begin
                        // Keep a quiet release tail while the bounded steal
                        // hold is active; never wrap the 16-bit envelope.
                        calc_envelope <= 16'd0;
                    end else calc_envelope <= rd_envelope - RELEASE_STEP;
                end else if (rd_env_stage == ENV_ATTACK) begin
                    if ({1'b0, rd_envelope} + {1'b0, ATTACK_STEP} >= 17'h0FFFF) begin
                        calc_envelope <= 16'hFFFF; calc_env_stage <= ENV_DECAY;
                    end else calc_envelope <= rd_envelope + ATTACK_STEP;
                end else if (rd_env_stage == ENV_DECAY) begin
                    if (rd_envelope <= SUSTAIN_LEVEL + DECAY_STEP) begin
                        calc_envelope <= SUSTAIN_LEVEL; calc_env_stage <= ENV_SUSTAIN;
                    end else calc_envelope <= rd_envelope - DECAY_STEP;
                end
            end

            // Capture the registered bank output and issue the next address.
            rd_valid <= bank_rd_pending;
            rd_last <= bank_rd_last_pending;
            rd_slot <= bank_rd_slot_pending;
            rd_active <= active[bank_rd_slot_pending];
            rd_releasing <= releasing[bank_rd_slot_pending];
            if (bank_rd_pending) begin
                rd_phase_a <= bank_rd_data[31:0];
                rd_phase_b <= bank_rd_data[63:32];
                rd_step_a <= bank_rd_data[95:64];
                rd_step_b <= bank_rd_data[127:96];
                if (revoice_pending && (note[bank_rd_slot_pending] == revoice_note_pending)) begin
                    rd_target_a <= revoice_target_a_pending;
                    rd_target_b <= revoice_target_b_pending;
                end else begin
                    rd_target_a <= bank_rd_data[159:128];
                    rd_target_b <= bank_rd_data[191:160];
                end
                rd_envelope <= bank_rd_data[207:192];
                rd_gain <= bank_rd_data[215:208];
                rd_mix_a <= bank_rd_data[223:216];
                rd_mix_b <= bank_rd_data[231:224];
                rd_env_stage <= bank_rd_data[233:232];
                rd_vibrato_phase <= bank_rd_data[249:234];
            end
            bank_rd_pending <= bank_rd_en;
            bank_rd_last_pending <= scan_active && (scan_index == VOICES - 1);
            bank_rd_slot_pending <= scan_slot[4:0];

            if (scan_active) begin
                if (scan_index == VOICES - 1) scan_active <= 1'b0;
                else begin
                    scan_index <= scan_index + 6'd1;
                    scan_slot <= (scan_slot == VOICES - 1) ? 6'd0 : scan_slot + 6'd1;
                end
            end else if (sample_ce && !scan_busy) begin
                if (victim_scan_active) begin
                    sample_pending <= 1'b1;
                end else begin
                    scan_busy <= 1'b1;
                    scan_active <= 1'b1;
                    scan_index <= 6'd0;
                    scan_slot <= scan_base;
                    mix_acc <= 48'sd0;
                    sample_pending <= 1'b0;
                end
            end else if (sample_pending && !scan_busy && !victim_scan_active) begin
                scan_busy <= 1'b1;
                scan_active <= 1'b1;
                scan_index <= 6'd0;
                scan_slot <= scan_base;
                mix_acc <= 48'sd0;
                sample_pending <= 1'b0;
            end
        end
    end
endmodule
