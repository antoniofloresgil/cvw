# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# muRISCV-NN (addins/muriscv-nn, TUM, Apache-2.0) on the chip's RV32IMAC, scalar C kernels (docs/engineering/decisions/0024):
#   build/mnn.bin   a 64 x 64 int8 fully connected layer through the library's muriscv_nn_fully_connected_s8, its cycles, and the cost of
#                   the library's requantization alone (any chip)
#   build/mlp.bin   a 64-64-32-10 int8 network three ways (the library, the unit RAW, the unit Q31), same bytes, cycles per layer
#   build/unit.bin  wally_fc.h: the same layer with the product done by the AI unit in RAW mode and the library's requantization in
#                   software, compared byte for byte with the library on random layers (needs asic_soc_rv32imac_ai)
# The library is used as it is (git submodule update --init addins/muriscv-nn); the sources compiled are the ones the layer needs.
# The .bin files are flat images for the bootloader (chip/uart_load.py), same start file and link script as ../baseline.
#   make [OPT=-O2]
CROSS ?= riscv64-unknown-elf-
ARCH  := -march=rv32imac_zicsr -mabi=ilp32
OPT   ?= -O2
BUILD := build
MNN   := ../../../../../addins/muriscv-nn
SRCS  := $(MNN)/Source/FullyConnectedFunctions/muriscv_nn_fully_connected_s8.c \
         $(MNN)/Source/FullyConnectedFunctions/muriscv_nn_fully_connected_get_buffer_sizes_s8.c \
         $(MNN)/Source/NNSupportFunctions/muriscv_nn_vec_mat_mult_t_s8.c
DEFS  ?=
CFLAGS := $(ARCH) $(OPT) $(DEFS) -g -ffunction-sections -fdata-sections -mno-relax -ffreestanding -I$(MNN)/Include
LIBOBJS := $(addprefix $(BUILD)/,$(notdir $(SRCS:.c=.o)))

all: $(BUILD)/mnn.bin $(BUILD)/unit.bin $(BUILD)/mlp.bin

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(CROSS)objcopy -O binary $< $@
	test $$(stat -c %s $@) -le 57344
	$(CROSS)size $<

# mnn.elf is made from main.o, unit.elf from unit.o
$(BUILD)/mnn.elf: $(BUILD)/main.o $(BUILD)/crt0.o $(LIBOBJS) ../baseline/link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,../baseline/link.ld -Wl,-Map,$(BUILD)/mnn.map \
	  -o $@ $(BUILD)/main.o $(BUILD)/crt0.o $(LIBOBJS) -lgcc

$(BUILD)/unit.elf: $(BUILD)/unit.o $(BUILD)/crt0.o $(LIBOBJS) ../baseline/link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,../baseline/link.ld -Wl,-Map,$(BUILD)/unit.map \
	  -o $@ $(BUILD)/unit.o $(BUILD)/crt0.o $(LIBOBJS) -lgcc

$(BUILD)/mlp.elf: $(BUILD)/mlp.o $(BUILD)/crt0.o $(LIBOBJS) ../baseline/link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,../baseline/link.ld -Wl,-Map,$(BUILD)/mlp.map \
	  -o $@ $(BUILD)/mlp.o $(BUILD)/crt0.o $(LIBOBJS) -lgcc

$(BUILD)/mlp.o: mlp.c common.h wally_fc.h | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -Wall -Wextra -c -o $@ $<

$(BUILD)/main.o: main.c common.h | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -Wall -Wextra -c -o $@ $<

$(BUILD)/unit.o: unit.c common.h wally_fc.h | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -Wall -Wextra -c -o $@ $<

$(BUILD)/crt0.o: ../baseline/crt0.S | $(BUILD)
	$(CROSS)gcc $(ARCH) -mno-relax -c -o $@ $<

define LIBRULE
$(BUILD)/$(notdir $(1:.c=.o)): $(1) | $(BUILD)
	$(CROSS)gcc $(CFLAGS) -w -c -o $$@ $$<
endef
$(foreach s,$(SRCS),$(eval $(call LIBRULE,$(s))))

$(BUILD):
	mkdir -p $@

# build/ and build-asm/ (the variant with DEFS=-DMURISCV_NN_USE_REQUANTIZE_INLINE_ASSEMBLY BUILD=build-asm)
clean:
	$(RM) -r build build-asm

.PHONY: all clean
