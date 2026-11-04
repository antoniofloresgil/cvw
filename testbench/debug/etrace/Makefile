# Instruction trace (docs/trace.md): the test program for RV32 and RV64, and its check against
# the E-Trace reference flow.
#   make                # build etracetest32.elf and etracetest64.elf
#   make check          # run them on trace_rv32gc and debug_rv64gc, then check the trace with
#                       # etracecheck.py (needs ETRACE_SPEC: a clone of riscv-trace-spec)
# Needs $WALLY (source setup.sh).

LINK  = $(WALLY)/examples/link/link.ld
CC    = riscv64-unknown-elf-gcc -g -nostdlib -nostartfiles -T$(LINK)
WORK ?= $(WALLY)/sim/verilator/wkdir/etrace
export ETRACE_SPEC

.PHONY: all check clean
all: etracetest32.elf etracetest64.elf

etracetest32.elf: etracetest.S
	$(CC) -march=rv32imc_zicsr -mabi=ilp32 -o $@ $<

etracetest64.elf: etracetest.S
	$(CC) -march=rv64imc_zicsr -mabi=lp64 -o $@ $<

# Run a program with the trace dumped, then check the trace: $(1) configuration, $(2) XLEN
define check
	@mkdir -p $(WORK)
	wsim $(1) $(CURDIR)/etracetest$(2).elf --sim verilator --args "+EtraceCsv=$(WORK)/etracetest$(2).csv" \
	  > $(WORK)/etracetest$(2).log 2>&1 || (tail -20 $(WORK)/etracetest$(2).log; false)
	python3 $(CURDIR)/etracecheck.py --csv $(WORK)/etracetest$(2).csv --elf $(CURDIR)/etracetest$(2).elf --xlen $(2)
endef

check: all
	$(call check,trace_rv32gc,32)
	$(call check,debug_rv64gc,64)

clean:
	rm -f etracetest32.elf etracetest64.elf
