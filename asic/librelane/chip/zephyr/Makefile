# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Zephyr image for asic_soc_rv32imac: build/zephyr/zephyr.bin, the flat binary the bootloader loads into the RAM
# at 0x80000000.  The kernel is the submodule addins/zephyr (git submodule update --init addins/zephyr); its
# Python requirements (west is not needed) are in a virtual environment, ZEPHYR_VENV:
#   python3 -m venv $(ZEPHYR_VENV); $(ZEPHYR_VENV)/bin/pip install -r addins/zephyr/scripts/requirements-base.txt
# The toolchain is the RISC-V GCC of $RISCV (CROSS_COMPILE), as for the other images.

WALLY       ?= $(abspath ../../../..)
ZEPHYR_BASE := $(WALLY)/addins/zephyr
ZEPHYR_VENV ?= $(WALLY)/.zephyr-venv
APP         ?= app
BUILD       ?= build
CROSS       ?= $(if $(RISCV),$(RISCV)/bin/)riscv64-unknown-elf-
# a devicetree overlay for simulation: the chip's UART in chipsim runs at one bit per 16 clocks
OVERLAY     ?=

export ZEPHYR_BASE
export ZEPHYR_TOOLCHAIN_VARIANT := cross-compile
export CROSS_COMPILE := $(CROSS)
# the RISC-V GCC supports thread-local storage, which the PMP userspace of Zephyr needs
export ZEPHYR_TOOLCHAIN_SUPPORTS_THREAD_LOCAL_STORAGE := y

all: $(BUILD)/zephyr/zephyr.bin

$(BUILD)/zephyr/zephyr.bin: FORCE
	PATH=$(ZEPHYR_VENV)/bin:$$PATH cmake -GNinja -S $(APP) -B $(BUILD) -DBOARD=wally_chip \
	  -DZEPHYR_MODULES=$(abspath module) -DPython3_EXECUTABLE=$(ZEPHYR_VENV)/bin/python3 \
	  $(if $(OVERLAY),-DEXTRA_DTC_OVERLAY_FILE=$(abspath $(OVERLAY))) >$(BUILD).log 2>&1 || { cat $(BUILD).log; exit 1; }
	PATH=$(ZEPHYR_VENV)/bin:$$PATH ninja -C $(BUILD)
	test $$(stat -c %s $@) -le 57344

clean:
	rm -rf build build.log

.PHONY: all clean FORCE
