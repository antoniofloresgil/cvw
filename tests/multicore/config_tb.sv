// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Actual SystemVerilog configuration evaluation for manifests and DT generation.
`include "config.vh"
module config_tb import cvw::*; #(`CVW_MULTICORE_PARAMS(AHBW));
  `include "parameter-defs.vh"
  localparam multicore_t M = `CVW_MULTICORE_VALUE;
  string output_file;
  integer fd;
  initial begin
    assert (multicore_config_error(P, M) == 0)
      else $fatal(1, "%s", multicore_config_message(multicore_config_error(P, M)));
    if (!$value$plusargs("output=%s", output_file)) $fatal(1, "Missing +output");
    fd = $fopen(output_file, "w");
    if (fd == 0) $fatal(1, "Cannot open configuration report");
    $fdisplay(fd, "{\"multicore\": {");
    $fdisplay(fd, "\"NCORES\": %0d,", M.NCORES);
    $fdisplay(fd, "\"SHARED_CACHE\": %0d,", M.SHARED_CACHE);
    $fdisplay(fd, "\"SHARED_CACHE_WORDS\": %0d,", M.SHARED_CACHE_WORDS);
    $fdisplay(fd, "\"PRIVATE_DCACHE\": %0d,", M.PRIVATE_DCACHE);
    $fdisplay(fd, "\"PRIVATE_DCACHE_WORDS\": %0d,", M.PRIVATE_DCACHE_WORDS);
    $fdisplay(fd, "\"PRIVATE_DCACHE_LINE_WORDS\": %0d,", M.PRIVATE_DCACHE_LINE_WORDS);
    $fdisplay(fd, "\"PRIVATE_ICACHE\": %0d,", M.PRIVATE_ICACHE);
    $fdisplay(fd, "\"PRIVATE_ICACHE_WORDS\": %0d,", M.PRIVATE_ICACHE_WORDS);
    $fdisplay(fd, "\"PRIVATE_ICACHE_LINE_WORDS\": %0d,", M.PRIVATE_ICACHE_LINE_WORDS);
    $fdisplay(fd, "\"CACHE_TO_CACHE\": %0d,", M.CACHE_TO_CACHE);
    $fdisplay(fd, "\"CACHE_BURSTS\": %0d,", M.CACHE_BURSTS);
    $fdisplay(fd, "\"MESI\": %0d,", M.MESI);
    $fdisplay(fd, "\"COHERENCE_BANKS\": %0d,", M.COHERENCE_BANKS);
    $fdisplay(fd, "\"LOCAL_DCACHE_READS\": %0d,", M.LOCAL_DCACHE_READS);
    $fdisplay(fd, "\"LOCAL_DCACHE_WRITES\": %0d", M.LOCAL_DCACHE_WRITES);
    $fdisplay(fd, "}, \"core\": {");
    $fdisplay(fd, "\"XLEN\": %0d,", P.XLEN);
    $fdisplay(fd, "\"AHBW\": %0d,", P.AHBW);
    $fdisplay(fd, "\"MISA\": %0d,", P.MISA);
    $fdisplay(fd, "\"ZICSR_SUPPORTED\": %0d,", P.ZICSR_SUPPORTED);
    $fdisplay(fd, "\"ZIFENCEI_SUPPORTED\": %0d,", P.ZIFENCEI_SUPPORTED);
    $fdisplay(fd, "\"SSTC_SUPPORTED\": %0d,", P.SSTC_SUPPORTED);
    $fdisplay(fd, "\"SVADU_SUPPORTED\": %0d,", P.SVADU_SUPPORTED);
    $fdisplay(fd, "\"SVPBMT_SUPPORTED\": %0d,", P.SVPBMT_SUPPORTED);
    $fdisplay(fd, "\"SV32_SUPPORTED\": %0d,", P.SV32_SUPPORTED);
    $fdisplay(fd, "\"SV39_SUPPORTED\": %0d,", P.SV39_SUPPORTED);
    $fdisplay(fd, "\"SV48_SUPPORTED\": %0d,", P.SV48_SUPPORTED);
    $fdisplay(fd, "\"SV57_SUPPORTED\": %0d,", P.SV57_SUPPORTED);
    $fdisplay(fd, "\"BUS_SUPPORTED\": %0d,", P.BUS_SUPPORTED);
    $fdisplay(fd, "\"DTIM_SUPPORTED\": %0d,", P.DTIM_SUPPORTED);
    $fdisplay(fd, "\"IROM_SUPPORTED\": %0d,", P.IROM_SUPPORTED);
    $fdisplay(fd, "\"DCACHE_SUPPORTED\": %0d,", P.DCACHE_SUPPORTED);
    $fdisplay(fd, "\"ICACHE_SUPPORTED\": %0d,", P.ICACHE_SUPPORTED);
    $fdisplay(fd, "\"BURST_EN\": %0d,", P.BURST_EN);
    $fdisplay(fd, "\"ZICBOM_SUPPORTED\": %0d,", P.ZICBOM_SUPPORTED);
    $fdisplay(fd, "\"ZICBOZ_SUPPORTED\": %0d,", P.ZICBOZ_SUPPORTED);
    $fdisplay(fd, "\"ZICBOP_SUPPORTED\": %0d,", P.ZICBOP_SUPPORTED);
    $fdisplay(fd, "\"UNCORE_RAM_SUPPORTED\": %0d,", P.UNCORE_RAM_SUPPORTED);
    $fdisplay(fd, "\"UNCORE_RAM_BASE\": %0d,", P.UNCORE_RAM_BASE);
    $fdisplay(fd, "\"UNCORE_RAM_RANGE\": %0d,", P.UNCORE_RAM_RANGE);
    $fdisplay(fd, "\"EXT_MEM_SUPPORTED\": %0d,", P.EXT_MEM_SUPPORTED);
    $fdisplay(fd, "\"EXT_MEM_BASE\": %0d,", P.EXT_MEM_BASE);
    $fdisplay(fd, "\"EXT_MEM_RANGE\": %0d,", P.EXT_MEM_RANGE);
    $fdisplay(fd, "\"BOOTROM_SUPPORTED\": %0d,", P.BOOTROM_SUPPORTED);
    $fdisplay(fd, "\"BOOTROM_BASE\": %0d,", P.BOOTROM_BASE);
    $fdisplay(fd, "\"BOOTROM_RANGE\": %0d,", P.BOOTROM_RANGE);
    $fdisplay(fd, "\"RESET_VECTOR\": %0d,", P.RESET_VECTOR);
    $fdisplay(fd, "\"UART_SUPPORTED\": %0d,", P.UART_SUPPORTED);
    $fdisplay(fd, "\"UART_BASE\": %0d,", P.UART_BASE);
    $fdisplay(fd, "\"UART_RANGE\": %0d,", P.UART_RANGE);
    $fdisplay(fd, "\"CLINT_SUPPORTED\": %0d,", P.CLINT_SUPPORTED);
    $fdisplay(fd, "\"CLINT_BASE\": %0d,", P.CLINT_BASE);
    $fdisplay(fd, "\"CLINT_RANGE\": %0d,", P.CLINT_RANGE);
    $fdisplay(fd, "\"PLIC_SUPPORTED\": %0d,", P.PLIC_SUPPORTED);
    $fdisplay(fd, "\"PLIC_BASE\": %0d,", P.PLIC_BASE);
    $fdisplay(fd, "\"PLIC_RANGE\": %0d,", P.PLIC_RANGE);
    $fdisplay(fd, "\"PLIC_NUM_SRC\": %0d,", P.PLIC_NUM_SRC);
    $fdisplay(fd, "\"PLIC_UART_ID\": %0d", P.PLIC_UART_ID);
    $fdisplay(fd, "}}");
    $fclose(fd);
    $finish;
  end
endmodule
