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
  logic sys_clk;
  logic sys_rst, ddr_init_done, ddr_init_error, ddr_ready, ddr_cpu_active;
  logic init_uart_tx, wally_uart_tx;
  logic init_uart_tx_q, uart_start_seen;
  logic reset;
  logic [P.AHBW-1:0] HRDATAEXT;
  logic HREADYEXT, HRESPEXT;
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
  logic SPICLK, SDCCmd, SDCCLK;
  logic [3:0] SDCCS, PWMGPIO;
  logic [31:0] heartbeat;

  // Wishbone between the LiteDRAM DDR3 controller and the AHB bridge
  logic [26:0] wb_adr;
  logic [31:0] wb_dat_w, wb_dat_r;
  logic [3:0]  wb_sel;
  logic        wb_we, wb_cyc, wb_stb, wb_ack;
  logic wb_err;

  BUFGCTRL input_clock_buffer (
    .I0(default_100mhz_clk), .CE0(1'b1), .S0(1'b1), .O(clk100)
  );

  // LiteDRAM DDR3 subsystem.  It generates the system clock, which is shared
  // with the SoC so Wally and the DDR controller live in a single clock domain
  // (no clock-domain crossing on the memory bus).
  litedram_ddr litedram (
    .clk100, .cpu_reset_n(resetn), .sys_clk, .sys_rst,
    .init_done(ddr_init_done), .init_error(ddr_init_error),
    .debug_cpu_active(ddr_cpu_active),
    .uart_rx(UARTSin), .uart_tx(init_uart_tx),
    .ddram_a, .ddram_ba, .ddram_cas_n, .ddram_cke, .ddram_clk_n, .ddram_clk_p,
    .ddram_dm, .ddram_dq, .ddram_dqs_n, .ddram_dqs_p, .ddram_odt,
    .ddram_ras_n, .ddram_reset_n, .ddram_we_n,
    .wb_adr, .wb_dat_w, .wb_dat_r, .wb_sel, .wb_we, .wb_cyc, .wb_stb, .wb_ack,
    .wb_err
  );

  // The upstream initialization firmware owns DDR until JEDEC initialization,
  // leveling, and its memory test complete. Keep Wally in reset on failure.
  assign ddr_ready = ddr_init_done & ~ddr_init_error & ~sys_rst;
  assign UARTSout = ddr_ready ? wally_uart_tx : init_uart_tx;

  assign GPIOIN[31:4] = '0;
  assign GPIOIN[3:0] = GPI;

  always_ff @(posedge sys_clk or negedge resetn) begin
    if (!resetn) heartbeat <= '0;
    else heartbeat <= heartbeat + 1'b1;
  end

  // Temporary bring-up diagnostics on the user LEDs (LD0..LD4):
  //   LD0 = clk100 activity, LD1 = init_done, LD2 = init_error,
  //   LD3 = service CPU wrote SRAM (BIOS executing),
  //   LD4 = service CPU UART started a frame (BIOS printing).
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

  assign GPO = {uart_start_seen, ddr_cpu_active, ddr_init_error, ddr_init_done, led_cnt100[25]};

  // AHB -> Wishbone bridge for the external (DDR3) memory region at 0x40000000.
  ahbwishbonebridge #(.ADDR_WIDTH(29), .DATA_WIDTH(32)) extbridge (
    .HCLK(sys_clk), .HRESETn(~reset), .HSEL(HSELEXT),
    .HADDR(HADDR[28:0]), .HTRANS, .HWRITE, .HWDATA, .HWSTRB, .HREADY,
    .HREADYOUT(HREADYEXT), .HRDATA(HRDATAEXT), .HRESP(HRESPEXT),
    .wb_adr, .wb_dat_w, .wb_sel, .wb_we, .wb_cyc, .wb_stb, .wb_dat_r, .wb_ack
  );

  wallypipelinedsoc #(P) soc (
    .clk(sys_clk),
    .reset_ext(!resetn | ~ddr_ready),
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
    .TIMECLK(sys_clk),
    .GPIOIN,
    .GPIOOUT,
    .GPIOEN,
    .UARTSin,
    .UARTSout(wally_uart_tx),
    .SPIIn(1'b0),
    .SPIOut,
    .SPICS,
    .SPICLK,
    .SDCIn(1'b0),
    .SDCCmd,
    .SDCCS,
    .SDCCLK,
    .PWMGPIO
  );

endmodule
