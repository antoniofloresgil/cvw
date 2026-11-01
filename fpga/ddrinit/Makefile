# ddrinit: DDR3 initialization run by Wally (open-source FPGA flow, LiteDRAM
# generated with --init-cpu none).
#
#   make                build build/ddrinit.elf and build/ddrinit.mem (RV32
#                       fpgaopensource: initialize, then test the DDR3 forever)
#   make install        copy the image to fpga/src/boot.mem and data.mem
#                       (the IROM and DTIM preload files; back them up first)
#   make SKIP_INIT=1    only the memory test, for a build whose LiteDRAM still
#                       has the service CPU (--init-cpu vexriscv)
#   make stage0         RV64 fpganexysvideoopen: initialize, test once and jump
#                       to the ZSBL; writes fpga/src/ddrinit.mem for its IROM/DTIM
#                       (build-opensource.sh runs it)
#
# The LiteDRAM headers (csr.h, sdram_phy.h, ...) come from the generator's
# output, so run `gen-litedram.sh --init-cpu none` (or the open build with
# INIT_CPU=none) first.  liblitedram is compiled from the installed LiteX
# sources; nothing from LiteX is copied into the repository.

LITEX_VENV   ?= $(RISCV)/litex-venv
LITEX_SW     ?= $(shell $(LITEX_VENV)/bin/python -c 'import litex, os; print(os.path.dirname(litex.__file__))')/soc/software
GENERATED    ?= ../generator/opensource-litedram/init/software/include

# Memory map and clock (config/derivlist.txt, fpga/generator/Makefile): RV32
# fpgaopensource by default; `stage0` sets the RV64 fpganexysvideoopen values.
XLEN          ?= 32
TIM_BASE      ?= 0x80000000
TIM_SIZE      ?= 64K
CSR_BASE      ?= 0x48000000
MAIN_RAM_BASE ?= 0x40000000
UART_BASE     ?= 0x10000000
UART_PRESCALE ?= 1
SYSTEMCLOCK   ?= 40000000
BAUD          ?= 115200
NEXT          ?=

CC      := riscv64-unknown-elf-gcc
OBJCOPY := riscv64-unknown-elf-objcopy
OBJDUMP := riscv64-unknown-elf-objdump
SIZE    := riscv64-unknown-elf-size

ifeq ($(XLEN),64)
ARCH    := -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany
MEMWORD := 8
else
ARCH    := -march=rv32imc_zicsr -mabi=ilp32
MEMWORD := 4
endif
DEFINES := -DCSR_BASE=$(CSR_BASE)L -DMAIN_RAM_BASE=$(MAIN_RAM_BASE)L \
           -DMAIN_RAM_BASE_VA=$(MAIN_RAM_BASE)L -DSDRAM_TEST_DISABLE \
           -DUART_BASE=$(UART_BASE) -DUART_PRESCALE=$(UART_PRESCALE) \
           -DSYSTEMCLOCK=$(SYSTEMCLOCK) -DBAUD=$(BAUD) \
           $(if $(filter 1,$(SKIP_INIT)),-DDDRINIT_SKIP) $(if $(NEXT),-DDDRINIT_NEXT=$(NEXT))
CFLAGS  := $(ARCH) -Os -g -ffreestanding -fno-common -ffunction-sections -fdata-sections \
           -Wall -Wno-unused-function $(DEFINES) \
           -Ishim -I$(GENERATED) -I$(LITEX_SW)/include -I$(LITEX_SW)
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -Wl,--gc-sections -T build/link.ld

SOURCES := start.S main.c printf.c \
           $(LITEX_SW)/liblitedram/sdram.c $(LITEX_SW)/liblitedram/accessors.c

all: build/ddrinit.mem

build/ddrinit.elf: $(SOURCES) link.ld shim/system.h $(GENERATED)/generated/csr.h FORCE | build
	sed 's/ORIGIN = 0x80000000, LENGTH = 64K/ORIGIN = $(TIM_BASE), LENGTH = $(TIM_SIZE)/' link.ld > build/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SOURCES) -lgcc
	$(OBJDUMP) -d $@ > build/ddrinit.objdump
	$(SIZE) $@

# One XLEN-bit little-endian word per line, from TIM_BASE: the format the IROM
# and the DTIM preload with $readmemh.
build/ddrinit.mem: build/ddrinit.elf
	$(OBJCOPY) -O binary $< build/ddrinit.bin
	od -An -v -tx$(MEMWORD) -w$(MEMWORD) build/ddrinit.bin | tr -d ' ' > $@
	@echo "$$(wc -l < $@) words ($$(stat -c %s build/ddrinit.bin) bytes) in $@"

$(GENERATED)/generated/csr.h:
	$(error $@ is missing: run gen-litedram.sh --init-cpu none first)

install: build/ddrinit.mem
	cp build/ddrinit.mem ../src/boot.mem
	cp build/ddrinit.mem ../src/data.mem

stage0:
	$(MAKE) XLEN=64 TIM_BASE=0x4000 TIM_SIZE=16K CSR_BASE=0xA0000000 \
	        MAIN_RAM_BASE=0x80000000 UART_PRESCALE=0 SYSTEMCLOCK=12500000 NEXT=0x1000 \
	        build/ddrinit.mem
	cp build/ddrinit.mem ../src/ddrinit.mem

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: all install stage0 clean FORCE
FORCE:
