///////////////////////////////////////////
// i2c_apb.sv
//
// Purpose: single-master I2C controller, byte at a time, with clock stretching.  The lines are
//          open drain: SCLDrive/SDADrive pull the line low, otherwise the pad releases it.
//
// Registers (word accesses):
//   00 PRE     SCL period is 4 * (PRE+1) clocks
//   04 CTRL    [0] EN  [1] IE
//   08 TXR/RXR write: byte to send; read: byte received
//   0C CMD     write: [0] START  [1] STOP  [2] READ  [3] WRITE  [4] NACK (with READ: answer the
//              byte with a NACK, the last byte of a read).  One command is a START, then a byte
//              (READ or WRITE), then a STOP, each as flagged and in that order.
//   10 STATUS  [0] BUSY: a command is running  [1] RXACK: the addressed device did not
//              acknowledge the last written byte  [2] IF: a command finished; write 1 to clear
//
// Each bit takes four steps of PRE+1 clocks: put the data on SDA with SCL low, release SCL, sample
// SDA with SCL high (waiting first while a slave stretches SCL), pull SCL low.  PRE must be at
// least 2, for the two synchronizer flops on the pad inputs.  A STOP command on an idle bus
// (SCL and SDA high) makes a START first: send STOP only after a byte.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module i2c_apb (
  input  logic        PCLK, PRESETn,
  input  logic        PSEL, PWRITE, PENABLE,
  input  logic [7:0]  PADDR,
  input  logic [31:0] PWDATA,
  output logic [31:0] PRDATA,
  input  logic        SCLIn, SDAIn,        // the pads' values
  output logic        SCLDrive, SDADrive,  // 1: pull the line low
  output logic        Intr
);

  typedef enum logic [1:0] {IDLE, START, BYTE, STOP} phase_t;

  logic [15:0] Pre, TickCount;
  logic        En, Ie, Flag, RxNack;
  logic [7:0]  Tx, Rx;
  logic        CmdStart, CmdStop, CmdRead, CmdWrite, CmdNack;
  phase_t      Phase;
  logic [1:0]  Step;
  logic [3:0]  Bit;        // 0..7 data bits, 8 the acknowledge
  logic        SclRel, SdaRel;
  logic        SclS1, SclS2, SdaS1, SdaS2;

  logic        Write, Tick, Stretch;
  logic [7:0]  Entry;

  assign Write = PSEL & PENABLE & PWRITE;
  assign Entry = {PADDR[7:2], 2'b00};

  assign SCLDrive = ~SclRel;
  assign SDADrive = ~SdaRel;

  // synchronizers for the pad inputs
  always_ff @(posedge PCLK)
    if (~PRESETn) {SclS1, SclS2, SdaS1, SdaS2} <= '1;
    else          {SclS1, SclS2, SdaS1, SdaS2} <= {SCLIn, SclS1, SDAIn, SdaS1};

  assign Tick    = (TickCount == 16'd0);
  // Step 2 follows the step that released SCL: wait there while a slave still holds SCL low
  assign Stretch = (Step == 2'd2) & ~SclS2;

  always_ff @(posedge PCLK)
    if (~PRESETn) begin
      Pre <= '1; TickCount <= '0; En <= 1'b0; Ie <= 1'b0; Flag <= 1'b0; RxNack <= 1'b0;
      Tx <= '0; Rx <= '0; {CmdStart, CmdStop, CmdRead, CmdWrite, CmdNack} <= '0;
      Phase <= IDLE; Step <= '0; Bit <= '0; SclRel <= 1'b1; SdaRel <= 1'b1;
    end else begin
      if (Tick | Phase == IDLE) TickCount <= Pre;
      else                      TickCount <= TickCount - 16'd1;

      if (Phase != IDLE & En & Tick & ~Stretch) begin
        Step <= Step + 2'd1;
        case (Phase)
          START: begin // SDA high with SCL low, SCL high, SDA low, SCL low
            case (Step)
              2'd0: SdaRel <= 1'b1;
              2'd1: SclRel <= 1'b1;
              2'd2: SdaRel <= 1'b0;
              2'd3: begin
                SclRel <= 1'b0;
                Phase <= (CmdRead | CmdWrite) ? BYTE : (CmdStop ? STOP : IDLE);
                Bit <= '0;
                if (!(CmdRead | CmdWrite | CmdStop)) Flag <= 1'b1;
              end
            endcase
          end
          BYTE: begin
            case (Step)
              2'd0: // data (or the acknowledge) on SDA while SCL is low
                if (Bit == 4'd8) SdaRel <= CmdWrite ? 1'b1 : ~CmdRead ? 1'b1 : CmdNack; // read: ACK pulls low
                else             SdaRel <= CmdWrite ? Tx[7] : 1'b1;
              2'd1: SclRel <= 1'b1;
              2'd2: begin // SCL high: sample
                if (Bit == 4'd8) begin
                  if (CmdWrite) RxNack <= SdaS2;
                end else if (CmdRead) Rx <= {Rx[6:0], SdaS2};
              end
              2'd3: begin
                SclRel <= 1'b0;
                if (Bit == 4'd8) begin
                  Phase <= CmdStop ? STOP : IDLE;
                  if (!CmdStop) Flag <= 1'b1;
                end else begin
                  if (CmdWrite) Tx <= {Tx[6:0], 1'b0};
                  Bit <= Bit + 4'd1;
                end
              end
            endcase
          end
          STOP: begin // SDA low with SCL low, SCL high, SDA high
            case (Step)
              2'd0: SdaRel <= 1'b0;
              2'd1: SclRel <= 1'b1;
              2'd2: SdaRel <= 1'b1;
              2'd3: begin Phase <= IDLE; Flag <= 1'b1; end
            endcase
          end
          default: ;
        endcase
      end

      if (Write)
        case (Entry)
          8'h00: Pre <= PWDATA[15:0];
          8'h04: begin En <= PWDATA[0]; Ie <= PWDATA[1]; end
          8'h08: Tx <= PWDATA[7:0];
          8'h0C: if (Phase == IDLE & En) begin
            {CmdNack, CmdWrite, CmdRead, CmdStop, CmdStart} <= PWDATA[4:0];
            Step <= '0;
            Bit <= '0;
            Phase <= PWDATA[0] ? START : (PWDATA[3] | PWDATA[2]) ? BYTE : PWDATA[1] ? STOP : IDLE;
            Flag <= 1'b0;
          end
          8'h10: if (PWDATA[2]) Flag <= 1'b0;
          default: ;
        endcase
    end

  assign Intr = Flag & Ie;

  always_comb
    case (Entry)
      8'h00:   PRDATA = {16'b0, Pre};
      8'h04:   PRDATA = {30'b0, Ie, En};
      8'h08:   PRDATA = {24'b0, Rx};
      8'h10:   PRDATA = {29'b0, Flag, RxNack, Phase != IDLE};
      default: PRDATA = 32'b0;
    endcase

endmodule
