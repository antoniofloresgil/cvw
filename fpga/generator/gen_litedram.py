#!/usr/bin/env python3
"""
gen_litedram.py

Generate standalone Verilog for the LiteDRAM DDR3 subsystem used by the
CORE-V-Wally open-source FPGA flow.  This replaces Vivado's MIG so that the
whole design can be built with Yosys and nextpnr-xilinx.

Only the DDR subsystem is generated (clocking, PHY, LiteDRAM controller and a
Wishbone slave port).  No CPU, no SoC bus, and no CSR interconnect are emitted.
The Wishbone slave becomes top-level ports of the generated module and is the
attachment point for Wally's uncore bridge.

A component of the CORE-V-WALLY configurable RISC-V project.
https://github.com/openhwfoundation/cvw

SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""

import argparse
import os
import shutil
from pathlib import Path

from litedram.core import LiteDRAMCore
from litedram.frontend.wishbone import LiteDRAMWishbone2Native
from litedram.gen import LiteDRAMCore as StandaloneCore
from litedram.modules import MT41K256M16
from litedram.phy.s7ddrphy import A7DDRPHY
from litex.build.xilinx import XilinxPlatform
from litex.gen import LiteXModule
from litex.soc.cores.clock import S7IDELAYCTRL, S7MMCM, S7PLL
from litex.soc.integration.builder import Builder
from litex.soc.interconnect import wishbone
from litex_boards.platforms import digilent_nexys_video
from migen import ClockDomain, Signal


class DDRSubsystem(LiteXModule):
    """LiteDRAM DDR3 subsystem (clocking + PHY + controller + Wishbone slave)."""
    def __init__(self, platform, sys_clk_freq=100e6, with_wishbone=True, toolchain="openxc7"):
        self.sys_clk_freq = sys_clk_freq
        self.reset = Signal()

        # Platform IOs (requested once and kept for top-level export).
        self.clk100 = clk100 = platform.request("clk100")
        self.rst_n  = rst_n  = platform.request("cpu_reset_n")
        self.ddram  = ddram  = platform.request("ddram")

        # Clock domains required by the DDR PHY.
        self.cd_sys       = ClockDomain()
        self.cd_sys4x     = ClockDomain()
        self.cd_sys4x_dqs = ClockDomain()
        self.cd_idelay    = ClockDomain()

        # PLL / MMCM.  The open-source toolchain supports the S7PLL; Vivado
        # prefers the MMCM.
        if toolchain == "vivado":
            self.pll = pll = S7MMCM(speedgrade=-1)
        else:
            self.pll = pll = S7PLL(speedgrade=-1)
        self.comb += pll.reset.eq(~rst_n | self.reset)
        pll.register_clkin(clk100, 100e6)
        pll.create_clkout(self.cd_sys,       sys_clk_freq)
        pll.create_clkout(self.cd_sys4x,     4 * sys_clk_freq)
        pll.create_clkout(self.cd_sys4x_dqs, 4 * sys_clk_freq, phase=90)
        pll.create_clkout(self.cd_idelay,    200e6)
        self.idelayctrl = S7IDELAYCTRL(self.cd_idelay)

        # DDR3 PHY.
        self.ddrphy = ddrphy = A7DDRPHY(
            ddram,
            memtype      = "DDR3",
            nphases      = 4,
            sys_clk_freq = sys_clk_freq)

        # SP / DDR3 module (Nexys Video: 256M x 16).
        module = MT41K256M16(sys_clk_freq, "1:4")

        # LiteDRAM controller + crossbar.
        self.sdram = sdram = LiteDRAMCore(
            phy             = ddrphy,
            geom_settings   = module.geom_settings,
            timing_settings = module.timing_settings,
            clk_freq        = sys_clk_freq)

        # Wishbone slave: the bridge to Wally's AHB uncore attaches here.
        if with_wishbone:
            port = sdram.crossbar.get_port(data_width=32)
            self.wb = wb = wishbone.Interface(
                data_width = port.data_width,
                adr_width  = port.address_width,
                addressing = "word")
            self.submodules += LiteDRAMWishbone2Native(wb, port)


def main():
    parser = argparse.ArgumentParser(description="Generate LiteDRAM DDR3 Verilog for CORE-V-Wally.")
    parser.add_argument("--toolchain", default="openxc7", choices=["openxc7", "vivado"],
                        help="Toolchain (selects PLL vs MMCM and constraint dialect).")
    parser.add_argument("--sys-clk-freq", default=40e6, type=float,
                        help="System clock frequency in Hz. This is the clock shared with the SoC.")
    parser.add_argument("--output-dir", default=os.path.join(os.path.dirname(__file__), "opensource-litedram"),
                        help="Directory for the generated gateware.")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    # Use the official standalone generator: its service CPU executes the
    # upstream JEDEC/leveling routines through the PHY/DFII CSRs. Raw
    # LiteDRAMCore does not perform this software-controlled initialization.
    output = Path(args.output_dir).resolve()
    platform = XilinxPlatform("xc7a200tsbg484-1", io=[], toolchain=args.toolchain)
    config = dict(
        cpu="vexriscv", cpu_variant="minimal", uart="rs232", speedgrade=-1,
        memtype="DDR3", sdram_module=MT41K256M16, sdram_module_nb=2,
        sdram_rank_nb=1, sdram_phy=A7DDRPHY, input_clk_freq=100e6,
        sys_clk_freq=args.sys_clk_freq, iodelay_clk_freq=200e6, cmd_latency=0,
        user_ports={"wally": dict(type="wishbone", data_width=32,
                                  block_until_ready=True)},
    )
    core = StandaloneCore(platform, config, integrated_rom_size=0x10000,
                          integrated_sram_size=0x4000)
    builder = Builder(core, output_dir=str(output / "init"),
                      compile_gateware=False, compile_software=True,
                      csr_csv=str(output / "csr.csv"))
    builder.build(build_name="litedram_core", run=False)
    # Keep the CPU Verilog and ROM initialization beside the generated core.
    gateware = output / "init" / "gateware"
    for source in gateware.glob("*.init"):
        shutil.copy2(source, output / source.name)
    for source, *_ in platform.sources:
        path = Path(source)
        if path.suffix in (".v", ".sv"):
            shutil.copy2(path, output / path.name)
    # The ROM reads the firmware image with $readmemh.  Rewrite the (relative)
    # paths to absolute ones *after* copying, so Yosys can find them regardless
    # of its working directory.
    text = (gateware / "litedram_core.v").read_text()
    for source in output.glob("*.init"):
        text = text.replace('"' + source.name + '"', '"' + str(source) + '"')
    # Bring-up diagnostic: expose a sticky bit that latches once the service CPU
    # writes its SRAM (the BIOS clears .bss and builds its stack there, so it
    # only asserts when real firmware is executing).
    text = text.replace(
        "    output wire          user_rst\n);",
        "    output wire          user_rst,\n"
        "    output wire          debug_cpu_active\n);")
    text = text.replace(
        "endmodule",
        "reg debug_cpu_active = 1'b0;\n"
        "always @(posedge sys_clk)\n"
        "    if (sys_rst) debug_cpu_active <= 1'b0;\n"
        "    else if (|litedramcore_ram_we) debug_cpu_active <= 1'b1;\n\n"
        "endmodule")
    (output / "litedram_core.v").write_text(text)
    (output / "litedram_ddr.v").write_text("""
// Generated wrapper: one sys clock for DDR, service CPU, and Wally.
module litedram_ddr (
  input wire clk100, cpu_reset_n, uart_rx,
  output wire sys_clk, sys_rst, init_done, init_error, uart_tx,
  output wire debug_cpu_active,
  output wire [14:0] ddram_a,
  output wire [2:0] ddram_ba,
  output wire ddram_cas_n, ddram_cke, ddram_clk_n, ddram_clk_p,
  output wire [1:0] ddram_dm,
  inout wire [15:0] ddram_dq,
  inout wire [1:0] ddram_dqs_n, ddram_dqs_p,
  output wire ddram_odt, ddram_ras_n, ddram_reset_n, ddram_we_n,
  input wire [26:0] wb_adr,
  input wire [31:0] wb_dat_w,
  output wire [31:0] wb_dat_r,
  input wire [3:0] wb_sel,
  input wire wb_we, wb_cyc, wb_stb,
  output wire wb_ack, wb_err
);
  // The board has no power-on-reset circuit, but the LiteX core expects an
  // active-high reset pulse at startup. Hold reset for ~10 ms after
  // configuration (or while the CPU reset button is pressed).
  reg [19:0] por_cnt = 20'd0;
  wire por_rst = (por_cnt != 20'hFFFFF);
  always @(posedge clk100) if (por_rst) por_cnt <= por_cnt + 1'b1;

  litedram_core core (
    .clk(clk100), .rst(por_rst | ~cpu_reset_n),
    .user_clk(sys_clk), .user_rst(sys_rst), .pll_locked(),
    .init_done(init_done), .init_error(init_error),
    .uart_rx(uart_rx), .uart_tx(uart_tx),
    .ddram_a(ddram_a), .ddram_ba(ddram_ba), .ddram_cs_n(),
    .ddram_cas_n(ddram_cas_n), .ddram_cke(ddram_cke),
    .ddram_clk_n(ddram_clk_n), .ddram_clk_p(ddram_clk_p),
    .ddram_dm(ddram_dm), .ddram_dq(ddram_dq),
    .ddram_dqs_n(ddram_dqs_n), .ddram_dqs_p(ddram_dqs_p),
    .ddram_odt(ddram_odt), .ddram_ras_n(ddram_ras_n),
    .ddram_reset_n(ddram_reset_n), .ddram_we_n(ddram_we_n),
    .user_port_wally_adr(wb_adr), .user_port_wally_dat_w(wb_dat_w),
    .user_port_wally_dat_r(wb_dat_r), .user_port_wally_sel(wb_sel),
    .user_port_wally_we(wb_we), .user_port_wally_cyc(wb_cyc),
    .user_port_wally_stb(wb_stb), .user_port_wally_ack(wb_ack),
    .user_port_wally_err(wb_err), .debug_cpu_active(debug_cpu_active)
  );
endmodule
""")

    # 2) Constraints: a pin-only elaboration is enough to make the platform
    #    emit the DDR pin and timing constraints (they are independent of the
    #    Wishbone, which stays inside the bitstream).
    platform2 = digilent_nexys_video.Platform(toolchain=args.toolchain)
    ddr2      = DDRSubsystem(platform2, sys_clk_freq=args.sys_clk_freq,
                             toolchain=args.toolchain)
    platform2.build(ddr2, build_dir=args.output_dir, run=False)

    # platform.build writes its own pad-only Verilog/synthesis files; keep only
    # the constraints and give them a name matching the exported module.
    os.replace(os.path.join(args.output_dir, "top.xdc"),
               os.path.join(args.output_dir, "litedram_ddr.xdc"))
    for stale in ("top.v", "top.ys", "build_top.sh"):
        stale_path = os.path.join(args.output_dir, stale)
        if os.path.exists(stale_path):
            os.remove(stale_path)
    print(f"Generated LiteDRAM gateware in {args.output_dir}")


if __name__ == "__main__":
    main()
