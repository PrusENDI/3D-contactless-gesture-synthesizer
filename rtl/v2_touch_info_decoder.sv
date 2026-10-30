// Explicit GestIC TouchInfo decoder. Low five bits are S/W/N/E/center electrodes.
// TouchInfo is diagnostic; it never drives general hand presence.
module v2_touch_info_decoder (
  input logic field_valid,
  input logic [31:0] touch_info,
  output logic [4:0] electrode_mask,
  output logic touch_state
);
  always_comb begin
    electrode_mask = field_valid ? touch_info[4:0] : 5'd0;
    touch_state = field_valid && (|electrode_mask);
  end
endmodule
