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
  localparam logic [7:0] V2_FAMILY_PATCH=8'd0, V2_FAMILY_CALIBRATION=8'd1;
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

  typedef enum logic [2:0] { IDLE, LIVE, RECORD, COMMIT, PLAY, ERROR } v2_mode_e;

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
  localparam logic [7:0] V2_ADDR_PATCH_FIRST  = 8'h48;
  localparam logic [7:0] V2_ADDR_PATCH_LAST   = 8'h5C;
  localparam logic [7:0] V2_ADDR_WT_FIRST     = 8'h60;
  localparam logic [7:0] V2_ADDR_WT_LAST      = 8'h7C;
  localparam logic [7:0] V2_ADDR_DIAG_FIRST   = 8'h80;
  localparam logic [7:0] V2_ADDR_DIAG_LAST    = 8'h9C;
  localparam logic [7:0] V2_ADDR_TEST_FIRST   = 8'hA0;
  localparam logic [7:0] V2_ADDR_TEST_LAST    = 8'hAF;

  // Word register offsets; A0..AF are sixteen indexed test selectors.
  localparam logic [7:0] V2_CSR_STATUS=8'h00, V2_CSR_MODE=8'h04,
      V2_CSR_BPM=8'h08, V2_CSR_TRACK=8'h0C, V2_CSR_PLAY=8'h10,
      V2_CSR_STOP=8'h14, V2_CSR_RECORD=8'h18, V2_CSR_OVERDUB=8'h1C,
      V2_CSR_CLEAR_TRACK=8'h20, V2_CSR_CLEAR_ALL=8'h24,
      V2_CSR_COMMIT=8'h28, V2_CSR_RESET=8'h2C,
      V2_CSR_THRESHOLDS=8'h30, V2_CSR_POSITION=8'h34,
      V2_CSR_FAULT=8'h38, V2_CSR_DIAG_INPUT=8'h3C,
      V2_CSR_DIAG_AUDIO=8'h40, V2_CSR_DIAG_ROUTER=8'h44;
  localparam logic [7:0] V2_CSR_PATCH_SELECT=8'h48,
      V2_CSR_PATCH_SHADOW_DATA=8'h4C, V2_CSR_PATCH_ACTIVE_DATA=8'h50,
      V2_CSR_PATCH_STATUS=8'h54, V2_CSR_PATCH_CRC=8'h58,
      V2_CSR_PATCH_APPLY=8'h5C;
  localparam logic [7:0] V2_CSR_WT_SELECT=8'h60,
      V2_CSR_WT_INDEX=8'h64, V2_CSR_WT_DATA=8'h68,
      V2_CSR_WT_LENGTH=8'h6C, V2_CSR_WT_CRC=8'h70,
      V2_CSR_WT_VERSION=8'h74, V2_CSR_WT_APPLY=8'h78,
      V2_CSR_WT_STATUS=8'h7C;
  localparam logic [7:0] V2_CSR_TLM_CONTROL=8'h80,
      V2_CSR_TLM_STATUS=8'h84, V2_CSR_TLM_LATENCY=8'h88,
      V2_CSR_TLM_PEAK=8'h8C, V2_CSR_TLM_RMS=8'h90,
      V2_CSR_TLM_FIFO=8'h94, V2_CSR_TLM_FAULT=8'h98,
      V2_CSR_TLM_TABLE_VERSION=8'h9C;
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
  localparam logic [31:0] V2_CSR_POSITION_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_FAULT_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_DIAG_INPUT_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_DIAG_AUDIO_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_DIAG_ROUTER_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_PATCH_SELECT_WRITE_MASK=32'h0000FF1F;
  localparam logic [31:0] V2_CSR_PATCH_SHADOW_DATA_WRITE_MASK=32'hFFFFFFFF;
  localparam logic [31:0] V2_CSR_PATCH_ACTIVE_DATA_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_PATCH_STATUS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_PATCH_CRC_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_PATCH_APPLY_WRITE_MASK=32'h8000FFFF;
  localparam logic [31:0] V2_CSR_WT_SELECT_WRITE_MASK=32'h0000FF07;
  localparam logic [31:0] V2_CSR_WT_INDEX_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_DATA_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_LENGTH_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_CRC_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_VERSION_WRITE_MASK=32'h0000FFFF;
  localparam logic [31:0] V2_CSR_WT_APPLY_WRITE_MASK=32'h8000FFFF;
  localparam logic [31:0] V2_CSR_WT_STATUS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_CONTROL_WRITE_MASK=32'hFFFF0001;
  localparam logic [31:0] V2_CSR_TLM_STATUS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_LATENCY_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_PEAK_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_RMS_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_FIFO_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_FAULT_WRITE_MASK=32'h00000000;
  localparam logic [31:0] V2_CSR_TLM_TABLE_VERSION_WRITE_MASK=32'h00000000;
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
  localparam int V2_CSR_POSITION_TICK_SHIFT=0;
  localparam int V2_CSR_POSITION_ACTIVE_VALID_SHIFT=8;
  localparam int V2_CSR_POSITION_COMMIT_PENDING_SHIFT=9;
  localparam int V2_CSR_POSITION_FAULT_SHIFT=10;
  localparam int V2_CSR_FAULT_FAULT_CODE_SHIFT=0;
  localparam int V2_CSR_FAULT_STICKY_SHIFT=8;
  localparam int V2_CSR_DIAG_INPUT_INVALID_COUNT_SHIFT=0;
  localparam int V2_CSR_DIAG_INPUT_GAP_COUNT_SHIFT=16;
  localparam int V2_CSR_DIAG_AUDIO_UNDERRUN_COUNT_SHIFT=0;
  localparam int V2_CSR_DIAG_AUDIO_PEAK_Q15_SHIFT=16;
  localparam int V2_CSR_DIAG_ROUTER_DROP_COUNT_SHIFT=0;
  localparam int V2_CSR_DIAG_ROUTER_FIFO_LEVEL_SHIFT=16;
  localparam int V2_CSR_PATCH_SELECT_FAMILY_SHIFT=0;
  localparam int V2_CSR_PATCH_SELECT_TRACK_SHIFT=2;
  localparam int V2_CSR_PATCH_SELECT_INDEX_SHIFT=8;
  localparam int V2_CSR_PATCH_SHADOW_DATA_VALUE_SHIFT=0;
  localparam int V2_CSR_PATCH_ACTIVE_DATA_VALUE_SHIFT=0;
  localparam int V2_CSR_PATCH_STATUS_ACTIVE_VERSION_SHIFT=0;
  localparam int V2_CSR_PATCH_STATUS_SHADOW_DIRTY_SHIFT=16;
  localparam int V2_CSR_PATCH_STATUS_CRC_OK_SHIFT=17;
  localparam int V2_CSR_PATCH_STATUS_APPLY_BUSY_SHIFT=18;
  localparam int V2_CSR_PATCH_STATUS_LAST_ERROR_SHIFT=24;
  localparam int V2_CSR_PATCH_CRC_CRC16_CCITT_SHIFT=0;
  localparam int V2_CSR_PATCH_APPLY_EXPECTED_VERSION_SHIFT=0;
  localparam int V2_CSR_PATCH_APPLY_TRIGGER_SHIFT=31;
  localparam int V2_CSR_WT_SELECT_TABLE_ID_SHIFT=0;
  localparam int V2_CSR_WT_SELECT_BANK_SHIFT=8;
  localparam int V2_CSR_WT_SELECT_BAND_SHIFT=9;
  localparam int V2_CSR_WT_SELECT_OCTAVE_SHIFT=12;
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
  localparam int V2_CSR_TLM_STATUS_LAST_TYPE_SHIFT=0;
  localparam int V2_CSR_TLM_STATUS_SEQUENCE_SHIFT=8;
  localparam int V2_CSR_TLM_LATENCY_LATENCY_US_SHIFT=0;
  localparam int V2_CSR_TLM_PEAK_PEAK_Q15_SHIFT=0;
  localparam int V2_CSR_TLM_RMS_RMS_Q15_SHIFT=0;
  localparam int V2_CSR_TLM_FIFO_RX_LEVEL_SHIFT=0;
  localparam int V2_CSR_TLM_FIFO_TX_LEVEL_SHIFT=8;
  localparam int V2_CSR_TLM_FIFO_EVENT_LEVEL_SHIFT=16;
  localparam int V2_CSR_TLM_FAULT_FAULT_CODE_SHIFT=0;
  localparam int V2_CSR_TLM_FAULT_FAULT_COUNT_SHIFT=8;
  localparam int V2_CSR_TLM_TABLE_VERSION_ACTIVE_VERSION_SHIFT=0;
  localparam int V2_CSR_TLM_TABLE_VERSION_SHADOW_VERSION_SHIFT=16;
  localparam int V2_PARAM_OSC_MIX=0;
  localparam int V2_PARAM_BRIGHTNESS=1;
  localparam int V2_PARAM_DETUNE_CENTS=2;
  localparam int V2_PARAM_ATTACK_MS=3;
  localparam int V2_PARAM_DECAY_MS=4;
  localparam int V2_PARAM_SUSTAIN=5;
  localparam int V2_PARAM_RELEASE_MS=6;
  localparam int V2_PARAM_GLIDE_MS=7;
  localparam int V2_PARAM_VIBRATO_HZ=8;
  localparam int V2_PARAM_VIBRATO_CENTS=9;
  localparam int V2_PARAM_Z_GAIN=10;
  localparam int V2_PARAM_Z_BRIGHTNESS=11;
  localparam int V2_PARAM_Z_SPACE=12;
  localparam int V2_PARAM_TRACK_ENABLE=13;
  localparam int V2_PARAM_GAIN=14;
  localparam int V2_PARAM_FX_LEVEL=15;
  localparam int V2_PARAM_FX_CUTOFF_HZ=16;
  localparam int V2_PARAM_FX_DELAY_MS=17;
  localparam int V2_PARAM_FX_FEEDBACK=18;
  localparam int V2_PARAM_FX_REVERB_MIX=19;
  localparam int V2_PARAM_NEUTRAL_X=0;
  localparam int V2_PARAM_NEUTRAL_Y=1;
  localparam int V2_PARAM_NEUTRAL_Z=2;
  localparam int V2_PARAM_COUPLING_X=3;
  localparam int V2_PARAM_COUPLING_Y=4;
  localparam int V2_PARAM_GAIN_X=5;
  localparam int V2_PARAM_GAIN_Y=6;
  localparam int V2_PARAM_GAIN_Z=7;
  localparam int V2_PARAM_WS_X_MIN=8;
  localparam int V2_PARAM_WS_X_MAX=9;
  localparam int V2_PARAM_WS_Y_MIN=10;
  localparam int V2_PARAM_WS_Y_MAX=11;
  localparam int V2_PARAM_WS_Z_MIN=12;
  localparam int V2_PARAM_WS_Z_MAX=13;
  localparam int V2_PARAM_EPOCH=14;

  // Additional frozen indexed families and timing limits.
  localparam int V2_PARAM_LAMBDA_Q16=0;
  localparam int V2_PARAM_DENSITY_Q16=1;
  localparam int V2_PARAM_MIN_LENGTH_TICKS=2;
  localparam int V2_PARAM_REST_POLICY=3;
  localparam int V2_PARAM_FIXED_SCALE_MASK=4;
  localparam int V2_PARAM_BEND_CENTS=5;
  localparam int V2_PARAM_GATE_MODE=6;
  localparam int V2_PARAM_ALPHA_Q16=0;
  localparam int V2_PARAM_Z_ENGAGE=1;
  localparam int V2_PARAM_Z_RELEASE=2;
  localparam int V2_PARAM_MAX_STEP=3;
  localparam int V2_PARAM_SETTLE_FRAMES=4;
  localparam int V2_FAMILY_RULE=2;
  localparam int V2_FAMILY_CURSOR=3;
  localparam int V2_LOOP_TICKS=128;
  localparam int V2_TICKS_PER_BEAT=4;
  localparam int V2_BPM_MIN=60;
  localparam int V2_BPM_MAX=240;
  localparam int V2_BPM_DEFAULT=120;
  localparam int V2_PATCH_PARAM_COUNT=20;
  localparam int V2_CAL_PARAM_COUNT=15;
  localparam int V2_RULE_PARAM_COUNT=7;
  localparam int V2_CURSOR_PARAM_COUNT=5;

  localparam int V2_CSR_TEST_SELECT_SELECTOR_SHIFT=0;
  localparam int V2_CSR_TEST_SELECT_VALUE_SHIFT=8;

  function automatic bit v2_address_valid(input logic [7:0] address);
    return ((address >= V2_ADDR_TEST_FIRST && address <= V2_ADDR_TEST_LAST) ||
            ((address[1:0] == 2'b00) &&
            ((address >= V2_ADDR_LEGACY_FIRST && address <= V2_ADDR_LEGACY_LAST) ||
            (address >= V2_ADDR_PATCH_FIRST && address <= V2_ADDR_PATCH_LAST) ||
            (address >= V2_ADDR_WT_FIRST && address <= V2_ADDR_WT_LAST) ||
            (address >= V2_ADDR_DIAG_FIRST && address <= V2_ADDR_DIAG_LAST))));
  endfunction
  function automatic logic [1:0] v2_csr_access(input logic [7:0] address);
    if (address >= 8'hA0 && address <= 8'hAF) return V2_ACCESS_RW;
    if (address[1:0] != 2'b00 || !v2_address_valid(address)) return V2_ACCESS_NONE;
    case (address)
      V2_CSR_STATUS, V2_CSR_POSITION, V2_CSR_FAULT,
      V2_CSR_DIAG_INPUT, V2_CSR_DIAG_AUDIO, V2_CSR_DIAG_ROUTER,
      V2_CSR_PATCH_ACTIVE_DATA, V2_CSR_PATCH_STATUS,
      V2_CSR_WT_STATUS, V2_CSR_TLM_STATUS, V2_CSR_TLM_LATENCY,
      V2_CSR_TLM_PEAK, V2_CSR_TLM_RMS, V2_CSR_TLM_FIFO,
      V2_CSR_TLM_FAULT, V2_CSR_TLM_TABLE_VERSION: return V2_ACCESS_RO;
      V2_CSR_PLAY, V2_CSR_STOP, V2_CSR_RECORD, V2_CSR_OVERDUB,
      V2_CSR_CLEAR_TRACK, V2_CSR_CLEAR_ALL, V2_CSR_COMMIT,
      V2_CSR_RESET, V2_CSR_PATCH_APPLY, V2_CSR_WT_APPLY: return V2_ACCESS_WO;
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
      V2_CSR_POSITION: return V2_CSR_POSITION_WRITE_MASK;
      V2_CSR_FAULT: return V2_CSR_FAULT_WRITE_MASK;
      V2_CSR_DIAG_INPUT: return V2_CSR_DIAG_INPUT_WRITE_MASK;
      V2_CSR_DIAG_AUDIO: return V2_CSR_DIAG_AUDIO_WRITE_MASK;
      V2_CSR_DIAG_ROUTER: return V2_CSR_DIAG_ROUTER_WRITE_MASK;
      V2_CSR_PATCH_SELECT: return V2_CSR_PATCH_SELECT_WRITE_MASK;
      V2_CSR_PATCH_SHADOW_DATA: return V2_CSR_PATCH_SHADOW_DATA_WRITE_MASK;
      V2_CSR_PATCH_ACTIVE_DATA: return V2_CSR_PATCH_ACTIVE_DATA_WRITE_MASK;
      V2_CSR_PATCH_STATUS: return V2_CSR_PATCH_STATUS_WRITE_MASK;
      V2_CSR_PATCH_CRC: return V2_CSR_PATCH_CRC_WRITE_MASK;
      V2_CSR_PATCH_APPLY: return V2_CSR_PATCH_APPLY_WRITE_MASK;
      V2_CSR_WT_SELECT: return V2_CSR_WT_SELECT_WRITE_MASK;
      V2_CSR_WT_INDEX: return V2_CSR_WT_INDEX_WRITE_MASK;
      V2_CSR_WT_DATA: return V2_CSR_WT_DATA_WRITE_MASK;
      V2_CSR_WT_LENGTH: return V2_CSR_WT_LENGTH_WRITE_MASK;
      V2_CSR_WT_CRC: return V2_CSR_WT_CRC_WRITE_MASK;
      V2_CSR_WT_VERSION: return V2_CSR_WT_VERSION_WRITE_MASK;
      V2_CSR_WT_APPLY: return V2_CSR_WT_APPLY_WRITE_MASK;
      V2_CSR_WT_STATUS: return V2_CSR_WT_STATUS_WRITE_MASK;
      V2_CSR_TLM_CONTROL: return V2_CSR_TLM_CONTROL_WRITE_MASK;
      V2_CSR_TLM_STATUS: return V2_CSR_TLM_STATUS_WRITE_MASK;
      V2_CSR_TLM_LATENCY: return V2_CSR_TLM_LATENCY_WRITE_MASK;
      V2_CSR_TLM_PEAK: return V2_CSR_TLM_PEAK_WRITE_MASK;
      V2_CSR_TLM_RMS: return V2_CSR_TLM_RMS_WRITE_MASK;
      V2_CSR_TLM_FIFO: return V2_CSR_TLM_FIFO_WRITE_MASK;
      V2_CSR_TLM_FAULT: return V2_CSR_TLM_FAULT_WRITE_MASK;
      V2_CSR_TLM_TABLE_VERSION: return V2_CSR_TLM_TABLE_VERSION_WRITE_MASK;
      default: return 32'h00000000;
    endcase
  endfunction
  // Indexed parameter metadata is generated from the frozen table in tools/v2_contract.py.
  localparam int V2_PARAM_F0_I0_FAMILY=0;
  localparam int V2_PARAM_F0_I0_INDEX=0;
  localparam integer V2_PARAM_F0_I0_MIN=0;
  localparam integer V2_PARAM_F0_I0_MAX=65535;
  localparam integer V2_PARAM_F0_I0_DEFAULT=32768;
  localparam logic [3:0] V2_PARAM_F0_I0_Q_CODE=4;
  localparam logic V2_PARAM_F0_I0_GLOBAL=0;
  localparam int V2_PARAM_F0_I1_FAMILY=0;
  localparam int V2_PARAM_F0_I1_INDEX=1;
  localparam integer V2_PARAM_F0_I1_MIN=0;
  localparam integer V2_PARAM_F0_I1_MAX=65535;
  localparam integer V2_PARAM_F0_I1_DEFAULT=32768;
  localparam logic [3:0] V2_PARAM_F0_I1_Q_CODE=4;
  localparam logic V2_PARAM_F0_I1_GLOBAL=0;
  localparam int V2_PARAM_F0_I2_FAMILY=0;
  localparam int V2_PARAM_F0_I2_INDEX=2;
  localparam integer V2_PARAM_F0_I2_MIN=-307200;
  localparam integer V2_PARAM_F0_I2_MAX=307200;
  localparam integer V2_PARAM_F0_I2_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I2_Q_CODE=3;
  localparam logic V2_PARAM_F0_I2_GLOBAL=0;
  localparam int V2_PARAM_F0_I3_FAMILY=0;
  localparam int V2_PARAM_F0_I3_INDEX=3;
  localparam integer V2_PARAM_F0_I3_MIN=0;
  localparam integer V2_PARAM_F0_I3_MAX=10000;
  localparam integer V2_PARAM_F0_I3_DEFAULT=35;
  localparam logic [3:0] V2_PARAM_F0_I3_Q_CODE=1;
  localparam logic V2_PARAM_F0_I3_GLOBAL=0;
  localparam int V2_PARAM_F0_I4_FAMILY=0;
  localparam int V2_PARAM_F0_I4_INDEX=4;
  localparam integer V2_PARAM_F0_I4_MIN=0;
  localparam integer V2_PARAM_F0_I4_MAX=10000;
  localparam integer V2_PARAM_F0_I4_DEFAULT=180;
  localparam logic [3:0] V2_PARAM_F0_I4_Q_CODE=1;
  localparam logic V2_PARAM_F0_I4_GLOBAL=0;
  localparam int V2_PARAM_F0_I5_FAMILY=0;
  localparam int V2_PARAM_F0_I5_INDEX=5;
  localparam integer V2_PARAM_F0_I5_MIN=0;
  localparam integer V2_PARAM_F0_I5_MAX=32767;
  localparam integer V2_PARAM_F0_I5_DEFAULT=23593;
  localparam logic [3:0] V2_PARAM_F0_I5_Q_CODE=4;
  localparam logic V2_PARAM_F0_I5_GLOBAL=0;
  localparam int V2_PARAM_F0_I6_FAMILY=0;
  localparam int V2_PARAM_F0_I6_INDEX=6;
  localparam integer V2_PARAM_F0_I6_MIN=0;
  localparam integer V2_PARAM_F0_I6_MAX=10000;
  localparam integer V2_PARAM_F0_I6_DEFAULT=520;
  localparam logic [3:0] V2_PARAM_F0_I6_Q_CODE=1;
  localparam logic V2_PARAM_F0_I6_GLOBAL=0;
  localparam int V2_PARAM_F0_I7_FAMILY=0;
  localparam int V2_PARAM_F0_I7_INDEX=7;
  localparam integer V2_PARAM_F0_I7_MIN=0;
  localparam integer V2_PARAM_F0_I7_MAX=2000;
  localparam integer V2_PARAM_F0_I7_DEFAULT=85;
  localparam logic [3:0] V2_PARAM_F0_I7_Q_CODE=1;
  localparam logic V2_PARAM_F0_I7_GLOBAL=0;
  localparam int V2_PARAM_F0_I8_FAMILY=0;
  localparam int V2_PARAM_F0_I8_INDEX=8;
  localparam integer V2_PARAM_F0_I8_MIN=0;
  localparam integer V2_PARAM_F0_I8_MAX=3840;
  localparam integer V2_PARAM_F0_I8_DEFAULT=1075;
  localparam logic [3:0] V2_PARAM_F0_I8_Q_CODE=4;
  localparam logic V2_PARAM_F0_I8_GLOBAL=0;
  localparam int V2_PARAM_F0_I9_FAMILY=0;
  localparam int V2_PARAM_F0_I9_INDEX=9;
  localparam integer V2_PARAM_F0_I9_MIN=0;
  localparam integer V2_PARAM_F0_I9_MAX=25600;
  localparam integer V2_PARAM_F0_I9_DEFAULT=2816;
  localparam logic [3:0] V2_PARAM_F0_I9_Q_CODE=4;
  localparam logic V2_PARAM_F0_I9_GLOBAL=0;
  localparam int V2_PARAM_F0_I10_FAMILY=0;
  localparam int V2_PARAM_F0_I10_INDEX=10;
  localparam integer V2_PARAM_F0_I10_MIN=0;
  localparam integer V2_PARAM_F0_I10_MAX=32767;
  localparam integer V2_PARAM_F0_I10_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I10_Q_CODE=4;
  localparam logic V2_PARAM_F0_I10_GLOBAL=0;
  localparam int V2_PARAM_F0_I11_FAMILY=0;
  localparam int V2_PARAM_F0_I11_INDEX=11;
  localparam integer V2_PARAM_F0_I11_MIN=0;
  localparam integer V2_PARAM_F0_I11_MAX=32767;
  localparam integer V2_PARAM_F0_I11_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I11_Q_CODE=4;
  localparam logic V2_PARAM_F0_I11_GLOBAL=0;
  localparam int V2_PARAM_F0_I12_FAMILY=0;
  localparam int V2_PARAM_F0_I12_INDEX=12;
  localparam integer V2_PARAM_F0_I12_MIN=0;
  localparam integer V2_PARAM_F0_I12_MAX=32767;
  localparam integer V2_PARAM_F0_I12_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I12_Q_CODE=4;
  localparam logic V2_PARAM_F0_I12_GLOBAL=0;
  localparam int V2_PARAM_F0_I13_FAMILY=0;
  localparam int V2_PARAM_F0_I13_INDEX=13;
  localparam integer V2_PARAM_F0_I13_MIN=0;
  localparam integer V2_PARAM_F0_I13_MAX=1;
  localparam integer V2_PARAM_F0_I13_DEFAULT=1;
  localparam logic [3:0] V2_PARAM_F0_I13_Q_CODE=1;
  localparam logic V2_PARAM_F0_I13_GLOBAL=0;
  localparam int V2_PARAM_F0_I14_FAMILY=0;
  localparam int V2_PARAM_F0_I14_INDEX=14;
  localparam integer V2_PARAM_F0_I14_MIN=0;
  localparam integer V2_PARAM_F0_I14_MAX=262144;
  localparam integer V2_PARAM_F0_I14_DEFAULT=65536;
  localparam logic [3:0] V2_PARAM_F0_I14_Q_CODE=4;
  localparam logic V2_PARAM_F0_I14_GLOBAL=0;
  localparam int V2_PARAM_F0_I15_FAMILY=0;
  localparam int V2_PARAM_F0_I15_INDEX=15;
  localparam integer V2_PARAM_F0_I15_MIN=0;
  localparam integer V2_PARAM_F0_I15_MAX=3;
  localparam integer V2_PARAM_F0_I15_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I15_Q_CODE=1;
  localparam logic V2_PARAM_F0_I15_GLOBAL=0;
  localparam int V2_PARAM_F0_I16_FAMILY=0;
  localparam int V2_PARAM_F0_I16_INDEX=16;
  localparam integer V2_PARAM_F0_I16_MIN=20;
  localparam integer V2_PARAM_F0_I16_MAX=20000;
  localparam integer V2_PARAM_F0_I16_DEFAULT=12000;
  localparam logic [3:0] V2_PARAM_F0_I16_Q_CODE=1;
  localparam logic V2_PARAM_F0_I16_GLOBAL=0;
  localparam int V2_PARAM_F0_I17_FAMILY=0;
  localparam int V2_PARAM_F0_I17_INDEX=17;
  localparam integer V2_PARAM_F0_I17_MIN=0;
  localparam integer V2_PARAM_F0_I17_MAX=1000;
  localparam integer V2_PARAM_F0_I17_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I17_Q_CODE=1;
  localparam logic V2_PARAM_F0_I17_GLOBAL=0;
  localparam int V2_PARAM_F0_I18_FAMILY=0;
  localparam int V2_PARAM_F0_I18_INDEX=18;
  localparam integer V2_PARAM_F0_I18_MIN=0;
  localparam integer V2_PARAM_F0_I18_MAX=31129;
  localparam integer V2_PARAM_F0_I18_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I18_Q_CODE=4;
  localparam logic V2_PARAM_F0_I18_GLOBAL=0;
  localparam int V2_PARAM_F0_I19_FAMILY=0;
  localparam int V2_PARAM_F0_I19_INDEX=19;
  localparam integer V2_PARAM_F0_I19_MIN=0;
  localparam integer V2_PARAM_F0_I19_MAX=32767;
  localparam integer V2_PARAM_F0_I19_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F0_I19_Q_CODE=4;
  localparam logic V2_PARAM_F0_I19_GLOBAL=0;
  localparam int V2_PARAM_F1_I0_FAMILY=1;
  localparam int V2_PARAM_F1_I0_INDEX=0;
  localparam integer V2_PARAM_F1_I0_MIN=-32768;
  localparam integer V2_PARAM_F1_I0_MAX=32767;
  localparam integer V2_PARAM_F1_I0_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I0_Q_CODE=1;
  localparam logic V2_PARAM_F1_I0_GLOBAL=1;
  localparam int V2_PARAM_F1_I1_FAMILY=1;
  localparam int V2_PARAM_F1_I1_INDEX=1;
  localparam integer V2_PARAM_F1_I1_MIN=-32768;
  localparam integer V2_PARAM_F1_I1_MAX=32767;
  localparam integer V2_PARAM_F1_I1_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I1_Q_CODE=1;
  localparam logic V2_PARAM_F1_I1_GLOBAL=1;
  localparam int V2_PARAM_F1_I2_FAMILY=1;
  localparam int V2_PARAM_F1_I2_INDEX=2;
  localparam integer V2_PARAM_F1_I2_MIN=0;
  localparam integer V2_PARAM_F1_I2_MAX=65535;
  localparam integer V2_PARAM_F1_I2_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I2_Q_CODE=1;
  localparam logic V2_PARAM_F1_I2_GLOBAL=1;
  localparam int V2_PARAM_F1_I3_FAMILY=1;
  localparam int V2_PARAM_F1_I3_INDEX=3;
  localparam integer V2_PARAM_F1_I3_MIN=-262144;
  localparam integer V2_PARAM_F1_I3_MAX=262144;
  localparam integer V2_PARAM_F1_I3_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I3_Q_CODE=3;
  localparam logic V2_PARAM_F1_I3_GLOBAL=1;
  localparam int V2_PARAM_F1_I4_FAMILY=1;
  localparam int V2_PARAM_F1_I4_INDEX=4;
  localparam integer V2_PARAM_F1_I4_MIN=-262144;
  localparam integer V2_PARAM_F1_I4_MAX=262144;
  localparam integer V2_PARAM_F1_I4_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I4_Q_CODE=3;
  localparam logic V2_PARAM_F1_I4_GLOBAL=1;
  localparam int V2_PARAM_F1_I5_FAMILY=1;
  localparam int V2_PARAM_F1_I5_INDEX=5;
  localparam integer V2_PARAM_F1_I5_MIN=0;
  localparam integer V2_PARAM_F1_I5_MAX=262144;
  localparam integer V2_PARAM_F1_I5_DEFAULT=65536;
  localparam logic [3:0] V2_PARAM_F1_I5_Q_CODE=4;
  localparam logic V2_PARAM_F1_I5_GLOBAL=1;
  localparam int V2_PARAM_F1_I6_FAMILY=1;
  localparam int V2_PARAM_F1_I6_INDEX=6;
  localparam integer V2_PARAM_F1_I6_MIN=0;
  localparam integer V2_PARAM_F1_I6_MAX=262144;
  localparam integer V2_PARAM_F1_I6_DEFAULT=65536;
  localparam logic [3:0] V2_PARAM_F1_I6_Q_CODE=4;
  localparam logic V2_PARAM_F1_I6_GLOBAL=1;
  localparam int V2_PARAM_F1_I7_FAMILY=1;
  localparam int V2_PARAM_F1_I7_INDEX=7;
  localparam integer V2_PARAM_F1_I7_MIN=0;
  localparam integer V2_PARAM_F1_I7_MAX=262144;
  localparam integer V2_PARAM_F1_I7_DEFAULT=65536;
  localparam logic [3:0] V2_PARAM_F1_I7_Q_CODE=4;
  localparam logic V2_PARAM_F1_I7_GLOBAL=1;
  localparam int V2_PARAM_F1_I8_FAMILY=1;
  localparam int V2_PARAM_F1_I8_INDEX=8;
  localparam integer V2_PARAM_F1_I8_MIN=-32768;
  localparam integer V2_PARAM_F1_I8_MAX=32767;
  localparam integer V2_PARAM_F1_I8_DEFAULT=-32768;
  localparam logic [3:0] V2_PARAM_F1_I8_Q_CODE=1;
  localparam logic V2_PARAM_F1_I8_GLOBAL=1;
  localparam int V2_PARAM_F1_I9_FAMILY=1;
  localparam int V2_PARAM_F1_I9_INDEX=9;
  localparam integer V2_PARAM_F1_I9_MIN=-32768;
  localparam integer V2_PARAM_F1_I9_MAX=32767;
  localparam integer V2_PARAM_F1_I9_DEFAULT=32767;
  localparam logic [3:0] V2_PARAM_F1_I9_Q_CODE=1;
  localparam logic V2_PARAM_F1_I9_GLOBAL=1;
  localparam int V2_PARAM_F1_I10_FAMILY=1;
  localparam int V2_PARAM_F1_I10_INDEX=10;
  localparam integer V2_PARAM_F1_I10_MIN=-32768;
  localparam integer V2_PARAM_F1_I10_MAX=32767;
  localparam integer V2_PARAM_F1_I10_DEFAULT=-32768;
  localparam logic [3:0] V2_PARAM_F1_I10_Q_CODE=1;
  localparam logic V2_PARAM_F1_I10_GLOBAL=1;
  localparam int V2_PARAM_F1_I11_FAMILY=1;
  localparam int V2_PARAM_F1_I11_INDEX=11;
  localparam integer V2_PARAM_F1_I11_MIN=-32768;
  localparam integer V2_PARAM_F1_I11_MAX=32767;
  localparam integer V2_PARAM_F1_I11_DEFAULT=32767;
  localparam logic [3:0] V2_PARAM_F1_I11_Q_CODE=1;
  localparam logic V2_PARAM_F1_I11_GLOBAL=1;
  localparam int V2_PARAM_F1_I12_FAMILY=1;
  localparam int V2_PARAM_F1_I12_INDEX=12;
  localparam integer V2_PARAM_F1_I12_MIN=0;
  localparam integer V2_PARAM_F1_I12_MAX=65535;
  localparam integer V2_PARAM_F1_I12_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I12_Q_CODE=1;
  localparam logic V2_PARAM_F1_I12_GLOBAL=1;
  localparam int V2_PARAM_F1_I13_FAMILY=1;
  localparam int V2_PARAM_F1_I13_INDEX=13;
  localparam integer V2_PARAM_F1_I13_MIN=0;
  localparam integer V2_PARAM_F1_I13_MAX=65535;
  localparam integer V2_PARAM_F1_I13_DEFAULT=65535;
  localparam logic [3:0] V2_PARAM_F1_I13_Q_CODE=1;
  localparam logic V2_PARAM_F1_I13_GLOBAL=1;
  localparam int V2_PARAM_F1_I14_FAMILY=1;
  localparam int V2_PARAM_F1_I14_INDEX=14;
  localparam integer V2_PARAM_F1_I14_MIN=0;
  localparam integer V2_PARAM_F1_I14_MAX=255;
  localparam integer V2_PARAM_F1_I14_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F1_I14_Q_CODE=1;
  localparam logic V2_PARAM_F1_I14_GLOBAL=1;
  localparam int V2_PARAM_F2_I0_FAMILY=2;
  localparam int V2_PARAM_F2_I0_INDEX=0;
  localparam integer V2_PARAM_F2_I0_MIN=0;
  localparam integer V2_PARAM_F2_I0_MAX=1048576;
  localparam integer V2_PARAM_F2_I0_DEFAULT=65536;
  localparam logic [3:0] V2_PARAM_F2_I0_Q_CODE=4;
  localparam logic V2_PARAM_F2_I0_GLOBAL=0;
  localparam int V2_PARAM_F2_I1_FAMILY=2;
  localparam int V2_PARAM_F2_I1_INDEX=1;
  localparam integer V2_PARAM_F2_I1_MIN=0;
  localparam integer V2_PARAM_F2_I1_MAX=65535;
  localparam integer V2_PARAM_F2_I1_DEFAULT=32768;
  localparam logic [3:0] V2_PARAM_F2_I1_Q_CODE=4;
  localparam logic V2_PARAM_F2_I1_GLOBAL=0;
  localparam int V2_PARAM_F2_I2_FAMILY=2;
  localparam int V2_PARAM_F2_I2_INDEX=2;
  localparam integer V2_PARAM_F2_I2_MIN=1;
  localparam integer V2_PARAM_F2_I2_MAX=128;
  localparam integer V2_PARAM_F2_I2_DEFAULT=4;
  localparam logic [3:0] V2_PARAM_F2_I2_Q_CODE=1;
  localparam logic V2_PARAM_F2_I2_GLOBAL=0;
  localparam int V2_PARAM_F2_I3_FAMILY=2;
  localparam int V2_PARAM_F2_I3_INDEX=3;
  localparam integer V2_PARAM_F2_I3_MIN=0;
  localparam integer V2_PARAM_F2_I3_MAX=2;
  localparam integer V2_PARAM_F2_I3_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F2_I3_Q_CODE=1;
  localparam logic V2_PARAM_F2_I3_GLOBAL=0;
  localparam int V2_PARAM_F2_I4_FAMILY=2;
  localparam int V2_PARAM_F2_I4_INDEX=4;
  localparam integer V2_PARAM_F2_I4_MIN=1;
  localparam integer V2_PARAM_F2_I4_MAX=4095;
  localparam integer V2_PARAM_F2_I4_DEFAULT=4095;
  localparam logic [3:0] V2_PARAM_F2_I4_Q_CODE=1;
  localparam logic V2_PARAM_F2_I4_GLOBAL=0;
  localparam int V2_PARAM_F2_I5_FAMILY=2;
  localparam int V2_PARAM_F2_I5_INDEX=5;
  localparam integer V2_PARAM_F2_I5_MIN=-307200;
  localparam integer V2_PARAM_F2_I5_MAX=307200;
  localparam integer V2_PARAM_F2_I5_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F2_I5_Q_CODE=3;
  localparam logic V2_PARAM_F2_I5_GLOBAL=0;
  localparam int V2_PARAM_F2_I6_FAMILY=2;
  localparam int V2_PARAM_F2_I6_INDEX=6;
  localparam integer V2_PARAM_F2_I6_MIN=0;
  localparam integer V2_PARAM_F2_I6_MAX=4;
  localparam integer V2_PARAM_F2_I6_DEFAULT=0;
  localparam logic [3:0] V2_PARAM_F2_I6_Q_CODE=1;
  localparam logic V2_PARAM_F2_I6_GLOBAL=0;
  localparam int V2_PARAM_F3_I0_FAMILY=3;
  localparam int V2_PARAM_F3_I0_INDEX=0;
  localparam integer V2_PARAM_F3_I0_MIN=0;
  localparam integer V2_PARAM_F3_I0_MAX=65535;
  localparam integer V2_PARAM_F3_I0_DEFAULT=32768;
  localparam logic [3:0] V2_PARAM_F3_I0_Q_CODE=4;
  localparam logic V2_PARAM_F3_I0_GLOBAL=1;
  localparam int V2_PARAM_F3_I1_FAMILY=3;
  localparam int V2_PARAM_F3_I1_INDEX=1;
  localparam integer V2_PARAM_F3_I1_MIN=0;
  localparam integer V2_PARAM_F3_I1_MAX=65535;
  localparam integer V2_PARAM_F3_I1_DEFAULT=30000;
  localparam logic [3:0] V2_PARAM_F3_I1_Q_CODE=1;
  localparam logic V2_PARAM_F3_I1_GLOBAL=1;
  localparam int V2_PARAM_F3_I2_FAMILY=3;
  localparam int V2_PARAM_F3_I2_INDEX=2;
  localparam integer V2_PARAM_F3_I2_MIN=0;
  localparam integer V2_PARAM_F3_I2_MAX=65535;
  localparam integer V2_PARAM_F3_I2_DEFAULT=36000;
  localparam logic [3:0] V2_PARAM_F3_I2_Q_CODE=1;
  localparam logic V2_PARAM_F3_I2_GLOBAL=1;
  localparam int V2_PARAM_F3_I3_FAMILY=3;
  localparam int V2_PARAM_F3_I3_INDEX=3;
  localparam integer V2_PARAM_F3_I3_MIN=0;
  localparam integer V2_PARAM_F3_I3_MAX=65535;
  localparam integer V2_PARAM_F3_I3_DEFAULT=4096;
  localparam logic [3:0] V2_PARAM_F3_I3_Q_CODE=1;
  localparam logic V2_PARAM_F3_I3_GLOBAL=1;
  localparam int V2_PARAM_F3_I4_FAMILY=3;
  localparam int V2_PARAM_F3_I4_INDEX=4;
  localparam integer V2_PARAM_F3_I4_MIN=0;
  localparam integer V2_PARAM_F3_I4_MAX=255;
  localparam integer V2_PARAM_F3_I4_DEFAULT=3;
  localparam logic [3:0] V2_PARAM_F3_I4_Q_CODE=1;
  localparam logic V2_PARAM_F3_I4_GLOBAL=1;
  function automatic bit v2_patch_value_valid(input logic [1:0] family, input logic [2:0] track,
                                                     input logic [7:0] index, input logic signed [31:0] value);
    case ({family,index})
      10'h000: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I0_MIN) && (value <= V2_PARAM_F0_I0_MAX);
      10'h001: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I1_MIN) && (value <= V2_PARAM_F0_I1_MAX);
      10'h002: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I2_MIN) && (value <= V2_PARAM_F0_I2_MAX);
      10'h003: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I3_MIN) && (value <= V2_PARAM_F0_I3_MAX);
      10'h004: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I4_MIN) && (value <= V2_PARAM_F0_I4_MAX);
      10'h005: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I5_MIN) && (value <= V2_PARAM_F0_I5_MAX);
      10'h006: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I6_MIN) && (value <= V2_PARAM_F0_I6_MAX);
      10'h007: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I7_MIN) && (value <= V2_PARAM_F0_I7_MAX);
      10'h008: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I8_MIN) && (value <= V2_PARAM_F0_I8_MAX);
      10'h009: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I9_MIN) && (value <= V2_PARAM_F0_I9_MAX);
      10'h00A: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I10_MIN) && (value <= V2_PARAM_F0_I10_MAX);
      10'h00B: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I11_MIN) && (value <= V2_PARAM_F0_I11_MAX);
      10'h00C: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I12_MIN) && (value <= V2_PARAM_F0_I12_MAX);
      10'h00D: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I13_MIN) && (value <= V2_PARAM_F0_I13_MAX);
      10'h00E: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I14_MIN) && (value <= V2_PARAM_F0_I14_MAX);
      10'h00F: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I15_MIN) && (value <= V2_PARAM_F0_I15_MAX);
      10'h010: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I16_MIN) && (value <= V2_PARAM_F0_I16_MAX);
      10'h011: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I17_MIN) && (value <= V2_PARAM_F0_I17_MAX);
      10'h012: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I18_MIN) && (value <= V2_PARAM_F0_I18_MAX);
      10'h013: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F0_I19_MIN) && (value <= V2_PARAM_F0_I19_MAX);
      10'h100: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I0_MIN) && (value <= V2_PARAM_F1_I0_MAX);
      10'h101: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I1_MIN) && (value <= V2_PARAM_F1_I1_MAX);
      10'h102: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I2_MIN) && (value <= V2_PARAM_F1_I2_MAX);
      10'h103: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I3_MIN) && (value <= V2_PARAM_F1_I3_MAX);
      10'h104: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I4_MIN) && (value <= V2_PARAM_F1_I4_MAX);
      10'h105: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I5_MIN) && (value <= V2_PARAM_F1_I5_MAX);
      10'h106: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I6_MIN) && (value <= V2_PARAM_F1_I6_MAX);
      10'h107: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I7_MIN) && (value <= V2_PARAM_F1_I7_MAX);
      10'h108: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I8_MIN) && (value <= V2_PARAM_F1_I8_MAX);
      10'h109: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I9_MIN) && (value <= V2_PARAM_F1_I9_MAX);
      10'h10A: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I10_MIN) && (value <= V2_PARAM_F1_I10_MAX);
      10'h10B: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I11_MIN) && (value <= V2_PARAM_F1_I11_MAX);
      10'h10C: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I12_MIN) && (value <= V2_PARAM_F1_I12_MAX);
      10'h10D: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I13_MIN) && (value <= V2_PARAM_F1_I13_MAX);
      10'h10E: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F1_I14_MIN) && (value <= V2_PARAM_F1_I14_MAX);
      10'h200: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I0_MIN) && (value <= V2_PARAM_F2_I0_MAX);
      10'h201: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I1_MIN) && (value <= V2_PARAM_F2_I1_MAX);
      10'h202: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I2_MIN) && (value <= V2_PARAM_F2_I2_MAX);
      10'h203: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I3_MIN) && (value <= V2_PARAM_F2_I3_MAX);
      10'h204: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I4_MIN) && (value <= V2_PARAM_F2_I4_MAX);
      10'h205: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I5_MIN) && (value <= V2_PARAM_F2_I5_MAX);
      10'h206: v2_patch_value_valid = (track < 3'd6) && (value >= V2_PARAM_F2_I6_MIN) && (value <= V2_PARAM_F2_I6_MAX);
      10'h300: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F3_I0_MIN) && (value <= V2_PARAM_F3_I0_MAX);
      10'h301: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F3_I1_MIN) && (value <= V2_PARAM_F3_I1_MAX);
      10'h302: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F3_I2_MIN) && (value <= V2_PARAM_F3_I2_MAX);
      10'h303: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F3_I3_MIN) && (value <= V2_PARAM_F3_I3_MAX);
      10'h304: v2_patch_value_valid = (track == 3'd7) && (value >= V2_PARAM_F3_I4_MIN) && (value <= V2_PARAM_F3_I4_MAX);
      default: v2_patch_value_valid = 1'b0;
    endcase
  endfunction
  function automatic bit v2_csr_data_valid(input logic [7:0] address,
                                            input logic [31:0] data,
                                            input logic [1:0] patch_family = 2'd0,
                                            input logic [2:0] patch_track = 3'd0,
                                            input logic [7:0] patch_index = 8'd0);
    logic [1:0] family;
    logic [2:0] track;
    logic [7:0] index;
    if (v2_csr_access(address) != V2_ACCESS_RW &&
        v2_csr_access(address) != V2_ACCESS_WO) return 1'b0;
    if ((data & ~v2_csr_write_mask(address)) != 0) return 1'b0;
    case (address)
      V2_CSR_MODE: return data <= 5;
      V2_CSR_TRACK: return data <= 5;
      V2_CSR_BPM: return data >= V2_BPM_MIN && data <= V2_BPM_MAX;
      V2_CSR_THRESHOLDS: return data[15:0] < data[31:16];
      V2_CSR_PATCH_SELECT: begin
        family=data[1:0]; track=data[4:2]; index=data[15:8];
        case (family)
          V2_FAMILY_PATCH: return track < 6 && index < V2_PATCH_PARAM_COUNT;
          V2_FAMILY_CALIBRATION: return track == 7 && index < V2_CAL_PARAM_COUNT;
          V2_FAMILY_RULE: return track < 6 && index < V2_RULE_PARAM_COUNT;
          V2_FAMILY_CURSOR: return track == 7 && index < V2_CURSOR_PARAM_COUNT;
          default: return 1'b0;
        endcase
      end
      V2_CSR_WT_SELECT: return data[2:0] <= V2_WT_C;
      V2_CSR_WT_INDEX: return data < V2_WT_SAMPLES;
      V2_CSR_WT_LENGTH: return data == V2_WT_SAMPLES;
      V2_CSR_PATCH_SHADOW_DATA: return v2_patch_value_valid(patch_family, patch_track, patch_index, $signed(data));
      V2_CSR_PATCH_APPLY, V2_CSR_WT_APPLY: return data[31];
      V2_CSR_PLAY, V2_CSR_STOP, V2_CSR_RECORD, V2_CSR_OVERDUB,
      V2_CSR_CLEAR_ALL, V2_CSR_COMMIT, V2_CSR_RESET: return data == 1;
      default: return 1'b1;
    endcase
  endfunction
endpackage
