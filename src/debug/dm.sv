///////////////////////////////////////////
// dm.sv
//
// Purpose: RISC-V Debug Module (RISC-V Debug Specification 1.0, chapter 3) for one hart.  It is
//          execution-based, as PULP's riscv-dbg: the hart has a Debug Mode (debugmode.sv) in which
//          it runs code from this module's debug memory, an AHB slave at 0x0-0xFFF:
//            0x100 HALTED, 0x104 GOING, 0x108 RESUMING, 0x10C EXCEPTION   written by the ROM
//            0x300 WHERETO        a jal to the abstract command or the program buffer
//            0x338 abstract command (8 instructions), generated from the command register
//            0x358 program buffer (8 instructions), then an ebreak at 0x378 (impebreak)
//            0x380 data0, data1   (abstract data)
//            0x400 FLAGS          one byte per hart: bit 0 go, bit 1 resume
//            0x800 ROM            halt entry 0x800, resume 0x804, exception 0x808
//          The ROM loops writing HALTED while the hart is halted; on go it jumps to WHERETO, and
//          the command or program buffer ends with an ebreak, which takes it back to the ROM; on
//          resume it writes RESUMING and executes dret.
//
//          Implemented:
//          - halt and resume (haltreq, resumereq, resumeack), and setresethaltreq to halt a hart
//            as it leaves reset;
//          - the Access Register abstract command for GPRs, CSRs and FPRs (32 or 64 bits, with
//            postexec and aarpostincrement), a program buffer of 8 instructions, abstractauto;
//          - System Bus Access (dmsba.sv);
//          - hartreset (the core only) and ndmreset (the SoC except the DTM and this module).
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module dm import cvw::*; #(parameter cvw_t P, parameter int unsigned NHARTS = 1) (
  input  logic                  clk,
  input  logic                  reset,        // power-on reset only: ndmreset must not reset the DM
  // DMI from the DTM
  input  logic                  DMIReq,
  input  logic [6:0]            DMIAddr,
  input  logic [31:0]           DMIWData,
  input  logic                  DMIWrite,
  output logic [31:0]           DMIRData,
  output logic                  DMIError,
  // The hart
  output logic                  NDMReset,     // the SoC, except the DTM and DM
  output logic [NHARTS-1:0]     HartReset,    // each core
  output logic [NHARTS-1:0]     DebugHaltReq, // halt request to each core's Debug Mode
  output logic [NHARTS-1:0]     DebugResetHaltReq, // the halt request is resethaltreq's (dcsr.cause 5)
  // Debug memory: AHB-Lite slave at 0x0-0xFFF, with no wait states
  input  logic                  DMHSEL,       // address phase of a transfer to the debug memory
  input  logic [11:0]           DMHADDR,
  input  logic                  DMHWRITE,
  input  logic                  DMHREADY,     // the bus is ready: the address phase is taken
  input  logic [P.AHBW-1:0]     DMHWDATA,
  input  logic [P.AHBW/8-1:0]   DMHWSTRB,
  output logic [P.AHBW-1:0]     DMHRDATA,
  // System Bus Access: AHB-Lite master
  output logic [P.PA_BITS-1:0]  SBHADDR,
  output logic [P.AHBW-1:0]     SBHWDATA,
  output logic [P.AHBW/8-1:0]   SBHWSTRB,
  output logic                  SBHWRITE,
  output logic [2:0]            SBHSIZE,
  output logic [1:0]            SBHTRANS,
  input  logic                  SBHREADY,
  input  logic [P.AHBW-1:0]     SBHRDATA,
  input  logic                  SBHRESP
);

  // DMI registers
  localparam logic [6:0] DATA0 = 7'h04, DATA1 = 7'h05, DMCONTROL = 7'h10, DMSTATUS = 7'h11,
                         HARTINFO = 7'h12, HALTSUM1 = 7'h13, ABSTRACTCS = 7'h16, COMMAND = 7'h17, ABSTRACTAUTO = 7'h18,
                         PROGBUF0 = 7'h20, HALTSUM0 = 7'h40;
  localparam int unsigned DATACOUNT = 2, PROGBUFSIZE = 8;
  // Debug memory
  localparam logic [11:0] HALTED = 12'h100, GOING = 12'h104, RESUMING = 12'h108, EXCEPTION = 12'h10C,
                          WHERETO = 12'h300, ABSTRACT = 12'h338, PROGBUF = 12'h358, IMPEBREAK = 12'h378,
                          DATA = 12'h380, FLAGS = 12'h400, ROM = 12'h800;
  localparam logic [31:0] NOP = 32'h00000013, EBREAK = 32'h00100073;

  // The ROM (0x800), from this source, assembled for RV32 and RV64 alike (.option norvc).  Every
  // report to the Debug Module carries the hart's id, which tells the harts apart:
  //   entry:      j _entry               # 0x800: halt, and ebreak in Debug Mode
  //   resume:     j _resume              # 0x804
  //   exception:  j _exception           # 0x808: exception in Debug Mode
  //   _exception: csrr s0, mhartid
  //               sw   s0, 0x10C(zero)   # EXCEPTION
  //               csrr s0, dscratch1     # s0 as the command found it
  //               ebreak                 # back to entry
  //   _entry:     fence
  //               csrw dscratch1, s0     # free s0
  //   entry_loop: csrr s0, mhartid
  //               sw   s0, 0x100(zero)   # HALTED
  //               lbu  s0, 0x400(s0)     # FLAGS[hartid]
  //               andi s0, s0, 1         # go
  //               bnez s0, _going
  //               csrr s0, mhartid
  //               lbu  s0, 0x400(s0)
  //               andi s0, s0, 2         # resume
  //               bnez s0, _resume
  //               j    entry_loop
  //   _going:     csrr s0, mhartid
  //               sw   s0, 0x104(zero)   # GOING
  //               csrr s0, dscratch1
  //               jalr zero, 0x300(zero) # WHERETO
  //   _resume:    csrr s0, mhartid
  //               sw   s0, 0x108(zero)   # RESUMING
  //               csrr s0, dscratch1
  //               dret
  localparam int unsigned ROMWORDS = 27;
  localparam logic [31:0] ROMCODE [ROMWORDS] = '{
    32'h01c0006f, 32'h0580006f, 32'h0040006f, 32'hf1402473, 32'h10802623, 32'h7b302473,
    32'h00100073, 32'h0ff0000f, 32'h7b341073, 32'hf1402473, 32'h10802023, 32'h40044403,
    32'h00147413, 32'h00041c63, 32'hf1402473, 32'h40044403, 32'h00247413, 32'h00041c63,
    32'hfddff06f, 32'hf1402473, 32'h10802223, 32'h7b302473, 32'h30000067, 32'hf1402473,
    32'h10802423, 32'h7b302473, 32'h7b200073};

  // The FLAGS bytes (0x400-0x7FF) hold one byte per hart, so up to 1024 harts
  if (NHARTS < 1 || NHARTS > 1024) begin : badharts
    $error("dm: NHARTS must be between 1 and 1024");
  end
  localparam int unsigned HW = NHARTS > 1 ? $clog2(NHARTS) : 1;     // bits of a hart index

  logic        Write, Read;
  logic        DMActive;
  logic [NHARTS-1:0] HaveReset, Unavail;
  logic [NHARTS-1:0] HaltReq, ResetHaltReq, ResetHaltPending;
  logic [NHARTS-1:0] Halted, ResumeAck, GoFlag, ResumeFlag;
  logic [19:0] HartSel;                                // the selected hart (dmcontrol.hartsel)
  logic [HW-1:0] SelIdx, CmdHart;                      // its index; the hart that runs the command
  logic        SelExists;
  logic [2:0]  CmdErr;
  logic [31:0] Command;
  logic [31:0] Data [DATACOUNT];
  logic [31:0] ProgBuf [PROGBUFSIZE];
  logic [11:0] AutoExecData;
  logic [15:0] AutoExecProgBuf;
  logic [31:0] SBARData;

  typedef enum logic [1:0] {CMD_IDLE, CMD_GO, CMD_RUN} cmdstate_t;
  cmdstate_t   CmdState;
  logic        Busy;

  assign Write = DMIReq &  DMIWrite;
  assign Read  = DMIReq & ~DMIWrite;
  assign DMIError = 1'b0;
  assign Unavail = {NHARTS{NDMReset}} | HartReset;   // the harts in reset
  assign SelExists = HartSel < 20'(NHARTS);
  assign SelIdx = HartSel[HW-1:0];
  assign Busy = CmdState != CMD_IDLE;
  assign DebugHaltReq = {NHARTS{DMActive}} & (HaltReq | ResetHaltPending) & ~Halted;
  assign DebugResetHaltReq = {NHARTS{DMActive}} & ResetHaltPending;

  ///////////////////////////////////////////
  // Abstract command: Access Register
  ///////////////////////////////////////////

  // command: cmdtype 0 (Access Register), aarsize, aarpostincrement, postexec, transfer, write, regno
  logic [2:0]  AarSize;
  logic        PostIncrement, PostExec, Transfer, CmdWrite;
  logic [15:0] RegNo;
  logic        IsCSR, IsGPR, IsFPR;
  assign {AarSize, PostIncrement, PostExec, Transfer, CmdWrite, RegNo} = Command[22:0];
  assign IsCSR = RegNo < 16'h1000;
  assign IsGPR = RegNo >= 16'h1000 & RegNo < 16'h1020;
  assign IsFPR = RegNo >= 16'h1020 & RegNo < 16'h1040;

  // Whether a new command (from DMIWData, or the stored one for abstractauto) is supported
  function automatic logic supported(input logic [31:0] cmd);
    logic [2:0]  size;
    logic [15:0] regno;
    logic        transfer;
    size = cmd[22:20]; transfer = cmd[17]; regno = cmd[15:0];
    if (cmd[31:24] != 8'd0) return 1'b0;                          // only Access Register
    if (!transfer) return 1'b1;
    if (regno < 16'h1000) return size == 3'd2 || size == 3'd3 && P.XLEN == 64;   // CSR
    if (regno < 16'h1020) return size == 3'd2 || size == 3'd3 && P.XLEN == 64;   // GPR
    if (regno < 16'h1040) return P.F_SUPPORTED && (size == 3'd2 || size == 3'd3 && P.D_SUPPORTED);
    return 1'b0;
  endfunction

  // Instruction encodings
  localparam logic [4:0] S0 = 5'd8;
  localparam logic [11:0] DSCRATCH1 = 12'h7B3;
  function automatic logic [31:0] load(input logic [2:0] f3, input logic [4:0] rd, input logic [6:0] op);
    return {DATA, 5'd0, f3, rd, op};                              // l* rd, 0x380(zero)
  endfunction
  function automatic logic [31:0] store(input logic [2:0] f3, input logic [4:0] rs2, input logic [6:0] op);
    return {DATA[11:5], rs2, 5'd0, f3, DATA[4:0], op};            // s* rs2, 0x380(zero)
  endfunction
  function automatic logic [31:0] csrrw(input logic [11:0] csr, input logic [4:0] rd, input logic [4:0] rs1);
    return {csr, rs1, 3'b001, rd, 7'h73};
  endfunction
  function automatic logic [31:0] csrrs(input logic [11:0] csr, input logic [4:0] rd, input logic [4:0] rs1);
    return {csr, rs1, 3'b010, rd, 7'h73};
  endfunction
  function automatic logic [31:0] jal0(input logic [11:0] from, input logic [11:0] to);
    logic [20:0] off;
    off = 21'(to) - 21'(from);
    return {off[20], off[10:1], off[11], off[19:12], 5'd0, 7'h6f};
  endfunction

  // The abstract command: the transfer (GPRs and FPRs directly; CSRs through s0, saved in
  // dscratch1), then nops into the program buffer (postexec) or an ebreak
  logic [31:0] CmdWords [8];
  logic [31:0] WhereTo;
  always_comb begin
    CmdWords = '{default: NOP};
    if (Transfer)
      if (IsGPR)
        CmdWords[0] = CmdWrite ? load(AarSize, RegNo[4:0], 7'h03) : store(AarSize, RegNo[4:0], 7'h23);
      else if (IsFPR)
        CmdWords[0] = CmdWrite ? load(AarSize, RegNo[4:0], 7'h07) : store(AarSize, RegNo[4:0], 7'h27);
      else begin
        CmdWords[0] = csrrw(DSCRATCH1, 5'd0, S0);
        CmdWords[1] = CmdWrite ? load(AarSize, S0, 7'h03) : csrrs(RegNo[11:0], S0, 5'd0);
        CmdWords[2] = CmdWrite ? csrrw(RegNo[11:0], 5'd0, S0) : store(AarSize, S0, 7'h23);
        CmdWords[3] = csrrs(DSCRATCH1, S0, 5'd0);
      end
    if (!PostExec) CmdWords[7] = EBREAK;
  end
  assign WhereTo = jal0(WHERETO, Transfer ? ABSTRACT : PROGBUF);

  ///////////////////////////////////////////
  // Debug memory: reads
  ///////////////////////////////////////////

  function automatic logic [31:0] memword(input logic [11:0] adr);
    logic [11:0] a, rom, abstr, progbuf;
    a = {adr[11:2], 2'b00};
    rom = a - ROM; abstr = a - ABSTRACT; progbuf = a - PROGBUF;   // offsets
    if (a >= ROM && a < ROM + 12'(4*ROMWORDS))       return ROMCODE[rom[6:2]];
    if (a == WHERETO)                                return WhereTo;
    if (a >= ABSTRACT && a < PROGBUF)                return CmdWords[abstr[4:2]];
    if (a >= PROGBUF && a < IMPEBREAK)               return ProgBuf[progbuf[4:2]];
    if (a == IMPEBREAK)                              return EBREAK;
    if (a >= DATA && a < DATA + 12'(4*DATACOUNT))    return Data[a[2]];
    if (a >= FLAGS && a < FLAGS + 12'(4*((NHARTS + 3)/4))) begin   // one byte per hart
      logic [31:0] w;
      w = '0;
      for (int b = 0; b < 4; b++)
        if (4*int'(a[9:2]) + b < NHARTS) w[8*b +: 2] = {ResumeFlag[HW'(4*int'(a[9:2]) + b)], GoFlag[HW'(4*int'(a[9:2]) + b)]};
      return w;
    end
    return 32'b0;
  endfunction

  // Address phase registered; the data phase has no wait states
  logic        MemAccess, MemWrite;
  logic [11:0] MemAdr;
  always_ff @(posedge clk)
    if (reset) MemAccess <= 1'b0;
    else if (DMHREADY) begin
      MemAccess <= DMHSEL; MemAdr <= DMHADDR; MemWrite <= DMHWRITE;
    end

  if (P.AHBW == 64) begin : rd64
    assign DMHRDATA = {memword({MemAdr[11:3], 3'b100}), memword({MemAdr[11:3], 3'b000})};
  end else begin : rd32
    assign DMHRDATA = memword(MemAdr);
  end

  // Writes by the hart: one 32-bit word per half of a 64-bit bus
  localparam int unsigned WORDS = P.AHBW/32;
  logic [WORDS-1:0]   WordWrite;
  logic [11:0]        WordAdr [WORDS];
  logic [31:0]        WordData [WORDS];
  logic [3:0]         WordStrb [WORDS];
  for (genvar w = 0; w < WORDS; w++) begin : words
    assign WordAdr[w]   = WORDS == 2 ? {MemAdr[11:3], w[0], 2'b00} : {MemAdr[11:2], 2'b00};
    assign WordData[w]  = DMHWDATA[32*w +: 32];
    assign WordStrb[w]  = DMHWSTRB[4*w +: 4];
    assign WordWrite[w] = MemAccess & MemWrite & DMHREADY & |WordStrb[w];
  end

  // The ROM reports with the hart's id as data: events per hart
  logic [NHARTS-1:0] HartHalted, HartGoing, HartResuming, HartException;
  always_comb begin
    HartHalted = '0; HartGoing = '0; HartResuming = '0; HartException = '0;
    for (int w = 0; w < WORDS; w++)
      if (WordWrite[w] && WordData[w] < 32'(NHARTS))
        case (WordAdr[w])
          HALTED:    HartHalted[HW'(WordData[w])] = 1'b1;
          GOING:     HartGoing[HW'(WordData[w])] = 1'b1;
          RESUMING:  HartResuming[HW'(WordData[w])] = 1'b1;
          EXCEPTION: HartException[HW'(WordData[w])] = 1'b1;
          default: ;
        endcase
  end

  ///////////////////////////////////////////
  // DMI register reads
  ///////////////////////////////////////////

  // data0-1 and progbuf0-7 among the DMI registers
  logic       DataReg, ProgBufReg, DataIdx;
  logic [6:0] DataOff, ProgBufOff;
  logic [2:0] ProgBufIdx;
  assign DataOff = DMIAddr - DATA0;
  assign ProgBufOff = DMIAddr - PROGBUF0;
  assign DataReg = DMIAddr >= DATA0 & DataOff < 7'(DATACOUNT);
  assign ProgBufReg = DMIAddr >= PROGBUF0 & ProgBufOff < 7'(PROGBUFSIZE);
  assign DataIdx = DataOff[0];
  assign ProgBufIdx = ProgBufOff[2:0];

  // The selected hart's state (all the dmstatus "any" and "all" bits are the same: no hasel)
  logic        SelHalted, SelRunning, SelUnavail, SelHaveReset, SelResumeAck;
  assign SelHalted    = SelExists & Halted[SelIdx] & ~Unavail[SelIdx];
  assign SelRunning   = SelExists & ~Halted[SelIdx] & ~Unavail[SelIdx];
  assign SelUnavail   = SelExists & Unavail[SelIdx];
  assign SelHaveReset = SelExists & HaveReset[SelIdx];
  assign SelResumeAck = SelExists & ResumeAck[SelIdx];

  // haltsum0: the harts of the 32 that contain the selected hart; haltsum1: groups of 32 of the
  // 1024 that contain it
  logic [31:0] HaltSum0, HaltSum1;
  always_comb begin
    HaltSum0 = '0; HaltSum1 = '0;
    for (int h = 0; h < NHARTS; h++) begin
      if (h / 32 == int'(HartSel[19:5]) && Halted[h] && !Unavail[h]) HaltSum0[h % 32] = 1'b1;
      if (h / 1024 == int'(HartSel[19:10]) && Halted[h] && !Unavail[h]) HaltSum1[(h / 32) % 32] = 1'b1;
    end
  end
  always_comb
    case (DMIAddr)
      // dmcontrol: hartreset, hartsel, ndmreset, dmactive (no hasel)
      DMCONTROL:    DMIRData = {2'b0, SelExists & HartReset[SelIdx], 3'b0, HartSel[9:0], HartSel[19:10],
                                4'b0, NDMReset, DMActive};
      // dmstatus: ndmresetpending, impebreak, havereset, resumeack, unavail, running, halted,
      // authenticated, hasresethaltreq, version 3 (1.0)
      DMSTATUS:     DMIRData = {7'b0, NDMReset, 1'b0, 1'b1, 2'b0, {2{SelHaveReset}}, {2{SelResumeAck}}, {2{~SelExists}},
                                {2{SelUnavail}}, {2{SelRunning}}, {2{SelHalted}}, 1'b1, 1'b0, 1'b1, 1'b0, 4'd3};
      // hartinfo: nscratch 1 (dscratch0; the ROM uses dscratch1), data registers in memory at 0x380
      HARTINFO:     DMIRData = {8'b0, 4'd1, 3'b0, 1'b1, 4'(DATACOUNT), DATA};
      ABSTRACTCS:   DMIRData = {3'b0, 5'(PROGBUFSIZE), 11'b0, Busy, 1'b0, CmdErr, 4'b0, 4'(DATACOUNT)};
      ABSTRACTAUTO: DMIRData = {AutoExecProgBuf, 4'b0, AutoExecData};
      HALTSUM0:     DMIRData = HaltSum0;
      HALTSUM1:     DMIRData = HaltSum1;
      DATA0:        DMIRData = Data[0];
      DATA1:        DMIRData = Data[1];
      default:
        if (ProgBufReg) DMIRData = ProgBuf[ProgBufIdx];
        else DMIRData = SBARData;                     // System Bus Access registers, else 0
    endcase

  ///////////////////////////////////////////
  // State
  ///////////////////////////////////////////

  logic        DMReset, DataAccess, ProgBufAccess, AutoExec, NewCommand, Issue;
  logic [31:0] IssueCmd;
  assign DMReset = reset | Write & DMIAddr == DMCONTROL & ~DMIWData[0];
  assign DataAccess = DMIReq & DataReg;
  assign ProgBufAccess = DMIReq & ProgBufReg;
  // abstractauto: an access to a data or program buffer register re-executes the command
  assign AutoExec = DataAccess & AutoExecData[4'(DataIdx)] | ProgBufAccess & AutoExecProgBuf[4'(ProgBufIdx)];
  assign NewCommand = Write & DMIAddr == COMMAND;
  // A command or an auto-execution runs if no command is running and no error is pending
  assign IssueCmd = NewCommand ? DMIWData : Command;
  assign Issue = DMActive & (NewCommand | AutoExec) & ~Busy & CmdErr == 3'd0;

  // The hart that a dmcontrol write addresses
  logic [19:0]  NewSel;
  logic [HW-1:0] NewIdx;
  logic         NewExists;
  assign NewSel = {DMIWData[15:6], DMIWData[25:16]};
  assign NewIdx = NewSel[HW-1:0];
  assign NewExists = NewSel < 20'(NHARTS);

  always_ff @(posedge clk)
    if (DMReset) begin
      DMActive <= 1'b0; NDMReset <= 1'b0; HartReset <= '0; HaltReq <= '0; ResetHaltReq <= '0;
      ResetHaltPending <= '0; Halted <= '0; ResumeAck <= '0; GoFlag <= '0; ResumeFlag <= '0; HartSel <= '0;
      CmdErr <= '0; Command <= '0; CmdState <= CMD_IDLE; CmdHart <= '0; AutoExecData <= '0; AutoExecProgBuf <= '0;
      Data <= '{default: '0}; ProgBuf <= '{default: NOP};
      if (reset) HaveReset <= '1;
    end else begin
      // A hart in reset: it restarts running, and halts as it leaves reset with resethaltreq.
      // (Before dmcontrol, so that ackhavereset as the reset ends wins.)
      for (int h = 0; h < NHARTS; h++)
        if (Unavail[h]) begin
          HaveReset[h] <= 1'b1; Halted[h] <= 1'b0; GoFlag[h] <= 1'b0; ResumeFlag[h] <= 1'b0;
          ResetHaltPending[h] <= ResetHaltReq[h];
        end
      if (Unavail[CmdHart]) CmdState <= CMD_IDLE;
      // Registers of dmcontrol: the bits that concern harts go to the selected one (no hasel)
      if (Write & DMIAddr == DMCONTROL) begin
        DMActive  <= 1'b1;
        HartSel   <= NewSel;
        NDMReset  <= DMIWData[1];
        if (NewExists) begin
          HaltReq[NewIdx]   <= DMIWData[31];
          HartReset[NewIdx] <= DMIWData[29];
          if (DMIWData[28]) HaveReset[NewIdx] <= 1'b0;           // ackhavereset
          if (DMIWData[3]) ResetHaltReq[NewIdx] <= 1'b1;         // setresethaltreq
          else if (DMIWData[2]) ResetHaltReq[NewIdx] <= 1'b0;    // clrresethaltreq
          // resumereq, unless haltreq is also set: the ROM resumes on the resume flag
          if (DMIWData[30] & ~DMIWData[31] & Halted[NewIdx]) begin
            ResumeFlag[NewIdx] <= 1'b1; ResumeAck[NewIdx] <= 1'b0;
          end
        end
      end
      // The ROM reports the harts' state
      for (int h = 0; h < NHARTS; h++) begin
        if (HartHalted[h]) begin
          Halted[h] <= 1'b1; ResetHaltPending[h] <= 1'b0;
        end
        if (HartGoing[h]) GoFlag[h] <= 1'b0;
        if (HartResuming[h]) begin
          Halted[h] <= 1'b0; ResumeFlag[h] <= 1'b0; ResumeAck[h] <= 1'b1;
        end
      end
      // The command runs on one hart: it starts when that hart takes the go flag, and completes when
      // it halts again
      if (HartGoing[CmdHart]) CmdState <= CMD_RUN;
      if (HartHalted[CmdHart] && CmdState == CMD_RUN) begin
        CmdState <= CMD_IDLE;
        if (Command[19] & CmdErr == 3'd0) Command[15:0] <= Command[15:0] + 16'd1;  // aarpostincrement
      end
      if (HartException[CmdHart] & CmdErr == 3'd0) CmdErr <= 3'd3;   // exception
      // Abstract commands
      if (Write & DMIAddr == ABSTRACTCS) CmdErr <= CmdErr & ~DMIWData[10:8];
      if (Write & DMIAddr == ABSTRACTAUTO)
        if (Busy) begin if (CmdErr == 3'd0) CmdErr <= 3'd1; end
        else begin AutoExecData <= DMIWData[11:0] & 12'(2**DATACOUNT - 1); AutoExecProgBuf <= DMIWData[31:16] & 16'(2**PROGBUFSIZE - 1); end
      if ((NewCommand | DataAccess | ProgBufAccess) & Busy & CmdErr == 3'd0) CmdErr <= 3'd1;   // busy
      if (Issue) begin
        Command <= IssueCmd;
        if (SelExists) CmdHart <= SelIdx;
        if (!supported(IssueCmd))       CmdErr <= 3'd2;          // not supported
        else if (!SelHalted)            CmdErr <= 3'd4;          // the hart is not halted (or does not exist)
        else if (IssueCmd[17] | IssueCmd[18]) begin               // transfer or postexec
          GoFlag[SelIdx] <= 1'b1; CmdState <= CMD_GO;
        end
      end
      // Data and program buffer, written by the debugger (not while a command runs) or the hart
      if (Write & ~Busy) begin
        if (DataAccess) Data[DataIdx] <= DMIWData;
        if (ProgBufAccess) ProgBuf[ProgBufIdx] <= DMIWData;
      end
      for (int w = 0; w < WORDS; w++)
        if (WordWrite[w] & WordAdr[w] >= DATA & WordAdr[w] < DATA + 12'(4*DATACOUNT))
          for (int b = 0; b < 4; b++)
            if (WordStrb[w][b]) Data[WordAdr[w][2]][8*b +: 8] <= WordData[w][8*b +: 8];
    end

  ///////////////////////////////////////////
  // System Bus Access
  ///////////////////////////////////////////

  dmsba #(P) sba(.clk, .reset(DMReset), .DMActive, .Write, .Read, .DMIAddr, .DMIWData, .DMIRData(SBARData),
    .SBHADDR, .SBHWDATA, .SBHWSTRB, .SBHWRITE, .SBHSIZE, .SBHTRANS, .SBHREADY, .SBHRDATA, .SBHRESP);
endmodule
