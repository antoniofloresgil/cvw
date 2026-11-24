///////////////////////////////////////////
// xilinx_tap.sv
//
// Purpose: a model of the JTAG TAP of a Xilinx 7-series FPGA as the BSCANE2 primitives of USER3 and
//          USER4 see it, for openocd_tb with BSCAN=1 (the DTM's BSCAN mode, src/debug/dtm.sv): a 6-bit
//          instruction register with IDCODE (0x09, the XC7A200T's 0x13636093), USER3 (0x22) and USER4
//          (0x23); every other instruction is BYPASS.  Like BSCANE2, it gives each USER register its
//          select, and to both the TAP's Capture/Shift/Update-DR; TDO changes on the falling edge of TCK.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module xilinx_tap (
  input  logic TCK, TMS, TDI,
  output logic TDO,
  output logic Sel3, Sel4, Capture, Shift, Update,
  input  logic UserTDO                      // of the selected USER register
);
  typedef enum logic [3:0] {
    TLR, RTI, SELDR, CAPDR, SHDR, EX1DR, PDR, EX2DR, UPDR, SELIR, CAPIR, SHIR, EX1IR, PIR, EX2IR, UPIR
  } st_t;
  st_t        State = TLR, Next;
  logic [5:0] IR = 6'h09, IRShift;
  logic [31:0] DR;

  always_comb
    case (State)
      TLR:   Next = TMS ? TLR : RTI;     RTI:   Next = TMS ? SELDR : RTI;
      SELDR: Next = TMS ? SELIR : CAPDR; CAPDR: Next = TMS ? EX1DR : SHDR;
      SHDR:  Next = TMS ? EX1DR : SHDR;  EX1DR: Next = TMS ? UPDR : PDR;
      PDR:   Next = TMS ? EX2DR : PDR;   EX2DR: Next = TMS ? UPDR : SHDR;
      UPDR:  Next = TMS ? SELDR : RTI;   SELIR: Next = TMS ? TLR : CAPIR;
      CAPIR: Next = TMS ? EX1IR : SHIR;  SHIR:  Next = TMS ? EX1IR : SHIR;
      EX1IR: Next = TMS ? UPIR : PIR;    PIR:   Next = TMS ? EX2IR : PIR;
      EX2IR: Next = TMS ? UPIR : SHIR;   UPIR:  Next = TMS ? SELDR : RTI;
      default: Next = TLR;
    endcase

  always_ff @(posedge TCK) begin
    State <= Next;
    if (State == TLR) IR <= 6'h09;
    else if (State == UPIR) IR <= IRShift;
    if (State == CAPIR) IRShift <= 6'b110101;  // 7-series: ...01 in the two low bits
    else if (State == SHIR) IRShift <= {TDI, IRShift[5:1]};
    if (State == CAPDR) DR <= IR == 6'h09 ? 32'h13636093 : '0;
    else if (State == SHDR) DR <= IR == 6'h09 ? {TDI, DR[31:1]} : {31'b0, TDI};
  end

  assign Sel3 = IR == 6'h22;
  assign Sel4 = IR == 6'h23;
  assign Capture = State == CAPDR;
  assign Shift   = State == SHDR;
  assign Update  = State == UPDR;

  always_ff @(negedge TCK)
    TDO <= State == SHIR ? IRShift[0] : State != SHDR ? 1'b0 : (Sel3 | Sel4) ? UserTDO : DR[0];
endmodule
