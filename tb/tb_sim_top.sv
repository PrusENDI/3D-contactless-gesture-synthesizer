// Simulation wrapper for the top-level regression.
//
// Gowin's prim_sim.v refers to the global set/reset primitive hierarchically as
// `GSR.GSRO`, so an instance whose *instance* name is exactly `GSR` must exist
// somewhere above every instantiated primitive.  Without it ModelSim reports
// Unresolved reference to 'GSR' eight times and the design never loads.
//
// The instance name is load-bearing: renaming `GSR` to something friendlier
// (`u_gsr`, `gsr_i`, ...) breaks elaboration.
`timescale 1ns/1ps

module tb_sim_top;
  GSR GSR (.GSRI(1'b1));

  tb_top_csr_gate u_tb ();

`ifdef CSR_TRACE
  // Emits the command/apply/reply stream.  Off by default so a signal rename
  // in the DUT cannot break the regression build.
  mon_csr_trace u_trace ();
`endif
endmodule
