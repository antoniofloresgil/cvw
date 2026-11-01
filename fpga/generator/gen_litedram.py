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
import re
import shutil
from pathlib import Path

from litedram.core import LiteDRAMCore
from litedram.frontend.wishbone import LiteDRAMWishbone2Native
from litedram.gen import LiteDRAMCore as StandaloneCore
from litedram.gen import get_wishbone_user_port_ios
from litedram.modules import MT41K256M16
from litedram.phy.s7ddrphy import A7DDRPHY
from litex.build.generic_platform import Pins
from litex.build.xilinx import XilinxPlatform
from litex.gen import LiteXModule
from litex.soc.cores.clock import S7IDELAYCTRL, S7MMCM, S7PLL
from litex.soc.integration.builder import Builder
from litex.soc.interconnect import wishbone
from litex_boards.platforms import digilent_nexys_video
from migen import ClockDomain, ClockDomainsRenamer, ClockSignal, ResetSignal, Signal


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


def add_wally_port(core, platform, data_width, clk_freq):
    """Attach Wally's Wishbone port in its own clock domain.

    The PLL gets one more output for Wally, and the crossbar port crosses into
    it through LiteDRAM's asynchronous FIFOs (LiteDRAMNativePortCDC).  Wally is
    held in reset until DDR initialization completes, so the port needs no
    block_until_ready gating.
    """
    core.cd_wally = ClockDomain()
    core.crg.pll.create_clkout(core.cd_wally, clk_freq)
    port = core.sdram.crossbar.get_port(data_width=data_width, clock_domain="wally")
    wb = wishbone.Interface(data_width=port.data_width, adr_width=port.address_width,
                            addressing="word")
    core.wally_wb2native = ClockDomainsRenamer("wally")(LiteDRAMWishbone2Native(wb, port))
    platform.add_extension(get_wishbone_user_port_ios("wally", len(wb.adr), len(wb.dat_w)))
    platform.add_extension([("wally_clk", 0, Pins(1)), ("wally_rst", 0, Pins(1))])
    pads = platform.request("user_port_wally")
    core.comb += [
        wb.adr.eq(pads.adr), wb.dat_w.eq(pads.dat_w), pads.dat_r.eq(wb.dat_r),
        wb.sel.eq(pads.sel), wb.cyc.eq(pads.cyc), wb.stb.eq(pads.stb),
        pads.ack.eq(wb.ack), wb.we.eq(pads.we), pads.err.eq(wb.err),
        platform.request("wally_clk").eq(ClockSignal("wally")),
        platform.request("wally_rst").eq(ResetSignal("wally")),
    ]


def main():
    parser = argparse.ArgumentParser(description="Generate LiteDRAM DDR3 Verilog for CORE-V-Wally.")
    parser.add_argument("--toolchain", default="openxc7", choices=["openxc7", "vivado"],
                        help="Toolchain (selects PLL vs MMCM and constraint dialect).")
    parser.add_argument("--sys-clk-freq", default=40e6, type=float,
                        help="System clock frequency in Hz. This is the clock shared with the SoC.")
    parser.add_argument("--user-data-width", default=32, type=int,
                        help="Data width of Wally's Wishbone port (Wally's AHBW).")
    parser.add_argument("--user-clk-freq", default=None, type=float,
                        help="Clock for Wally and its Wishbone port, in Hz. By default Wally "
                             "shares the system clock; otherwise the PLL generates this clock "
                             "and the port crosses into it through asynchronous FIFOs.")
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
        user_ports={} if args.user_clk_freq else
                   {"wally": dict(type="wishbone", data_width=args.user_data_width,
                                  block_until_ready=True)},
    )
    core = StandaloneCore(platform, config, integrated_rom_size=0x10000,
                          integrated_sram_size=0x4000)
    if args.user_clk_freq:
        add_wally_port(core, platform, args.user_data_width, args.user_clk_freq)
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
            if path.name == "VexRiscv_Min.v":
                # Bring-up experiment: the CPU boots in RTL simulation, but
                # hardware issues its first data access at 0x8 instead of
                # 0x72a0. Isolate the forced BRAM register-file implementation.
                cpu_text = path.read_text()
                regfile_marker = '(* ram_style = "block" *) reg [31:0] RegFilePlugin_regFile'
                if cpu_text.count(regfile_marker) != 1:
                    raise RuntimeError("Unexpected VexRiscv register-file layout")
                cpu_text = cpu_text.replace(regfile_marker, regfile_marker.replace('"block"', '"distributed"'))
                (output / path.name).write_text(cpu_text)
    # The ROM reads the firmware image with $readmemh.  Rewrite the (relative)
    # paths to absolute ones *after* copying, so Yosys can find them regardless
    # of its working directory.
    text = (gateware / "litedram_core.v").read_text()
    # Word-address width of Wally's port, as generated in either clock mode.
    wb_adr_width = int(re.search(r"\[(\d+):0\] user_port_wally_adr", text).group(1)) + 1
    boot_words = (output / "litedram_core_rom.init").read_text().split()
    boot_checks = "\n".join(
        f"                30'h{index:x}: if (litedramcore_ibus_dat_r != 32'h{word}) debug_cpu_data[3] <= 1'b1;"
        for index, word in enumerate(boot_words[:0x114 // 4])
    )
    for source in output.glob("*.init"):
        text = text.replace('"' + source.name + '"', '"' + str(source) + '"')
    # Bring-up diagnostic: expose a sticky bit that latches once the service CPU
    # writes its SRAM (the BIOS clears .bss and builds its stack there, so it
    # only asserts when real firmware is executing).
    port_marker = "\n);"
    if "module litedram_core" not in text.split(port_marker, 1)[0] or text.count("endmodule") != 1:
        raise RuntimeError("Unexpected LiteDRAM module layout; cannot inject CPU diagnostics")
    text = text.replace(
        port_marker,
        ",\n"
        "    output reg           debug_cpu_active = 1'b0,\n"
        "    output wire [3:0]    debug_cpu_bus,\n"
        "    output reg [3:0]     debug_cpu_boot = 4'b0,\n"
        "    output reg [3:0]     debug_cpu_data = 4'b0,\n"
        "    output reg [3:0]     debug_cpu_copy = 4'b0,\n"
        "    output reg [31:0]    debug_first_data_addr = 32'b0\n);", 1)
    text = text.replace(
        "endmodule",
        "reg [2:0] debug_bus_seen = 3'b0;\n"
        "reg debug_first_data_seen = 1'b0;\n"
        "assign debug_cpu_bus = {debug_bus_seen, sys_rst | litedramcore_reset};\n"
        "always @(posedge sys_clk) begin\n"
        "    if (sys_rst) debug_bus_seen <= 3'b0;\n"
        "    else begin\n"
        "        if (litedramcore_ibus_cyc & litedramcore_ibus_stb) begin\n"
        "            debug_bus_seen[0] <= 1'b1;\n"
        "            if (litedramcore_ibus_ack) debug_bus_seen[1] <= 1'b1;\n"
        "            if (litedramcore_ibus_err) debug_bus_seen[2] <= 1'b1;\n"
        "        end\n"
        "    end\n"
        "end\n"
        "always @(posedge sys_clk) begin\n"
        "    if (sys_rst) begin\n"
        "        debug_cpu_boot <= 4'b0;\n"
        "        debug_cpu_data <= 4'b0;\n"
        "        debug_cpu_copy <= 4'b0;\n"
        "        debug_first_data_seen <= 1'b0;\n"
        "        debug_first_data_addr <= 32'b0;\n"
        "    end else begin\n"
        "        if (litedramcore_ibus_cyc & litedramcore_ibus_stb & litedramcore_ibus_ack) begin\n"
        "            if (litedramcore_ibus_adr == 0) begin\n"
        "                debug_cpu_boot[0] <= 1'b1;\n"
        "                if (litedramcore_ibus_dat_r == 32'h0b00006f) debug_cpu_boot[1] <= 1'b1;\n"
        "            end\n"
        "            if (litedramcore_ibus_adr == 30'h2c) begin\n"
        "                debug_cpu_boot[2] <= 1'b1;\n"
        "            end\n"
        "            case (litedramcore_ibus_adr)\n"
        + boot_checks + "\n"
        "            endcase\n"
        "            if (litedramcore_ibus_adr == 30'h8) debug_cpu_data[2] <= 1'b1;\n"
        "        end\n"
        "        if (litedramcore_dbus_cyc & litedramcore_dbus_stb) begin\n"
        "            if (!debug_first_data_seen) begin\n"
        "                debug_first_data_addr <= {litedramcore_dbus_adr, 2'b0};\n"
        "                debug_first_data_seen <= 1'b1;\n"
        "            end\n"
        "            debug_cpu_boot[3] <= 1'b1;\n"
        "            if (litedramcore_dbus_ack) debug_cpu_data[0] <= 1'b1;\n"
        "            if (litedramcore_dbus_err) debug_cpu_data[1] <= 1'b1;\n"
        "            if (!litedramcore_dbus_we & (litedramcore_dbus_adr == 30'h1ca8)) begin\n"
        "                debug_cpu_copy[0] <= 1'b1;\n"
        "                if (litedramcore_dbus_ack) debug_cpu_copy[1] <= 1'b1;\n"
        "            end\n"
        "            if (litedramcore_dbus_we & (litedramcore_dbus_adr == 30'h4000000)) begin\n"
        "                debug_cpu_copy[2] <= 1'b1;\n"
        "                if (litedramcore_dbus_ack) debug_cpu_copy[3] <= 1'b1;\n"
        "            end\n"
        "        end\n"
        "    end\n"
        "end\n"
        "always @(posedge sys_clk)\n"
        "    if (sys_rst) debug_cpu_active <= 1'b0;\n"
        "    else if (|litedramcore_ram_we) debug_cpu_active <= 1'b1;\n\n"
        "endmodule")
    (output / "litedram_core.v").write_text(text)
    dw = args.user_data_width
    if args.user_clk_freq:
        wally_clock = ".user_clk(sys_clk), .user_rst(sys_rst), .wally_clk(wally_clk), .wally_rst(wally_rst),"
        wrapper_comment = "// Generated wrapper: Wally runs on wally_clk; DDR and the service CPU on sys_clk."
        wally_clock_assigns = ""
    else:
        wally_clock = ".user_clk(sys_clk), .user_rst(sys_rst),"
        wrapper_comment = "// Generated wrapper: one sys clock for DDR, service CPU, and Wally."
        wally_clock_assigns = "  assign wally_clk = sys_clk;\n  assign wally_rst = sys_rst;\n"
    (output / "litedram_ddr.v").write_text(f"""
{wrapper_comment}
module litedram_ddr (
  input wire clk100, cpu_reset_n, uart_rx,
  output wire sys_clk, sys_rst, wally_clk, wally_rst, init_done, init_error, uart_tx,
  output wire debug_cpu_active,
  output wire [3:0] debug_cpu_bus,
  output wire [3:0] debug_cpu_boot, debug_cpu_data,
  output wire [3:0] debug_cpu_copy,
  output wire [31:0] debug_first_data_addr,
  output wire [14:0] ddram_a,
  output wire [2:0] ddram_ba,
  output wire ddram_cas_n, ddram_cke, ddram_clk_n, ddram_clk_p,
  output wire [1:0] ddram_dm,
  inout wire [15:0] ddram_dq,
  inout wire [1:0] ddram_dqs_n, ddram_dqs_p,
  output wire ddram_odt, ddram_ras_n, ddram_reset_n, ddram_we_n,
  input wire [{wb_adr_width-1}:0] wb_adr,
  input wire [{dw-1}:0] wb_dat_w,
  output wire [{dw-1}:0] wb_dat_r,
  input wire [{dw//8-1}:0] wb_sel,
  input wire wb_we, wb_cyc, wb_stb,
  output wire wb_ack, wb_err
);
{wally_clock_assigns}  // The board has no power-on-reset circuit, but the LiteX core expects an
  // active-high reset pulse at startup. Hold reset for ~10 ms after
  // configuration (or while the CPU reset button is pressed).
  reg [19:0] por_cnt = 20'd0;
  wire por_rst = (por_cnt != 20'hFFFFF);
  always @(posedge clk100) if (por_rst) por_cnt <= por_cnt + 1'b1;

  litedram_core core (
    .clk(clk100), .rst(por_rst | ~cpu_reset_n),
    {wally_clock} .pll_locked(),
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
    .user_port_wally_err(wb_err), .debug_cpu_active(debug_cpu_active),
    .debug_cpu_bus(debug_cpu_bus), .debug_cpu_boot(debug_cpu_boot),
    .debug_cpu_data(debug_cpu_data), .debug_cpu_copy(debug_cpu_copy),
    .debug_first_data_addr(debug_first_data_addr)
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
