# Tests of the JTAG debug port (src/debug) with Verilator, on configurations with DEBUG_SUPPORTED
# (config/derivlist.txt):
#   make                          # debug_tb.sv drives the JTAG pins itself: debug_rv32imc and debug_rv64gc
#   make CONFIGS=debug_rv64gc     # one configuration
#   make openocd                  # OpenOCD (openocd.cfg, openocd_test.tcl) on openocd_tb.sv through remote_bitbang
# Needs $WALLY (source setup.sh), the derivative configurations (derivgen.pl) and, for
# make openocd, OpenOCD 0.12 or later.

CONFIGS ?= debug_rv32imc debug_rv64gc
OPENOCD_CONFIG ?= debug_rv32imc
RBB_PORT ?= 9823
OPENOCD ?= openocd
WORK    ?= $(WALLY)/sim/verilator/wkdir/debug

SOURCES  = $(WALLY)/src/cvw.sv $(shell find $(WALLY)/src -name '*.sv' ! -name cvw.sv)
VFLAGS   = --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -I$(WALLY)/config/shared

.PHONY: all openocd $(CONFIGS)
all: $(CONFIGS)

# Build $(1) (the testbench top) for configuration $(2) in directory $(3)
define build
	@mkdir -p $(3)
	@echo "Building $(1) for $(2) (log in $(3)/build.log)"
	@verilator $(VFLAGS) --top-module $(1) -Mdir $(3) -I$(WALLY)/config/deriv/$(2) \
	  $(SOURCES) $(CURDIR)/$(1).sv $(CURDIR)/getenvval.cpp $(4) > $(3)/build.log 2>&1 \
	  || (grep -E "%Error|error:" $(3)/build.log | head -20; false)
endef

$(CONFIGS):
	$(call build,debug_tb,$@,$(WORK)/$@)
	@$(WORK)/$@/Vdebug_tb | tee $(WORK)/$@/sim.log
	@grep -q "SUCCESS! All tests ran without failures." $(WORK)/$@/sim.log

openocd:
	$(call build,openocd_tb,$(OPENOCD_CONFIG),$(WORK)/openocd-$(OPENOCD_CONFIG),$(CURDIR)/jtag_rbb.cpp)
	@$(WORK)/openocd-$(OPENOCD_CONFIG)/Vopenocd_tb +RBB_PORT=$(RBB_PORT) > $(WORK)/openocd-$(OPENOCD_CONFIG)/sim.log 2>&1 & \
	  sleep 2; \
	  $(OPENOCD) -f $(CURDIR)/openocd.cfg -c "remote_bitbang port $(RBB_PORT)" \
	    -f $(CURDIR)/openocd_test.tcl 2>&1 | tee $(WORK)/openocd-$(OPENOCD_CONFIG)/openocd.log; \
	  wait
	@grep -q "SUCCESS! All tests ran without failures." $(WORK)/openocd-$(OPENOCD_CONFIG)/openocd.log
