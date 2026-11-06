///////////////////////////////////////////
// mcu_apb.sv
//
// Purpose: the microcontroller peripherals of the open-ASIC chip behind one APB select: a timer with
//          four PWM/capture channels, a watchdog, an I2C master and an RTC.  PADDR[15:12] selects one:
//          0 timer, 1 watchdog, 2 I2C, 3 RTC.  Every register is 32 bits wide (word accesses); an
//          access to another 4 KiB block reads zero and writes nothing.  The pins are multiplexed by
//          the GPIO's IOF registers (uncore.sv).
//          docs/engineering/decisions/0022-asic-microcontroller.md
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module mcu_apb import cvw::*; #(parameter cvw_t P) (
  input  logic                PCLK, PRESETn,
  input  logic                PSEL,
  input  logic [15:0]         PADDR,
  input  logic [P.XLEN-1:0]   PWDATA,
  input  logic                PWRITE,
  input  logic                PENABLE,
  output logic [P.XLEN-1:0]   PRDATA,
  output logic                PREADY,
  output logic [3:0]          MCUIntr,                  // timer, watchdog, I2C, RTC
  input  logic [3:0]          TimerCaptureIn,
  output logic [3:0]          TimerPWMOut, TimerPWMEn,
  input  logic                I2CSCLIn, I2CSDAIn,
  output logic                I2CSCLDrive, I2CSDADrive,
  output logic                WDTReset
);

  logic [3:0][31:0] Read;
  logic [3:0]       Sel;
  logic [31:0]      Dout;

  assign PREADY = 1'b1;
  for (genvar i = 0; i < 4; i++) assign Sel[i] = PSEL & (PADDR[15:12] == 4'(i));

  timer_apb timer(.PCLK, .PRESETn, .PSEL(Sel[0]), .PWRITE, .PENABLE, .PADDR(PADDR[7:0]), .PWDATA(PWDATA[31:0]),
    .PRDATA(Read[0]), .CaptureIn(TimerCaptureIn), .PWMOut(TimerPWMOut), .PWMEn(TimerPWMEn), .Intr(MCUIntr[0]));
  wdt_apb wdt(.PCLK, .PRESETn, .PSEL(Sel[1]), .PWRITE, .PENABLE, .PADDR(PADDR[7:0]), .PWDATA(PWDATA[31:0]),
    .PRDATA(Read[1]), .Intr(MCUIntr[1]), .ResetReq(WDTReset));
  i2c_apb i2c(.PCLK, .PRESETn, .PSEL(Sel[2]), .PWRITE, .PENABLE, .PADDR(PADDR[7:0]), .PWDATA(PWDATA[31:0]),
    .PRDATA(Read[2]), .SCLIn(I2CSCLIn), .SDAIn(I2CSDAIn), .SCLDrive(I2CSCLDrive), .SDADrive(I2CSDADrive),
    .Intr(MCUIntr[2]));
  rtc_apb rtc(.PCLK, .PRESETn, .PSEL(Sel[3]), .PWRITE, .PENABLE, .PADDR(PADDR[7:0]), .PWDATA(PWDATA[31:0]),
    .PRDATA(Read[3]), .Intr(MCUIntr[3]));

  assign Dout = (PADDR[15:14] == 2'b00) ? Read[PADDR[13:12]] : 32'b0;
  if (P.XLEN == 64) assign PRDATA = {Dout, Dout};
  else              assign PRDATA = Dout;

endmodule
