# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Bootloader image of asic_soc_rv32imc: boot.mem, one 32-bit word per line for the 512-byte BOOTROM.

CROSS ?= riscv64-unknown-elf-
WORDS := 128

boot.mem: boot.S
	$(CROSS)gcc -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Wl,-Ttext=0x1000 -o boot.elf boot.S
	$(CROSS)objcopy -O binary boot.elf boot.bin
	test $$(stat -c %s boot.bin) -le $$(($(WORDS) * 4))
	python3 -c "import sys; b = open('boot.bin', 'rb').read().ljust($(WORDS) * 4, b'\0'); \
	  sys.stdout.write(''.join(f'{int.from_bytes(b[i:i+4], \"little\"):08x}\n' for i in range(0, len(b), 4)))" > $@

clean:
	rm -f boot.elf boot.bin boot.mem
