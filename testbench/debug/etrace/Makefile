# Instruction trace (docs/trace.md): the test program for RV32 and RV64, and its check against
# the E-Trace reference flow.
#   make                # build etracetest32_r0.elf and etracetest64_r0.elf
#   make check          # run them on trace_rv32gc and debug_rv64gc, then check the trace and the
#                       # packets that the program reads back from the RAM sink with
#                       # etracecheck.py (needs ETRACE_SPEC: a clone of riscv-trace-spec)
#   make check RESYNC_MAX=2   # another resynchronization period
# Needs $WALLY (source setup.sh).

LINK  = $(WALLY)/examples/link/link.ld
CC    = riscv64-unknown-elf-gcc -g -nostdlib -nostartfiles -T$(LINK)
WORK ?= $(WALLY)/sim/verilator/wkdir/etrace
# A sync packet at least every 2^(RESYNC_MAX+4) packets
RESYNC_MAX ?= 0
export ETRACE_SPEC

.PHONY: all check clean
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

clean:
	rm -f etracetest*.elf*
