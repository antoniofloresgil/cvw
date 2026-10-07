dst := IP
SHELL := /bin/bash

FLOW ?= vivado

ifeq ($(FLOW),vivado)
all: ArtyA7
else ifeq ($(FLOW),opensource)
all: ArtyA7
else
$(error FLOW must be vivado or opensource)
endif

.PHONY: ArtyA7 vcu118 vcu108 genesys2 nexysa7 nexysvideo

ArtyA7: export XILINX_PART := xc7a100tcsg324-1
ArtyA7: export XILINX_BOARD := digilentinc.com:arty-a7-100:part0:1.1
ArtyA7: export board := ArtyA7
ArtyA7: export SYSTEMCLOCK := 20000000
ArtyA7: export MAXSDCCLOCK  :=  5000000
ifeq ($(FLOW),opensource)
ArtyA7: PreProcessOpenSource
	./build-opensource.sh "ArtyA7"
else
ArtyA7: FPGA_Arty
endif

vcu118: export XILINX_PART := xcvu9p-flga2104-2L-e
vcu118: export XILINX_BOARD := xilinx.com:vcu118:part0:2.4
vcu118: export board := vcu118
vcu118: export SYSTEMCLOCK := 71000000
vcu118: export MAXSDCCLOCK  :=  1000000
vcu118: FPGA_VCU

vcu108: export XILINX_PART := xcvu095-ffva2104-2-e
vcu108: export XILINX_BOARD := xilinx.com:vcu108:part0:1.7
vcu108: export board := vcu108
vcu108: export SYSTEMCLOCK := 50000000
vcu108: export MAXSDCCLOCK  := 12500000
vcu108: FPGA_VCU

genesys2: export XILINX_PART := xc7k325tffg900-2
genesys2: export XILINX_BOARD := digilentinc.com:genesys2:part0:1.1
genesys2: export board := genesys2
genesys2: export SYSTEMCLOCK := 40000000
genesys2: export MAXSDCCLOCK  := 10000000
genesys2: FPGA_GENESYS2

nexysa7: export XILINX_PART := xc7a100tcsg324-1
nexysa7: export XILINX_BOARD := digilentinc.com:nexys-a7-100t:part0:1.0
nexysa7: export board := nexysa7
nexysa7: export SYSTEMCLOCK := 20000000
nexysa7: export MAXSDCCLOCK  :=  10000000
ifeq ($(FLOW),opensource)
nexysa7: PreProcessOpenSource
	./build-opensource.sh "nexysa7"
else
nexysa7: FPGA_NEXYSA7
endif

nexysvideo: export XILINX_PART := xc7a200tsbg484-1
nexysvideo: export XILINX_BOARD := digilentinc.com:nexys_video:part0:1.2
nexysvideo: export XILINX_BOARD_REPO := $(WALLY)/addins/vivado-boards/new/board_files
nexysvideo: export board := nexysvideo
nexysvideo: export SYSTEMCLOCK := 20000000
nexysvideo: export MAXSDCCLOCK := 10000000
ifeq ($(FLOW),opensource)
nexysvideo: PreProcessOpenSource
	./build-opensource.sh "nexysvideo"
else
nexysvideo: FPGA_NEXYSVIDEO
endif

# variables computed from config
EXT_MEM_BASE = $(shell grep 'EXT_MEM_BASE' ../../config/deriv/fpga$(board)/config.vh | sed 's/.*=.*h\([[:alnum:]]*\);/0x\1/g')

EXT_MEM_RANGE = $(shell grep 'EXT_MEM_RANGE' ../../config/deriv/fpga$(board)/config.vh | sed 's/.*=.*h\([[:alnum:]]*\);/\1/g' | sed 's/\(.*\)/base=16;\1+1/g' | bc | sed 's/\(.*\)/0x\1/g')


.PHONY: FPGA_Arty FPGA_VCU
FPGA_Arty: PreProcessFiles IP_Arty zsbl
	set -o pipefail; vivado -mode tcl -source wally.tcl 2>&1 | tee wally.log
FPGA_VCU: PreProcessFiles IP_VCU zsbl
	set -o pipefail; vivado -mode tcl -source wally.tcl 2>&1 | tee wally.log

FPGA_GENESYS2: PreProcessFiles IP_GENESYS2 zsbl
	set -o pipefail; vivado -mode tcl -source wally.tcl 2>&1 | tee wally.log

FPGA_NEXYSA7: PreProcessFiles IP_NEXYSA7 zsbl
	set -o pipefail; vivado -mode tcl -source wally.tcl 2>&1 | tee wally.log

FPGA_NEXYSVIDEO: PreProcessFiles IP_NEXYSVIDEO zsbl
	set -o pipefail; vivado -mode tcl -source wally.tcl 2>&1 | tee wally.log

FPGA_OPEN: PreProcessOpenSource
	./build-opensource.sh "$(board)"

# Generate IP Blocks
.PHONY: IP_Arty IP_VCU
IP_VCU: $(dst)/sysrst.log \
	MEM_VCU \
	$(dst)/clkconverter.log \
	$(dst)/ahbaxibridge.log
IP_Arty: $(dst)/sysrst.log \
	MEM_Arty \
	$(dst)/mmcm.log \
	$(dst)/clkconverter.log \
	$(dst)/ahbaxibridge.log

IP_GENESYS2: $(dst)/sysrst.log \
	MEM_GENESYS2 \
	$(dst)/mmcm-genesys2.log \
	$(dst)/clkconverter.log \
	$(dst)/ahbaxibridge.log

IP_NEXYSA7: $(dst)/sysrst.log \
	MEM_NEXYSA7 \
	$(dst)/mmcm-nexysa7.log \
	$(dst)/clkconverter.log \
	$(dst)/ahbaxibridge.log

IP_NEXYSVIDEO: $(dst)/sysrst.log \
	MEM_NEXYSVIDEO \
	$(dst)/mmcm-nexysvideo.log \
	$(dst)/clkconverter.log \
	$(dst)/ahbaxibridge.log

# Generate Memory IP Blocks
.PHONY: MEM_VCU MEM_Arty
MEM_VCU:
	$(MAKE) $(dst)/ddr4-$(board).log
MEM_Arty:
	$(MAKE) $(dst)/ddr3-$(board).log

MEM_GENESYS2:
	$(MAKE) $(dst)/ddr3-$(board).log

MEM_NEXYSA7:
	$(MAKE) $(dst)/ddr2-$(board).log

MEM_NEXYSVIDEO:
	$(MAKE) $(dst)/ddr3-$(board).log

# Copy files and make necessary modifications
.PHONY: PreProcessFiles
PreProcessFiles:
	$(MAKE) -C ../../sim deriv
	rm -rf ../src/CopiedFiles_do_not_add_to_repo/
	cp -r ../../src/ ../src/CopiedFiles_do_not_add_to_repo/
	cp -r ../../addins/verilog-ethernet/*/*.sv ../src/CopiedFiles_do_not_add_to_repo/rvvi
	cp -r ../../addins/verilog-ethernet/*/*/*/*.sv ../src/CopiedFiles_do_not_add_to_repo/rvvi
	mkdir ../src/CopiedFiles_do_not_add_to_repo/config/
	cp ../../config/deriv/fpga$(board)/config.vh ../src/CopiedFiles_do_not_add_to_repo/config/
	./insert_debug_comment.sh
	# This line allows the Bootloader to be loaded in a Block RAM on the FPGA
	sed -i "s/bit \[DATA_WIDTH-1:0\].*ROM.*/(\* rom_style=\"block\" \*) &/g" ../src/CopiedFiles_do_not_add_to_repo/generic/mem/rom1p1r.sv
	sed -i 's/$$WALLY/\.\.\/\.\.\//g' ../src/CopiedFiles_do_not_add_to_repo/generic/mem/rom1p1r.sv
	sed -i 's/$$WALLY/\.\.\/\.\.\//g' ../src/CopiedFiles_do_not_add_to_repo/generic/mem/ram1p1rwbe.sv

.PHONY: PreProcessOpenSource
PreProcessOpenSource:
	$(MAKE) -C ../../sim deriv
	rm -rf ../src/CopiedFiles_do_not_add_to_repo
	cp -r ../../src/ ../src/CopiedFiles_do_not_add_to_repo/
	mkdir -p ../src/CopiedFiles_do_not_add_to_repo/config
	cp ../../config/deriv/fpgaopensource/config.vh ../src/CopiedFiles_do_not_add_to_repo/config/
	cp ../../config/shared/*.vh ../src/CopiedFiles_do_not_add_to_repo/config/
	cp ../../fpga/src/fpgaOpenSource.sv ../src/CopiedFiles_do_not_add_to_repo/
	sed -i "s/bit \[DATA_WIDTH-1:0\].*ROM.*/(\* rom_style=\"block\" \*) &/g" ../src/CopiedFiles_do_not_add_to_repo/generic/mem/rom1p1r.sv
	sed -i 's|\$$WALLY|$(WALLY)|g' ../src/CopiedFiles_do_not_add_to_repo/generic/mem/rom1p1r.sv
	sed -i 's|\$$WALLY|$(WALLY)|g' ../src/CopiedFiles_do_not_add_to_repo/generic/mem/ram1p1rwbe.sv
	sed -i '/write("%c",Din);/d' ../src/CopiedFiles_do_not_add_to_repo/uncore/uartPC16550D.sv

# Generate the LiteDRAM DDR3 controller/PHY Verilog for the open-source flow
.PHONY: litedram
litedram:
	./gen-litedram.sh

# build the Zero stage boot loader (ZSBL)
.PHONY: zsbl
zsbl:
	$(MAKE) -C ../zsbl clean
	SYSTEMCLOCK=$(SYSTEMCLOCK) MAXSDCCLOCK=$(MAXSDCCLOCK) EXT_MEM_BASE=$(EXT_MEM_BASE) EXT_MEM_RANGE=$(EXT_MEM_RANGE) $(MAKE) -C ../zsbl

# Generate Individual IP Blocks
$(dst)/%.log: %.tcl
	mkdir -p IP
	cd IP;\
	set -o pipefail; vivado -mode batch -source ../$*.tcl | tee $*.log

# Clean
.PHONY: cleanIP cleanLogs cleanFPGA cleanAll
cleanIP:
	rm -rf IP
cleanLogs:
	rm -rf  *.jou *.log
cleanFPGA:
	rm -rf WallyFPGA.* reports sim .Xil
cleanAll: cleanIP cleanLogs cleanFPGA

# Aliases
.PHONY: arty artya7 VCU118 VCU108 nexys nexysa7 NexysVideo
arty artya7: ArtyA7
VCU118: vcu118
VCU108: vcu108
NexysVideo: nexysvideo
