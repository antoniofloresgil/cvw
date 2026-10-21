// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module csrc_tb import cvw::*; #(
    parameter int COUNTER_COUNT = 32,
    parameter int SSCOFPMF = 0,
    parameter int SMCNTRPMF = 0
);
    `include "parameter-defs.vh"
    function automatic cvw_t configuration();
        cvw_t c = P;
        c.COUNTERS = 12'(COUNTER_COUNT);
        c.SSCOFPMF_SUPPORTED = (SSCOFPMF != 0);
        c.SMCNTRPMF_SUPPORTED = (SMCNTRPMF != 0);
        return c;
    endfunction
    localparam cvw_t C = configuration();
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    logic valid = 0, wrong = 0;
    logic [3:0] iclass = 0;
    logic daccess = 0, dmiss = 0, iaccess = 0, imiss = 0;
    logic write_csr = 0;
    logic [11:0] address = 0;
    logic [P.XLEN-1:0] wdata = 0, rdata;
    logic illegal, overflow_pulse;
    logic [31:0] inhibit = '1, men = '1, sen = '1;
    logic [1:0] privilege = 3;
    csrc #(.P(C)) dut(
        .clk, .reset, .StallE(1'b0), .StallM(1'b0), .StallW(1'b0), .FlushM(1'b0),
        .InstrValidNotFlushedM(valid), .LoadStallD(1'b0), .StoreStallD(1'b0),
        .CSRMWriteM(write_csr), .CSRWriteM(write_csr), .BPDirWrongM(1'b0), .BTAWrongM(1'b0),
        .RASPredPCWrongM(1'b0), .IClassWrongM(1'b0), .BPWrongM(wrong), .IClassM(iclass),
        .DCacheMiss(dmiss), .DCacheAccess(daccess), .ICacheMiss(imiss), .ICacheAccess(iaccess),
        .ICacheStallF(1'b0), .DCacheStallM(1'b0), .sfencevmaM(1'b0), .InterruptM(1'b0),
        .TrapM(1'b0), .InvalidateICacheM(1'b0), .DivBusyE(1'b0), .FDivBusyE(1'b0),
        .CSRAdrM(address), .PrivilegeModeW(privilege), .CSRWriteValM(wdata),
        .MCOUNTINHIBIT_REGW(inhibit), .MCOUNTEREN_REGW(men), .SCOUNTEREN_REGW(sen),
        .MTIME_CLINT(64'h1122334455667788), .CSRCReadValM(rdata), .IllegalCSRCAccessM(illegal),
        .LCOFIPSetM(overflow_pulse));
    task automatic put(input int csr, input logic [P.XLEN-1:0] value);
        @(negedge clk); address = 12'(csr); wdata = value; write_csr = 1;
        @(negedge clk); write_csr = 0;
    endtask
    task automatic expect_csr(input int csr, input logic [P.XLEN-1:0] value, input bit bad = 0);
        @(negedge clk); address = 12'(csr); #1;
        assert (illegal == bad && (bad || rdata == value))
            else $fatal(1, "CSR %h priv %0d read %h illegal=%0d expected %h illegal=%0d", csr, privilege, rdata, illegal, value, bad);
    endtask
    task automatic stimulus(input logic [3:0] kind, input bit retired, input bit mispred);
        @(negedge clk); iclass = kind; valid = retired; wrong = mispred;
        @(negedge clk); iclass = 0; valid = 0; wrong = 0;
    endtask
    initial begin
        repeat (3) @(negedge clk); reset = 0;
        // Read-only time shadows, machine-time hole, and RV32 split aliases.
        expect_csr('hc01, P.XLEN'(64'h1122334455667788));
        expect_csr('hb01, 0, 1);
        if (P.XLEN == 32) expect_csr('hc81, 'h11223344);
        else expect_csr('hc80, 0, 1);
        put('hb00, P.XLEN'('hfedcba98)); put('hb02, 'h1234);
        expect_csr('hb00, P.XLEN'('hfedcba98)); expect_csr('hc00, P.XLEN'('hfedcba98));
        expect_csr('hc02, 'h1234);
        if (COUNTER_COUNT > 3) begin
            for (int c = 3; c < COUNTER_COUNT; c++) begin
                put('h320+c, 1); put('hb00+c, 0);
            end
            inhibit = 0;
            stimulus(1, 1, 0); // conditional
            stimulus(2, 1, 1); // jump
            stimulus(6, 1, 1); // return: Jump and Return overlap, count once
            stimulus(8, 1, 1); // invalid Call-without-Jump encoding: no control-transfer event
            stimulus(1, 0, 1); // flushed/invalid instruction must not count
            inhibit = '1;
            expect_csr('hb03, 1);
            if (COUNTER_COUNT > 26) begin
                expect_csr('hb19, 3); expect_csr('hb1a, 2);
                // Disable selectors, then enable inhibition, independently.
                put('h339, 0); put('h33a, 0); inhibit = 0;
                stimulus(1, 1, 1); inhibit = '1;
                expect_csr('hb19, 3); expect_csr('hb1a, 2);
                put('h339, 1); put('h33a, 1);
                stimulus(1, 1, 1);
                expect_csr('hb19, 3); expect_csr('hb1a, 2);
                // Standard S/U aliases are gated by both counter-enable CSRs.
                privilege = 1; expect_csr('hc19, 3);
                men[25] = 0; expect_csr('hc19, 0, 1); men[25] = 1;
                privilege = 0; expect_csr('hc19, 3);
                sen[25] = 0; expect_csr('hc19, 0, 1); sen[25] = 1;
                privilege = 3;
            end
            // Cache access/miss pulses are independent from instruction retirement.
            if (COUNTER_COUNT > 17) begin
                put('h32d, 1); put('h32e, 1); put('h330, 1); put('h331, 1);
                inhibit = 0;
                @(negedge clk); daccess = 1; dmiss = 1; iaccess = 1; imiss = 1;
                @(negedge clk); dmiss = 0; imiss = 0;
                @(negedge clk); daccess = 0; iaccess = 0; inhibit = '1;
                expect_csr('hb0d, 2); expect_csr('hb0e, 1);
                expect_csr('hb10, 2); expect_csr('hb11, 1);
            end
        end
        if (COUNTER_COUNT < 32) begin
            expect_csr('hb1f, 0); expect_csr('h33f, 0);
        end
        // CSR writes take precedence; RV32 carry propagates into the high CSR.
        put('hb00, '1);
        if (P.XLEN == 32) put('hb80, 'h12345678);
        @(negedge clk); inhibit = 32'hfffffffe;
        @(negedge clk); inhibit = '1;
        expect_csr('hb00, 0);
        if (P.XLEN == 32) expect_csr('hb80, 'h12345679);
        if (SSCOFPMF != 0 && COUNTER_COUNT > 3) begin
            // MINH suppresses M-mode events; S-mode still counts the same event.
            inhibit = '1;
            put('hb03, 0);
            if (P.XLEN == 32) begin
                put('h323, 0);
                put('h723, P.XLEN'('h80000000));
            end else put('h323, P.XLEN'(64'h8000000000000000));
            inhibit[3] = 0;
            stimulus(1, 1, 0);
            inhibit = '1;
            expect_csr('hb03, 0); // OF alone is not an event selection.
            if (P.XLEN == 32) begin
                put('h323, 1);
                put('h723, 'h40000000);
                expect_csr('h723, 'h40000000);
            end else put('h323, P.XLEN'(64'h4000000000000001));
            inhibit[3] = 0;
            stimulus(1, 1, 0);
            inhibit = '1;
            expect_csr('hb03, 0);
            privilege = 1;
            inhibit[3] = 0;
            stimulus(1, 1, 0);
            inhibit = '1;
            expect_csr('hc03, 1);
            privilege = 3;
            // A hardware increment across 64 bits sets OF and requests one interrupt.
            if (P.XLEN == 32) begin
                put('hb03, '1);
                put('hb83, '1);
                put('h723, 0);
            end else begin
                put('hb03, '1);
                put('h323, 1);
            end
            @(negedge clk); iclass = 1; valid = 1; inhibit[3] = 0;
            #1; assert (overflow_pulse) else $fatal(1, "missing overflow pulse");
            @(negedge clk); iclass = 0; valid = 0; inhibit = '1;
            #1; assert (!overflow_pulse) else $fatal(1, "overflow request must be one-shot");
            expect_csr('hda0, 8);
            men[3] = 0;
            privilege = 1; expect_csr('hda0, 0);
            privilege = 0; expect_csr('hda0, 0, 1);
            privilege = 3; expect_csr('hda0, 8);
            men[3] = 1;
            @(negedge clk); address = 'hda0; write_csr = 1; #1;
            assert (illegal) else $fatal(1, "scountovf write must fault");
            write_csr = 0;
            if (P.XLEN == 32) put('h723, 0);
            else put('h323, 1);
            expect_csr('hda0, 0);
            // A selector write cannot hide a simultaneous hardware wrap.
            put('hb03, '1);
            if (P.XLEN == 32) put('hb83, '1);
            @(negedge clk); address = 'h323; wdata = 1; write_csr = 1;
            iclass = 1; valid = 1; inhibit[3] = 0;
            #1; assert (overflow_pulse) else $fatal(1, "simultaneous selector write lost overflow");
            @(negedge clk); write_csr = 0; iclass = 0; valid = 0; inhibit = '1;
            expect_csr('hda0, 8);
        end else begin
            expect_csr('hda0, 0, 1);
            if (P.XLEN == 32) expect_csr('h723, 0, 1);
        end
        if (SMCNTRPMF != 0) begin
            // The fixed counter filters are 64-bit even on RV32. OF and all
            // unsupported/reserved fields read zero.
            inhibit = '1;
            privilege = 3;
            if (P.XLEN == 32) begin
                put('h721, P.XLEN'('hffffffff));
                put('h722, P.XLEN'('hffffffff));
                expect_csr('h721, P.XLEN'('h70000000));
                expect_csr('h722, P.XLEN'('h70000000));
                put('h321, P.XLEN'('hffffffff));
                put('h322, P.XLEN'('hffffffff));
                expect_csr('h321, 0);
                expect_csr('h322, 0);
                expect_csr('h721, P.XLEN'('h70000000));
                expect_csr('h722, P.XLEN'('h70000000));
                put('h721, P.XLEN'('h60000000));
                put('h722, P.XLEN'('h60000000));
            end else begin
                put('h321, '1);
                put('h322, '1);
                expect_csr('h321, P.XLEN'(64'h7000000000000000));
                expect_csr('h322, P.XLEN'(64'h7000000000000000));
                put('h321, P.XLEN'(64'h6000000000000000));
                put('h322, P.XLEN'(64'h6000000000000000));
            end
            put('hb00, 0); put('hb02, 0);
            if (P.XLEN == 32) begin put('hb80, 0); put('hb82, 0); end
            @(negedge clk); valid = 1; inhibit[0] = 0; inhibit[2] = 0;
            repeat (3) @(negedge clk); // M-mode excluded
            privilege = 1;
            repeat (2) @(negedge clk); // S-mode excluded
            privilege = 0;
            repeat (4) @(negedge clk); // U-mode included
            valid = 0; inhibit = '1;
            expect_csr('hc00, 4);
            expect_csr('hc02, 4);
            privilege = 3;
            // Filters are independent: U increments cycle, M increments instret.
            if (P.XLEN == 32) put('h722, P.XLEN'('h10000000));
            else put('h322, P.XLEN'(64'h1000000000000000));
            put('hb00, 0); put('hb02, 0);
            @(negedge clk); privilege = 0; valid = 1; inhibit[0] = 0; inhibit[2] = 0;
            repeat (2) @(negedge clk);
            privilege = 3;
            repeat (2) @(negedge clk);
            valid = 0; inhibit = '1;
            expect_csr('hb00, 2);
            expect_csr('hb02, 2);
            privilege = 1;
            expect_csr('h321, 0, 1);
            expect_csr('h322, 0, 1);
            if (P.XLEN == 32) expect_csr('h721, 0, 1);
            privilege = 3;
        end else begin
            expect_csr('h321, 0, 1);
            expect_csr('h322, 0, 1);
            if (P.XLEN == 32) begin
                expect_csr('h721, 0, 1);
                expect_csr('h722, 0, 1);
            end
        end
        $display("PASS: RV%0d %0d counter CSR permissions, fixed events, enable/inhibit and rollover", P.XLEN, COUNTER_COUNT);
        $finish;
    end
endmodule
