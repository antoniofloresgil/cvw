// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Single physical RAM allocation policy for all optional multicore engines.
// Physical addresses are zero-extended to the configuration's 64-bit map width.
function automatic logic multicore_cacheable(input cvw_t P, input logic [63:0] address);
  return (P.UNCORE_RAM_SUPPORTED && ((address & ~P.UNCORE_RAM_RANGE) == P.UNCORE_RAM_BASE)) ||
         (P.EXT_MEM_SUPPORTED && ((address & ~P.EXT_MEM_RANGE) == P.EXT_MEM_BASE));
endfunction
