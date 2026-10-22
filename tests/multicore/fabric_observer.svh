// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Fabric-specific passive binding; scenario code uses only semantic views/events.
    logic [BANKS-1:0] Active;
    for (genvar b = 0; b < BANKS; b++) begin : monitors
        assign Active[b] = dut.banks[b].cache.observation.TransactionActive;
    end
    logic [BANKS-1:0][NCORES-1:0][WORDS/BANKS/LINE_WORDS-1:0][1:0] TestPermissions;
    logic [BANKS-1:0] TestLookup;
    for (genvar b = 0; b < BANKS; b++) begin : mesiprobes
        assign TestPermissions[b] = dut.banks[b].cache.observation.Permissions;
        assign TestLookup[b] = dut.banks[b].cache.observation.LookupAccepted;
    end
    function automatic permission_t line_state(input int hart, input int word_index);
        return permission_t'(TestPermissions[(word_index/STRIDE)%BANKS][hart][(word_index/LINE_WORDS) % (WORDS/BANKS/LINE_WORDS)]);
    endfunction
