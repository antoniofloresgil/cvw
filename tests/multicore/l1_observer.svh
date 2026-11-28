// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Coherent L1 D-caches (COHERENT_L1, ADR 0026): a passive copy of every hart's D-cache, so that the
// architectural value of a word is the dirty copy in a D-cache when there is one, else RAM.
    if (P.DCACHE_SUPPORTED) begin : l1view
        localparam L1_LINE = P.DCACHE_LINELENINBITS;
        localparam L1_WAYS = P.DCACHE_NUMWAYS;
        localparam L1_SETS = P.DCACHE_WAYSIZEINBYTES*8/L1_LINE;
        localparam L1_OFF = $clog2(L1_LINE/8);
        localparam L1_SETB = $clog2(L1_SETS);
        localparam L1_TAGB = P.PA_BITS-L1_OFF-L1_SETB;
        localparam L1_SRAMS = L1_LINE/P.CACHE_SRAMLEN;
        logic [L1_SETS-1:0] V[NCORES][L1_WAYS], Dy[NCORES][L1_WAYS];
        logic [L1_TAGB-1:0] T[NCORES][L1_WAYS][L1_SETS-1:0];
        logic [P.CACHE_SRAMLEN-1:0] Dt[NCORES][L1_WAYS][L1_SRAMS][L1_SETS-1:0];
        for (genvar h = 0; h < NCORES; h++) begin : harts
            for (genvar w = 0; w < L1_WAYS; w++) begin : ways
                if (h == 0) begin : first
                    always @(posedge clk) begin
                        V[h][w] <= dut.core.lsu.bus.dcache.dcache.CacheWays[w].ValidBits;
                        Dy[h][w] <= dut.core.lsu.bus.dcache.dcache.CacheWays[w].DirtyBits;
                        T[h][w] <= dut.core.lsu.bus.dcache.dcache.CacheWays[w].CacheTagMem.ram.RAM;
                    end
                    for (genvar i = 0; i < L1_SRAMS; i++) begin : srams
                        always @(posedge clk) Dt[h][w][i] <= dut.core.lsu.bus.dcache.dcache.CacheWays[w].word[i].wordram.CacheDataMem.ram.RAM;
                    end
                end else begin : other
                    always @(posedge clk) begin
                        V[h][w] <= dut.harts[h].core.lsu.bus.dcache.dcache.CacheWays[w].ValidBits;
                        Dy[h][w] <= dut.harts[h].core.lsu.bus.dcache.dcache.CacheWays[w].DirtyBits;
                        T[h][w] <= dut.harts[h].core.lsu.bus.dcache.dcache.CacheWays[w].CacheTagMem.ram.RAM;
                    end
                    for (genvar i = 0; i < L1_SRAMS; i++) begin : srams
                        always @(posedge clk) Dt[h][w][i] <= dut.harts[h].core.lsu.bus.dcache.dcache.CacheWays[w].word[i].wordram.CacheDataMem.ram.RAM;
                    end
                end
            end
        end
        // Single-writer/multiple-reader invariant of the coherent L1 (ADR 0026), checked every cycle on the copies
        // above, which are all taken on the same clock edge, plus each line's writable bit from cachecoherence.sv:
        //   - a line writable in one hart (E or M) is valid in no other hart;
        //   - a dirty line is writable (M implies write permission);
        //   - a line is in at most one way of a hart's D-cache;
        //   - every valid copy of a line holds the same data (they can only be S copies).
        // +swmr_inject treats the first line found valid in two harts as writable in one of them, so that a
        // run shows the check fires (tests/multicore/run.py --swmr-inject).
        if (COHERENT_L1 && NCORES > 1) begin : swmr
            logic [L1_SETS-1:0] Wr[NCORES][L1_WAYS];
            for (genvar h = 0; h < NCORES; h++) begin : harts
                for (genvar w = 0; w < L1_WAYS; w++) begin : ways
                    if (h == 0) begin : first
                        always @(posedge clk) Wr[h][w] <= dut.core.lsu.bus.dcache.dcache.coherence.cachecoherence.WritableBits[w];
                    end else begin : other
                        always @(posedge clk) Wr[h][w] <= dut.harts[h].core.lsu.bus.dcache.dcache.coherence.cachecoherence.WritableBits[w];
                    end
                end
            end
            bit Inject;
            int unsigned Checked = 0, Shared = 0;   // cycles checked; cycles with a line valid in two harts
            int unsigned SinceReset = 0;
            initial Inject = $test$plusargs("swmr_inject");
            function automatic logic [P.PA_BITS-1:0] line_address(input logic [L1_TAGB-1:0] tag, input int set);
                return {tag, L1_SETB'(set), L1_OFF'(0)};
            endfunction
            always @(posedge clk) begin
                SinceReset <= reset ? 0 : SinceReset + 32'(SinceReset < 2);
                if (SinceReset >= 2) begin   // the copies are one edge behind
                    bit shared;
                    shared = 0;
                    for (int s = 0; s < L1_SETS; s++)
                        for (int h = 0; h < NCORES; h++)
                            for (int w = 0; w < L1_WAYS; w++) if (V[h][w][s]) begin
                                if (Dy[h][w][s] && !Wr[h][w][s])
                                    $fatal(1, "Coherent L1: hart %0d holds line %h dirty but not writable", h, line_address(T[h][w][s], s));
                                for (int g = h; g < NCORES; g++)
                                    for (int u = (g == h ? w + 1 : 0); u < L1_WAYS; u++)
                                        if (V[g][u][s] && T[g][u][s] == T[h][w][s]) begin
                                            if (g == h)
                                                $fatal(1, "Coherent L1: hart %0d holds line %h in ways %0d and %0d", h, line_address(T[h][w][s], s), w, u);
                                            shared = 1;
                                            if (Wr[h][w][s] || Wr[g][u][s])
                                                $fatal(1, "SWMR violation: line %h valid in harts %0d and %0d, writable in hart %0d", line_address(T[h][w][s], s), h, g,
                                                    Wr[h][w][s] ? h : g);
                                            if (Inject)
                                                $fatal(1, "SWMR violation: line %h valid in harts %0d and %0d (injected by +swmr_inject)", line_address(T[h][w][s], s), h, g);
                                            for (int i = 0; i < L1_SRAMS; i++)
                                                if (Dt[h][w][i][s] != Dt[g][u][i][s])
                                                    $fatal(1, "Coherent L1: line %h differs between harts %0d and %0d (bits %0d..%0d)", line_address(T[h][w][s], s), h, g,
                                                        i*P.CACHE_SRAMLEN, (i+1)*P.CACHE_SRAMLEN-1);
                                        end
                            end
                    Checked <= Checked + 1;
                    Shared <= Shared + 32'(shared);
                end
            end
            final $display("SWMR: %0d cycles checked, %0d with a line shared by two harts", Checked, Shared);
        end
        // The dirty copy of the 64-bit word at RAM index `index`, if a D-cache has one
        function automatic logic [64:0] dirty_word(input int unsigned index);
            logic [P.PA_BITS-1:0] a;
            int set, pos;
            a = P.PA_BITS'(P.UNCORE_RAM_BASE) + P.PA_BITS'(index) * 8;
            set = int'((a >> L1_OFF) % P.PA_BITS'(L1_SETS));
            pos = int'(a % P.PA_BITS'(L1_LINE/8)) * 8;
            for (int h = 0; h < NCORES; h++)
                for (int w = 0; w < L1_WAYS; w++)
                    if (V[h][w][set] && Dy[h][w][set] && T[h][w][set] == L1_TAGB'(a >> (L1_OFF+L1_SETB)))
                        return {1'b1, Dt[h][w][pos / P.CACHE_SRAMLEN][set][pos % P.CACHE_SRAMLEN +: 64]};
            return '0;
        endfunction
    end else begin : l1view
        function automatic logic [64:0] dirty_word(input int unsigned index);
            return {1'b0, 64'(index) & '0};
        endfunction
    end
