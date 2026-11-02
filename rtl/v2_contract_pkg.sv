package v2_contract_pkg;
  localparam logic [7:0] V2_VERSION = 8'h02;
  localparam logic [7:0] V2_CONTROL_SOF = 8'hA5;
  localparam logic [7:0] V2_TELEMETRY_SOF = 8'h5A;
  localparam int V2_EVENT_BITS = 96;
  localparam int V2_CONTROL_BYTES = 11;
  localparam int V2_TELEMETRY_BYTES = 22;
  localparam logic [3:0] V2_EV_NOTE_ON=4'd1, V2_EV_NOTE_OFF=4'd2,
      V2_EV_REVOICE=4'd3, V2_EV_CONTROL=4'd4, V2_EV_ALL_NOTES_OFF=4'd5,
      V2_EV_BOUNDARY=4'd6;
  localparam logic [7:0] V2_FLAG_TOUCH=8'h01, V2_FLAG_BOW=8'h02,
      V2_FLAG_Z=8'h04, V2_FLAG_REBASED=8'h08,
      V2_FLAG_DEGRADED=8'h10, V2_FLAG_GAP=8'h20;
  localparam logic [7:0] V2_FAULT_NONE=8'd0, V2_FAULT_INVALID=8'd1,
      V2_FAULT_REVERSE=8'd2, V2_FAULT_FIFO=8'd3, V2_FAULT_TICK=8'd4,
      V2_FAULT_OVERFLOW=8'd5, V2_FAULT_ABORT=8'd6;
  localparam logic [7:0] V2_OP_READ=8'h01, V2_OP_WRITE=8'h02,
      V2_OP_PING=8'h03;
  localparam logic [7:0] V2_ACK_ACCEPTED=8'd0, V2_ACK_APPLIED=8'd1,
      V2_ACK_REJECTED=8'd2, V2_ACK_BUSY=8'd3, V2_ACK_ERROR=8'd4,
      V2_ACK_SHADOW_STORED=8'd5, V2_ACK_APPLY_ACCEPTED=8'd6;
  localparam logic [7:0] V2_TLM_SNAPSHOT=8'h01,
      V2_TLM_STATS=8'h02, V2_TLM_TABLE=8'h03,
      V2_TLM_ACK=8'h80, V2_TLM_NACK=8'h81;
  localparam int V2_RESPONSE_TIMEOUT_MS=1000;
  localparam int V2_BOUNDARY_TIMEOUT_MS=34000;
  localparam logic [7:0] V2_WT_A=8'd0, V2_WT_B=8'd1, V2_WT_C=8'd2;
  localparam int V2_WT_SAMPLES=1024;
  localparam int V2_WT_BAND_BITS=3;
  localparam int V2_WT_BAND_MAX=7;
  localparam int V2_WT_OCTAVE_BITS=4;
  localparam int V2_WT_OCTAVE_MAX=15;
  localparam int V2_WT_BAND_DEFAULT=0;
  localparam int V2_WT_OCTAVE_DEFAULT=0;

  localparam int V2_LOOP_BANKS=2;
  localparam int V2_LOOP_TRACKS=6;
  localparam int V2_LOOP_SLOTS_PER_TRACK=32;
  localparam int V2_LOOP_SLOT_BITS=5;
  localparam int V2_LOOP_COUNT_BITS=6;
  localparam int V2_LOOP_TOTAL_SLOTS=192;
  localparam int V2_VOICE_COUNT=32;
  localparam int V2_OSCILLATORS_PER_VOICE=2;
  localparam int V2_VOICE_STEAL_COUNTER_BITS=16;
  localparam int V2_VOICE_STEAL_PRIORITY_COUNT=4;
  localparam int V2_VOICE_STEAL_RELEASED=0;
  localparam int V2_VOICE_STEAL_OLDEST=1;
  localparam int V2_VOICE_STEAL_LOWEST_VELOCITY=2;
  localparam int V2_VOICE_STEAL_LOWEST_VOICE_ID=3;
  // P2b voice parameter pack (spec 11.1/11.3): the one source of the engine's
  // seven defaults, and the only value a testbench has to pass.  The layout is
  // low field first, exactly what v2_voice_engine_banked unpacks:
  //   [15:0] attack_step   [31:16] decay_step  [47:32] sustain_level
  //   [63:48] release_step [65:64] velocity_shift [67:66] detune_shift
  //   [83:68] glide_rate   [95:84] reserved 0
  // Every field is a named constant, so the default is readable as the numbers
  // the design has always used and no field can drift out of place silently.
  localparam logic [15:0] V2_VOICE_CFG_ATTACK_DEFAULT  = 16'd4096;
  localparam logic [15:0] V2_VOICE_CFG_DECAY_DEFAULT   = 16'd256;
  localparam logic [15:0] V2_VOICE_CFG_SUSTAIN_DEFAULT = 16'd49152;
  localparam logic [15:0] V2_VOICE_CFG_RELEASE_DEFAULT = 16'd1024;
  localparam logic [1:0]  V2_VOICE_CFG_VELOCITY_SHIFT_DEFAULT = 2'd0;
  localparam logic [1:0]  V2_VOICE_CFG_DETUNE_SHIFT_DEFAULT   = 2'd0;
  localparam logic [15:0] V2_VOICE_CFG_GLIDE_DEFAULT   = 16'd512;
  localparam logic [95:0] V2_VOICE_CFG_DEFAULT = {
      12'd0,
      V2_VOICE_CFG_GLIDE_DEFAULT,
      V2_VOICE_CFG_DETUNE_SHIFT_DEFAULT,
      V2_VOICE_CFG_VELOCITY_SHIFT_DEFAULT,
      V2_VOICE_CFG_RELEASE_DEFAULT,
      V2_VOICE_CFG_SUSTAIN_DEFAULT,
      V2_VOICE_CFG_DECAY_DEFAULT,
      V2_VOICE_CFG_ATTACK_DEFAULT};
  localparam logic [7:0] V2_TEST_SELECTOR_N_TONE=8'd1;
  localparam logic [7:0] V2_TEST_SELECTOR_VIBRATO_READBACK=8'd2;
  localparam int V2_TEST_N_TONE_COUNT_MIN=1;
  localparam int V2_TEST_N_TONE_COUNT_MAX=32;
  localparam int V2_TEST_N_TONE_COUNT_DEFAULT=8;
  localparam int V2_VIBRATO_READBACK_PHASE_BITS=16;
  localparam int V2_VIBRATO_READBACK_DELTA_CENTS_BITS=16;
  localparam int V2_VIBRATO_READBACK_PHASE_SHIFT=0;
  localparam int V2_VIBRATO_READBACK_DELTA_CENTS_SHIFT=16;
  localparam logic [31:0] V2_VIBRATO_READBACK_PHASE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_VIBRATO_READBACK_DELTA_CENTS_MASK=32'hFFFF0000;

  typedef enum logic [2:0] { IDLE, LIVE, RECORD, COMMIT, PLAY, ERROR, WT_PLAY } v2_mode_e;

  // Packed MSB-first layout: reserved[95], then the named fields through sequence[15:0].
  // The reserved bit is frozen at zero by serializers; the named fields are directly accessible.
  typedef struct packed {
    logic        reserved;
    logic [3:0]  event_type;
    logic [2:0]  track;
    logic [7:0]  tick;
    logic [7:0]  duration;
    logic [7:0]  note;
    logic [7:0]  velocity;
    logic signed [15:0] pitch_mod;
    logic [15:0] timbre_mod;
    logic [7:0]  flags;
    logic [15:0] event_sequence;
  } v2_event_t;

  typedef struct packed {
    logic [7:0]  op;
    logic [7:0]  address;
    logic [7:0]  event_sequence;
    logic [31:0] data;
  } v2_cmd_t;
  typedef struct packed {
    logic [7:0]  event_type;
    logic [15:0] event_sequence;
    logic signed [15:0] x;
    logic signed [15:0] y;
    logic signed [15:0] z;
    logic [7:0] note;
    logic [7:0] flags;
    logic [7:0] tick;
    logic [31:0] voice_bitmap;
    logic [7:0] fifo_level;
    logic [7:0] fault_code;
  } v2_telemetry_t;

  localparam logic [7:0] V2_ADDR_LEGACY_FIRST = 8'h00;
  localparam logic [7:0] V2_ADDR_LEGACY_LAST  = 8'h44;
  localparam logic [7:0] V2_ADDR_WT_FIRST     = 8'h60;
  localparam logic [7:0] V2_ADDR_WT_LAST      = 8'h7C;
  localparam logic [7:0] V2_ADDR_TLM_FIRST    = 8'h80;
localparam logic [7:0] V2_ADDR_TLM_LAST     = 8'h9C;
localparam logic [7:0] V2_ADDR_DIAG_FIRST   = 8'hB0;
  localparam logic [7:0] V2_ADDR_DIAG_LAST    = 8'hFC;
  localparam logic [7:0] V2_ADDR_TEST_FIRST   = 8'hA0;
  localparam logic [7:0] V2_ADDR_TEST_LAST    = 8'hAF;

  // Word register offsets; A0..AF are sixteen indexed test selectors.
  localparam logic [7:0] V2_CSR_STATUS=8'h00, V2_CSR_MODE=8'h04,
      V2_CSR_BPM=8'h08, V2_CSR_TRACK=8'h0C, V2_CSR_PLAY=8'h10,
      V2_CSR_STOP=8'h14, V2_CSR_RECORD=8'h18, V2_CSR_OVERDUB=8'h1C,
      V2_CSR_CLEAR_TRACK=8'h20, V2_CSR_CLEAR_ALL=8'h24,
      V2_CSR_COMMIT=8'h28, V2_CSR_RESET=8'h2C,
      V2_CSR_THRESHOLDS=8'h30, V2_CSR_CONTOUR_DATA=8'h34,
      V2_CSR_POTTS_STATUS=8'h38, V2_CSR_POTTS_LAMBDA=8'h3C,
      V2_CSR_FILTER=8'h40, V2_CSR_LFO=8'h44;
  localparam logic [7:0] V2_CSR_WT_SELECT=8'h60,
      V2_CSR_WT_INDEX=8'h64, V2_CSR_WT_DATA=8'h68,
      V2_CSR_WT_LENGTH=8'h6C, V2_CSR_WT_CRC=8'h70,
      V2_CSR_WT_VERSION=8'h74, V2_CSR_WT_APPLY=8'h78,
      V2_CSR_WT_STATUS=8'h7C;
  localparam logic [7:0] V2_CSR_TLM_CONTROL=8'h80,
      V2_CSR_FX_A=8'h84, V2_CSR_FX_B=8'h88,
      V2_CSR_FX_C=8'h8C, V2_CSR_VOLUME=8'h90;
  // P2b parameter surface (spec 11.1).  These three addresses were the empty
  // TLM_FIFO / TLM_FAULT / TLM_TABLE_VERSION shells; nothing ever implemented
  // them, so they are reused rather than appended.
  localparam logic [7:0] V2_CSR_ENV_AD=8'h94, V2_CSR_ENV_SR=8'h98,
      V2_CSR_VOICE_MIX=8'h9C;
  localparam logic [7:0] V2_CSR_TEST_SELECT=8'hA0;
  localparam logic [1:0] V2_ACCESS_NONE=2'd0, V2_ACCESS_RO=2'd1,
      V2_ACCESS_WO=2'd2, V2_ACCESS_RW=2'd3;

  localparam logic [7:0] V2_ERR_NONE = 8'h00;
  localparam logic [7:0] V2_ERR_BAD_CRC = 8'h01;
  localparam logic [7:0] V2_ERR_BAD_ADDRESS = 8'h02;
  localparam logic [7:0] V2_ERR_BAD_VERSION = 8'h03;
  localparam logic [7:0] V2_ERR_BAD_LENGTH = 8'h04;
  localparam logic [7:0] V2_ERR_SEQUENCE = 8'h05;
  localparam logic [7:0] V2_ERR_BAD_OP=8'h06, V2_ERR_BAD_DATA=8'h07,
      V2_ERR_VERSION=8'h08, V2_ERR_INCOMPLETE=8'h09,
      V2_ERR_WT_CRC=8'h0A, V2_ERR_OVERFLOW=8'h0B,
      V2_ERR_TIMEOUT=8'h0C;

  // Generated parity surface for CSR masks, field shifts and parameter indices.
  localparam logic [31:0] V2_CSR_STATUS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_MODE_WRITE_MASK=32'h00000007;
  localparam logic [31:0] V2_CSR_BPM_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_TRACK_WRITE_MASK=32'h00000007;
  localparam logic [31:0] V2_CSR_PLAY_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_STOP_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_RECORD_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_OVERDUB_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_CLEAR_TRACK_WRITE_MASK=32'h00000107;
  localparam logic [31:0] V2_CSR_CLEAR_ALL_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_COMMIT_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_RESET_WRITE_MASK=32'h00000001;
  localparam logic [31:0] V2_CSR_THRESHOLDS_WRITE_MASK=32'hFFFFFFFF;
  localparam logic [31:0] V2_CSR_CONTOUR_DATA_WRITE_MASK=32'h0000001F;
  localparam logic [31:0] V2_CSR_POTTS_STATUS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_POTTS_LAMBDA_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_FILTER_WRITE_MASK=32'h010FFFFF;
  localparam logic [31:0] V2_CSR_LFO_WRITE_MASK=32'h3FFFFFFF;
  localparam logic [31:0] V2_CSR_WT_SELECT_WRITE_MASK=32'hFFFFFFF7;
  localparam logic [31:0] V2_CSR_WT_INDEX_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_DATA_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_LENGTH_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_CRC_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_VERSION_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_APPLY_WRITE_MASK=32'h8000FFFF;
  localparam logic [31:0] V2_CSR_WT_STATUS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_CONTROL_WRITE_MASK=32'hFFFF0001;
  localparam logic [31:0] V2_CSR_FX_A_WRITE_MASK=32'h001FFFFF;
  localparam logic [31:0] V2_CSR_FX_B_WRITE_MASK=32'hFFFF03FF;
  localparam logic [31:0] V2_CSR_FX_C_WRITE_MASK=32'hFFFFFFFF;
  localparam logic [31:0] V2_CSR_VOLUME_WRITE_MASK=32'h0003FFFF;
  localparam logic [31:0] V2_CSR_ENV_AD_WRITE_MASK=32'hFFFFFFFF;
  localparam logic [31:0] V2_CSR_ENV_SR_WRITE_MASK=32'hFFFFFFFF;
  // Only the two 2-bit shift fields live in the low half of VOICE_MIX; a
  // velocity_depth byte is not part of this round (spec 11.3 uses a shift).
  localparam logic [31:0] V2_CSR_VOICE_MIX_WRITE_MASK=32'hFFFF000F;
  localparam logic [31:0] V2_CSR_TEST_SELECT_WRITE_MASK=32'hFFFFFFFF;
  localparam int V2_CSR_STATUS_MODE_SHIFT=0;
  localparam int V2_CSR_STATUS_ACTIVE_VALID_SHIFT=8;
  localparam int V2_CSR_STATUS_FAULT_SHIFT=9;
  localparam int V2_CSR_MODE_MODE_SHIFT=0;
  localparam int V2_CSR_BPM_ACTIVE_BPM_SHIFT=16;
  localparam int V2_CSR_BPM_SHADOW_BPM_SHIFT=0;
  localparam int V2_CSR_TRACK_TRACK_SHIFT=0;
  localparam int V2_CSR_PLAY_TRIGGER_SHIFT=0;
  localparam int V2_CSR_STOP_TRIGGER_SHIFT=0;
  localparam int V2_CSR_RECORD_TRIGGER_SHIFT=0;
  localparam int V2_CSR_OVERDUB_TRIGGER_SHIFT=0;
  localparam int V2_CSR_CLEAR_TRACK_TRACK_SHIFT=0;
  localparam int V2_CSR_CLEAR_TRACK_TRIGGER_SHIFT=8;
  localparam int V2_CSR_CLEAR_ALL_TRIGGER_SHIFT=0;
  localparam int V2_CSR_COMMIT_TRIGGER_SHIFT=0;
  localparam int V2_CSR_RESET_TRIGGER_SHIFT=0;
  localparam int V2_CSR_THRESHOLDS_RELEASE_SHIFT=16;
  localparam int V2_CSR_THRESHOLDS_ENGAGE_SHIFT=0;
  // 0x34 is a window: the write selects the sample, the read returns it and
  // advances the pointer.
  localparam int V2_CSR_CONTOUR_DATA_INDEX_SHIFT=0;
  localparam int V2_CSR_POTTS_STATUS_DONE_SHIFT=0;
  localparam int V2_CSR_POTTS_STATUS_BUSY_SHIFT=1;
  localparam int V2_CSR_POTTS_STATUS_OVERFLOW_SHIFT=2;
  localparam int V2_CSR_POTTS_STATUS_TIMEOUT_SHIFT=3;
  localparam int V2_CSR_POTTS_STATUS_FULL_SHIFT=4;
  localparam int V2_CSR_POTTS_LAMBDA_VALUE_SHIFT=0;
  localparam int V2_CSR_WT_SELECT_TABLE_ID_SHIFT=0;
  localparam int V2_CSR_WT_SELECT_VOICE_SHIFT_SHIFT=4;
  localparam int V2_CSR_WT_SELECT_MORPH_EN_SHIFT=8;
  localparam int V2_CSR_WT_SELECT_LFO_STEP_SHIFT=9;
  // Default scaling between the wavetable samples and the 32-voice mix sum.
  // This is a gain, not only a headroom control: a 0.9 FS table already loses
  // 18 dB in the per-voice attenuation and another 12 dB in the output trim, so
  // shift 6 left a single note at about -66 dBFS and the board was silent.
  // Shift 2 puts one note near -37 dBFS and lets two full-scale voices sum to
  // 29490 without clipping.  Three or more voices saturate in the mix (no wrap);
  // making loud single notes AND 32 clip-free voices needs a real gain stage or
  // limiter, which is still open.
  localparam logic [3:0] V2_WT_VOICE_SHIFT_DEFAULT=4'd2;
  localparam int V2_CSR_WT_INDEX_SAMPLE_INDEX_SHIFT=0;
  localparam int V2_CSR_WT_DATA_SAMPLE_S16_SHIFT=0;
  localparam int V2_CSR_WT_LENGTH_SAMPLE_COUNT_SHIFT=0;
  localparam int V2_CSR_WT_CRC_CRC16_CCITT_SHIFT=0;
  localparam int V2_CSR_WT_VERSION_EXPECTED_VERSION_SHIFT=0;
  localparam int V2_CSR_WT_APPLY_EXPECTED_VERSION_SHIFT=0;
  localparam int V2_CSR_WT_APPLY_TRIGGER_SHIFT=31;
  localparam int V2_CSR_WT_STATUS_ACTIVE_VERSION_SHIFT=0;
  localparam int V2_CSR_WT_STATUS_SHADOW_VALID_SHIFT=16;
  localparam int V2_CSR_WT_STATUS_APPLY_BUSY_SHIFT=17;
  localparam int V2_CSR_WT_STATUS_LAST_ERROR_SHIFT=24;
  localparam int V2_CSR_TLM_CONTROL_ENABLE_SHIFT=0;
  localparam int V2_CSR_TLM_CONTROL_PERIOD_MS_SHIFT=16;
  localparam int V2_CSR_ENV_AD_ATTACK_STEP_SHIFT=0;
  localparam int V2_CSR_ENV_AD_DECAY_STEP_SHIFT=16;
  localparam int V2_CSR_ENV_SR_SUSTAIN_LEVEL_SHIFT=0;
  localparam int V2_CSR_ENV_SR_RELEASE_STEP_SHIFT=16;
  localparam int V2_CSR_VOICE_MIX_VELOCITY_SHIFT_SHIFT=0;
  localparam int V2_CSR_VOICE_MIX_DETUNE_SHIFT_SHIFT=2;
  localparam int V2_CSR_VOICE_MIX_GLIDE_RATE_SHIFT=16;
  localparam int V2_LOOP_TICKS=128;
  localparam int V2_TICKS_PER_BEAT=4;
  localparam int V2_BPM_MIN=60;
  localparam int V2_BPM_MAX=240;
  localparam int V2_BPM_DEFAULT=120;

  localparam int V2_CSR_TEST_SELECT_SELECTOR_SHIFT=0;
  localparam int V2_CSR_TEST_SELECT_VALUE_SHIFT=8;

  function automatic bit v2_address_valid(input logic [7:0] address);
    return ((address >= V2_ADDR_TEST_FIRST && address <= V2_ADDR_TEST_LAST) ||
            ((address[1:0] == 2'b00) &&
            ((address >= V2_ADDR_LEGACY_FIRST && address <= V2_ADDR_LEGACY_LAST) ||
            (address >= V2_ADDR_WT_FIRST && address <= V2_ADDR_WT_LAST) ||
            (address >= V2_ADDR_DIAG_FIRST && address <= V2_ADDR_DIAG_LAST) ||
  (address >= V2_ADDR_TLM_FIRST && address <= V2_ADDR_TLM_LAST))));
  endfunction
  function automatic logic [1:0] v2_csr_access(input logic [7:0] address);
    if (address >= 8'hA0 && address <= 8'hAF) return V2_ACCESS_RW;
    if (address[1:0] != 2'b00 || !v2_address_valid(address)) return V2_ACCESS_NONE;
    case (address)
      V2_CSR_STATUS, V2_CSR_POTTS_STATUS,
      V2_CSR_WT_STATUS: return V2_ACCESS_RO;
      V2_CSR_PLAY, V2_CSR_STOP, V2_CSR_RECORD, V2_CSR_OVERDUB,
      V2_CSR_CLEAR_TRACK, V2_CSR_CLEAR_ALL, V2_CSR_COMMIT,
      V2_CSR_RESET, V2_CSR_WT_APPLY: return V2_ACCESS_WO;
      default: return V2_ACCESS_RW;
    endcase
  endfunction
  function automatic logic [31:0] v2_csr_write_mask(input logic [7:0] address);
    if (address >= 8'hA0 && address <= 8'hAF) return V2_CSR_TEST_SELECT_WRITE_MASK;
    if (!v2_address_valid(address)) return 32'h00000000;
    case (address)
      V2_CSR_STATUS: return V2_CSR_STATUS_WRITE_MASK;
      V2_CSR_MODE: return V2_CSR_MODE_WRITE_MASK;
      V2_CSR_BPM: return V2_CSR_BPM_WRITE_MASK;
      V2_CSR_TRACK: return V2_CSR_TRACK_WRITE_MASK;
      V2_CSR_PLAY: return V2_CSR_PLAY_WRITE_MASK;
      V2_CSR_STOP: return V2_CSR_STOP_WRITE_MASK;
      V2_CSR_RECORD: return V2_CSR_RECORD_WRITE_MASK;
      V2_CSR_OVERDUB: return V2_CSR_OVERDUB_WRITE_MASK;
      V2_CSR_CLEAR_TRACK: return V2_CSR_CLEAR_TRACK_WRITE_MASK;
      V2_CSR_CLEAR_ALL: return V2_CSR_CLEAR_ALL_WRITE_MASK;
      V2_CSR_COMMIT: return V2_CSR_COMMIT_WRITE_MASK;
      V2_CSR_RESET: return V2_CSR_RESET_WRITE_MASK;
      V2_CSR_THRESHOLDS: return V2_CSR_THRESHOLDS_WRITE_MASK;
      V2_CSR_CONTOUR_DATA: return V2_CSR_CONTOUR_DATA_WRITE_MASK;
      V2_CSR_POTTS_STATUS: return V2_CSR_POTTS_STATUS_WRITE_MASK;
      V2_CSR_POTTS_LAMBDA: return V2_CSR_POTTS_LAMBDA_WRITE_MASK;
      V2_CSR_FILTER: return V2_CSR_FILTER_WRITE_MASK;
      V2_CSR_LFO: return V2_CSR_LFO_WRITE_MASK;
      V2_CSR_WT_SELECT: return V2_CSR_WT_SELECT_WRITE_MASK;
      V2_CSR_WT_INDEX: return V2_CSR_WT_INDEX_WRITE_MASK;
      V2_CSR_WT_DATA: return V2_CSR_WT_DATA_WRITE_MASK;
      V2_CSR_WT_LENGTH: return V2_CSR_WT_LENGTH_WRITE_MASK;
      V2_CSR_WT_CRC: return V2_CSR_WT_CRC_WRITE_MASK;
      V2_CSR_WT_VERSION: return V2_CSR_WT_VERSION_WRITE_MASK;
      V2_CSR_WT_APPLY: return V2_CSR_WT_APPLY_WRITE_MASK;
      V2_CSR_WT_STATUS: return V2_CSR_WT_STATUS_WRITE_MASK;
      V2_CSR_TLM_CONTROL: return V2_CSR_TLM_CONTROL_WRITE_MASK;
      V2_CSR_FX_A: return V2_CSR_FX_A_WRITE_MASK;
      V2_CSR_FX_B: return V2_CSR_FX_B_WRITE_MASK;
      V2_CSR_FX_C: return V2_CSR_FX_C_WRITE_MASK;
      V2_CSR_VOLUME: return V2_CSR_VOLUME_WRITE_MASK;
      V2_CSR_ENV_AD: return V2_CSR_ENV_AD_WRITE_MASK;
      V2_CSR_ENV_SR: return V2_CSR_ENV_SR_WRITE_MASK;
      V2_CSR_VOICE_MIX: return V2_CSR_VOICE_MIX_WRITE_MASK;
      default: return 32'h00000000;
    endcase
  endfunction
  // Single source of truth for parameter validation: a write succeeds with the
  // value clamped (spec 2026-11-01 section 11.6), it is never NACKed for range.
  // Addresses outside the nine parameter CSRs pass through untouched.
  // For those, the final AND with the write mask guarantees that a write can
  // never leave a bit outside the mask behind.
  function automatic logic [31:0] v2_csr_clamp(input logic [7:0] address,
                                               input logic [31:0] data);
    logic [31:0] clamped;
    begin
      clamped = data;
      case (address)
        V2_CSR_FILTER: begin
          // res[19:12] is already inside the mask, so 0..255 needs no clamp.
          if (clamped[11:0] > 12'd423) clamped[11:0] = 12'd423;
        end
        V2_CSR_LFO: begin
          // depth[23:16] is already inside the mask, so 0..255 needs no clamp.
          if (clamped[15:0] > 16'd20000) clamped[15:0] = 16'd20000;
        end
        V2_CSR_FX_A: begin
          if (clamped[17:0] > 18'h10000) clamped[17:0] = 18'h10000;
        end
        V2_CSR_FX_B: begin
          // delay_samples is a truncation, not a saturation (spec 11.2); the
          // mask alone defines it.
        end
        V2_CSR_FX_C: begin
          if (clamped[15:0] > 16'h7333) clamped[15:0] = 16'h7333;
          if (clamped[31:16] > 16'h7FFF) clamped[31:16] = 16'h7FFF;
        end
        V2_CSR_VOLUME: begin
          if (clamped[17:0] > 18'h20000) clamped[17:0] = 18'h20000;
        end
        V2_CSR_ENV_AD: begin
          // decay_step 0 is legal (the envelope holds the peak); attack_step 0
          // is not (the envelope never rises, so the voice is silent forever
          // while still holding a slot).
          if (clamped[15:0] == 16'd0) clamped[15:0] = 16'd1;
        end
        V2_CSR_ENV_SR: begin
          // sustain_level 0 is legal (silent sustain); release_step 0 is a
          // deadlock, not a silence: the envelope never reaches zero, active[]
          // never clears and event_ready never comes back (spec 11.6).
          if (clamped[31:16] == 16'd0) clamped[31:16] = 16'd1;
        end
        V2_CSR_VOICE_MIX: begin
          // Both 2-bit shift fields accept their whole range, so only the glide
          // floor is left: glide_rate 0 would pin every offset note to its base
          // pitch forever.
          if (clamped[31:16] == 16'd0) clamped[31:16] = 16'd1;
        end
        default: return data;
      endcase
      return (clamped & v2_csr_write_mask(address));
    end
  endfunction
  function automatic bit v2_csr_data_valid(input logic [7:0] address,
                                            input logic [31:0] data);
    if (v2_csr_access(address) != V2_ACCESS_RW &&
        v2_csr_access(address) != V2_ACCESS_WO) return 1'b0;
    if ((data & ~v2_csr_write_mask(address)) != 0) return 1'b0;
    case (address)
      V2_CSR_MODE: return data <= 6;
      V2_CSR_TRACK: return data <= 5;
      V2_CSR_BPM: return data >= V2_BPM_MIN && data <= V2_BPM_MAX;
      V2_CSR_THRESHOLDS: return data[15:0] < data[31:16];
      V2_CSR_WT_SELECT: return data[2:0] <= V2_WT_C;
      V2_CSR_WT_INDEX: return data < V2_WT_SAMPLES;
      V2_CSR_WT_LENGTH: return data == V2_WT_SAMPLES;
      V2_CSR_WT_APPLY: return data[31];
      V2_CSR_PLAY, V2_CSR_STOP, V2_CSR_RECORD, V2_CSR_OVERDUB,
      V2_CSR_CLEAR_ALL, V2_CSR_COMMIT, V2_CSR_RESET: return data == 1;
      default: return 1'b1;
    endcase
  endfunction
endpackage
