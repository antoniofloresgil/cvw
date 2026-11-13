# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# The software reference for the AI unit (docs/engineering/decisions/0024-edge-ai-accelerator.md, step 0): build/baseline.bin, a flat
# image that the bootloader loads at 0x80000000 (chip/uart_load.py), prints cycles per MAC of int8 kernels on the chip's RV32IMAC.
#   make [OPT=-O3]
CROSS ?= riscv64-unknown-elf-
ARCH  := -march=rv32imac_zicsr -mabi=ilp32
OPT   ?= -O2
BUILD := build
CFLAGS := $(ARCH) $(OPT) -g -ffunction-sections -fdata-sections -mno-relax -Wall -Wextra -ffreestanding

$(BUILD)/baseline.bin: $(BUILD)/baseline.elf
	$(CROSS)objcopy -O binary $< $@
	test $$(stat -c %s $@) -le 56320
	$(CROSS)size $<

$(BUILD)/baseline.elf: $(BUILD)/main.o $(BUILD)/crt0.o link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,link.ld -Wl,-Map,$(BUILD)/baseline.map \
	  -o $@ $(BUILD)/main.o $(BUILD)/crt0.o -lgcc

$(BUILD)/main.o: main.c | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -c -o $@ $<

$(BUILD)/crt0.o: crt0.S | $(BUILD)
	$(CROSS)gcc $(ARCH) -mno-relax -c -o $@ $<

$(BUILD):
	mkdir -p $@

clean:
	$(RM) -r $(BUILD)

.PHONY: clean
