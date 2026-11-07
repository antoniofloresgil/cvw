# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# FreeRTOS demo image for asic_soc_rv32imac: build/freertos.bin, the flat binary the bootloader loads into
# the RAM at 0x80000000 (at most 32 KiB).  The kernel is the submodule addins/FreeRTOS-Kernel:
#   git submodule update --init addins/FreeRTOS-Kernel

WALLY  ?= $(abspath ../../../..)
KERNEL := $(WALLY)/addins/FreeRTOS-Kernel
PORT   := $(KERNEL)/portable/GCC/RISC-V
CROSS  ?= riscv64-unknown-elf-
ARCH   := -march=rv32imac_zicsr -mabi=ilp32
BUILD  := build

SRCS := main.c $(KERNEL)/tasks.c $(KERNEL)/queue.c $(KERNEL)/list.c $(KERNEL)/timers.c \
        $(PORT)/port.c $(KERNEL)/portable/MemMang/heap_4.c
INC  := -I. -I$(KERNEL)/include -I$(PORT)
CFLAGS := $(ARCH) -Os -g -ffunction-sections -fdata-sections -mno-relax -Wall -Wextra \
          -Wno-unused-parameter -ffreestanding $(INC)
ASFLAGS := $(ARCH) -mno-relax $(INC) -I$(PORT)/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions
OBJS := $(patsubst %.c,$(BUILD)/%.o,$(notdir $(SRCS))) $(BUILD)/crt0.o $(BUILD)/portASM.o

vpath %.c . $(KERNEL) $(PORT) $(KERNEL)/portable/MemMang

$(BUILD)/freertos.bin: $(BUILD)/freertos.elf
	$(CROSS)objcopy -O binary $< $@
	test $$(stat -c %s $@) -le 32768
	$(CROSS)size $<

$(BUILD)/freertos.elf: $(OBJS) link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,link.ld -Wl,-Map,$(BUILD)/freertos.map \
	  -o $@ $(OBJS) -lc -lgcc

$(BUILD)/%.o: %.c FreeRTOSConfig.h | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

$(BUILD)/crt0.o: crt0.S | $(BUILD)
	$(CROSS)gcc $(ASFLAGS) -c -o $@ $<

$(BUILD)/portASM.o: $(PORT)/portASM.S FreeRTOSConfig.h | $(BUILD)
	$(CROSS)gcc $(ASFLAGS) -c -o $@ $<

$(BUILD):
	mkdir -p $@

clean:
	rm -rf $(BUILD)
