// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Coherent L1 D-caches (COHERENT_L1, ADR 0026): a passive copy of every hart's D-cache, so that the
// architectural value of a word is the dirty copy in a D-cache when there is one, else RAM.
    if (COHERENT_L1) begin : l1view
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
