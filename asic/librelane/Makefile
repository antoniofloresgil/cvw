# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Open ASIC flow for Wally with LibreLane (Yosys + slang, OpenROAD, Magic, KLayout, Netgen).
#
#   make CONFIG=syn_rv32imc              full flow: synthesis to GDS, DRC and LVS
#   make synth CONFIG=syn_rv32imc        synthesis only
#   make check CONFIG=sramtest           DRC check of the newest run of a design with SRAM macros
#   make sramsim                         sram/ram1p1rwbe.sv with the macro's model against Wally's RAM
#   make CONFIG=asic_soc_rv32imac         a chip: Wally's SoC in a pad ring (chip/), Chip flow
#   make chipsim                         cocotb test of that chip: boots a program from SPI flash,
#                                        over the UART and through JTAG
#   make boardsim                        the same chip on the netlist of the KiCad test board
#                                        (hardware/board/sim/; needs kicad-cli)
#   make PDK=ihp-sg13cmos5l CONFIG=...   the same in SG13CMOS5L (CMOS, 5 metals), in work/<CONFIG>-sg13cmos5l
#
# CONFIG is a Wally configuration, whose inputs gen_config.py writes, or a directory here with
# its own config.json (sramtest).  Designs with IHP SRAM macros turn off ERROR_ON_MAGIC_DRC,
# and `make` runs check_drc.py after the flow instead (see that script).
#
# The tools come from LibreLane's Nix environment, pinned by LIBRELANE.  PDK_VERSION is the IHP
# PDK that this LibreLane release pins (librelane/pdk_hashes.yaml), the first one with the SRAM
# rule exceptions for Magic (IHP-Open-PDK PR #863); `make pdk` downloads it with ciel into
# ~/.ciel without enabling it, and the flow reads it from there.  Results go to work/<CONFIG>/runs/.

WALLY        ?= $(abspath ../..)
CONFIG       ?= syn_rv32imc
PDK          ?= ihp-sg13g2
# With LibreLane 3.1 (Yosys 0.69, SYNTH_STRATEGY AREA 0) asic_rv32imc misses 30 ns by 6.8 ns in the
# slow corner, and the chips have a path from the PLIC through the trap logic to the 64-bit
# counters as long; 40 ns for every design until those paths are optimized.  The chips (asic_soc_*)
# add the debug triggers and the 32 KiB RAM, which put a path from the trigger comparators through
# the trap logic to the counters at -0.25 ns in the slow corner at 40 ns, and the 16 PMP entries a
# path from the address of the memory stage through the PMP comparators at -0.12 ns at 45 ns: 50 ns
# for them (20 MHz; the board's oscillator is 18.432 MHz)
ifneq (,$(findstring asic_soc_,$(CONFIG)))
CLOCK_PERIOD ?= 50
else
CLOCK_PERIOD ?= 40
endif
LIBRELANE    ?= github:librelane/librelane/3.1.0.dev4
# Runs in SG13CMOS5L go to their own work directories
SUFFIX       := $(if $(filter ihp-sg13g2,$(PDK)),,-$(PDK:ihp-%=%))
WORK         := work/$(CONFIG)$(SUFFIX)
PDK_VERSION  ?= 89d42ee6d2fd9b50b86a1aada6fee6673c3e6008
PDK_ROOT     ?= $(HOME)/.ciel/ciel/ihp-sg13/versions/$(PDK_VERSION)
IHP_PDK      := $(PDK_ROOT)/$(PDK)
SRAM_MODELS  := $(IHP_PDK)/libs.ref/$(PDK:ihp-%=%)_sram/verilog
# cocotb and the Verilator it runs with
OSS_CAD      ?= $(HOME)/riscv/oss-cad-suite

NIX := nix develop $(LIBRELANE) --accept-flake-config --command
LL  := $(NIX) librelane --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk

.PHONY: all synth check sramsim chipsim boardsim pdk inputs clean
all: inputs $(IHP_PDK)
	cd $(WORK) && $(LL) config.json
	if grep -q '"MACROS"' $(WORK)/config.json; then $(MAKE) check; fi

synth: inputs $(IHP_PDK)
	cd $(WORK) && $(LL) --to Yosys.Synthesis config.json

check:
	cd $(WORK) && $(NIX) python3 $(CURDIR)/check_drc.py

chipsim: $(IHP_PDK)
	$(MAKE) inputs CONFIG=asic_soc_rv32imac
	$(MAKE) -C chip/zephyr BUILD=build-sim OVERLAY=sim.overlay
	cd chip/test && IHP_PDK=$(IHP_PDK) WORK=$(CURDIR)/work/asic_soc_rv32imac$(SUFFIX) \
	  PATH=$(OSS_CAD)/bin:$$PATH tabbypy3 test_chip.py

boardsim: $(IHP_PDK)
	$(MAKE) inputs CONFIG=asic_soc_rv32imac
	cd $(WALLY)/hardware/board/sim && WALLY=$(WALLY) IHP_PDK=$(IHP_PDK) WORK=$(CURDIR)/work/asic_soc_rv32imac$(SUFFIX) \
	  PATH=$(OSS_CAD)/bin:$$PATH tabbypy3 test_board.py

pdk: $(IHP_PDK)
$(IHP_PDK):
	$(NIX) ciel fetch --pdk-family ihp-sg13 $(PDK_VERSION)

# The adapter's shapes: one 1024 x 32 macro, and the 32 KiB RAM of the chip in four 2048 x 32 banks
SRAM_DEPTHS ?= 1024 2048 8192
sramsim: $(IHP_PDK)
	mkdir -p work/sramsim
	sed 's/^module ram1p1rwbe /module ram1p1rwbe_generic /' $(WALLY)/src/generic/mem/ram1p1rwbe.sv > work/sramsim/ram1p1rwbe_generic.sv
	for d in $(SRAM_DEPTHS); do \
	  (cd work/sramsim && $(NIX) verilator --binary -j 8 --top-module ram1p1rwbe_tb -GDEPTH=$$d -Mdir obj_dir_$$d \
	    -Wno-fatal -Wno-lint -Wno-style -I$(WALLY)/config/shared -I$(WALLY)/config/rv32imc $(WALLY)/src/cvw.sv \
	    $(WALLY)/src/generic/flop/flopen.sv ram1p1rwbe_generic.sv $(CURDIR)/sram/ram1p1rwbe.sv \
	    $(SRAM_MODELS)/RM_IHPSG13_1P_core_behavioral_bm_bist.v $(SRAM_MODELS)/RM_IHPSG13_1P_1024x32_c2_bm_bist.v \
	    $(SRAM_MODELS)/RM_IHPSG13_1P_2048x32_c2_bm_bist.v $(CURDIR)/sram/ram1p1rwbe_tb.sv $(CURDIR)/sram/getenvval.c) || exit 1; \
	  work/sramsim/obj_dir_$$d/Vram1p1rwbe_tb | tee work/sramsim/sim_$$d.log; \
	  grep -q PASS work/sramsim/sim_$$d.log || exit 1; \
	done

inputs:
ifneq ($(filter asic_soc_%,$(CONFIG)),)
	$(MAKE) -C chip boot.mem
endif
ifneq ($(wildcard $(CONFIG)/config.json),)
	mkdir -p $(WORK) && cp $(CONFIG)/config.json $(WORK)/
else
	python3 gen_config.py --wally $(WALLY) --config $(CONFIG) --work $(WORK) --clock-period $(CLOCK_PERIOD) --pdk $(PDK)
endif

clean:
	rm -rf work
