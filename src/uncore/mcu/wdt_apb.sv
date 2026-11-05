///////////////////////////////////////////
// wdt_apb.sv
//
// Purpose: two-stage watchdog.  A down counter reloads from LOAD; when it reaches zero the first
//          time the timeout flag is set (an interrupt, if enabled) and it reloads; if the flag is
//          still set when it reaches zero again, the watchdog requests a system reset.  Software
//          refreshes it by writing KICK_KEY to KICK, which reloads the counter and clears the flag.
//
// Registers (word accesses):
//   00 CTRL    [0] EN  [1] IE.  EN sticks: once set only a reset clears it, as a watchdog should.
//   04 LOAD    timeout in prescaled ticks (reset value all ones, about 4.6 days at 1 MHz ticks)
//   08 COUNT   the counter (read only)
//   0C KICK    write 32'h5A1CE55A to reload the counter and clear the timeout flag; other values
//              are ignored
//   10 STATUS  [0] timeout flag; write 1 to clear
//   14 PSC     the counter ticks once every PSC+1 clocks
// ResetReq goes high on the second timeout and stays high until the chip resets.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module wdt_apb (
  input  logic        PCLK, PRESETn,
  input  logic        PSEL, PWRITE, PENABLE,
  input  logic [7:0]  PADDR,
  input  logic [31:0] PWDATA,
  output logic [31:0] PRDATA,
  output logic        Intr, ResetReq
);

  localparam KICK_KEY = 32'h5A1CE55A;

  logic        En, Ie, Timeout;
  logic [31:0] Load, Count;
  logic [15:0] Psc, PscCount;
  logic        Write, Tick, Expire, Kick;
  logic [7:0]  Entry;

  assign Write  = PSEL & PENABLE & PWRITE;
  assign Entry  = {PADDR[7:2], 2'b00};
  assign Kick   = Write & (Entry == 8'h0C) & (PWDATA == KICK_KEY);
  assign Tick   = En & (PscCount == 16'd0);
  assign Expire = Tick & (Count == 32'd0);

  always_ff @(posedge PCLK)
    if (~PRESETn) begin
      En <= 1'b0; Ie <= 1'b0; Timeout <= 1'b0; ResetReq <= 1'b0;
      Load <= '1; Count <= '1; Psc <= '0; PscCount <= '0;
    end else begin
      if (!En || PscCount == 16'd0) PscCount <= Psc;
      else                          PscCount <= PscCount - 16'd1;

      if (Kick)        Count <= Load;
      else if (Tick)   Count <= Expire ? Load : Count - 32'd1;

      if (Expire & !Kick) begin
        Timeout <= 1'b1;
        if (Timeout) ResetReq <= 1'b1;
      end
      if (Kick) Timeout <= 1'b0;

      if (Write)
        case (Entry)
          8'h00: begin En <= En | PWDATA[0]; Ie <= PWDATA[1]; end
          8'h04: begin Load <= PWDATA; if (!En) Count <= PWDATA; end
          8'h10: if (PWDATA[0] & !Expire) Timeout <= 1'b0;
          8'h14: Psc <= PWDATA[15:0];
          default: ;
        endcase
    end

  assign Intr = Timeout & Ie;

  always_comb
    case (Entry)
      8'h00:   PRDATA = {30'b0, Ie, En};
      8'h04:   PRDATA = Load;
      8'h08:   PRDATA = Count;
      8'h10:   PRDATA = {31'b0, Timeout};
      8'h14:   PRDATA = {16'b0, Psc};
      default: PRDATA = 32'b0;
    endcase

endmodule
