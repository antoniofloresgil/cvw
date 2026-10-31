///////////////////////////////////////////////////////////////////////
// gpt.c
//
// Written: Jaocb Pease jacob.pease@okstate.edu 7/22/2024
//
// Purpose: Code to read GPT Partitions off of an SD card.
//
//
//
// A component of the Wally configurable RISC-V project.
//
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
///////////////////////////////////////////////////////////////////////

#include "gpt.h"
#include "boot.h"
#include "uart.h"
#include <stddef.h>

static uint32_t be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static int streq(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return *a == *b;
}

// Every clock in the SoC (CPU, timer, UART, SPI) runs at SYSTEMCLOCK, so set
// every 4-byte clock-frequency and timebase-frequency property in the device
// tree to it.  This lets one SD card image boot bitstreams built for different
// clock frequencies.  Returns the number of properties changed.
static int fdt_set_clocks(uint8_t *fdt, uint32_t freq) {
  if (be32(fdt) != 0xd00dfeed) return 0;
  uint8_t *p = fdt + be32(fdt + 8);                 // structure block
  const char *strings = (const char *)fdt + be32(fdt + 12);
  int changed = 0;
  for (;;) {
    uint32_t token = be32(p);
    p += 4;
    if (token == 1) {                                // FDT_BEGIN_NODE: skip padded name
      while (*p) p++;
      p = (uint8_t *)(((uintptr_t)p + 4) & ~(uintptr_t)3);
    } else if (token == 3) {                         // FDT_PROP: len, nameoff, value
      uint32_t len = be32(p);
      const char *name = strings + be32(p + 4);
      uint8_t *value = p + 8;
      if (len == 4 && be32(value) != freq &&
          (streq(name, "clock-frequency") || streq(name, "timebase-frequency"))) {
        value[0] = freq >> 24; value[1] = freq >> 16; value[2] = freq >> 8; value[3] = freq;
        changed++;
      }
      p = value + ((len + 3) & ~3u);
    } else if (token != 2 && token != 4) {           // not FDT_END_NODE or FDT_NOP
      return changed;                                // FDT_END or malformed
    }
  }
}

int gpt_load_partitions() {
  // size_t block_size = 512/8;
  // long int lba1_buf[block_size];

  BYTE lba1_buf[512];

  int ret = 0;
  //ret = disk_read(/* BYTE * buf, LBA_t sector, UINT count, BYTE card_type */);
  print_time();
  println("Getting GPT information.");
  ret = disk_read(lba1_buf, 1, 1);

  gpt_pth_t *lba1 = (gpt_pth_t *)lba1_buf;

  print_time();
  println("Getting partition entries.");
  BYTE lba2_buf[512];
  ret = disk_read(lba2_buf, (LBA_t)lba1->partition_entries_lba, 1);

  // Load partition entries for the relevant boot partitions.
  partition_entries_t *fdt = (partition_entries_t *)(lba2_buf);
  partition_entries_t *opensbi = (partition_entries_t *)(lba2_buf + 128);
  partition_entries_t *kernel = (partition_entries_t *)(lba2_buf + 256);

  // Load device tree
  print_time();
  println_with_int("Loading device tree at: 0x", FDT_ADDRESS);
  ret = disk_read((BYTE *)FDT_ADDRESS, fdt->first_lba, fdt->last_lba - fdt->first_lba + 1);
  if (ret < 0) {
    print_uart("Failed to load device tree!\r\n");
    return -1;
  }
  if (fdt_set_clocks((uint8_t *)FDT_ADDRESS, SYSTEMCLOCK)) {
    println_with_int("Device tree clocks set to 0x", SYSTEMCLOCK);
  }

  // Load OpenSBI
  print_time();
  println_with_int("Loading OpenSBI at: 0x", OPENSBI_ADDRESS);
  ret = disk_read((BYTE *)OPENSBI_ADDRESS, opensbi->first_lba, opensbi->last_lba - opensbi->first_lba + 1);
  if (ret < 0) {
    print_uart("Failed to load OpenSBI!\r\n");
    return -1;
  }

  // Load Linux
  print_time();
  println_with_int("Loading Linux Kernel at: 0x", KERNEL_ADDRESS);
  ret = disk_read((BYTE *)KERNEL_ADDRESS, kernel->first_lba,kernel->last_lba - kernel->first_lba + 1);
  if (ret < 0) {
    print_uart("Failed to load Linux!\r\n");
    return -1;
  }

  print_time();
  println("Done! Flashing LEDs and jumping to OpenSBI...");

  return 0;
}
