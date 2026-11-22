###########################################
# Makefile for gsim (sim/gsim)
#
# Purpose: Build a gsim model of a Wally configuration and the C++ harness tb.cpp that runs ELFs on it, plus a
#          Verilator model of the same top (sim/gsim/gsimtop.sv) for comparison:
#            SystemVerilog --(Yosys + slang)--> JSON netlist --(yosys2firrtl.py)--> CHIRRTL --(gsim)--> C++
#
#   make CONFIG=rv32gc                 gsim model and harness: work/rv32gc/tb <elf> [max cycles]
#   make CONFIG=rv32gc verilator       the same top in Verilator: work/rv32gc/vl/tb
#   make ... RUN=$WALLY/sim/gsim/docker-run.sh GSIM_CXX=/usr/local/llvm/bin/clang++
#                                      run gsim and clang inside a Docker image that has them
#
# The design differs from src/ only where gsim needs it (sim/gsim/src): the register files write on the rising edge
# with a bypass instead of the falling edge, and the RAM/ROM models have no preload and no 0 initializer.  SPI is
# switched off (its controller has a falling-edge flop).  Both models of the same top run cycle for cycle alike.
#
# A component of the Wally configurable RISC-V project.
#
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
################################################################################################

CONFIG    ?= rv32gc
WORK      ?= $(WALLY)/sim/gsim/work/$(CONFIG)
YOSYS     ?= yosys
GSIM      ?= gsim
GSIM_CXX  ?= clang++
RUN       ?=
GSIM_FLAGS ?= --supernode-max-size=15 --cpp-max-size-KB=8192
CXXFLAGS  ?= -O3 -march=native
VERILATOR ?= verilator

GSIMDIR   = $(WALLY)/sim/gsim
CFGDIR    = $(firstword $(wildcard $(WALLY)/config/$(CONFIG) $(WALLY)/config/deriv/$(CONFIG)))
VARIANTS  = $(notdir $(wildcard $(GSIMDIR)/src/*.sv))
SOURCES   = $(WALLY)/src/cvw.sv $(GSIMDIR)/gsimtop.sv $(wildcard $(GSIMDIR)/src/*.sv) \
            $(filter-out $(WALLY)/src/cvw.sv $(addprefix %/,$(VARIANTS)), $(wildcard $(WALLY)/src/*/*.sv $(WALLY)/src/*/*/*.sv))
RAM       = gsimtop__DOT__dut__DOT__uncoregen__DOT__uncore__DOT__ram__DOT__ram__DOT__memory__DOT__ram__DOT__RAM

all: $(WORK)/tb

$(WORK)/config/config.vh: $(CFGDIR)/config.vh
	mkdir -p $(@D)
	sed 's/^localparam logic SPI_SUPPORTED = 1;/localparam logic SPI_SUPPORTED = 0;/' $< > $@

$(WORK)/wally.ys: $(WORK)/config/config.vh $(SOURCES) Makefile
	@echo "read_slang --std 1800-2017 --single-unit --ignore-timing --ignore-assertions -I $(WORK)/config \
	  -I $(WALLY)/config/shared -I $(WALLY)/src --top gsimtop $(SOURCES)" > $@
	@echo "hierarchy -top gsimtop; proc; flatten" >> $@
	@echo 'delete t:$$print t:$$check t:$$assert t:$$assume t:$$cover t:$$scopeinfo' >> $@
	@echo "opt; opt_mem; opt_mem_priority; opt_mem_feedback; memory_bmux2rom; opt_clean; memory_share -nowiden" >> $@
	@echo "opt_clean; stat; tee -o $(WORK)/scc.log scc; write_json $(WORK)/wally.json" >> $@

$(WORK)/wally.json: $(WORK)/wally.ys
	cd $(WALLY) && $(YOSYS) -m slang -q -l $(WORK)/yosys.log -s $<
	grep -q 'Found 0 SCCs.' $(WORK)/scc.log || { echo "combinational loops: $(WORK)/scc.log"; false; }

$(WORK)/wally.fir: $(WORK)/wally.json $(GSIMDIR)/yosys2firrtl.py
	python3 $(GSIMDIR)/yosys2firrtl.py $< $@

$(WORK)/model/gsimtop0.cpp: $(WORK)/wally.fir
	mkdir -p $(@D)
	$(RUN) $(GSIM) $(GSIM_FLAGS) --dir $(@D) $< > $(WORK)/gsim.log 2>&1 || { tail $(WORK)/gsim.log; false; }

$(WORK)/tb: $(WORK)/model/gsimtop0.cpp $(GSIMDIR)/tb.cpp
	$(RUN) $(GSIM_CXX) $(CXXFLAGS) -std=c++17 -DGSIM -fbracket-depth=2048 -Wno-parentheses-equality \
	  -I$(WORK)/model $(wildcard $(WORK)/model/gsimtop*.cpp) $(GSIMDIR)/tb.cpp -o $@

# the same top in Verilator, with the C++ optimization wsim uses
verilator: $(WORK)/vl/tb

$(WORK)/vl/tb: $(WORK)/config/config.vh $(SOURCES) $(GSIMDIR)/tb.cpp
	mkdir -p $(@D)
	printf '`verilator_config\npublic_flat_rw -module "ram1p1rwbe" -var "RAM"\n' > $(WORK)/vl/ram.vlt
	$(VERILATOR) --cc --Mdir $(@D) -Wno-fatal -Wno-lint -Wno-style --top-module gsimtop -I$(WORK)/config \
	  -I$(WALLY)/config/shared -I$(WALLY)/src $(WORK)/vl/ram.vlt $(SOURCES) > $(WORK)/vl/verilator.log
	$(MAKE) -C $(@D) -f Vgsimtop.mk OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2 Vgsimtop__ALL.a libverilated.a
	cd $(@D) && $(CXX) -O2 -std=c++17 -I. -I$$($(VERILATOR) --getenv VERILATOR_ROOT)/include \
	  -I$$($(VERILATOR) --getenv VERILATOR_ROOT)/include/vltstd -DVGSIM_RAM=$(RAM) $(GSIMDIR)/tb.cpp \
	  Vgsimtop__ALL.a libverilated.a -lpthread -o tb

.PHONY: all verilator
