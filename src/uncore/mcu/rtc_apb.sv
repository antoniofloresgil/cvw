///////////////////////////////////////////
// rtc_apb.sv
//
// Purpose: real-time counter with an alarm and an optional periodic wake-up.  A 32-bit counter
//          advances once every DIV+1 clocks (set DIV for 1 Hz, or use a slower tick), and the alarm
//          interrupt, which like any interrupt ends a WFI, fires when TIME equals ALARM.  With
//          PERIOD non-zero the alarm re-arms itself: ALARM advances by PERIOD at each match.
//
// Registers (word accesses):
//   00 CTRL    [0] EN  [1] IE
//   04 DIV     clocks per tick minus one (reset value 0)
//   08 TIME    the counter (writable)
//   0C ALARM   alarm value
//   10 STATUS  [0] alarm flag; write 1 to clear
//   14 PERIOD  0: one-shot alarm; otherwise ALARM += PERIOD at each match
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module rtc_apb (
  input  logic        PCLK, PRESETn,
  input  logic        PSEL, PWRITE, PENABLE,
  input  logic [7:0]  PADDR,
  input  logic [31:0] PWDATA,
  output logic [31:0] PRDATA,
  output logic        Intr
);

  logic        En, Ie, Flag;
  logic [31:0] Div, DivCount, Time, Alarm, Period;
  logic        Write, Tick, Match;
  logic [7:0]  Entry;

  assign Write = PSEL & PENABLE & PWRITE;
  assign Entry = {PADDR[7:2], 2'b00};
  assign Tick  = En & (DivCount == 32'd0);
  // the alarm is compared when the counter has just advanced
  assign Match = Tick & (Time + 32'd1 == Alarm);

  always_ff @(posedge PCLK)
    if (~PRESETn) begin
      En <= 1'b0; Ie <= 1'b0; Flag <= 1'b0;
      Div <= '0; DivCount <= '0; Time <= '0; Alarm <= '1; Period <= '0;
    end else begin
      if (!En || DivCount == 32'd0) DivCount <= Div;
      else                          DivCount <= DivCount - 32'd1;
      if (Tick) Time <= Time + 32'd1;
      if (Match) begin
        Flag <= 1'b1;
        if (Period != 32'd0) Alarm <= Alarm + Period;
      end
      if (Write)
        case (Entry)
          8'h00: begin En <= PWDATA[0]; Ie <= PWDATA[1]; end
          8'h04: begin Div <= PWDATA; DivCount <= PWDATA; end
          8'h08: Time <= PWDATA;
          8'h0C: Alarm <= PWDATA;
          8'h10: if (PWDATA[0] & !Match) Flag <= 1'b0;
          8'h14: Period <= PWDATA;
          default: ;
        endcase
    end

  assign Intr = Flag & Ie;

  always_comb
    case (Entry)
      8'h00:   PRDATA = {30'b0, Ie, En};
      8'h04:   PRDATA = Div;
      8'h08:   PRDATA = Time;
      8'h0C:   PRDATA = Alarm;
      8'h10:   PRDATA = {31'b0, Flag};
      8'h14:   PRDATA = Period;
      default: PRDATA = 32'b0;
    endcase

endmodule
