// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Included inside a temporary copy of the ordinary testbench by check_singlecore.py.
// Force RAM data accesses through the uncacheable path even when a D-cache exists:
// this exercises the cache/bus adapter as well as the cacheless LSU implementation.
initial if (!$test$plusargs("CACHEABLE_DATA")) force dut.core.lsu.CacheableM = 1'b0;
int WalkerAMOOverlaps = 0;
always @(negedge clk) if (!reset && dut.core.lsu.SelHPTW && dut.core.lsu.AtomicM[1]) begin
    WalkerAMOOverlaps++;
    assert (!dut.core.lsu.LSUAtomicM[1]) else $fatal(1, "Walker selected a CPU AMO");
end
always @(negedge clk) if (!reset && dut.core.lsu.SelHPTW && dut.core.lsu.AtomicM[1])
    assert (!dut.core.lsu.bus.dcache.BusAtomic) else $fatal(1, "PTE request tagged as AMO in cached LSU");
final begin
    assert (WalkerAMOOverlaps > 0) else $fatal(1, "Missing AMO/walker overlap coverage");
    $display("PASS: observed %0d AMO/walker overlap cycles", WalkerAMOOverlaps);
end
