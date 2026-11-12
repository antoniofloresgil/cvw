///////////////////////////////////////////
// ai_unit.sv
//
// Purpose: int8 matrix-vector unit with its own AHB master (docs/engineering/decisions/0024-edge-ai-accelerator.md).
//          y = clamp(((W x + bias) * MULT) >> SHIFT): the layer of a neural network, in one command.  With RAW set the unit returns the
//          int32 accumulator W x + bias, one word per output, and leaves the requantization to software (the scheme of CMSIS-NN and
//          muRISCV-NN, which differs from the one above in the multiplier, the rounding and the zero points).
//          W (OUT rows of IN int8, row-major) and the int32 bias stay in the RAM and are streamed by the unit's master one 32-bit word
//          (four int8) per clock; the input vector x (IN bytes, up to X_BYTES) is read once into a small memory inside the unit, so the
//          bus carries only W.  The results are int8, four to a word, written back to the RAM.
//
// Registers (word accesses at the unit's PADDR, block 4 of mcu_apb):
//   00 CTRL     [0] START (a write of 1 starts a run when idle)  [1] RELU: clamp to 0..127 instead of -128..127
//               [2] RAW: write W x + bias as an int32 per output (Y is OUT words); MULT, SHIFT and RELU are then ignored
//   04 STATUS   [0] BUSY  [1] DONE  [2] ERROR: write 1 to clear DONE and ERROR.  A start with bad arguments, or a bus error, sets ERROR
//   08 IN       bytes of x and of a row of W: a multiple of 4, 4..X_BYTES
//   0C OUT      rows, 1..65535
//   10 W_ADDR   weights, word aligned          14 X_ADDR   input vector, word aligned
//   18 BIAS_ADDR  OUT int32, word aligned; 0 means no bias      1C Y_ADDR   OUT int8 (OUT int32 with RAW), word aligned
//   20 MULT     signed 16-bit multiplier (bits 15:0)            24 SHIFT    arithmetic right shift, 0..47
//   28 CYCLES   clocks of the last run (read only)
// Every address must lie in the uncore RAM outside the trace buffer, else the start is refused (ERROR).  The registers are written
// only while idle.  The core is stalled while the unit owns the bus (uncore.sv): the unit takes it only between two transfers of the
// core, for the length of a row.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module ai_unit import cvw::*; #(parameter cvw_t P) (
  input  logic                 HCLK, HRESETn,
  // APB slave: the registers
  input  logic                 PSEL, PWRITE, PENABLE,
  input  logic [7:0]           PADDR,
  input  logic [31:0]          PWDATA,
  output logic [31:0]          PRDATA,
  // AHB master, to the arbiter in uncore.sv
  output logic                 Req,                    // an address is on the bus if the arbiter grants it
  output logic                 Write,
  output logic [P.PA_BITS-1:0] Addr,
  output logic [31:0]          WData,                  // data of a write, valid in its data phase
  output logic [3:0]           WStrb,
  input  logic                 Accept,                 // the address was accepted this clock
  input  logic                 DataDone,               // the data phase of the unit's previous transfer ends this clock
  input  logic                 BusErr,                 // HRESP during the unit's data phase
  input  logic [31:0]          RData
);

  localparam X_BYTES = 1024;
  localparam X_WORDS = X_BYTES / 4;
  localparam [39:0] RAM_BASE   = 40'(P.UNCORE_RAM_BASE);
  localparam [39:0] RAM_USABLE = 40'(P.UNCORE_RAM_RANGE) + 40'd1 - (P.TRACE_IN_RAM ? 40'(P.TRACE_RAM_WORDS) * 40'd4 : 40'd0);

  typedef enum logic [2:0] {IDLE, LOADX, ROW, EPI0, EPI1, WR, WRWAIT, FIN} state_t;
  state_t State;

  // registers
  logic        Relu, Raw, Busy, Done, Err;
  logic [31:0] InB, OutR, WAddr, XAddr, BiasAddr, YAddr, Mult, Shift, Cycles;

  // run state
  logic [31:0]  WPtr, BPtr, YPtr;
  logic [15:0]  Row;
  logic [9:0]   IssueCnt, RespCnt;
  logic signed [31:0] Acc, Sum, BiasReg;
  logic [31:0]  WReg, Pack;
  logic         MacValid;
  logic [31:0]  XMem [X_WORDS];
  logic [31:0]  XDout;
  logic [3:0]   StrbReg;

  logic [8:0]   Kw;                       // words per row
  logic [9:0]   Total;                    // reads per row: the words and the bias
  logic         NoBias, LastRow;
  assign Kw      = InB[10:2];
  assign NoBias  = (BiasAddr == 32'd0);
  assign Total   = {1'b0, Kw} + (NoBias ? 10'd0 : 10'd1);
  assign LastRow = (Row == OutR[15:0] - 16'd1);

  // ---- the check of a start ----
  function automatic logic inram(input [31:0] a, input [31:0] len);
    logic [39:0] off;
    off = {8'b0, a} - RAM_BASE;
    return ({8'b0, a} >= RAM_BASE) && (off + 40'(len) <= RAM_USABLE);
  endfunction

  // the start is the same write that sets RAW, so the check must use the bit being written, not the register's old value
  logic Wr, Start, RawNow;
  assign Wr     = PSEL & PENABLE & PWRITE;
  assign Start  = Wr & (PADDR[7:2] == 6'h00) & PWDATA[0];
  assign RawNow = Start ? PWDATA[2] : Raw;

  logic Valid;
  assign Valid = InB[1:0] == 2'b00 && InB != 32'd0 && InB <= 32'(X_BYTES)
               && OutR != 32'd0 && OutR <= 32'hFFFF && (RawNow || Shift <= 32'd47)
               && WAddr[1:0] == 2'b00 && XAddr[1:0] == 2'b00 && BiasAddr[1:0] == 2'b00 && YAddr[1:0] == 2'b00
               && inram(WAddr, OutR[15:0] * InB[10:0]) && inram(XAddr, InB)
               && (NoBias || inram(BiasAddr, {14'b0, OutR[15:0], 2'b00}))
               && inram(YAddr, RawNow ? {14'b0, OutR[15:0], 2'b00} : OutR);

  // ---- APB registers ----
  always_ff @(posedge HCLK)
    if (~HRESETn) begin
      Relu <= 1'b0; Raw <= 1'b0;
      {InB, OutR, WAddr, XAddr, BiasAddr, YAddr, Mult, Shift} <= '0;
    end else if (Wr & ~Busy) begin
      case (PADDR[7:2])
        6'h00: begin Relu <= PWDATA[1]; Raw <= PWDATA[2]; end
        6'h02: InB      <= PWDATA;
        6'h03: OutR     <= PWDATA;
        6'h04: WAddr    <= PWDATA;
        6'h05: XAddr    <= PWDATA;
        6'h06: BiasAddr <= PWDATA;
        6'h07: YAddr    <= PWDATA;
        6'h08: Mult     <= PWDATA;
        6'h09: Shift    <= PWDATA;
        default: ;
      endcase
    end

  always_comb
    case (PADDR[7:2])
      6'h00:   PRDATA = {29'b0, Raw, Relu, 1'b0};
      6'h01:   PRDATA = {29'b0, Err, Done, Busy};
      6'h02:   PRDATA = InB;
      6'h03:   PRDATA = OutR;
      6'h04:   PRDATA = WAddr;
      6'h05:   PRDATA = XAddr;
      6'h06:   PRDATA = BiasAddr;
      6'h07:   PRDATA = YAddr;
      6'h08:   PRDATA = Mult;
      6'h09:   PRDATA = Shift;
      6'h0A:   PRDATA = Cycles;
      default: PRDATA = '0;
    endcase

  // ---- the bus master ----
  assign Req   = (State == LOADX && IssueCnt < {1'b0, Kw}) || (State == ROW && IssueCnt < Total) || (State == WR);
  assign Write = (State == WR);
  always_comb
    if (State == WR)                  Addr = P.PA_BITS'(YPtr);
    else if (State == LOADX)          Addr = P.PA_BITS'(XAddr + {20'b0, IssueCnt, 2'b00});
    else if (IssueCnt < {1'b0, Kw})   Addr = P.PA_BITS'(WPtr + {20'b0, IssueCnt, 2'b00});
    else                              Addr = P.PA_BITS'(BPtr);
  assign WData = Pack;
  assign WStrb = StrbReg;

  // ---- the datapath ----
  function automatic logic signed [31:0] dot4(input [31:0] w, input [31:0] x);
    logic signed [15:0] p0, p1, p2, p3;            // each product is formed at 16 bits
    p0 = signed'(w[7:0])   * signed'(x[7:0]);
    p1 = signed'(w[15:8])  * signed'(x[15:8]);
    p2 = signed'(w[23:16]) * signed'(x[23:16]);
    p3 = signed'(w[31:24]) * signed'(x[31:24]);
    return 32'(p0) + 32'(p1) + 32'(p2) + 32'(p3);
  endfunction

  logic signed [47:0] Prod, Shifted;
  logic signed [47:0] Lo, Hi;
  logic signed [7:0]  Byte;
  assign Prod    = Sum * signed'(Mult[15:0]);
  assign Shifted = Prod >>> Shift[5:0];
  assign Lo      = Relu ? 48'sd0 : -48'sd128;
  assign Hi      = 48'sd127;
  assign Byte    = (Shifted > Hi) ? 8'sd127 : (Shifted < Lo) ? 8'(Lo) : 8'(Shifted);

  // the input vector's memory: written by the load, read at the response's index (one clock later the word is there)
  always_ff @(posedge HCLK) begin
    if (State == LOADX && DataDone) XMem[RespCnt[7:0]] <= RData;
    XDout <= XMem[RespCnt[7:0]];
  end

  logic Fetching;
  assign Fetching = (State == LOADX) || (State == ROW);

  task automatic start_row();
    IssueCnt <= '0;
    RespCnt  <= '0;
    Acc      <= '0;
    MacValid <= 1'b0;
  endtask

  always_ff @(posedge HCLK)
    if (~HRESETn) begin
      State <= IDLE; Busy <= 1'b0; Done <= 1'b0; Err <= 1'b0; Cycles <= '0;
      WPtr <= '0; BPtr <= '0; YPtr <= '0; Row <= '0; IssueCnt <= '0; RespCnt <= '0;
      Acc <= '0; Sum <= '0; BiasReg <= '0; WReg <= '0; Pack <= '0; MacValid <= 1'b0; StrbReg <= '0;
    end else begin
      if (Busy) Cycles <= Cycles + 32'd1;
      // a write of 1 clears DONE and ERROR
      if (Wr & (PADDR[7:2] == 6'h01)) begin
        if (PWDATA[1]) Done <= 1'b0;
        if (PWDATA[2]) Err  <= 1'b0;
      end
      MacValid <= 1'b0;
      if (MacValid) Acc <= Acc + dot4(WReg, XDout);
      if (Fetching && Accept) IssueCnt <= IssueCnt + 10'd1;
      if (Fetching && DataDone) RespCnt <= RespCnt + 10'd1;
      if (BusErr && State != IDLE && State != FIN) begin
        Err <= 1'b1;
        State <= FIN;
      end else
      case (State)
        IDLE: if (Start) begin
          if (Valid) begin
            State <= LOADX; Busy <= 1'b1; Done <= 1'b0; Err <= 1'b0; Cycles <= '0;
            WPtr <= WAddr; BPtr <= BiasAddr; YPtr <= YAddr; Row <= '0;
            IssueCnt <= '0; RespCnt <= '0; Acc <= '0;
          end else Err <= 1'b1;
        end
        LOADX: if (DataDone && RespCnt == {1'b0, Kw} - 10'd1) begin
          State <= ROW;
          start_row();
        end
        ROW: begin
          if (DataDone && RespCnt < {1'b0, Kw}) begin
            WReg <= RData;
            MacValid <= 1'b1;
          end
          if (DataDone && RespCnt == {1'b0, Kw}) BiasReg <= signed'(RData);
          if (RespCnt == Total && !MacValid) State <= EPI0;
        end
        EPI0: begin
          Sum <= Acc + (NoBias ? 32'sd0 : BiasReg);
          State <= EPI1;
        end
        EPI1: begin
          if (Raw) Pack <= Sum;                       // a word per output: written at once
          else case (Row[1:0])
            2'd0: Pack[7:0]   <= Byte;
            2'd1: Pack[15:8]  <= Byte;
            2'd2: Pack[23:16] <= Byte;
            2'd3: Pack[31:24] <= Byte;
          endcase
          if (Raw || Row[1:0] == 2'd3 || LastRow) begin
            StrbReg <= Raw ? 4'b1111 : 4'b1111 >> (2'd3 - Row[1:0]);
            State <= WR;
          end else begin
            Row <= Row + 16'd1;
            WPtr <= WPtr + InB;
            BPtr <= BPtr + 32'd4;
            State <= ROW;
            start_row();
          end
        end
        WR: if (Accept) State <= WRWAIT;
        WRWAIT: if (DataDone) begin
          YPtr <= YPtr + 32'd4;
          if (LastRow) State <= FIN;
          else begin
            Row <= Row + 16'd1;
            WPtr <= WPtr + InB;
            BPtr <= BPtr + 32'd4;
            State <= ROW;
            start_row();
          end
        end
        FIN: begin
          Busy <= 1'b0;
          if (!Err) Done <= 1'b1;
          State <= IDLE;
        end
        default: State <= IDLE;
      endcase
    end

endmodule
