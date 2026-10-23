// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive architectural-word lookup. Never writes back, flushes or grants access.
module multicore_word_observer import cvw::*; import multicore_observation::*; #(
    parameter cvw_t P,
    parameter bit PRIVATE = 1,
    parameter int NCORES = 2, BANKS = 1, DCACHE_WORDS = 32, ICACHE_WORDS = 32, LINE_WORDS = 4,
    parameter int DW = DCACHE_WORDS/BANKS, IW = ICACHE_WORDS/BANKS,
    parameter int OFFSET = $clog2(P.AHBW/8), LINE_OFFSET = OFFSET+$clog2(LINE_WORDS),
    parameter int CI = $clog2(DW/LINE_WORDS),
    parameter int TAG_BITS = P.PA_BITS-LINE_OFFSET-CI
)(
    input logic [BANKS-1:0][NCORES-1:0][DW/LINE_WORDS-1:0][1:0] Permissions,
    input logic [TAG_BITS-1:0] Tags[BANKS][NCORES][DW/LINE_WORDS],
    input logic [P.AHBW-1:0] Lines[BANKS][NCORES][DW]
);
    localparam LINE_MASK = DW/LINE_WORDS-1;
    localparam HOME_OFFSET = OFFSET+$clog2(DW > IW ? DW : IW);
    function automatic logic [P.AHBW-1:0] word(input int unsigned index, input logic [P.AHBW-1:0] ram_word);
        logic [P.PA_BITS-1:0] address;
        int bank, line_index, data_index, owners;
        if (!PRIVATE) return ram_word;
        address = P.PA_BITS'(P.UNCORE_RAM_BASE) + (P.PA_BITS'(index) << OFFSET);
        bank = int'((address >> HOME_OFFSET) & P.PA_BITS'(BANKS-1));
        line_index = int'((address >> LINE_OFFSET) & P.PA_BITS'(LINE_MASK));
        data_index = int'((address >> OFFSET) & P.PA_BITS'(DW-1));
        owners = 0;
        word = ram_word;
        for (int h = 0; h < NCORES; h++) begin
            assert (!$isunknown(Permissions[bank][h][line_index]))
                else $fatal(1, "observation contract: unknown permission mapping");
            if (Permissions[bank][h][line_index] == OBS_MODIFIED &&
                    Tags[bank][h][line_index] == TAG_BITS'(address >> (LINE_OFFSET+CI))) begin
                owners++;
                word = Lines[bank][h][data_index];
            end
        end
        assert (owners <= 1) else $fatal(1, "observation contract: multiple dirty owners");
    endfunction
endmodule
