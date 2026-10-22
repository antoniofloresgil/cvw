// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive bridge events and independently checked conflict/lock invariants.
module multicore_bridge_observer import cvw::*; #(
    parameter cvw_t P,
    parameter int NCORES = 2, DCACHE_LINE_WORDS = 1, ICACHE_LINE_WORDS = 1,
    parameter int OWNER_BITS = NCORES > 1 ? $clog2(NCORES) : 1
)(
    input logic HCLK, HRESETn, LockActive, DataPhase, IFillActive, HREADY, HRESP,
    input logic [OWNER_BITS-1:0] Owner,
    input logic [NCORES-1:0] Write, LocalReply, LocalStoreCommitted,
    input logic [NCORES-1:0][P.PA_BITS-1:0] Addr,
    input logic [NCORES-1:0][3:0] Prot,
    input logic [NCORES-1:0][1:0] Op
);
    // Expected physical region derives from the public geometry, not DUT decode.
    localparam CONFLICT_BITS = $clog2(P.XLEN/8) + $clog2(
        DCACHE_LINE_WORDS > ICACHE_LINE_WORDS ? DCACHE_LINE_WORDS : ICACHE_LINE_WORDS);
    wire GlobalDataActive = DataPhase;
    wire GlobalWriteActive = DataPhase && Write[Owner];
    wire GlobalReadActive = DataPhase && !Write[Owner];
    wire GlobalOrRefillActive = DataPhase || IFillActive;
    wire LRReply = GlobalOrRefillActive && HREADY && !HRESP && Op[Owner] == COREBUS_LR;
    wire InstructionReply = GlobalOrRefillActive && HREADY && !HRESP && !Prot[Owner][0];
    wire [NCORES-1:0] LocalDataReply;
    wire [31:0] LocalCompletionCount = 32'($countones(LocalReply | LocalStoreCommitted));
    for (genvar h = 0; h < NCORES; h++) begin : harts
        assign LocalDataReply[h] = LocalReply[h] && Prot[h][0];
        always @(posedge HCLK) if (HRESETn) begin
            if (LocalStoreCommitted[h]) begin
                assert (!LockActive) else $fatal(1, "Local M store bypassed AMO lock");
                if (GlobalOrRefillActive)
                    assert (Owner != OWNER_BITS'(h) && Addr[h][P.PA_BITS-1:CONFLICT_BITS] != Addr[Owner][P.PA_BITS-1:CONFLICT_BITS])
                        else $fatal(1, "Local M store raced a global access to its coherence/refill region");
            end
            if (GlobalWriteActive && LocalReply[h])
                assert (Addr[h][P.PA_BITS-1:CONFLICT_BITS] != Addr[Owner][P.PA_BITS-1:CONFLICT_BITS])
                    else $fatal(1, "Local read bypassed a write to the same physical word");
        end
    end
endmodule

bind ahbmulticore multicore_bridge_observer #(.P(P), .NCORES(NCORES),
    .DCACHE_LINE_WORDS(DCACHE_LINE_WORDS), .ICACHE_LINE_WORDS(ICACHE_LINE_WORDS)) observation(
    .HCLK, .HRESETn, .LockActive, .DataPhase, .IFillActive, .HREADY, .HRESP,
    .Owner, .Write, .LocalReply, .LocalStoreCommitted(CacheWriteCommit), .Addr, .Prot, .Op
);
