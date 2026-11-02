# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Open ASIC flow for Wally with LibreLane (Yosys + slang, OpenROAD, Magic, KLayout, Netgen).
#
#   make CONFIG=syn_rv32imc              full flow: synthesis to GDS, DRC and LVS
#   make synth CONFIG=syn_rv32imc        synthesis only
#   make check CONFIG=sramtest           DRC check of the newest run of a design with SRAM macros
#   make sramsim                         sram/ram1p1rwbe.sv with the macro's model against Wally's RAM
#
# CONFIG is a Wally configuration, whose inputs gen_config.py writes, or a directory here with
# its own config.json (sramtest).  Designs with IHP SRAM macros turn off ERROR_ON_KLAYOUT_DRC,
# and `make` runs check_drc.py after the flow instead (see that script).
#
# The tools come from LibreLane's Nix environment, pinned by LIBRELANE; the PDK version is
# pinned by that LibreLane release and downloaded by ciel into ~/.ciel.  Results go to
# work/<CONFIG>/runs/.

WALLY        ?= $(abspath ../..)
CONFIG       ?= syn_rv32imc
PDK          ?= ihp-sg13g2
CLOCK_PERIOD ?= 30
LIBRELANE    ?= github:librelane/librelane/3.0.17
WORK         := work/$(CONFIG)
# The PDK version that LIBRELANE pins, as ciel installs it
IHP_PDK      ?= $(HOME)/.ciel/ciel/ihp-sg13g2/versions/c4b8b4e5e7a05f375cca3815d51b3a37721fbf5c/ihp-sg13g2
SRAM_MODELS  := $(IHP_PDK)/libs.ref/sg13g2_sram/verilog

NIX := nix develop $(LIBRELANE) --accept-flake-config --command

.PHONY: all synth check sramsim inputs clean
all: inputs
	cd $(WORK) && $(NIX) librelane --pdk $(PDK) config.json
	if grep -q '"MACROS"' $(WORK)/config.json; then $(MAKE) check; fi

synth: inputs
	cd $(WORK) && $(NIX) librelane --pdk $(PDK) --to Yosys.Synthesis config.json

check:
	cd $(WORK) && $(NIX) python3 $(CURDIR)/check_drc.py

sramsim:
	mkdir -p work/sramsim
	sed 's/^module ram1p1rwbe /module ram1p1rwbe_generic /' $(WALLY)/src/generic/mem/ram1p1rwbe.sv > work/sramsim/ram1p1rwbe_generic.sv
	cd work/sramsim && $(NIX) verilator --binary -j 8 --top-module ram1p1rwbe_tb -Wno-fatal -Wno-lint -Wno-style \
	  -I$(WALLY)/config/shared -I$(WALLY)/config/rv32imc $(WALLY)/src/cvw.sv $(WALLY)/src/generic/flop/flopen.sv \
	  ram1p1rwbe_generic.sv $(CURDIR)/sram/ram1p1rwbe.sv $(SRAM_MODELS)/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
	  $(SRAM_MODELS)/RM_IHPSG13_1P_1024x32_c2_bm_bist.v $(CURDIR)/sram/ram1p1rwbe_tb.sv $(CURDIR)/sram/getenvval.c
	work/sramsim/obj_dir/Vram1p1rwbe_tb | tee work/sramsim/sim.log
	grep -q PASS work/sramsim/sim.log

inputs:
ifneq ($(wildcard $(CONFIG)/config.json),)
	mkdir -p $(WORK) && cp $(CONFIG)/config.json $(WORK)/
else
	python3 gen_config.py --wally $(WALLY) --config $(CONFIG) --work $(WORK) --clock-period $(CLOCK_PERIOD)
endif

clean:
	rm -rf work
