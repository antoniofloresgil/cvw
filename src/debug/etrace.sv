///////////////////////////////////////////
// etrace.sv
//
// Purpose: The instruction trace of the SoC (TRACE_SUPPORTED, docs/trace.md): for each hart, an
//          E-Trace encoder (src/debug/etraceencoder.sv) fed by the hart's instruction trace
//          interface, and a Trace RAM Sink (src/debug/etracesink.sv), controlled through the
//          registers of the RISC-V Trace Control Interface v1.0 at
//            TRACE_BASE + h*0x2000            trace encoder of hart h (trTe...)
//            TRACE_BASE + h*0x2000 + 0x1000   RAM sink of hart h (trRam...)
//          32-bit registers, reached through System Bus Access (the external debugger) or by the
//          harts' loads and stores (the PMA allows 32-bit accesses, src/mmu/pmachecker.sv).
//
//          The uncore does not decode the window, so it answers a transfer there as it answers
//          any undecoded address: ready at once, OKAY, read data 0.  This block watches the
//          address phase on the bus after the debug arbiter, and supplies the read data in the
//          data phase (TraceHSEL selects it in place of the uncore's).
//
//          Trace encoder registers (offset in the encoder's 4 KiB block; others read 0):
//            0x000 trTeControl  0 trTeActive, 1 trTeEnable, 2 trTeInstTracing, 3 trTeEmpty (RO),
//                               6:4 trTeInstMode (3, baseline), 12 trTeInstStallOrOverflow
//                               (RW1C: a packet was dropped), 17:16 trTeInstSyncMode (1, count
//                               packets), 23:20 trTeInstSyncMax, 26:24 trTeFormat (0, E-Trace)
//            0x004 trTeImpl     version 1.0, component type 1, E-Trace protocol 2.0
//          The encoder traces while trTeEnable and trTeInstTracing are 1; clearing either
//          flushes it.  trTeActive 0 resets it.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module etrace import cvw::*; #(parameter cvw_t P, parameter int unsigned NHARTS = 1) (
  input  logic                                 clk, reset,
  input  logic [NHARTS-1:0][2*P.XLEN+13:0]     ITrace,      // instruction trace interface of each hart
  // The bus after the debug arbiter
  input  logic [P.PA_BITS-1:0]                 HADDR,
  input  logic [1:0]                           HTRANS,
  input  logic                                 HWRITE, HREADY,
  input  logic [P.AHBW-1:0]                    HWDATA,
  output logic                                 TraceHSEL,   // data phase of a transfer to the window
  output logic [P.AHBW-1:0]                    TraceHRDATA,
  // TRACE_IN_RAM: the port of hart 0's sink to the last TRACE_RAM_WORDS words of the uncore RAM
  output logic                                 TrReq, TrWe,
  output logic [3:0]                           TrBwe,
  output logic [$clog2(P.TRACE_RAM_WORDS)-1:0] TrAddr,
  output logic [31:0]                          TrDin,
  input  logic                                 TrGrant,
  input  logic [31:0]                          TrDout
);

  localparam int NBYTES = 1 + (2*P.XLEN + 13 + 7) / 8;

  if (P.TRACE_IN_RAM & NHARTS != 1) $error("TRACE_IN_RAM supports one hart: the trace RAM is one area of the uncore RAM");

  // Address phase: a transfer to the window
  logic                   InWindow;
  logic [P.PA_BITS-1:0]   Offset;
  assign Offset   = HADDR - P.TRACE_BASE[P.PA_BITS-1:0];
  assign InWindow = HADDR >= P.TRACE_BASE[P.PA_BITS-1:0] & Offset < P.PA_BITS'(NHARTS * 32'h2000);

  logic        DWrite;
  logic [15:2] DAdr;                               // hart 15:13, sink 12, register 11:2
  always_ff @(posedge clk)
    if (reset) TraceHSEL <= 1'b0;
    else if (HREADY) begin
      TraceHSEL <= HTRANS[1] & InWindow;
      DWrite    <= HWRITE;
      DAdr      <= Offset[15:2];
    end

  // Data phase: the 32-bit lane of the register
  logic [31:0] WData, RData;
  if (P.AHBW == 64) begin : lane
    assign WData = DAdr[2] ? HWDATA[63:32] : HWDATA[31:0];
  end else begin : nolane
    assign WData = HWDATA[31:0];
  end
  assign TraceHRDATA = {(P.AHBW/32){RData}};

  logic [NHARTS-1:0][31:0] HartRData;              // 0 unless the hart is selected
  always_comb begin
    RData = '0;
    for (int h = 0; h < NHARTS; h++) RData |= HartRData[h];
  end

  for (genvar h = 0; h < NHARTS; h++) begin : hart
    logic        Sel, TeSel, RamSel;
    assign Sel    = TraceHSEL & DAdr[15:13] == 3'(h);
    assign TeSel  = Sel & ~DAdr[12];
    assign RamSel = Sel & DAdr[12];

    // The encoder and its sink
    logic                PacketValid, PacketReady, LineTaken;
    logic [4:0]          PacketLen;
    logic [8*NBYTES-1:0] Packet;
    logic                DataRead;
    logic [31:0]         RamDout;
    logic                ShReq, ShWe;
    logic [3:0]          ShBwe;
    logic [$clog2(P.TRACE_RAM_WORDS)-1:0] ShAddr;
    logic [31:0]         ShDin;

    // Trace encoder control
    logic        Active, Enable, InstTracing, Overflow, Idle;
    logic [3:0]  SyncMax;
    logic        WCtrl;
    logic [31:0] TeRData, RamRData;
    assign WCtrl = TeSel & DWrite & DAdr[11:2] == 10'h000;
    always_ff @(posedge clk)
      if (reset | WCtrl & ~WData[0]) begin         // trTeActive 0 resets the encoder
        Active <= 1'b0; Enable <= 1'b0; InstTracing <= 1'b0; Overflow <= 1'b0; SyncMax <= '0;
      end else begin
        if (WCtrl) begin
          Active <= 1'b1; Enable <= WData[1]; InstTracing <= WData[2]; SyncMax <= WData[23:20];
        end
        // Set by a dropped packet; cleared by writing 1, or by enabling the encoder
        if (PacketValid & ~PacketReady) Overflow <= 1'b1;
        else if (WCtrl & (WData[12] | WData[1] & ~Enable)) Overflow <= 1'b0;
      end

    always_comb
      case (DAdr[11:2])
        10'h000: TeRData = {5'b0, 3'd0, SyncMax, 2'b0, 2'd1, 3'b0, Overflow, 5'b0, 3'd3,
                            Idle, InstTracing, Enable, Active};
        10'h001: TeRData = 32'h0002_0101;          // E-Trace 2.0, type 1 (encoder), version 1.0
        default: TeRData = 32'b0;
      endcase

    etraceencoder #(P) enc(.clk, .reset(reset | ~Active), .TraceOn(Enable & InstTracing),
      .ResyncMax(SyncMax), .ITrace(ITrace[h]), .PacketValid, .PacketLen, .Packet, .LineTaken, .Idle);
    etracesink #(.P(P), .NBYTES(NBYTES)) sink(.clk, .reset, .PacketValid, .PacketLen, .Packet,
      .PacketReady, .RegSel(RamSel), .RegWrite(DWrite), .RegAdr(DAdr[11:2]), .RegWData(WData),
      .RegRData(RamRData), .DataRead, .RamDout, .ShReq, .ShWe, .ShBwe, .ShAddr, .ShDin, .ShGrant(TrGrant), .ShDout(TrDout));
    if (h == 0) begin : port
      assign {TrReq, TrWe, TrBwe, TrAddr, TrDin} = {ShReq, ShWe, ShBwe, ShAddr, ShDin};
    end

    assign HartRData[h] = ~Sel ? '0 : DAdr[12] ? RamRData : TeRData;
  end
endmodule
