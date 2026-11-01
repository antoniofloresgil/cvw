// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive snapshot/event adapter. Only this binding knows cache FSM symbols.
module multicore_cache_observer import cvw::*; import multicore_observation::*; #(
    parameter cvw_t P,
    parameter int NCORES = 2, WORDS = 32, LINE_WORDS = 4,
    parameter logic [1:0] RAW_I = 0, RAW_S = 1, RAW_M = 2, RAW_E = 3,
    parameter int OFFSET = $clog2(P.AHBW/8),
    parameter int INDEX = $clog2(WORDS/LINE_WORDS),
    parameter int LINE_OFFSET = OFFSET + $clog2(LINE_WORDS),
    parameter int TAG_BITS = P.PA_BITS-LINE_OFFSET-INDEX
)(
    input logic [NCORES-1:0][WORDS/LINE_WORDS-1:0][1:0] RawStates,
    input logic [TAG_BITS-1:0] Tags[NCORES][WORDS/LINE_WORDS],
    input logic [P.AHBW-1:0] Lines[NCORES][WORDS],
    input logic TransactionActive, LookupAccepted, FillDataAccepted
);
    permission_t [NCORES-1:0][WORDS/LINE_WORDS-1:0] Permissions;
    always_comb
        for (int h = 0; h < NCORES; h++)
            for (int l = 0; l < WORDS/LINE_WORDS; l++)
                case (RawStates[h][l])
                    RAW_I: Permissions[h][l] = OBS_INVALID;
                    RAW_S: Permissions[h][l] = OBS_SHARED;
                    RAW_M: Permissions[h][l] = OBS_MODIFIED;
                    RAW_E: Permissions[h][l] = OBS_EXCLUSIVE;
                    default: Permissions[h][l] = permission_t'('x);
                endcase
    function automatic permission_t line_state(input int hart, input int word_index);
        assert (hart >= 0 && hart < NCORES && word_index >= 0)
            else $fatal(1, "observation contract: invalid permission query");
        return Permissions[hart][(word_index/LINE_WORDS) % (WORDS/LINE_WORDS)];
    endfunction
    function automatic bit has_line(input int hart, input logic [P.PA_BITS-1:0] address);
        int l;
        l = int'((address >> LINE_OFFSET) % P.PA_BITS'(WORDS/LINE_WORDS));
        return Permissions[hart][l] != OBS_INVALID && Tags[hart][l] == TAG_BITS'(address >> (LINE_OFFSET+INDEX));
    endfunction
endmodule

bind ahbmsicache multicore_cache_observer #(
    .P(P), .NCORES(NCORES), .WORDS(WORDS), .LINE_WORDS(LINE_WORDS),
    .RAW_I(I), .RAW_S(S), .RAW_M(M), .RAW_E(E)
) observation(
    .RawStates(States), .Tags, .Lines,
    .TransactionActive(State != IDLE && State != REPLY),
    .LookupAccepted(State == LOOKUP),
    .FillDataAccepted(State == DATA && (Transfer == FILL || Transfer == IFILL) && HREADY)
);
