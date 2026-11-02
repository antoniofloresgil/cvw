# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Open ASIC flow for Wally with LibreLane (Yosys + slang, OpenROAD, Magic, KLayout, Netgen).
#
#   make CONFIG=syn_rv32imc              full flow: synthesis to GDS, DRC and LVS
#   make synth CONFIG=syn_rv32imc        synthesis only
#
# The tools come from LibreLane's Nix environment, pinned by LIBRELANE; the PDK version is
# pinned by that LibreLane release and downloaded by ciel into ~/.ciel.  Results go to
# work/<CONFIG>/runs/.

WALLY        ?= $(abspath ../..)
CONFIG       ?= syn_rv32imc
PDK          ?= ihp-sg13g2
CLOCK_PERIOD ?= 20
LIBRELANE    ?= github:librelane/librelane/3.0.17
WORK         := work/$(CONFIG)

NIX := nix develop $(LIBRELANE) --accept-flake-config --command

.PHONY: all synth inputs clean
all: inputs
	cd $(WORK) && $(NIX) librelane --pdk $(PDK) config.json

synth: inputs
	cd $(WORK) && $(NIX) librelane --pdk $(PDK) --to Yosys.Synthesis config.json

inputs:
	python3 gen_config.py --wally $(WALLY) --config $(CONFIG) --work $(WORK) --clock-period $(CLOCK_PERIOD)

clean:
	rm -rf work
