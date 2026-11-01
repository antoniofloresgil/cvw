// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent sentinel values exercise passive lookup, not coherence stimulus.
`include "config.vh"
module observation_tb import cvw::*; import multicore_observation::*; #(
    parameter int BANKS = 2, LINE_WORDS = 4, ICACHE_WORDS = 64
);
    `include "parameter-defs.vh"
    localparam NCORES = 3, WORDS = 32, DW = WORDS/BANKS;
    localparam OFFSET = $clog2(P.AHBW/8), CI = $clog2(DW/LINE_WORDS);
    localparam TAG_BITS = P.PA_BITS-OFFSET-$clog2(LINE_WORDS)-CI;
    localparam HOME_STRIDE = (WORDS > ICACHE_WORDS ? WORDS : ICACHE_WORDS)/BANKS;
    logic [BANKS-1:0][NCORES-1:0][DW/LINE_WORDS-1:0][1:0] Raw, Permissions;
    logic [TAG_BITS-1:0] Tags[BANKS][NCORES][DW/LINE_WORDS];
    logic [P.AHBW-1:0] Lines[BANKS][NCORES][DW];
    for (genvar b = 0; b < BANKS; b++) begin : homes
        // Deliberately different from current DUT encoding.
        multicore_cache_observer #(.P(P), .NCORES(NCORES), .WORDS(DW), .LINE_WORDS(LINE_WORDS),
            .RAW_I(0), .RAW_S(2), .RAW_M(3), .RAW_E(1)) probe(
            .RawStates(Raw[b]), .Tags(Tags[b]), .Lines(Lines[b]),
            .TransactionActive(1'b0), .LookupAccepted(1'b0), .FillDataAccepted(1'b0));
        assign Permissions[b] = probe.Permissions;
    end
    multicore_word_observer #(.P(P), .NCORES(NCORES), .BANKS(BANKS), .DCACHE_WORDS(WORDS),
        .ICACHE_WORDS(ICACHE_WORDS), .LINE_WORDS(LINE_WORDS)) observer(.Permissions, .Tags, .Lines);
    initial begin
        Raw = '0;
        foreach (Tags[b,h,l]) Tags[b][h][l] = '0;
        foreach (Lines[b,h,w]) Lines[b][h][w] = P.AHBW'(int'(32'h1000+b*256+h*32+w));
        #1;
        assert (observer.word(3, 'h55) == 'h55) else $fatal(1, "observation contract: RAM fallback mismatch");
        for (int b = 0; b < BANKS; b++) begin
            int index, slot;
            logic [P.PA_BITS-1:0] address;
            index = b*HOME_STRIDE+3;
            address = P.PA_BITS'(P.UNCORE_RAM_BASE)+(P.PA_BITS'(index) << OFFSET);
            slot = (index/LINE_WORDS) % (DW/LINE_WORDS);
            Tags[b][0][slot] = TAG_BITS'(address >> (OFFSET+$clog2(DW)));
            Raw[b][0][slot] = 2; // Shared is clean, so use RAM.
            #1;
            assert (observer.word(index, 'h55) == 'h55) else $fatal(1, "observation contract: clean fallback mismatch");
            Raw[b][0][slot] = 3; // Modified sentinel, independent expected data.
            if ($test$plusargs("DUPLICATE")) begin
                Tags[b][1][slot] = Tags[b][0][slot];
                Raw[b][1][slot] = 3;
            end
            #1;
            assert (observer.word(index, 'h55) == P.AHBW'(int'(32'h1000+b*256+3)))
                else $fatal(1, "observation contract: word mapping mismatch");
            // Same index, another physical tag must not hit the dirty owner.
            assert (observer.word(index+2*HOME_STRIDE, 'h66) == 'h66)
                else $fatal(1, "observation contract: tag alias mismatch");
        end
        $display("PASS: observation sentinel mapping RV%0d banks=%0d line=%0d I=%0d", P.XLEN, BANKS, LINE_WORDS, ICACHE_WORDS);
        $finish;
    end
    initial begin
        #10000;
        $fatal(1, "Observation fixture timeout");
    end
endmodule
