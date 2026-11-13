///////////////////////////////////////////
// ai_unit.sv
//
// Purpose: int8 matrix-vector unit with its own AHB master (docs/engineering/decisions/0024-edge-ai-accelerator.md).
//          y = clamp(((W x + bias) * MULT) >> SHIFT): the layer of a neural network, in one command.  With RAW set the unit returns the
//          int32 accumulator W x + bias, one word per output, and leaves the requantization to software (the scheme of CMSIS-NN and
//          muRISCV-NN, which differs from the one above in the multiplier, the rounding and the zero points).  With Q31 set the unit
//          requantizes as that library does (muriscv_nn_requantize, then the output offset and the clamp), bit for bit:
//          y = clamp(requantize(W x + bias, MULT, SHIFT) + OFFSET, ACT_MIN, ACT_MAX), MULT a 32-bit Q31 multiplier, SHIFT signed -31..30.
//          The 32 x 32 product is made in two passes of the 32 x 16 multiplier (low half unsigned, high half signed) and the rest in a
//          pipeline of five stages that runs while the next row is read, so a layer costs a few cycles more than in byte mode.
//          W (OUT rows of IN int8, row-major) and the int32 bias stay in the RAM and are streamed by the unit's master one 32-bit word
//          (four int8) per clock; the input vector x (IN bytes, up to X_BYTES) is read once and copied into a reserved area of the RAM, the last
//          X_BYTES of the RAM part before the trace buffer (AREA_OFF below), and read from there through a port of its own to that part's macro
//          (ram_ahb.sv, XpReq), so the bus carries only W and the unit has no memory of its own.  The results are int8, four to a word, written
//          back to the RAM.
//
// Registers (word accesses at the unit's PADDR, block 4 of mcu_apb):
//   00 CTRL     [0] START (a write of 1 starts a run when idle)  [1] RELU: clamp to 0..127 instead of -128..127
//               [2] RAW: write W x + bias as an int32 per output (Y is OUT words); MULT, SHIFT and RELU are then ignored
//               [3] Q31: requantize as muRISCV-NN does (MULT 32-bit, SHIFT signed, OFFSET, ACT_MIN, ACT_MAX; RELU ignored); not with RAW
//               [4] W4: the weights are int4, two to a byte, the low nibble first (muriscv_nn_fully_connected_s4's layout), so a row of W is IN/2 bytes
//                   and IN a multiple of 8; each word of W feeds two clocks of the same four multipliers (4 x 8 bits would do, the 8 x 8 ones are
//                   shared), so the work per element is the same and the weights take half the RAM; with RAW, Q31 or neither
//   04 STATUS   [0] BUSY  [1] DONE  [2] ERROR: write 1 to clear DONE and ERROR.  A start with bad arguments, or a bus error, sets ERROR
//   08 IN       bytes of x and elements of a row of W: a multiple of 4 (of 8 with W4), 4..X_BYTES
//   0C OUT      rows, 1..65535
//   10 W_ADDR   weights (OUT*IN bytes, OUT*IN/2 with W4), word aligned          14 X_ADDR   input vector, word aligned
//   18 BIAS_ADDR  OUT int32, word aligned; 0 means no bias      1C Y_ADDR   OUT int8 (OUT int32 with RAW), word aligned
//   20 MULT     signed 16-bit multiplier (bits 15:0), with Q31 a signed 32-bit Q31 multiplier
//   24 SHIFT    arithmetic right shift, 0..47; with Q31 signed -31..30 (positive: left shift of the accumulator first)
//   28 CYCLES   clocks of the last run (read only)
//   2C OFFSET   Q31 only: added to the requantized value (int32)    30 ACT_MIN  34 ACT_MAX  Q31 only: clamp (int32), the low byte is stored
// Where the buffers may be (else the start is refused, ERROR): W, the bias and x in the RAM below the part that holds the input area (the part is
// 2^M words, M = log2 TRACE_RAM_WORDS: 0x8000C000 and up in the 64 KiB chip), because that part's macro has one port and the unit uses it for x; y
// anywhere in the RAM below the input area.  The input area itself (the last X_BYTES before the trace buffer) is the unit's: a program must not use it.
// The registers are written only while idle.  The core is stalled while the unit owns the bus (uncore.sv): the unit takes it only between two
// transfers of the core, for the length of the load of x and then of a row, also while it waits for the last words.
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
  input  logic [31:0]          RData,
  output logic                 Own,                    // the core is held off the bus (see uncore.sv): the unit has the RAM part of its input area
  // port to the RAM part that holds the input vector (ram_ahb.sv): a word written in LOADX, read in ROW, back one clock later
  output logic                 XpReq, XpWe,
  output logic [$clog2(P.TRACE_RAM_WORDS)-1:0] XpAddr,
  output logic [31:0]          XpDin,
  input  logic [31:0]          XpDout
);

  localparam X_BYTES = 1024;
  localparam X_WORDS = X_BYTES / 4;
  localparam [39:0] RAM_BASE   = 40'(P.UNCORE_RAM_BASE);
  // the RAM of 2^N words has parts of 2^(N-1), 2^(N-2) ... 2^M words and the trace RAM of 2^M (ram_ahb.sv); the unit's port is on the last part before
  // the trace RAM, which has 2^M words at word 2^N - 2^(M+1)
  localparam N = $clog2((P.UNCORE_RAM_RANGE + 1) / 4);
  localparam M = $clog2(P.TRACE_RAM_WORDS);
  localparam [39:0] PART_OFF = 40'd4 * (40'd1 << N) - 40'd8 * (40'd1 << M);          // the part's offset from RAM_BASE, in bytes
  localparam [39:0] AREA_OFF = 40'd4 * (40'd1 << N) - 40'd4 * (40'd1 << M) - 40'(X_BYTES);   // the input area's offset: the last X_BYTES of the part
  localparam [M-1:0] AREA_WORD = M'((1 << M) - X_WORDS);                              // the area's first word in the part
  if (X_WORDS > (1 << M)) $error("ai_unit: X_BYTES larger than the RAM part of the input area");

  typedef enum logic [3:0] {IDLE, LOADX, ROW, EPI0, EPI1, QDRAIN, WR, WRWAIT, FIN} state_t;
  state_t State;

  // registers
  logic        Relu, Raw, QMode, W4, Busy, Done, Err;
  logic [31:0] InB, OutR, WAddr, XAddr, BiasAddr, YAddr, Mult, Shift, Cycles, Offset, ActMin, ActMax;

  // run state
  logic [31:0]  WPtr, BPtr, YPtr;
  logic [15:0]  Row;
  logic [9:0]   IssueCnt, RespCnt;
  logic signed [31:0] Acc, Sum, BiasReg;
  logic [31:0]  WReg, Pack;
  logic         MacValid, Mac2;           // Mac2: the second clock of a W4 word (its high four nibbles)
  logic [31:0]  XDout;
  logic [3:0]   StrbReg;

  logic [8:0]   Kw, Kx;                   // words of W per row (IN/4, IN/8 with W4), words of x (IN/4)
  logic [9:0]   Total;                    // reads per row: the words and the bias
  logic         NoBias, LastRow;
  assign Kx      = InB[10:2];
  assign Kw      = W4 ? {1'b0, InB[10:3]} : InB[10:2];
  assign NoBias  = (BiasAddr == 32'd0);
  assign Total   = {1'b0, Kw} + (NoBias ? 10'd0 : 10'd1);
  assign LastRow = (Row == OutR[15:0] - 16'd1);

  // ---- the check of a start ----
  function automatic logic inram(input [31:0] a, input [31:0] len, input [39:0] limit);
    logic [39:0] off;
    off = {8'b0, a} - RAM_BASE;
    return ({8'b0, a} >= RAM_BASE) && (off + 40'(len) <= limit);
  endfunction

  // the start is the same write that sets RAW, so the check must use the bit being written, not the register's old value
  logic Wr, Start, RawNow, QNow, W4Now;
  assign Wr     = PSEL & PENABLE & PWRITE;
  assign Start  = Wr & (PADDR[7:2] == 6'h00) & PWDATA[0];
  assign RawNow = Start ? PWDATA[2] : Raw;
  assign QNow   = Start ? PWDATA[3] : QMode;
  assign W4Now  = Start ? PWDATA[4] : W4;
  logic ShiftOk;
  assign ShiftOk = RawNow | (QNow ? (signed'(Shift) >= -32'sd31 && signed'(Shift) <= 32'sd30) : Shift <= 32'd47);

  logic Valid;
  assign Valid = InB[1:0] == 2'b00 && (!W4Now || InB[2] == 1'b0) && InB != 32'd0 && InB <= 32'(X_BYTES)
               && OutR != 32'd0 && OutR <= 32'hFFFF && ShiftOk && !(RawNow && QNow)
               && WAddr[1:0] == 2'b00 && XAddr[1:0] == 2'b00 && BiasAddr[1:0] == 2'b00 && YAddr[1:0] == 2'b00
               && inram(WAddr, W4Now ? (OutR[15:0] * InB[10:0]) >> 1 : OutR[15:0] * InB[10:0], PART_OFF) && inram(XAddr, InB, PART_OFF)
               && (NoBias || inram(BiasAddr, {14'b0, OutR[15:0], 2'b00}, PART_OFF))
               && inram(YAddr, RawNow ? {14'b0, OutR[15:0], 2'b00} : OutR, AREA_OFF);

  // ---- APB registers ----
  always_ff @(posedge HCLK)
    if (~HRESETn) begin
      Relu <= 1'b0; Raw <= 1'b0; QMode <= 1'b0; W4 <= 1'b0;
      {InB, OutR, WAddr, XAddr, BiasAddr, YAddr, Mult, Shift, Offset, ActMin, ActMax} <= '0;
    end else if (Wr & ~Busy) begin
      case (PADDR[7:2])
        6'h00: begin Relu <= PWDATA[1]; Raw <= PWDATA[2]; QMode <= PWDATA[3]; W4 <= PWDATA[4]; end
        6'h02: InB      <= PWDATA;
        6'h03: OutR     <= PWDATA;
        6'h04: WAddr    <= PWDATA;
        6'h05: XAddr    <= PWDATA;
        6'h06: BiasAddr <= PWDATA;
        6'h07: YAddr    <= PWDATA;
        6'h08: Mult     <= PWDATA;
        6'h09: Shift    <= PWDATA;
        6'h0B: Offset   <= PWDATA;
        6'h0C: ActMin   <= PWDATA;
        6'h0D: ActMax   <= PWDATA;
        default: ;
      endcase
    end

  always_comb
    case (PADDR[7:2])
      6'h00:   PRDATA = {27'b0, W4, QMode, Raw, Relu, 1'b0};
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
      6'h0B:   PRDATA = Offset;
      6'h0C:   PRDATA = ActMin;
      6'h0D:   PRDATA = ActMax;
      default: PRDATA = '0;
    endcase

  // ---- the bus master ----
  // with W4 a word of W lasts two clocks of MAC, so the next read is issued once the previous has answered (the x port serves one word a clock)
  assign Req   = (State == LOADX && IssueCnt < {1'b0, Kx}) || (State == ROW && IssueCnt < Total && (!W4 || IssueCnt == RespCnt)) || (State == WR);
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

  // W4: the four nibbles of one half of a word of W, sign-extended to bytes, go through the same multipliers
  logic [15:0] WHalf;
  logic [31:0] WMul;
  assign WHalf = Mac2 ? WReg[31:16] : WReg[15:0];
  assign WMul  = W4 ? {{4{WHalf[15]}}, WHalf[15:12], {4{WHalf[11]}}, WHalf[11:8], {4{WHalf[7]}}, WHalf[7:4], {4{WHalf[3]}}, WHalf[3:0]} : WReg;

  // the multiplier: byte mode multiplies the sum by the 16-bit MULT; Q31 mode multiplies the shifted sum by the low half of MULT (unsigned,
  // stage Q1) and by its high half (signed, stage Q2)
  typedef enum logic [2:0] {QIDLE, Q1, Q2, Q3, Q4, Q5} qstate_t;
  qstate_t QSt;
  logic signed [31:0] Vsh;
  logic signed [31:0] MulA;
  logic signed [16:0] MulB;
  logic signed [48:0] Mul;
  assign MulA = QMode ? Vsh : Sum;
  assign MulB = QMode ? ((QSt == Q1) ? signed'({1'b0, Mult[15:0]}) : 17'(signed'(Mult[31:16]))) : 17'(signed'(Mult[15:0]));
  assign Mul  = MulA * MulB;

  logic signed [47:0] Prod, Shifted;
  logic signed [47:0] Lo, Hi;
  logic signed [7:0]  Byte;
  assign Prod    = Mul[47:0];
  assign Shifted = Prod >>> Shift[5:0];
  assign Lo      = Relu ? 48'sd0 : -48'sd128;
  assign Hi      = 48'sd127;
  assign Byte    = (Shifted > Hi) ? 8'sd127 : (Shifted < Lo) ? 8'(Lo) : 8'(Shifted);

  // the input vector's area in the RAM, through the port to its part: written by the load as the words arrive, read at the response's index of a
  // word of W (one clock later the word is there, as the MAC needs it); the core is held off the bus meanwhile (Own), and W, bias and the source of x are not
  // in the part (Valid), so the macro's port is the unit's in those clocks
  assign Own    = (State == LOADX || State == ROW) && IssueCnt != 10'd0;
  // W4: the word of W answers at clock c (x word 2k is read), its first half is multiplied in c+1 (MacValid) while x word 2k+1 is read, its second
  // half in c+2; RespCnt is k+1 in c+1, so the address is 2*RespCnt-1
  logic [8:0] XIdx;
  always_comb
    if (State == LOADX || !W4) XIdx = {1'b0, RespCnt[7:0]};
    else if (MacValid)         XIdx = {RespCnt[7:0], 1'b0} - 9'd1;
    else                       XIdx = {RespCnt[7:0], 1'b0};
  assign XpReq  = (DataDone && ((State == LOADX) || (State == ROW && RespCnt < {1'b0, Kw}))) || (State == ROW && W4 && MacValid);
  assign XpWe   = (State == LOADX);
  assign XpAddr = AREA_WORD + M'(XIdx);
  assign XpDin  = RData;
  assign XDout  = XpDout;

  // ---- Q31 requantization: muriscv_nn_requantize (doubling high multiply without saturation, rounding divide by a power of two),
  //      the output offset and the clamp, as a pipeline of stages Q1..Q5 that starts when a row's sum is ready (EPI1) ----
  logic signed [48:0] P0, P1;
  logic signed [63:0] Full;
  logic signed [31:0] Hq, Rq, Vo, Cl, Cl2, DivRes, DivMask, DivThr, DivRem;
  logic [4:0]         LeftSh, RightSh;
  logic [1:0]         QLane;
  assign LeftSh  = Shift[31] ? 5'd0 : Shift[4:0];
  assign RightSh = Shift[31] ? 5'(-Shift[4:0]) : 5'd0;          // Shift in -31..-1: 31..1
  assign Full    = (64'(P1) <<< 16) + 64'(P0) + 64'sd1073741824;      // 2^30: the rounding of a shift by 31
  assign DivMask = (32'sd1 <<< RightSh) - 32'sd1;                // for 31: 0x7FFFFFFF, as in C
  assign DivRes  = Hq >>> RightSh;
  assign DivRem  = Hq & DivMask;
  assign DivThr  = (DivMask >> 1) + (DivRes[31] ? 32'sd1 : 32'sd0);
  assign Vo      = Rq + signed'(Offset);
  assign Cl      = (Vo < signed'(ActMin)) ? signed'(ActMin) : Vo;
  assign Cl2     = (Cl > signed'(ActMax)) ? signed'(ActMax) : Cl;

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
      Acc <= '0; Sum <= '0; BiasReg <= '0; WReg <= '0; Pack <= '0; MacValid <= 1'b0; Mac2 <= 1'b0; StrbReg <= '0;
      QSt <= QIDLE; Vsh <= '0; P0 <= '0; P1 <= '0; Hq <= '0; Rq <= '0; QLane <= '0;
    end else begin
      if (Busy) Cycles <= Cycles + 32'd1;
      // a write of 1 clears DONE and ERROR
      if (Wr & (PADDR[7:2] == 6'h01)) begin
        if (PWDATA[1]) Done <= 1'b0;
        if (PWDATA[2]) Err  <= 1'b0;
      end
      MacValid <= 1'b0;
      Mac2     <= MacValid & W4 & (State == ROW);
      if (MacValid | Mac2) Acc <= Acc + dot4(WMul, XDout);
      case (QSt)
        Q1: begin P0 <= Mul; QSt <= Q2; end
        Q2: begin P1 <= Mul; QSt <= Q3; end
        Q3: begin Hq <= Full[62:31]; QSt <= Q4; end
        Q4: begin Rq <= DivRes + ((DivRem > DivThr) ? 32'sd1 : 32'sd0); QSt <= Q5; end
        Q5: begin
          case (QLane)
            2'd0: Pack[7:0]   <= Cl2[7:0];
            2'd1: Pack[15:8]  <= Cl2[7:0];
            2'd2: Pack[23:16] <= Cl2[7:0];
            2'd3: Pack[31:24] <= Cl2[7:0];
          endcase
          QSt <= QIDLE;
        end
        default: ;
      endcase
      if (Fetching && Accept) IssueCnt <= IssueCnt + 10'd1;
      if (Fetching && DataDone) RespCnt <= RespCnt + 10'd1;
      if (BusErr && State != IDLE && State != FIN) begin
        Err <= 1'b1;
        QSt <= QIDLE;
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
        LOADX: if (DataDone && RespCnt == {1'b0, Kx} - 10'd1) begin
          State <= ROW;
          start_row();
        end
        ROW: begin
          if (DataDone && RespCnt < {1'b0, Kw}) begin
            WReg <= RData;
            MacValid <= 1'b1;
          end
          if (DataDone && RespCnt == {1'b0, Kw}) BiasReg <= signed'(RData);
          if (RespCnt == Total && !MacValid && !Mac2) State <= EPI0;
        end
        EPI0: begin
          Sum <= Acc + (NoBias ? 32'sd0 : BiasReg);
          State <= EPI1;
        end
        EPI1: if (QMode) begin
          // Q31: the pipeline takes the sum (it must be free: the previous row's result is stored by now unless the rows are very short);
          // a word is written when its last byte is stored
          if (QSt == QIDLE) begin
            Vsh   <= Sum <<< LeftSh;
            QLane <= Row[1:0];
            QSt   <= Q1;
            if (Row[1:0] == 2'd3 || LastRow) begin
              StrbReg <= 4'b1111 >> (2'd3 - Row[1:0]);
              State <= QDRAIN;
            end else begin
              Row <= Row + 16'd1;
              WPtr <= WPtr + (W4 ? {1'b0, InB[31:1]} : InB);
              BPtr <= BPtr + 32'd4;
              State <= ROW;
              start_row();
            end
          end
        end else begin
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
            WPtr <= WPtr + (W4 ? {1'b0, InB[31:1]} : InB);
            BPtr <= BPtr + 32'd4;
            State <= ROW;
            start_row();
          end
        end
        QDRAIN: if (QSt == QIDLE) State <= WR;
        WR: if (Accept) State <= WRWAIT;
        WRWAIT: if (DataDone) begin
          YPtr <= YPtr + 32'd4;
          if (LastRow) State <= FIN;
          else begin
            Row <= Row + 16'd1;
            WPtr <= WPtr + (W4 ? {1'b0, InB[31:1]} : InB);
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
