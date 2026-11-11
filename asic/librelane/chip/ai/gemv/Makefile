# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# The AI unit's test (docs/engineering/decisions/0024-edge-ai-accelerator.md, step 1): build/gemv.bin, a flat
# image that the bootloader loads at 0x80000000 (chip/uart_load.py); runs the unit against a C reference (needs asic_soc_rv32imac_ai).
#   make [OPT=-O3]
CROSS ?= riscv64-unknown-elf-
ARCH  := -march=rv32imac_zicsr -mabi=ilp32
OPT   ?= -O2
BUILD := build
CFLAGS := $(ARCH) $(OPT) -g -ffunction-sections -fdata-sections -mno-relax -Wall -Wextra -ffreestanding

$(BUILD)/gemv.bin: $(BUILD)/gemv.elf
	$(CROSS)objcopy -O binary $< $@
	test $$(stat -c %s $@) -le 57344
	$(CROSS)size $<

$(BUILD)/gemv.elf: $(BUILD)/main.o $(BUILD)/crt0.o link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,link.ld -Wl,-Map,$(BUILD)/gemv.map \
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
