# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# muRISCV-NN (addins/muriscv-nn, TUM, Apache-2.0) on the chip's RV32IMAC, scalar C kernels: a 64 x 64 int8 fully connected layer through the
# library's muriscv_nn_fully_connected_s8, its cycles, and the cost of the library's requantization alone (docs/engineering/decisions/0024).
# The library is used as it is (git submodule update --init addins/muriscv-nn); the sources compiled are the ones the layer needs.
# build/mnn.bin is a flat image for the bootloader (chip/uart_load.py), same start file and link script as ../baseline.
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
OBJS  := $(BUILD)/main.o $(BUILD)/crt0.o $(addprefix $(BUILD)/,$(notdir $(SRCS:.c=.o)))

$(BUILD)/mnn.bin: $(BUILD)/mnn.elf
	$(CROSS)objcopy -O binary $< $@
	test $$(stat -c %s $@) -le 57344
	$(CROSS)size $<

$(BUILD)/mnn.elf: $(OBJS) ../baseline/link.ld
	$(CROSS)gcc $(ARCH) -nostartfiles -nostdlib -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-T,../baseline/link.ld -Wl,-Map,$(BUILD)/mnn.map \
	  -o $@ $(OBJS) -lgcc

$(BUILD)/main.o: main.c | $(BUILD)
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
