`timescale 1ns/1ps
// Contract clamp gate for the P2a and P2b parameter CSRs.
//
// Every row of spec 2026-11-01-filter-lfo-design.md section 11.6 that belongs to
// 0x40 FILTER, 0x44 LFO, 0x84 FX_A, 0x88 FX_B, 0x8C FX_C, 0x90 VOLUME and to the
// three P2b addresses 0x94 ENV_AD, 0x98 ENV_SR, 0x9C VOICE_MIX as one
// assertion, plus rows proving (a) bits outside the write mask are cleared and
// (b) the packed default of the seven voice parameters is the documented one.  The clamp is
// the single source of truth for the parameter surface: a write succeeds with
// the value clamped, never with an out-of-range value stored and never NACKed.
module tb_contract_clamp;
  import v2_contract_pkg::*;

  integer checks = 0;
  integer errors = 0;

  task automatic expect_clamp(input logic [7:0] address,
                              input logic [31:0] data_in,
                              input logic [31:0] want,
                              input [511:0] what);
    logic [31:0] got;
    begin
      got = v2_csr_clamp(address, data_in);
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: addr 0x%02h in 0x%08h got 0x%08h want 0x%08h",
                 what, address, data_in, got, want);
        errors = errors + 1;
      end else begin
        $display("PASS %0s: addr 0x%02h in 0x%08h -> 0x%08h", what, address, data_in, got);
      end
    end
  endtask

  task automatic expect_access(input logic [7:0] address,
                               input logic [1:0] want,
                               input [511:0] what);
    logic [1:0] got;
    begin
      got = v2_csr_access(address);
      checks = checks + 1;
      if (got !== want) begin
        $display("FAIL %0s: addr 0x%02h access %0d want %0d", what, address, got, want);
        errors = errors + 1;
      end else begin
        $display("PASS %0s: addr 0x%02h access %0d", what, address, got);
      end
    end
  endtask

  initial begin
    // 0x40 FILTER, mask 0x010FFFFF, spec 11.6: ci 0..423, res 0..255 in mask.
    expect_clamp(8'h40, 32'h0000_0FFF, 32'h0000_01A7, "filter ci over 423 clamps to 423");
    expect_clamp(8'h40, 32'h0000_01A7, 32'h0000_01A7, "filter ci at 423 is unchanged");
    expect_clamp(8'h40, 32'h000F_F000, 32'h000F_F000, "filter res 255 is unchanged");
    expect_clamp(8'h40, 32'hFF00_0000, 32'h0100_0000, "filter clears bits outside the mask");
    expect_clamp(8'h40, 32'h0100_0FFF, 32'h0100_01A7, "filter enable kept while ci clamps");

    // 0x44 LFO, mask 0x3FFFFFFF, spec 11.6: rate 0..20000, depth 0..255 in mask.
    expect_clamp(8'h44, 32'h0000_FFFF, 32'h0000_4E20, "lfo rate over 20000 clamps to 20000");
    expect_clamp(8'h44, 32'h0000_4E20, 32'h0000_4E20, "lfo rate at 20000 is unchanged");
    expect_clamp(8'h44, 32'h00FF_0000, 32'h00FF_0000, "lfo depth 255 is unchanged");
    expect_clamp(8'h44, 32'hC000_0000, 32'h0000_0000, "lfo reserved top bits are cleared");

    // 0x84 FX_A, mask 0x001FFFFF, spec 11.6: gain 0..0x10000.
    expect_clamp(8'h84, 32'h0002_0000, 32'h0001_0000, "fx_a gain over 1.0 clamps to 1.0");
    expect_clamp(8'h84, 32'h001F_0000, 32'h001D_0000, "fx_a gain 1.0 keeps level and enable");

    // 0x88 FX_B, mask 0xFFFF03FF: no clamp row in 11.6, only the mask applies.
    expect_clamp(8'h88, 32'hFFFF_FFFF, 32'hFFFF_03FF, "fx_b delay truncates to its field");

    // 0x8C FX_C, mask 0xFFFFFFFF, spec 11.6: feedback 0..0x7333, reverb_mix 0..0x7FFF.
    expect_clamp(8'h8C, 32'hFFFF_FFFF, 32'h7FFF_7333, "fx_c feedback and reverb clamp");
    expect_clamp(8'h8C, 32'h8000_0005, 32'h7FFF_0005, "fx_c reverb over 1.0 clamps alone");
    expect_clamp(8'h8C, 32'h0000_7333, 32'h0000_7333, "fx_c feedback at 0.9 is unchanged");

    // 0x90 VOLUME, mask 0x0003FFFF, spec 11.6: volume 0..0x20000.
    expect_clamp(8'h90, 32'hFFFF_FFFF, 32'h0002_0000, "volume over 2.0 clamps to 2.0");
    expect_clamp(8'h90, 32'h0002_0000, 32'h0002_0000, "volume at 2.0 is unchanged");
    expect_clamp(8'h90, 32'h0001_0000, 32'h0001_0000, "volume at unity is unchanged");

    // ---- P2b (spec 11.1): 0x94 ENV_AD --------------------------------
    // Attack has a floor of 1: attack_step 0 means the envelope never rises, so
    // the voice holds its slot and stays silent forever (spec 11.6).  Decay 0
    // stops at the peak and is legal, so it must pass through untouched.
    expect_clamp(8'h94, 32'h0100_0000, 32'h0100_0001, "env_ad attack 0 clamps to 1");
    expect_clamp(8'h94, 32'h0000_1000, 32'h0000_1000, "env_ad decay 0 stays 0");
    expect_clamp(8'h94, 32'hFFFF_FFFF, 32'hFFFF_FFFF, "env_ad full scale is unchanged");
    // ---- P2b: 0x98 ENV_SR --------------------------------------------
    // Release has a floor of 1: release_step 0 keeps the envelope above zero, so
    // active[] never clears and event_ready deadlocks (spec 11.6).  Sustain 0 is
    // a legal silent sustain and must stay 0.
    expect_clamp(8'h98, 32'h0000_C000, 32'h0001_C000, "env_sr release 0 clamps to 1");
    expect_clamp(8'h98, 32'h0400_0000, 32'h0400_0000, "env_sr sustain 0 stays 0");
    expect_clamp(8'h98, 32'h1234_5678, 32'h1234_5678, "env_sr arbitrary values pass");
    // ---- P2b: 0x9C VOICE_MIX -----------------------------------------
    // The two 2-bit shift fields accept their whole range (3 is the narrowest
    // detune / the weakest velocity depth), glide has a floor of 1, and bits
    // 4..15 are outside the write mask.
    expect_clamp(8'h9C, 32'h0200_000F, 32'h0200_000F, "voice_mix both shift fields accept 3");
    expect_clamp(8'h9C, 32'h0000_0000, 32'h0001_0000, "voice_mix glide 0 clamps to 1");
    expect_clamp(8'h9C, 32'hFFFF_FFFF, 32'hFFFF_000F, "voice_mix clears bits 4..15");
    expect_clamp(8'h9C, 32'h0200_0000, 32'h0200_0000, "voice_mix glide 512 is unchanged");

    // The six P2a addresses and the three P2b addresses are read/write.
    expect_access(8'h40, V2_ACCESS_RW, "filter is read/write");
    expect_access(8'h44, V2_ACCESS_RW, "lfo is read/write");
    expect_access(8'h84, V2_ACCESS_RW, "fx_a is read/write");
    expect_access(8'h88, V2_ACCESS_RW, "fx_b is read/write");
    expect_access(8'h8C, V2_ACCESS_RW, "fx_c is read/write");
    expect_access(8'h90, V2_ACCESS_RW, "volume is read/write");
    expect_access(8'h94, V2_ACCESS_RW, "env_ad is read/write");
    expect_access(8'h98, V2_ACCESS_RW, "env_sr is read/write");
    expect_access(8'h9C, V2_ACCESS_RW, "voice_mix is read/write");

    // A write mask is not a clamp input: in-mask data is accepted (and then
    // clamped), bits outside the mask are still a BAD_DATA NACK.
    checks = checks + 1;
    if (v2_csr_data_valid(8'h9C, 32'hFFFF_000F) !== 1'b1) begin
      $display("FAIL an in-mask 0x9C write must be accepted by v2_csr_data_valid");
      errors = errors + 1;
    end else begin
      $display("PASS in-mask 0x9C write is accepted by v2_csr_data_valid");
    end
    checks = checks + 1;
    if (v2_csr_data_valid(8'h9C, 32'h0000_00F0) !== 1'b0) begin
      $display("FAIL an out-of-mask 0x9C write must be rejected by v2_csr_data_valid");
      errors = errors + 1;
    end else begin
      $display("PASS out-of-mask 0x9C write is rejected by v2_csr_data_valid");
    end

    // The packed default of the seven voice parameters.  Writing the expected
    // word out by field keeps the layout in one visible place.
    checks = checks + 1;
    if (V2_VOICE_CFG_DEFAULT !== {12'd0, 16'd512, 2'd0, 2'd0,
                                  16'd1024, 16'd49152, 16'd256, 16'd4096}) begin
      $display("FAIL V2_VOICE_CFG_DEFAULT is 0x%024h, expected 0x%024h",
               V2_VOICE_CFG_DEFAULT,
               {12'd0, 16'd512, 2'd0, 2'd0, 16'd1024, 16'd49152, 16'd256, 16'd4096});
      errors = errors + 1;
    end else begin
      $display("PASS V2_VOICE_CFG_DEFAULT packs attack/decay/sustain/release/shifts/glide");
    end

    if (errors != 0)
      $fatal(1, "tb_contract_clamp: %0d of %0d checks failed", errors, checks);
    $display("PASS tb_contract_clamp: %0d checks, all rows of spec 11.6 for P2a and P2b", checks);
    $finish;
  end
endmodule
