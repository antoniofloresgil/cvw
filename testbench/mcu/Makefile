# Unit test of the MCU peripherals (src/uncore/mcu) with Verilator.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

SRC = $(abspath ../../src/uncore/mcu)

all: obj_dir/Vmcu_tb
	./obj_dir/Vmcu_tb | tee run.log
	@grep -q "^PASS" run.log

obj_dir/Vmcu_tb: mcu_tb.sv $(wildcard $(SRC)/*.sv)
	verilator --binary --timing -Wno-fatal -Wno-lint --top-module mcu_tb \
	  $(SRC)/timer_apb.sv $(SRC)/wdt_apb.sv $(SRC)/i2c_apb.sv $(SRC)/rtc_apb.sv mcu_tb.sv

clean:
	rm -rf obj_dir run.log
