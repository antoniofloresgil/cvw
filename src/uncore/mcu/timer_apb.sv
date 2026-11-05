///////////////////////////////////////////
// timer_apb.sv
//
// Purpose: general-purpose timer with four channels, each an edge-aligned PWM output or an input
//          capture.  One 32-bit up counter with a 16-bit prescaler and an auto-reload value.
//
// Registers (word accesses, offsets from the timer's base):
//   00 CTRL     [0] EN  [1] ONESHOT: EN clears at the next overflow
//   04 PSC      the counter ticks once every PSC+1 clocks
//   08 ARR      the counter counts 0..ARR and wraps (overflow); reset value all ones
//   0C CNT      the counter (writable)
//   10 STATUS   [0] overflow  [4:1] channel x match or capture; write 1 to clear
//   14 IE       interrupt enables, same bits as STATUS
//   20+4x CCR   channel x compare value, or the value captured
//   40+4x CCFG  channel x [0] CAPTURE (else PWM)  [1] capture on rising edge  [2] capture on
//               falling edge  [3] PWM output inverted
// A PWM output is high while CNT < CCR: CCR = 0 keeps it low, CCR > ARR keeps it high.  A PWM
// channel drives its pad (PWMEn) and sets its STATUS bit on the tick when CNT equals CCR; a
// capture channel leaves the pad as an input, whose edges are seen after two synchronizer flops
// and copy CNT into CCR.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module timer_apb (
  input  logic        PCLK, PRESETn,
  input  logic        PSEL, PWRITE, PENABLE,
  input  logic [7:0]  PADDR,
  input  logic [31:0] PWDATA,
  output logic [31:0] PRDATA,
  input  logic [3:0]  CaptureIn,       // pad inputs of the capture channels
  output logic [3:0]  PWMOut, PWMEn,   // PWM outputs and their pad output enables
  output logic        Intr
);

  logic        En, OneShot;
  logic [15:0] Psc, PscCount;
  logic [31:0] Arr, Cnt;
  logic [4:0]  Status, Ie;
  logic [31:0] Ccr [4];
  logic [3:0]  CCfg [4];
  logic [3:0]  Sync1, Sync2, Sync3;

  logic        Write, Tick, Overflow;
  logic [3:0]  Match, CapEdge;
  logic [4:0]  Events;
  logic [7:0]  Entry;

  assign Write = PSEL & PENABLE & PWRITE;
  assign Entry = {PADDR[7:2], 2'b00};

  assign Tick     = En & (PscCount == 16'd0);
  assign Overflow = Tick & (Cnt == Arr);

  // input synchronizers
  always_ff @(posedge PCLK)
    if (~PRESETn) {Sync1, Sync2, Sync3} <= '0;
    else          {Sync1, Sync2, Sync3} <= {CaptureIn, Sync1, Sync2};

  for (genvar i = 0; i < 4; i++) begin : ch
    assign CapEdge[i] = CCfg[i][0] & ((CCfg[i][1] & Sync2[i] & ~Sync3[i]) | (CCfg[i][2] & ~Sync2[i] & Sync3[i]));
    assign Match[i]   = ~CCfg[i][0] & Tick & (Cnt == Ccr[i]);
    assign PWMOut[i]  = (Cnt < Ccr[i]) ^ CCfg[i][3];
    assign PWMEn[i]   = ~CCfg[i][0];
  end

  assign Events = {Match | CapEdge, Overflow};

  always_ff @(posedge PCLK)
    if (~PRESETn) begin
      En <= 1'b0; OneShot <= 1'b0; Psc <= '0; PscCount <= '0;
      Arr <= '1; Cnt <= '0; Status <= '0; Ie <= '0;
      for (int i = 0; i < 4; i++) begin Ccr[i] <= '0; CCfg[i] <= '0; end
    end else begin
      // prescaler and counter
      if (!En || PscCount == 16'd0) PscCount <= Psc;
      else                          PscCount <= PscCount - 16'd1;
      if (Tick) Cnt <= Overflow ? 32'd0 : Cnt + 32'd1;
      if (Overflow & OneShot) En <= 1'b0;
      // captures
      for (int i = 0; i < 4; i++)
        if (CapEdge[i]) Ccr[i] <= Cnt;
      // status: events set bits, a write of 1 clears the bit unless a new event coincides
      Status <= Status | Events;
      // register writes, which win over the hardware where they overlap
      if (Write) begin
        case (Entry)
          8'h00: begin En <= PWDATA[0]; OneShot <= PWDATA[1]; end
          8'h04: Psc <= PWDATA[15:0];
          8'h08: Arr <= PWDATA;
          8'h0C: Cnt <= PWDATA;
          8'h10: Status <= (Status & ~PWDATA[4:0]) | Events;
          8'h14: Ie <= PWDATA[4:0];
          default: ;
        endcase
        for (int i = 0; i < 4; i++) begin
          if (Entry == 8'(8'h20 + 4*i)) Ccr[i]  <= PWDATA;
          if (Entry == 8'(8'h40 + 4*i)) CCfg[i] <= PWDATA[3:0];
        end
      end
    end

  assign Intr = |(Status & Ie);

  always_comb begin
    PRDATA = 32'b0;
    case (Entry)
      8'h00: PRDATA = {30'b0, OneShot, En};
      8'h04: PRDATA = {16'b0, Psc};
      8'h08: PRDATA = Arr;
      8'h0C: PRDATA = Cnt;
      8'h10: PRDATA = {27'b0, Status};
      8'h14: PRDATA = {27'b0, Ie};
      default: ;
    endcase
    for (int i = 0; i < 4; i++) begin
      if (Entry == 8'(8'h20 + 4*i)) PRDATA = Ccr[i];
      if (Entry == 8'(8'h40 + 4*i)) PRDATA = {28'b0, CCfg[i]};
    end
  end

endmodule
