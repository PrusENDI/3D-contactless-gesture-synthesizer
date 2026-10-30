// Optional trace of the CSR command / APPLY / reply stream.
//
// This is the monitor that produced the only trustworthy evidence in the 88th
// debug round: it counted 1045 accepted commands against 1045 replies, which is
// what finally ruled out "the DUT never answers".  Enable with +define+CSR_TRACE.
`timescale 1ns/1ps

module mon_csr_trace;
  integer n_reply = 0;

  initial $timeformat(-9, 3, " ns", 12);

  always @(posedge tb_sim_top.u_tb.clk) begin
    if (tb_sim_top.u_tb.dut.wt_apply_valid_q)
      $display("TRACE apply_req  t=%t payload=%04h version_reg=%04h",
               $time, tb_sim_top.u_tb.dut.wt_apply_payload_q,
               tb_sim_top.u_tb.dut.wt_apply_version);

    if (tb_sim_top.u_tb.dut.wt_apply_done)
      $display("TRACE apply_done t=%t ok=%b reason=%0d",
               $time, tb_sim_top.u_tb.dut.wt_apply_ok,
               tb_sim_top.u_tb.dut.wt_apply_reason);

    if (tb_sim_top.u_tb.dut.rsp_valid && tb_sim_top.u_tb.dut.rsp_ready) begin
      n_reply = n_reply + 1;
      if (n_reply <= 4 || n_reply % 256 == 0)
        $display("TRACE reply      t=%t n=%0d seq=%02h err=%02h status=%02h",
                 $time, n_reply, tb_sim_top.u_tb.dut.rsp_sequence,
                 tb_sim_top.u_tb.dut.rsp_error, tb_sim_top.u_tb.dut.rsp_status);
    end
  end

  final $display("TRACE total_replies=%0d", n_reply);
endmodule
