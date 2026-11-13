///////////////////////////////////////////
// uncore.sv
//
// Written:  David Harris David_Harris@hmc.edu 9 January 2021
// Modified: Rose Thompson, Jacob Pease, Ben Bracker, Noah Boorstin, Naiche Whyte-Aguayo, Thomas Fleming
//
// Purpose: Memories and peripherals outside the core.
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwfoundation/cvw
//
// Copyright (C) 2021-26 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

module uncore import cvw::*;  #(parameter cvw_t P, parameter int unsigned NCORES = 1)(
  // AHB Bus Interface
  input  logic                 HCLK, HRESETn,
  input  logic [P.PA_BITS-1:0] HADDR,
  input  logic [P.AHBW-1:0]    HWDATA,
  input  logic [P.XLEN/8-1:0]  HWSTRB,
  input  logic                 HWRITE,
  input  logic [2:0]           HSIZE,
  input  logic [2:0]           HBURST,
  input  logic [3:0]           HPROT,
  input  logic [1:0]           HTRANS,
  input  logic                 HMASTLOCK,
  input  logic [P.AHBW-1:0]    HRDATAEXT,
  input  logic                 HREADYEXT, HRESPEXT,
  output logic [P.AHBW-1:0]    HRDATA,
  output logic                 HREADY, HRESP,        // HREADY: the core's view (low while the AI unit has the bus)
  output logic                 HSELEXT,
  // peripheral pins
  output logic [NCORES-1:0]    MTimerInt, MSwInt,         // Timer and software interrupts from CLINT
  output logic [NCORES-1:0]    MExtInt, SExtInt,          // External interrupts from PLIC
  output logic [63:0]          MTIME_CLINT,               // MTIME, from CLINT
  input  logic [31:0]          GPIOIN,                    // GPIO pin input value
  output logic [31:0]          GPIOOUT, GPIOEN,           // GPIO pin output value and enable
  input  logic                 UARTSin,                   // UART serial input
  output logic                 UARTSout,                  // UART serial output
  input  logic                 SPIIn,
  output logic                 SPIOut,
  output logic [3:0]           SPICS,
  output logic                 SPICLK,
  input  logic                 SDCIn,
  output logic                 SDCCmd,
  output logic [3:0]           SDCCS,
  output logic                 SDCCLK,
  output logic [3:0]           PWMGPIO,
  output logic                 WDTReset,                  // from the MCU peripherals' watchdog
  // TRACE_IN_RAM: the trace sink's port to the RAM (see ram_ahb)
  input  logic                 TrReq, TrWe,
  input  logic [3:0]           TrBwe,
  input  logic [$clog2(P.TRACE_RAM_WORDS)-1:0] TrAddr,
  input  logic [31:0]          TrDin,
  output logic                 TrGrant,
  output logic [31:0]          TrDout
);

  logic [P.XLEN-1:0]           HREADRam;

  logic [13:0]                 HSELRegions;
  logic                        HSELDTIM, HSELIROM, HSELRam, HSELCLINT, HSELPLIC, HSELGPIO, HSELUART, HSELSDC, HSELSPI, HSELPWM, HSELMCU;
  logic                        HSELDTIMD, HSELIROMD, HSELEXTD, HSELRamD, HSELCLINTD, HSELPLICD, HSELGPIOD, HSELUARTD, HSELSDCD, HSELSPID, HSELPWMD, HSELMCUD;
  logic                        HRESPRam, HREADYRam;
  logic [P.XLEN-1:0]           HREADBootRom;
  logic                        HSELBootRom, HSELBootRomD, HRESPBootRom, HREADYBootRom;
  logic                        HSELNoneD;
  logic                        UARTIntr, GPIOIntr, SPIIntr;
  // The MCU peripherals' pins are GPIO alternate function 1 (IOF_SEL set): timer channels 0-3 on
  // GPIO 0-3, I2C SCL and SDA on GPIO 6 and 7 (open drain: the line is pulled low while the output
  // enable is set), clear of the boot straps the chip's bootloader reads from GPIO 0-5.  Their inputs read the pads, whatever the GPIO's own input enable.
  logic [3:0]                  TimerPWMOut, TimerPWMEn;
  logic                        I2CSCLDrive, I2CSDADrive;
  logic [3:0]                  MCUIntr;                     // timer, watchdog, I2C, RTC: four consecutive PLIC sources
  logic [3:0]                  PWMIntr;                     // one PLIC source per PWM comparator, as in the FU540

  logic                        PCLK, PRESETn, PWRITE, PENABLE;
  logic [7:0]                  PSEL;
  logic [31:0]                 PADDR;
  logic [P.XLEN-1:0]           PWDATA;
  logic [P.XLEN/8-1:0]         PSTRB;
  /* verilator lint_off UNDRIVEN */ // undriven in rv32e configuration
  logic [7:0]                  PREADY;
  logic [7:0][P.XLEN-1:0]      PRDATA;
  /* verilator lint_on UNDRIVEN */
  logic [P.XLEN-1:0]           HREADBRIDGE;
  logic                        HRESPBRIDGE, HREADYBRIDGE, HSELBRIDGE, HSELBRIDGED;
  /* SDC Interrupt (SPI Controller) */
  logic                        SDCIntr;

  // The bus the uncore decodes: the core's (HADDR ...), or, with AI_SUPPORTED, the AI unit's master (src/uncore/ai).  The unit takes the bus
  // only when no transfer of the core is in its data phase (CoreDV), so no response is lost at the change.  While it has the bus the core
  // sees HREADY low, and the core's bus FSM (ebu/busfsm.sv) issues an address only in a clock with HREADY high, so none is in flight.
  // The unit's transfers are single 32-bit accesses to the RAM, back to back.  While it loads or reads its input vector (Own: from its first address to
  // the end of the row) the core is held off the bus altogether, also after the unit's last address: the unit then has the port of the RAM part that holds
  // the vector (ram_ahb.sv, XpReq) and the core must not use that macro.
  logic [P.PA_BITS-1:0]        HADDRM;
  logic [P.AHBW-1:0]           HWDATAM;
  logic [P.XLEN/8-1:0]         HWSTRBM;
  logic                        HWRITEM, HREADYM;
  logic [2:0]                  HSIZEM;
  logic [1:0]                  HTRANSM;
  logic [P.XLEN-1:0]           MCURead;
  // the AI unit's port to the RAM part that holds its input vector (ram_ahb.sv)
  logic                        XpReq, XpWe;
  logic [$clog2(P.TRACE_RAM_WORDS)-1:0] XpAddr;
  logic [31:0]                 XpDin, XpDout;
  if (P.AI_SUPPORTED) begin : ai
    if (P.XLEN != 32 || !P.MCU_SUPPORTED || !P.UNCORE_RAM_SUPPORTED || P.AHBW != 32 || !P.TRACE_IN_RAM)
      $error("AI_SUPPORTED needs XLEN and AHBW 32, MCU_SUPPORTED, UNCORE_RAM_SUPPORTED and TRACE_IN_RAM (the unit's input vector is in a part of the shared RAM)");
    logic                      Req, Write, AUnit, UnitDV, CoreDV, Sel, Own;
    logic [P.PA_BITS-1:0]      Addr;
    logic [31:0]               WData, Read;
    logic [3:0]                WStrb;
    assign AUnit = Req & ~CoreDV;
    always_ff @(posedge HCLK)
      if (~HRESETn) {UnitDV, CoreDV} <= 2'b00;
      else if (HREADYM) begin
        UnitDV <= AUnit;
        CoreDV <= ~AUnit & ~Own & HTRANS[1];
      end
    assign HADDRM  = AUnit ? Addr : HADDR;
    assign HTRANSM = AUnit ? 2'b10 : Own ? 2'b00 : HTRANS;
    assign HWRITEM = AUnit ? Write : HWRITE;
    assign HSIZEM  = AUnit ? 3'b010 : HSIZE;
    assign HWDATAM = UnitDV ? WData : HWDATA;
    assign HWSTRBM = UnitDV ? WStrb : HWSTRB;
    assign HREADY  = HREADYM & ~AUnit & ~Own;      // the core's bus FSM (ebu/busfsm.sv) issues an address only while HREADY is high
    assign Sel     = PSEL[7] & (PADDR[15:12] == 4'd4);
    ai_unit #(P) unit(.HCLK, .HRESETn, .PSEL(Sel), .PWRITE, .PENABLE, .PADDR(PADDR[7:0]), .PWDATA(PWDATA[31:0]), .PRDATA(Read),
      .Req, .Write, .Addr, .WData, .WStrb, .Accept(AUnit & HREADYM), .DataDone(UnitDV & HREADYM), .BusErr(UnitDV & HRESP), .RData(HRDATA[31:0]),
      .Own, .XpReq, .XpWe, .XpAddr, .XpDin, .XpDout);
    assign PRDATA[7] = MCURead | Read;
  end else begin : noai
    assign HADDRM = HADDR;   assign HTRANSM = HTRANS; assign HWRITEM = HWRITE; assign HSIZEM = HSIZE;
    assign HWDATAM = HWDATA; assign HWSTRBM = HWSTRB;
    assign HREADY = HREADYM;
    assign {XpReq, XpWe, XpAddr, XpDin} = '0;
    assign PRDATA[7] = MCURead;
  end

  // Determine which region of physical memory (if any) is being accessed
  // Use a trimmed down portion of the PMA checker - only the address decoders
  // Set access types to all 1 as don't cares because the MMU has already done access checking
  adrdecs #(P) adrdecs(HADDRM, 1'b1, 1'b1, 1'b1, HSIZEM[1:0], HSELRegions);

  // unswizzle HSEL signals
  assign {HSELMCU, HSELPWM, HSELSPI, HSELSDC, HSELPLIC, HSELUART, HSELGPIO, HSELCLINT, HSELRam, HSELBootRom, HSELEXT, HSELIROM, HSELDTIM} = HSELRegions[13:1];

  // AHB -> APB bridge
  ahbapbbridge #(P, 8) ahbapbbridge (
    .HCLK, .HRESETn, .HSEL({HSELMCU, HSELPWM, HSELSDC, HSELSPI, HSELUART, HSELPLIC, HSELCLINT, HSELGPIO}), .HADDR(HADDRM), .HWDATA(HWDATAM), .HWSTRB(HWSTRBM), .HWRITE(HWRITEM), .HTRANS(HTRANSM), .HREADY(HREADYM),
    .HRDATA(HREADBRIDGE), .HRESP(HRESPBRIDGE), .HREADYOUT(HREADYBRIDGE),
    .PCLK, .PRESETn, .PSEL, .PWRITE, .PENABLE, .PADDR, .PWDATA, .PSTRB, .PREADY, .PRDATA);
  assign HSELBRIDGE = HSELGPIO | HSELCLINT | HSELPLIC | HSELUART | HSELSPI | HSELSDC | HSELPWM | HSELMCU; // if any of the bridge signals are selected

  // on-chip RAM
  if (P.UNCORE_RAM_SUPPORTED) begin : ram
    ram_ahb #(.P(P), .RANGE(P.UNCORE_RAM_RANGE), .PRELOAD(P.UNCORE_RAM_PRELOAD), .TRACE_SHARED(P.TRACE_IN_RAM)) ram (
      .HCLK, .HRESETn, .HSELRam, .HADDR(HADDRM), .HWRITE(HWRITEM), .HREADY(HREADYM),
      .HTRANS(HTRANSM), .HWDATA(HWDATAM), .HWSTRB(HWSTRBM), .HREADRam, .HRESPRam, .HREADYRam,
      .TrReq, .TrWe, .TrBwe, .TrAddr, .TrDin, .TrGrant, .TrDout,
      .XpReq, .XpWe, .XpAddr, .XpDin, .XpDout);
  end else begin
    assign {HREADRam, HRESPRam, HREADYRam} = '0;
    assign XpDout = '0;
    assign {TrGrant, TrDout} = '0;
  end

  if (P.BOOTROM_SUPPORTED) begin : bootrom
    rom_ahb #(.P(P), .RANGE(P.BOOTROM_RANGE), .PRELOAD(P.BOOTROM_PRELOAD))
    bootrom(.HCLK, .HRESETn, .HSELRom(HSELBootRom), .HADDR(HADDRM), .HREADY(HREADYM), .HTRANS(HTRANSM),
      .HREADRom(HREADBootRom), .HRESPRom(HRESPBootRom), .HREADYRom(HREADYBootRom));
  end else assign {HREADBootRom, HRESPBootRom, HREADYBootRom} = '0;

  // memory-mapped I/O peripherals
  if (P.CLINT_SUPPORTED == 1 && NCORES == 1) begin : clint
    clint_apb #(P) clint(.PCLK, .PRESETn, .PSEL(PSEL[1]), .PADDR(PADDR[15:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PRDATA(PRDATA[1]), .PREADY(PREADY[1]), .MTIME(MTIME_CLINT), .MTimerInt, .MSwInt);
  end else if (P.CLINT_SUPPORTED == 1) begin : clint
    clint_multicore_apb #(.P(P), .NCORES(NCORES)) clint(.PCLK, .PRESETn, .PSEL(PSEL[1]), .PADDR(PADDR[15:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PRDATA(PRDATA[1]), .PREADY(PREADY[1]), .MTIME(MTIME_CLINT), .MTimerInt, .MSwInt);
  end else begin : clint
    assign MTIME_CLINT = '0;
    assign MTimerInt = '0; assign MSwInt = '0;
  end

  if (P.PLIC_SUPPORTED == 1 && NCORES == 1) begin : plic
    plic_apb #(P) plic(.PCLK, .PRESETn, .PSEL(PSEL[2]), .PADDR(PADDR[27:0] - 28'(P.PLIC_BASE)), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PRDATA(PRDATA[2]), .PREADY(PREADY[2]), .UARTIntr, .GPIOIntr, .SDCIntr, .SPIIntr, .PWMIntr, .MCUIntr, .MExtInt, .SExtInt);
  end else if (P.PLIC_SUPPORTED == 1) begin : plic
    plic_multicore_apb #(.P(P), .NCORES(NCORES)) plic(.PCLK, .PRESETn, .PSEL(PSEL[2]), .PADDR(PADDR[27:0] - 28'(P.PLIC_BASE)), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PRDATA(PRDATA[2]), .PREADY(PREADY[2]), .UARTIntr, .GPIOIntr, .SDCIntr, .SPIIntr, .PWMIntr, .MCUIntr, .MExtInt, .SExtInt);
  end else begin : plic
    assign MExtInt = '0;
    assign SExtInt = '0;
  end

  if (P.GPIO_SUPPORTED == 1) begin : gpio
    // IOF0 of pins 3:0 is the PWM; with the MCU peripherals IOF1 of pins 3:0 is the timer's PWM and of
    // pins 7:6 the I2C (a pin whose IOF does not exist reverts to software control)
    gpio_apb #(.P(P), .IOF0_PINS(P.PWM_SUPPORTED ? 32'h0000000F : 32'h0),
               .IOF1_PINS(P.MCU_SUPPORTED ? 32'h000000CF : 32'h0)) gpio(
      .PCLK, .PRESETn, .PSEL(PSEL[0]), .PADDR(PADDR[7:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PRDATA(PRDATA[0]), .PREADY(PREADY[0]),
      .iof0({28'b0, PWMGPIO[3:0]}), .iof1({28'b0, TimerPWMOut}),
      .iof1oen({24'b0, I2CSDADrive, I2CSCLDrive, 2'b0, TimerPWMEn}), .GPIOIN, .GPIOOUT, .GPIOEN, .GPIOIntr);
  end else begin : gpio
    assign GPIOOUT = '0; assign GPIOEN = '0; assign GPIOIntr = 1'b0;
  end

  if (P.UART_SUPPORTED == 1) begin : uartgen
    uart_apb #(P) uart(
      .PCLK, .PRESETn, .PSEL(PSEL[3]), .PADDR(PADDR[2:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PRDATA(PRDATA[3]), .PREADY(PREADY[3]),
      .SIN(UARTSin), .DSRb(1'b1), .DCDb(1'b1), .CTSb(1'b0), .RIb(1'b1), // from E1A driver from RS232 interface
      .SOUT(UARTSout), .RTSb(), .DTRb(),                                // to E1A driver to RS232 interface
      .OUT1b(), .OUT2b(), .INTR(UARTIntr), .TXRDYb(), .RXRDYb());       // to CPU
  end else begin : uart
    assign UARTSout = 1'b0; assign UARTIntr = 1'b0;
  end

  if (P.SPI_SUPPORTED == 1) begin : spi
    spi_apb #(P) spi (
      .PCLK, .PRESETn, .PSEL(PSEL[4]), .PADDR(PADDR[7:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PREADY(PREADY[4]), .PRDATA(PRDATA[4]),
      .SPIOut, .SPIIn, .SPICS, .SPICLK, .SPIIntr);
  end else begin : spi
    assign SPIOut = 1'b0; assign SPICS = '0; assign SPIIntr = 1'b0; assign SPICLK = 1'b0;
  end

  if (P.SDC_SUPPORTED == 1) begin : sdc
    spi_apb #(P) sdc(
      .PCLK, .PRESETn, .PSEL(PSEL[5]), .PADDR(PADDR[7:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PREADY(PREADY[5]), .PRDATA(PRDATA[5]),
      .SPIOut(SDCCmd), .SPIIn(SDCIn), .SPICS(SDCCS), .SPICLK(SDCCLK), .SPIIntr(SDCIntr));
  end else begin : sdc
    assign SDCCmd = '0; assign SDCCS = 4'b0; assign SDCIntr = 1'b0; assign SDCCLK = 1'b0;
  end

  if (P.PWM_SUPPORTED == 1) begin : pwm
    pwm_apb #(P) pwm(
      .PCLK, .PRESETn, .PSEL(PSEL[6]), .PADDR(PADDR[7:0]), .PWDATA, .PSTRB, .PWRITE, .PENABLE,
      .PREADY(PREADY[6]), .PRDATA(PRDATA[6]),
      .PWMIntr, .PWMGPIO);
  end else begin : pwm
    assign PWMIntr = '0; assign PWMGPIO = '0;
  end

  if (P.MCU_SUPPORTED == 1) begin : mcu
    mcu_apb #(P) mcu(
      .PCLK, .PRESETn, .PSEL(PSEL[7]), .PADDR(PADDR[15:0]), .PWDATA, .PWRITE, .PENABLE,
      .PREADY(PREADY[7]), .PRDATA(MCURead), .MCUIntr,
      .TimerCaptureIn(GPIOIN[3:0]), .TimerPWMOut, .TimerPWMEn, .I2CSCLIn(GPIOIN[6]), .I2CSDAIn(GPIOIN[7]),
      .I2CSCLDrive, .I2CSDADrive, .WDTReset);
  end else begin : mcu
    assign MCURead = '0; assign MCUIntr = '0; assign TimerPWMOut = '0; assign TimerPWMEn = '0;
    assign I2CSCLDrive = 1'b0; assign I2CSDADrive = 1'b0; assign WDTReset = 1'b0;
  end

  // AHB Read Multiplexer
  assign HRDATA = ({P.XLEN{HSELRamD}} & HREADRam) |
                  ({P.XLEN{HSELEXTD}} & HRDATAEXT) |
                  ({P.XLEN{HSELBRIDGED}} & HREADBRIDGE) |
                  ({P.XLEN{HSELBootRomD}} & HREADBootRom);

  assign HRESP = HSELRamD & HRESPRam |
                 HSELEXTD & HRESPEXT |
                 HSELBRIDGED & HRESPBRIDGE |
                 HSELBootRomD & HRESPBootRom;

  assign HREADYM = HSELRamD & HREADYRam |
                  HSELEXTD & HREADYEXT |
                  HSELBRIDGED & HREADYBRIDGE |
                  HSELBootRomD & HREADYBootRom |
                  HSELNoneD; // don't lock up the bus if no region is being accessed

  // Address Decoder Delay (figure 4-2 in spec)
  // The select for HREADY needs to be based on the address phase address.  If the device
  // takes more than 1 cycle to respond it needs to hold on to the old select until the
  // device is ready.  Hence this register must be selectively enabled by HREADY.
  // However on reset None must be selected.
  flopenl #(14) hseldelayreg(HCLK, ~HRESETn, HREADYM, HSELRegions, 14'b1,
    {HSELMCUD, HSELPWMD, HSELSPID, HSELSDCD, HSELPLICD, HSELUARTD, HSELGPIOD, HSELCLINTD,
      HSELRamD, HSELBootRomD, HSELEXTD, HSELIROMD, HSELDTIMD, HSELNoneD});
  flopenr #(1) hselbridgedelayreg(HCLK, ~HRESETn, HREADYM, HSELBRIDGE, HSELBRIDGED);
endmodule
