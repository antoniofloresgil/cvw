`include "cvw.sv"
`include "config.vh"

(* blackbox *)
module BUFGCTRL (
  input  wire I0,
  input  wire CE0,
  input  wire S0,
  output wire O
);
endmodule

module fpgaOpenSource import cvw::*; (
  input  logic       default_100mhz_clk,
  input  logic       resetn,
  input  logic [3:0] GPI,
  output logic [4:0] GPO,
  input  logic       UARTSin,
  output logic       UARTSout,
  // SD card, accessed in SPI mode by the SDC
  input  logic       SDCIn,
  output logic       SDCCLK,
  output logic       SDCCmd,
  output logic       SDCCS,
  input  logic       SDCCD,
  output logic       SD_RESET,
  // DDR3 SDRAM
  output logic [14:0] ddram_a,
  output logic [2:0]  ddram_ba,
  output logic        ddram_cas_n,
  output logic        ddram_cke,
  output logic        ddram_clk_n,
  output logic        ddram_clk_p,
  output logic [1:0]  ddram_dm,
  inout  wire  [15:0] ddram_dq,
  inout  wire  [1:0]  ddram_dqs_n,
  inout  wire  [1:0]  ddram_dqs_p,
  output logic        ddram_odt,
  output logic        ddram_ras_n,
  output logic        ddram_reset_n,
  output logic        ddram_we_n
);

`include "parameter-defs.vh"

  logic clk100;
  logic sys_clk, wally_clk;
  logic sys_rst, wally_rst, ddr_init_done, ddr_init_error, ddr_ready, ddr_cpu_active;
  logic init_uart_tx, wally_uart_tx;
  logic init_uart_tx_q, uart_start_seen;
  logic [3:0] ddr_cpu_bus;
  logic [3:0] ddr_cpu_boot, ddr_cpu_data;
  logic [3:0] ddr_cpu_copy;
  logic [31:0] ddr_first_data_addr;
  logic reset;
  logic [P.AHBW-1:0] HRDATAEXT, HRDATADDR, HRDATACtrl;
  logic HREADYEXT, HRESPEXT, HREADYDDR, HREADYCtrl, HRESPDDR, HRESPCtrl;
  logic HSELDDR, HSELCtrl;
  logic [P.PA_BITS-1:0] HADDR;
  logic [P.AHBW-1:0] HWDATA;
  logic [P.XLEN/8-1:0] HWSTRB;
  logic HWRITE;
  logic [2:0] HSIZE, HBURST;
  logic [3:0] HPROT;
  logic [1:0] HTRANS;
  logic HMASTLOCK, HCLK, HRESETn, HREADY, HSELEXT;
  logic [31:0] GPIOIN, GPIOOUT, GPIOEN;
  logic SPIOut;
  logic [3:0] SPICS;
  logic SPICLK;
  logic [3:0] SDCCSin, PWMGPIO;
  logic [31:0] heartbeat;

  // Wishbone between the LiteDRAM DDR3 controller and the AHB bridge.  The
  // bridge spans the whole 512 MiB DDR3 device and addresses AHBW-bit words.
  localparam DDR_ADDR_BITS = 29;
  localparam WB_ADR_BITS = DDR_ADDR_BITS - $clog2(P.AHBW/8);
  logic [WB_ADR_BITS-1:0] wb_adr;
  logic [P.AHBW-1:0] wb_dat_w, wb_dat_r;
  logic [P.AHBW/8-1:0] wb_sel;
  logic        wb_we, wb_cyc, wb_stb, wb_ack;
  logic wb_err;

  // LiteDRAM control/status registers (CSRs) as a 32-bit Wishbone slave.  They
  // exist only when the gateware is generated with --init-cpu none, when Wally
  // runs the DDR3 initialization itself (init_by_wally); the generated wrapper
  // answers this port with zeros otherwise.  Wally reaches them through the
  // configuration's EXT_IO window, an uncached part of the external region
  // (EXT_IO_BASE/EXT_IO_RANGE); without EXT_IO the whole region is DDR3.
  localparam CTRL_WIN_BITS = 16;                       // 64 KiB window
  localparam bit HAS_CTRL  = P.EXT_IO_SUPPORTED;
  logic SelCtrlWin;
  assign SelCtrlWin = HAS_CTRL &
    ((HADDR & ~P.EXT_IO_RANGE[P.PA_BITS-1:0]) == P.EXT_IO_BASE[P.PA_BITS-1:0]);
  logic init_by_wally;
  logic [29:0] ctrl_adr;
  logic [31:0] ctrl_dat_w, ctrl_dat_r;
  logic [3:0]  ctrl_sel;
  logic        ctrl_we, ctrl_cyc, ctrl_stb, ctrl_ack, ctrl_err;

  BUFGCTRL input_clock_buffer (
    .I0(default_100mhz_clk), .CE0(1'b1), .S0(1'b1), .O(clk100)
  );

  // LiteDRAM DDR3 subsystem.  It generates Wally's clock (wally_clk).  Either
  // Wally shares the DDR controller's sys_clk, or (when the gateware is
  // generated with --user-clk-freq) wally_clk is a separate PLL output and
  // LiteDRAM crosses the Wishbone port into it with asynchronous FIFOs.
  litedram_ddr litedram (
    .clk100, .cpu_reset_n(resetn), .sys_clk, .sys_rst, .wally_clk, .wally_rst,
    .init_done(ddr_init_done), .init_error(ddr_init_error), .init_by_wally,
    .ctrl_adr, .ctrl_dat_w, .ctrl_dat_r, .ctrl_sel, .ctrl_we, .ctrl_cyc, .ctrl_stb,
    .ctrl_ack, .ctrl_err,
    .debug_cpu_active(ddr_cpu_active),
    .debug_cpu_bus(ddr_cpu_bus),
    .debug_cpu_boot(ddr_cpu_boot), .debug_cpu_data(ddr_cpu_data),
    .debug_cpu_copy(ddr_cpu_copy),
    .debug_first_data_addr(ddr_first_data_addr),
    .uart_rx(UARTSin), .uart_tx(init_uart_tx),
    .ddram_a, .ddram_ba, .ddram_cas_n, .ddram_cke, .ddram_clk_n, .ddram_clk_p,
    .ddram_dm, .ddram_dq, .ddram_dqs_n, .ddram_dqs_p, .ddram_odt,
    .ddram_ras_n, .ddram_reset_n, .ddram_we_n,
    .wb_adr, .wb_dat_w, .wb_dat_r, .wb_sel, .wb_we, .wb_cyc, .wb_stb, .wb_ack,
    .wb_err
  );

  // With a service CPU, its initialization firmware owns DDR until JEDEC
  // initialization, leveling, and its memory test complete. Keep Wally in reset
  // until then (and on failure). When Wally runs the initialization itself it
  // must start at power-up, and its DDR accesses wait in the controller's user
  // port until the firmware writes init_done.
  assign ddr_ready = ddr_init_done & ~ddr_init_error & ~sys_rst;
  assign UARTSout = (init_by_wally | ddr_ready) ? wally_uart_tx : init_uart_tx;

  // As in the Vivado Nexys tops: card detect at GPIO 6, no write protect.
  assign GPIOIN = {25'b0, SDCCD, 1'b0, 1'b0, GPI};
  assign SDCCS = SDCCSin[0];
  assign SD_RESET = 1'b0;  // powers the card

  always_ff @(posedge sys_clk or negedge resetn) begin
    if (!resetn) heartbeat <= '0;
    else heartbeat <= heartbeat + 1'b1;
  end

  // Temporary bring-up diagnostics on the user LEDs (LD0..LD4):
  //   LD0 = clk100 activity, LD1 = init_done, LD2 = init_error,
  //   LD3 = service CPU wrote SRAM (BIOS executing),
  //   LD4 = service CPU UART started a frame (BIOS printing).
  // SW0=1: LD0 = clk100, LD1 = actual CPU reset, LD2 = fetch seen,
  //        LD3 = fetch acknowledged, LD4 = instruction bus error seen.
  // SW1:SW0=10: LD1 = reset vector ACK, LD2 = correct reset instruction,
  //            LD3 = crt_init ACK, LD4 = data request seen.
  // SW1:SW0=11: LD1 = data ACK, LD2 = data ERR, LD3 = trap vector ACK,
  //            LD4 = incorrect instruction in the boot sequence (0..0x110).
  // SW2:SW1:SW0=100: LD1 = ROM data load requested at 0x72a0,
  //                 LD2 = load ACK, LD3 = SRAM store requested, LD4 = store ACK.
  // SW3=1: LD4..LD1 display a nibble of the first data byte address;
  //        SW2..SW0 select nibble 0 (least significant) through 7.
  logic [25:0] led_cnt100;
  always_ff @(posedge clk100) led_cnt100 <= led_cnt100 + 1'b1;

  always_ff @(posedge sys_clk) begin
    if (!resetn | sys_rst) begin
      init_uart_tx_q <= 1'b1;
      uart_start_seen <= 1'b0;
    end else begin
      init_uart_tx_q <= init_uart_tx;
      if (init_uart_tx_q && !init_uart_tx) uart_start_seen <= 1'b1;
    end
  end

  always_comb
    if (GPI[3]) GPO = {ddr_first_data_addr[4*GPI[2:0] +: 4], led_cnt100[25]};
    else case (GPI[2:0])
      3'b000: GPO = {uart_start_seen, ddr_cpu_active, ddr_init_error, ddr_init_done, led_cnt100[25]};
      3'b001: GPO = {ddr_cpu_bus, led_cnt100[25]};
      3'b010: GPO = {ddr_cpu_boot, led_cnt100[25]};
      3'b011: GPO = {ddr_cpu_data, led_cnt100[25]};
      3'b100: GPO = {ddr_cpu_copy, led_cnt100[25]};
      default: GPO = {4'b0, led_cnt100[25]};
    endcase

  // The external region (EXT_MEM_BASE) holds the DDR3 data path and, in the
  // EXT_IO window, the LiteDRAM CSRs; each has an AHB -> Wishbone bridge.
  extbussplit #(.DATA_WIDTH(P.AHBW)) extsplit (
    .HCLK(wally_clk), .HRESETn(~reset), .HSELEXT, .SelCtrl(SelCtrlWin),
    .HREADY, .HTRANS, .HSELDDR, .HSELCtrl,
    .HRDATADDR, .HRDATACtrl, .HREADYDDR, .HREADYCtrl, .HRESPDDR, .HRESPCtrl,
    .HRDATAEXT, .HREADYEXT, .HRESPEXT
  );

  ahbwishbonebridge #(.ADDR_WIDTH(DDR_ADDR_BITS), .DATA_WIDTH(P.AHBW)) extbridge (
    .HCLK(wally_clk), .HRESETn(~reset), .HSEL(HSELDDR),
    .HADDR(HADDR[DDR_ADDR_BITS-1:0]), .HTRANS, .HWRITE, .HWDATA, .HWSTRB, .HREADY,
    .HREADYOUT(HREADYDDR), .HRDATA(HRDATADDR), .HRESP(HRESPDDR),
    .wb_adr, .wb_dat_w, .wb_sel, .wb_we, .wb_cyc, .wb_stb, .wb_dat_r, .wb_ack
  );

  if (HAS_CTRL) begin : ctrlbus
    // Bridge at Wally's bus width; a 64-bit bus picks one 32-bit register per
    // access by its byte strobes (CSRs are accessed as 32-bit words).  The
    // transfer then crosses from Wally's clock to LiteDRAM's system clock (also
    // correct when they are the same clock).
    localparam OFFSET = $clog2(P.AHBW/8);
    logic [CTRL_WIN_BITS-OFFSET-1:0] bus_word;
    logic [P.AHBW-1:0]   bus_dat_w, bus_dat_r;
    logic [P.AHBW/8-1:0] bus_sel;
    logic                bus_we, bus_cyc, bus_stb, bus_ack;
    logic [29:0]         m_adr;
    logic [31:0]         m_dat_w, m_dat_r;
    logic [3:0]          m_sel;
    ahbwishbonebridge #(.ADDR_WIDTH(CTRL_WIN_BITS), .DATA_WIDTH(P.AHBW)) ctrlbridge (
      .HCLK(wally_clk), .HRESETn(~reset), .HSEL(HSELCtrl),
      .HADDR(HADDR[CTRL_WIN_BITS-1:0]), .HTRANS, .HWRITE, .HWDATA, .HWSTRB, .HREADY,
      .HREADYOUT(HREADYCtrl), .HRDATA(HRDATACtrl), .HRESP(HRESPCtrl),
      .wb_adr(bus_word), .wb_dat_w(bus_dat_w), .wb_sel(bus_sel), .wb_we(bus_we),
      .wb_cyc(bus_cyc), .wb_stb(bus_stb), .wb_dat_r(bus_dat_r), .wb_ack(bus_ack)
    );
    if (P.AHBW == 64) begin : narrow
      logic hi;
      assign hi = |bus_sel[7:4];
      assign m_adr = 30'({bus_word, hi});
      assign m_dat_w = hi ? bus_dat_w[63:32] : bus_dat_w[31:0];
      assign m_sel = hi ? bus_sel[7:4] : bus_sel[3:0];
      assign bus_dat_r = {m_dat_r, m_dat_r};
    end else begin : same
      assign m_adr = 30'(bus_word);
      assign m_dat_w = bus_dat_w;
      assign m_sel = bus_sel;
      assign bus_dat_r = m_dat_r;
    end
    wbcdc #(.ADR_WIDTH(30), .DATA_WIDTH(32)) ctrlcdc (
      .m_clk(wally_clk), .m_rst(reset), .m_adr, .m_dat_w, .m_sel, .m_we(bus_we),
      .m_cyc(bus_cyc), .m_stb(bus_stb), .m_dat_r, .m_ack(bus_ack),
      .s_clk(sys_clk), .s_rst(sys_rst), .s_adr(ctrl_adr), .s_dat_w(ctrl_dat_w),
      .s_sel(ctrl_sel), .s_we(ctrl_we), .s_cyc(ctrl_cyc), .s_stb(ctrl_stb),
      .s_dat_r(ctrl_dat_r), .s_ack(ctrl_ack)
    );
  end else begin : noctrlbus
    // No EXT_IO window: the control bus is not wired.
    assign ctrl_adr = '0;
    assign ctrl_dat_w = '0;
    assign ctrl_sel = '0;
    assign ctrl_we = 1'b0;
    assign ctrl_cyc = 1'b0;
    assign ctrl_stb = 1'b0;
    assign HREADYCtrl = 1'b1;
    assign HRESPCtrl = 1'b0;
    assign HRDATACtrl = '0;
  end

  wallypipelinedsoc #(P) soc (
    .clk(wally_clk),
    .reset_ext(!resetn | wally_rst | (~init_by_wally & ~ddr_ready)),
    .reset,
    .HRDATAEXT,
    .HREADYEXT,
    .HRESPEXT,
    .HSELEXT,
    .ExternalStall(1'b0),
    .HCLK,
    .HRESETn,
    .HADDR,
    .HWDATA,
    .HWSTRB,
    .HWRITE,
    .HSIZE,
    .HBURST,
    .HPROT,
    .HTRANS,
    .HMASTLOCK,
    .HREADY,
    .TIMECLK(wally_clk),
    .GPIOIN,
    .GPIOOUT,
    .GPIOEN,
    .UARTSin,
    .UARTSout(wally_uart_tx),
    .SPIIn(1'b0),
    .SPIOut,
    .SPICS,
    .SPICLK,
    .SDCIn,
    .SDCCmd,
    .SDCCS(SDCCSin),
    .SDCCLK,
    .PWMGPIO
  );

endmodule
