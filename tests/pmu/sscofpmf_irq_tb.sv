// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module sscofpmf_irq_tb import cvw::*; #(parameter int SSCOFPMF = 1);
  `include "parameter-defs.vh"
  function automatic cvw_t configuration();
    cvw_t c = P;
    c.SSCOFPMF_SUPPORTED = (SSCOFPMF != 0);
    return c;
  endfunction
  localparam cvw_t C = configuration();
  logic clk = 0, reset = 1;
  always #5 clk = ~clk;
  logic CSRMWriteM = 0, CSRSWriteM = 0, LCOFIPSetM = 0;
  logic [11:0] CSRAdrM = 0;
  logic [P.XLEN-1:0] CSRWriteValM = 0;
  logic [13:0] MIDELEG_REGW = 0, MIP_REGW, MIE_REGW, MIP_REGW_writeable;
  logic [1:0] PrivilegeModeW = 2'b11;
  logic TrapM, InterruptM, ExceptionM, IntPendingM, DelegateM;
  logic [4:0] CauseM;

  csri #(.P(C)) dut(
    .clk, .reset, .CSRMWriteM, .CSRSWriteM, .CSRWriteValM, .CSRAdrM,
    .MExtInt(1'b0), .SExtInt(1'b0), .MTimerInt(1'b0), .STimerInt(1'b0), .MSwInt(1'b0),
    .LCOFIPSetM, .MIDELEG_REGW, .ENVCFG_STCE(1'b0), .MIP_REGW, .MIE_REGW, .MIP_REGW_writeable);
  trap #(.P(C)) trap_dut(
    .reset, .InstrMisalignedFaultM(1'b0), .InstrAccessFaultM(1'b0),
    .HPTWInstrAccessFaultM(1'b0), .HPTWInstrPageFaultM(1'b0), .IllegalInstrFaultM(1'b0),
    .BreakpointFaultM(1'b0), .LoadMisalignedFaultM(1'b0), .StoreAmoMisalignedFaultM(1'b0),
    .LoadAccessFaultM(1'b0), .StoreAmoAccessFaultM(1'b0), .EcallFaultM(1'b0),
    .InstrPageFaultM(1'b0), .LoadPageFaultM(1'b0), .StoreAmoPageFaultM(1'b0),
    .WaitedM(1'b0), .PrivilegeModeW, .MIP_REGW, .MIE_REGW, .MIDELEG_REGW,
    .MEDELEG_REGW(16'b0), .STATUS_MIE(1'b1), .STATUS_SIE(1'b1), .InstrValidM(1'b1),
    .CommittedM(1'b0), .CommittedF(1'b0), .TrapM, .InterruptM, .ExceptionM,
    .IntPendingM, .DelegateM, .CauseM);

  task automatic write_csr(input bit supervisor, input logic [11:0] csr, input logic [P.XLEN-1:0] data);
    @(negedge clk); CSRAdrM = csr; CSRWriteValM = data; CSRMWriteM = !supervisor; CSRSWriteM = supervisor;
    @(negedge clk); CSRMWriteM = 0; CSRSWriteM = 0;
  endtask

  initial begin
    repeat (3) @(negedge clk); reset = 0;
    write_csr(0, 'h304, P.XLEN'('h2000));
    assert (MIE_REGW[13] == (SSCOFPMF != 0)) else $fatal(1, "LCOFIE mask");
    @(negedge clk); LCOFIPSetM = 1;
    @(negedge clk); LCOFIPSetM = 0;
    assert (MIP_REGW[13] == (SSCOFPMF != 0)) else $fatal(1, "LCOFIP hardware set");
    if (SSCOFPMF != 0) begin
      #1; assert (TrapM && InterruptM && CauseM == 13 && !DelegateM)
        else $fatal(1, "machine overflow trap cause");
    end
    write_csr(0, 'h344, '0);
    assert (!MIP_REGW[13]) else $fatal(1, "LCOFIP machine clear");
    if (SSCOFPMF != 0) begin
      MIDELEG_REGW[13] = 1;
      write_csr(1, 'h104, P.XLEN'('h2000));
      assert (MIE_REGW[13]) else $fatal(1, "delegated SIE write");
      write_csr(1, 'h144, P.XLEN'('h2000));
      assert (MIP_REGW[13]) else $fatal(1, "delegated SIP set");
      PrivilegeModeW = 2'b01;
      #1; assert (TrapM && InterruptM && CauseM == 13 && DelegateM)
        else $fatal(1, "supervisor overflow trap cause/delegation");
      PrivilegeModeW = 2'b11;
      write_csr(1, 'h144, '0);
      assert (!MIP_REGW[13]) else $fatal(1, "delegated SIP clear");
      // Hardware request has priority over a simultaneous software clear.
      @(negedge clk); CSRAdrM = 'h344; CSRWriteValM = 0; CSRMWriteM = 1; LCOFIPSetM = 1;
      @(negedge clk); CSRMWriteM = 0; LCOFIPSetM = 0;
      assert (MIP_REGW[13]) else $fatal(1, "lost concurrent overflow");
    end
    $display("PASS: RV%0d Sscofpmf=%0d interrupt CSR", P.XLEN, SSCOFPMF);
    $finish;
  end
endmodule
