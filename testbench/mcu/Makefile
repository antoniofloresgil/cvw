# Unit test of the MCU peripherals (src/uncore/mcu) with Verilator.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

SRC = $(abspath ../../src/uncore/mcu)

all: obj_dir/Vmcu_tb
	./obj_dir/Vmcu_tb | tee run.log
	@grep -q "^PASS" run.log

obj_dir/Vmcu_tb: mcu_tb.sv $(wildcard $(SRC)/*.sv)
	verilator --binary --timing -Wno-fatal -Wno-lint --top-module mcu_tb \
	  $(SRC)/timer_apb.sv $(SRC)/wdt_apb.sv $(SRC)/i2c_apb.sv $(SRC)/rtc_apb.sv mcu_tb.sv

# Line coverage of the peripherals under this test: the lines never executed are marked %000000 in cov/*.sv
cover:
	verilator --binary --timing -Wno-fatal -Wno-lint --coverage-line --top-module mcu_tb --Mdir cov_obj \
	  $(SRC)/timer_apb.sv $(SRC)/wdt_apb.sv $(SRC)/i2c_apb.sv $(SRC)/rtc_apb.sv mcu_tb.sv
	./cov_obj/Vmcu_tb | grep -a "^PASS"
	verilator_coverage --annotate cov coverage.dat
	@for f in timer_apb wdt_apb i2c_apb rtc_apb; do \
	  t=$$(grep -cE '^[ %][0-9]{6}' cov/$$f.sv); z=$$(grep -cE '^%000000' cov/$$f.sv); \
	  echo "$$f: $$((t-z))/$$t lines executed"; done

clean:
	rm -rf obj_dir run.log
