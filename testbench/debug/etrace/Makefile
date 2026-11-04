# Instruction trace (docs/trace.md): the test program for RV32 and RV64, and its check.
#   make                # build etracetest32_r0.elf and etracetest64_r0.elf
#   make check          # run them on trace_rv32gc and debug_rv64gc, then check with etracecheck.py
#                       # the packets that the program reads back from the RAM sink: decoded by
#                       # etracedecode.py, they give the program counters that the hart retired
#   make check ETRACE_SPEC=<riscv-trace-spec clone>   # also against the reference flow, byte for byte
#   make check RESYNC_MAX=2   # another resynchronization period
#   make check-harts    # the same on SoCs with NHARTS (2) harts that trace at once, debug_rv32imc
#                       # and debug_rv64gc_nocache (etrace_tb.sv): each hart is checked
# Needs $WALLY (source setup.sh).

LINK  = $(WALLY)/examples/link/link.ld
CC    = riscv64-unknown-elf-gcc -g -nostdlib -nostartfiles -T$(LINK)
WORK ?= $(WALLY)/sim/verilator/wkdir/etrace
# A sync packet at least every 2^(RESYNC_MAX+4) packets
RESYNC_MAX ?= 0
NHARTS ?= 2
# Parallel C++ compilations of a SoC: see testbench/debug/Makefile
JOBS ?= 3
export ETRACE_SPEC

.PHONY: all check check-harts clean
# The program sets trTeInstSyncMax itself: one ELF per RESYNC_MAX
ELF32 = etracetest32_r$(RESYNC_MAX).elf
ELF64 = etracetest64_r$(RESYNC_MAX).elf
all: $(ELF32) $(ELF64)

$(ELF32): etracetest.S
	$(CC) -march=rv32imc_zicsr -mabi=ilp32 -DRESYNC_MAX=$(RESYNC_MAX) -o $@ $<

$(ELF64): etracetest.S
	$(CC) -march=rv64imc_zicsr -mabi=lp64 -DRESYNC_MAX=$(RESYNC_MAX) -o $@ $<

# Run a program with the trace dumped, then check the trace: $(1) configuration, $(2) XLEN
define check
	@mkdir -p $(WORK)
	wsim $(1) $(CURDIR)/etracetest$(2)_r$(RESYNC_MAX).elf --sim verilator --args "+EtraceCsv=$(WORK)/etracetest$(2).csv +EtracePackets=$(WORK)/etracetest$(2).packets" \
	  > $(WORK)/etracetest$(2).log 2>&1 || (tail -20 $(WORK)/etracetest$(2).log; false)
	python3 $(CURDIR)/etracecheck.py --csv $(WORK)/etracetest$(2).csv --elf $(CURDIR)/etracetest$(2)_r$(RESYNC_MAX).elf --xlen $(2) --resync-max $(RESYNC_MAX) \
	  --rtl-packets $(WORK)/etracetest$(2).packets
endef

check: all
	$(call check,trace_rv32gc,32)
	$(call check,debug_rv64gc,64)

# Build etrace_tb for $(1) with NHARTS harts, run the program for XLEN $(2) on it, then check the
# trace of each hart
SOURCES = $(WALLY)/src/cvw.sv $(shell find $(WALLY)/src -name '*.sv' ! -name cvw.sv)
HARTWORK = $(WORK)/$(1)-$(NHARTS)harts
HARTELF  = $(CURDIR)/etracetest$(2)_r$(RESYNC_MAX).elf
define checkharts
	@mkdir -p $(HARTWORK)
	@echo "Building etrace_tb for $(1) with $(NHARTS) harts (log in $(HARTWORK)/build.log)"
	@verilator --binary --timing -j $(JOBS) -GNHARTS=$(NHARTS) -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  -I$(WALLY)/config/shared -I$(WALLY)/config/deriv/$(1) --top-module etrace_tb -Mdir $(HARTWORK) \
	  $(SOURCES) $(WALLY)/testbench/common/etracedump.sv $(CURDIR)/etrace_tb.sv $(CURDIR)/../getenvval.cpp > $(HARTWORK)/build.log 2>&1 \
	  || (grep -E "%Error|error:" $(HARTWORK)/build.log | head -20; false)
	$(MAKE) -s -f $(WALLY)/testbench/Makefile WALLY=$(WALLY) $(HARTELF).memfile
	$(HARTWORK)/Vetrace_tb +MemFile=$(HARTELF).memfile \
	  +Tohost=$$(riscv64-unknown-elf-nm $(HARTELF) | awk '$$3 == "tohost" {print $$1}') \
	  +Results=$$(riscv64-unknown-elf-nm $(HARTELF) | awk '$$3 == "results" {print $$1}') \
	  +EtraceCsv=$(HARTWORK)/etracetest.csv +EtracePackets=$(HARTWORK)/etracetest.packets \
	  | tee $(HARTWORK)/sim.log
	@grep -q "SUCCESS! All tests ran without failures." $(HARTWORK)/sim.log
	@for h in $$(seq 0 $$(($(NHARTS) - 1))); do echo "== hart $$h"; \
	  python3 $(CURDIR)/etracecheck.py --csv $(HARTWORK)/etracetest.csv.h$$h --elf $(HARTELF) --xlen $(2) \
	    --resync-max $(RESYNC_MAX) --rtl-packets $(HARTWORK)/etracetest.packets.h$$h || exit 1; done
endef

check-harts: all
	$(call checkharts,debug_rv32imc,32)
	$(call checkharts,debug_rv64gc_nocache,64)

clean:
	rm -f etracetest*.elf*
