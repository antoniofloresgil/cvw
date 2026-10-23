// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Compare shared policy results to independently supplied Python verdicts.
`include "config.vh"
module policy_tb import cvw::*; ();
  `include "parameter-defs.vh"
  cvw_t core;
  multicore_t topology;
  string vectors;
  integer fd, expected, mutation, count, status;
  initial begin
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "Missing vectors");
    fd = $fopen(vectors, "r");
    if (fd == 0) $fatal(1, "Cannot open vectors");
    count = 0;
    while (!$feof(fd)) begin
      status = $fscanf(fd, "%h %d %d\n", topology, mutation, expected);
      if (status == 3) begin
        core = P;
        case (mutation)
          1: core.DCACHE_SUPPORTED = 1;
          2: core.ZICBOM_SUPPORTED = 1;
          3: core.SVADU_SUPPORTED = 1;
          4: core.SVPBMT_SUPPORTED = 1;
          5: core.AHBW = 32;
          default: begin end
        endcase
        assert (multicore_config_error(core, topology) == expected)
          else $fatal(1, "Policy mismatch vector %0d: got %0d expected %0d", count,
            multicore_config_error(core, topology), expected);
        count++;
      end else $fatal(1, "Malformed policy vector");
    end
    $fclose(fd);
    // Independent address-boundary expectations for the current RAM map.
    assert (multicore_cacheable(P, P.UNCORE_RAM_BASE));
    assert (multicore_cacheable(P, P.UNCORE_RAM_BASE + P.UNCORE_RAM_RANGE));
    assert (!multicore_cacheable(P, P.UNCORE_RAM_BASE - 1));
    assert (!multicore_cacheable(P, P.UNCORE_RAM_BASE + P.UNCORE_RAM_RANGE + 1));
    assert (!multicore_cacheable(P, P.UART_BASE));
    assert (!multicore_cacheable(P, P.CLINT_BASE));
    assert (!multicore_cacheable(P, P.PLIC_BASE));
    core = P;
    core.UNCORE_RAM_SUPPORTED = 0;
    core.EXT_MEM_SUPPORTED = 0;
    assert (!multicore_cacheable(core, P.UNCORE_RAM_BASE));
    core.EXT_MEM_SUPPORTED = 1;
    core.EXT_MEM_BASE = 64'h100000000;
    core.EXT_MEM_RANGE = 64'hfff;
    assert (multicore_cacheable(core, 64'h100000000));
    assert (multicore_cacheable(core, 64'h100000fff));
    assert (!multicore_cacheable(core, 64'hffffffff));
    assert (!multicore_cacheable(core, 64'h100001000));
    $display("PASS: %0d Python/SV policy vectors and RAM/MMIO boundaries", count);
    $finish;
  end
endmodule
