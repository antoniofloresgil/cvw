///////////////////////////////////////////
// etracesink.sv
//
// Purpose: A Trace RAM Sink of the RISC-V Trace Control Interface v1.0 in SRAM mode, for the
//          packets of one trace encoder (src/debug/etraceencoder.sv): a circular buffer of
//          WORDS 32-bit words in a RAM of its own, written byte after byte in the order of the
//          packets (first byte of a packet in the least significant byte), and read back
//          through trRamRP and trRamData.  docs/trace.md describes its use.
//
//          Registers (offset in the sink's 4 KiB block; the others read 0 and ignore writes):
//            0x000 trRamControl  0 trRamActive, 1 trRamEnable, 3 trRamEmpty (RO), 4 trRamMode
//                                (0, SRAM), 8 trRamStopOnWrap, 10:9 trRamMemFormat (0, bytes)
//            0x004 trRamImpl     version 1.0, component type 9, trRamHasSRAM
//            0x010 trRamStartLow 0
//            0x018 trRamLimitLow 4*(WORDS-1), the last word
//            0x020 trRamWPLow    0 trRamWrap, 31:2 the word that the next byte goes to
//            0x028 trRamRPLow    31:2 the word that trRamData reads
//            0x040 trRamData     the word at trRamRP; a read advances trRamRP
//          trRamWP and trRamRP can be written, and trRamData read, only while the sink is
//          disabled and empty (otherwise the writes are ignored and trRamData reads 0).
//
//          A queue of QUEUE whole packets absorbs bursts; the RAM takes up to 4 bytes per
//          cycle (the rest of the current word).  A packet that arrives when the queue is full,
//          or the sink is not enabled, is dropped (PacketReady 0: the encoder records an
//          overflow).  Disabling the sink (trRamEnable 0) writes the queued packets, then fills
//          the last word with idle bytes 0 (never a packet header, which has msg_type 2), so
//          that trRamWP ends on a word boundary.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module etracesink import cvw::*; #(parameter cvw_t P, parameter int NBYTES = 19, QUEUE = 4,
  localparam int WORDS = P.TRACE_RAM_WORDS, AW = $clog2(P.TRACE_RAM_WORDS)
) (
  input  logic                clk, reset,
  // Packets from the encoder
  input  logic                PacketValid,
  input  logic [4:0]          PacketLen,
  input  logic [8*NBYTES-1:0] Packet,
  output logic                PacketReady,
  // Register access, in the data phase of a bus transfer
  input  logic                RegSel, RegWrite,
  input  logic [11:2]         RegAdr,
  input  logic [31:0]         RegWData,
  output logic [31:0]         RegRData,
  output logic                DataRead,           // a read of trRamData (for the testbench)
  output logic [31:0]         RamDout
);

  localparam logic [AW-1:0] LIMIT = AW'(WORDS - 1);
  localparam int QW = QUEUE > 1 ? $clog2(QUEUE) : 1;

  logic              Active, Enable, StopOnWrap, Wrap;
  logic [AW-1:0]     WP, RP;                       // word pointers
  logic [1:0]        WB;                           // next byte in word WP
  logic              Empty, Busy;                  // Busy: the RAM was written last cycle

  ///////////////////////////////////////////
  // The packet queue
  ///////////////////////////////////////////

  logic [QUEUE-1:0][8*NBYTES-1:0] QData;
  logic [QUEUE-1:0][4:0]          QLen;
  logic [QW-1:0]                  QHead, QTail;
  logic [QW:0]                    QCount;
  logic [4:0]                     Off;             // bytes of the head packet already written
  logic                           Push, Pop, QEmpty;
  assign QEmpty      = QCount == 0;
  assign PacketReady = Active & Enable & QCount != (QW+1)'(QUEUE);
  assign Push        = PacketValid & PacketReady;

  // The bytes written this cycle: the rest of the head packet, up to the end of word WP
  logic [8*NBYTES-1:0] Head;
  logic [4:0]          HeadLen, Left;
  logic [2:0]          Room, N;                    // bytes left in word WP, bytes written
  logic                Pad, WriteRam, WordDone;
  logic [31:0]         Din;
  logic [3:0]          Bwe;
  assign Head     = QData[QHead];
  assign HeadLen  = QLen[QHead];
  assign Left     = HeadLen - Off;
  assign Room     = 3'd4 - {1'b0, WB};
  assign Pad      = QEmpty & ~Enable & WB != 2'd0;  // fill the last word when the sink is disabled
  assign N        = Pad ? Room : (Left < {2'b0, Room}) ? Left[2:0] : Room;
  assign WriteRam = Active & (~QEmpty | Pad);
  assign WordDone = WriteRam & ({1'b0, WB} + N == 3'd4);
  assign Pop      = WriteRam & ~Pad & Off + {2'b0, N} == HeadLen;

  always_comb
    for (int i = 0; i < 4; i++) begin
      int b;
      Bwe[i] = WriteRam & i >= int'(WB) & i < int'(WB) + int'(N);
      b = Bwe[i] ? int'(Off) + i - int'(WB) : 0;    // the byte of the head packet in lane i
      Din[8*i +: 8] = Pad ? 8'h00 : Head[8*b +: 8];
    end

  ///////////////////////////////////////////
  // Registers
  ///////////////////////////////////////////

  logic Idle;                                       // reads and pointer writes allowed
  logic WCtrl, WWP, WRP;
  assign Idle     = ~Enable & Empty;
  assign WCtrl    = RegSel & RegWrite & RegAdr == 10'h000;
  assign WWP      = RegSel & RegWrite & RegAdr == 10'h008 & Idle;
  assign WRP      = RegSel & RegWrite & RegAdr == 10'h00A & Idle;
  assign DataRead = RegSel & ~RegWrite & RegAdr == 10'h010 & Idle;

  always_comb
    case (RegAdr)
      10'h000: RegRData = {23'b0, StopOnWrap, 3'b0, 1'b0, Empty, 1'b0, Enable, Active};
      10'h001: RegRData = 32'h0000_1091;            // trRamHasSRAM, type 9 (RAM sink), version 1.0
      10'h006: RegRData = 32'(LIMIT) << 2;
      10'h008: RegRData = (32'(WP) << 2) | {31'b0, Wrap};
      10'h00A: RegRData = 32'(RP) << 2;
      10'h010: RegRData = DataRead ? RamDout : 32'b0;
      default: RegRData = 32'b0;
    endcase

  // The RAM: written while packets drain, otherwise reading the word that trRamData returns next
  logic [AW-1:0] RPNext, RamAdr;
  always_comb
    if (WRP)           RPNext = RegWData[AW+1:2];
    else if (DataRead) RPNext = RP == LIMIT ? '0 : RP + 1'b1;
    else               RPNext = RP;
  assign RamAdr = WriteRam ? WP : RPNext;

  ram1p1rwbe #(.USE_SRAM(P.USE_SRAM), .DEPTH(WORDS), .WIDTH(32)) ram(.clk, .ce(1'b1), .addr(RamAdr),
    .din(Din), .we(WriteRam), .bwe(Bwe), .dout(RamDout));

  always_ff @(posedge clk)
    if (reset | WCtrl & ~RegWData[0]) begin         // trRamActive 0 resets the sink
      Active <= 1'b0; Enable <= 1'b0; StopOnWrap <= 1'b0;
      QHead <= '0; QTail <= '0; QCount <= '0; Off <= '0; WB <= '0; Busy <= 1'b0;
      if (reset) begin WP <= '0; RP <= '0; Wrap <= 1'b0; end
    end else begin
      if (WCtrl) begin
        Active <= 1'b1; Enable <= RegWData[1]; StopOnWrap <= RegWData[8];
      end
      // The queue
      if (Push) begin
        QData[QTail] <= Packet; QLen[QTail] <= PacketLen;
        QTail <= QTail == QW'(QUEUE-1) ? '0 : QTail + 1'b1;
      end
      if (Pop) begin
        QHead <= QHead == QW'(QUEUE-1) ? '0 : QHead + 1'b1;
        Off <= '0;
      end else if (WriteRam & ~Pad) Off <= Off + {2'b0, N};
      QCount <= QCount + (QW+1)'(Push) - (QW+1)'(Pop);
      // The write pointer, and the wrap at the end of the buffer
      if (WWP) begin
        WP <= RegWData[AW+1:2]; Wrap <= RegWData[0]; WB <= '0;
      end else if (WordDone) begin
        WB <= '0;
        if (WP == LIMIT) begin
          WP <= '0; Wrap <= 1'b1;
          if (StopOnWrap) begin                     // stop: the buffer keeps the oldest trace
            Enable <= 1'b0; QHead <= '0; QTail <= '0; QCount <= '0; Off <= '0;
          end
        end else WP <= WP + 1'b1;
      end else if (WriteRam) WB <= WB + N[1:0];
      RP <= RPNext;
      Busy <= WriteRam;
    end

  // Empty: nothing queued, the last word complete, and the RAM free since the last write
  assign Empty = QEmpty & WB == 2'd0 & ~Busy;
endmodule
