# ddrinit: DDR3 initialization run by Wally (open-source FPGA flow, RV32
# fpgaopensource generated with --init-cpu none).
#
#   make                build build/ddrinit.elf and build/ddrinit.mem
#   make install        copy the image to fpga/src/boot.mem and data.mem
#                       (the IROM and DTIM preload files; back them up first)
#   make SKIP_INIT=1    only the memory test, for a build whose LiteDRAM still
#                       has the service CPU (--init-cpu vexriscv)
#
# The LiteDRAM headers (csr.h, sdram_phy.h, ...) come from the generator's
# output, so run `gen-litedram.sh --init-cpu none` (or the open build with
# INIT_CPU=none) first.  liblitedram is compiled from the installed LiteX
# sources; nothing from LiteX is copied into the repository.

LITEX_VENV   ?= $(RISCV)/litex-venv
LITEX_SW     ?= $(shell $(LITEX_VENV)/bin/python -c 'import litex, os; print(os.path.dirname(litex.__file__))')/soc/software
GENERATED    ?= ../generator/opensource-litedram/init/software/include

# fpgaopensource memory map and clock (config/derivlist.txt, fpga/generator/Makefile)
CSR_BASE      ?= 0x48000000
MAIN_RAM_BASE ?= 0x40000000
UART_BASE     ?= 0x10000000
UART_PRESCALE ?= 1
SYSTEMCLOCK   ?= 40000000
BAUD          ?= 115200

CC      := riscv64-unknown-elf-gcc
OBJCOPY := riscv64-unknown-elf-objcopy
OBJDUMP := riscv64-unknown-elf-objdump
SIZE    := riscv64-unknown-elf-size

ARCH    := -march=rv32imc_zicsr -mabi=ilp32
DEFINES := -DCSR_BASE=$(CSR_BASE)L -DMAIN_RAM_BASE=$(MAIN_RAM_BASE)L \
           -DMAIN_RAM_BASE_VA=$(MAIN_RAM_BASE)L -DSDRAM_TEST_DISABLE \
           -DUART_BASE=$(UART_BASE) -DUART_PRESCALE=$(UART_PRESCALE) \
           -DSYSTEMCLOCK=$(SYSTEMCLOCK) -DBAUD=$(BAUD) \
           $(if $(filter 1,$(SKIP_INIT)),-DDDRINIT_SKIP)
CFLAGS  := $(ARCH) -Os -g -ffreestanding -fno-common -ffunction-sections -fdata-sections \
           -Wall -Wno-unused-function $(DEFINES) \
           -Ishim -I$(GENERATED) -I$(LITEX_SW)/include -I$(LITEX_SW)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -Wl,--gc-sections -T link.ld

SOURCES := start.S main.c printf.c \
           $(LITEX_SW)/liblitedram/sdram.c $(LITEX_SW)/liblitedram/accessors.c

all: build/ddrinit.mem

build/ddrinit.elf: $(SOURCES) link.ld shim/system.h $(GENERATED)/generated/csr.h FORCE | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) -lgcc
	$(OBJDUMP) -d $@ > build/ddrinit.objdump
	$(SIZE) $@

# One 32-bit little-endian word per line, from 0x80000000: the format the
# IROM (boot.mem) and the DTIM (data.mem) preload with $readmemh.
build/ddrinit.mem: build/ddrinit.elf
	$(OBJCOPY) -O binary $< build/ddrinit.bin
	od -An -v -tx4 -w4 build/ddrinit.bin | tr -d ' ' > $@
	@echo "$$(wc -l < $@) words ($$(stat -c %s build/ddrinit.bin) bytes) in $@"

$(GENERATED)/generated/csr.h:
	$(error $@ is missing: run gen-litedram.sh --init-cpu none first)

install: build/ddrinit.mem
	cp build/ddrinit.mem ../src/boot.mem
	cp build/ddrinit.mem ../src/data.mem

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all install clean FORCE
FORCE:
