// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Pin-level contracts of the extracted engines: priority and zero-cycle reads.
`include "config.vh"
module engines_tb import cvw::*; ();
    `include "parameter-defs.vh"
    localparam N = 3;
    localparam W = 16;
    localparam L = 4;
    localparam OFFSET = $clog2(P.AHBW/8);
    localparam logic [P.PA_BITS-1:0] A = P.PA_BITS'(P.UNCORE_RAM_BASE);
    localparam logic [P.PA_BITS-1:0] B = A + (P.PA_BITS'(W) << OFFSET);
    logic clk = 0, resetn = 0;
    always #5 clk = ~clk;
    logic [1:0] query = 0, completed_owner = 0, issue_op = 0, completed_op = 0;
    logic [P.PA_BITS-1:0] query_addr = A, completed_addr = A;
    logic [2:0] query_size = 3'(OFFSET), completed_size = 3'(OFFSET);
    logic blocked = 0, issue = 0, complete = 0, completed_write = 0, completed_error = 0, sc_valid;
    logic [N-1:0] clear = '0, local_commit = '0, sc_fail;
    logic [N-1:0][P.PA_BITS-1:0] local_addr = '0;
    multicore_reservations #(.P(P), .NCORES(N)) reservations(
        .HCLK(clk), .HRESETn(resetn), .QueryOwner(query), .QueryAddr(query_addr), .QuerySize(query_size),
        .QueryBlocked(blocked), .SCValid(sc_valid), .Issue(issue), .IssueOp(issue_op), .Complete(complete),
        .CompleteOwner(completed_owner), .CompleteAddr(completed_addr), .CompleteSize(completed_size),
        .CompleteOp(completed_op), .CompleteWrite(completed_write), .CompleteError(completed_error),
        .ReservationClear(clear), .LocalStoreCommit(local_commit), .LocalStoreAddr(local_addr), .SCFail(sc_fail));
    logic [N-1:0][P.PA_BITS-1:0] probe_addr = '0;
    logic [N-1:0] i_hit;
    logic [N-1:0][P.AHBW-1:0] i_data;
    logic global_write = 0, invalidate = 0, fill = 0, last = 0;
    logic [1:0] fill_owner = 0;
    logic [P.PA_BITS-1:0] global_addr = A, fill_addr = A, fill_word = A;
    logic [P.AHBW-1:0] fill_data = '0;
    multicore_icache_bank #(.P(P), .NCORES(N), .WORDS(W), .LINE_WORDS(L)) instructions(
        .HCLK(clk), .HRESETn(resetn), .ProbeAddr(probe_addr), .ProbeHit(i_hit), .ProbeData(i_data),
        .LocalStoreCommit(local_commit), .LocalStoreAddr(local_addr), .GlobalWrite(global_write), .GlobalAddr(global_addr),
        .FillInvalidate(invalidate), .FillBeat(fill), .FillLast(last), .FillOwner(fill_owner),
        .FillAddr(fill_addr), .FillWordAddr(fill_word), .FillData(fill_data));
    // A one-word I bank makes first/final fill coincide with old-tag invalidation.
    logic short_fill = 0;
    logic [P.PA_BITS-1:0] short_addr = A;
    logic [P.AHBW-1:0] short_data = 'h600;
    logic [N-1:0] short_hit;
    logic [N-1:0][P.AHBW-1:0] short_read;
    multicore_icache_bank #(.P(P), .NCORES(N), .WORDS(W), .LINE_WORDS(1)) short_instructions(
        .HCLK(clk), .HRESETn(resetn), .ProbeAddr({N{short_addr}}), .ProbeHit(short_hit), .ProbeData(short_read),
        .LocalStoreCommit(local_commit), .LocalStoreAddr(local_addr), .GlobalWrite(global_write), .GlobalAddr(global_addr),
        .FillInvalidate(1'b0), .FillBeat(short_fill), .FillLast(1'b1), .FillOwner(2'd0),
        .FillAddr(short_addr), .FillWordAddr(short_addr), .FillData(short_data));
    logic [N-1:0][$clog2(W)-1:0] local_index = '0;
    logic [N-1:0][P.AHBW-1:0] d_local_data;
    logic [1:0] word_owner = 0, line_owner = 0, write_owner = 0;
    logic [$clog2(W)-1:0] word_index = 0, store_index = 0;
    logic [$clog2(W/L)-1:0] line_index = 0, install_index = 0;
    logic [P.AHBW-1:0] word_data, line_data[L], install_line[L], store_data = '0;
    logic install = 0, store = 0;
    logic [P.XLEN/8-1:0] strb = '0;
    logic [N-1:0] d_local_store = '0;
    logic [N-1:0][P.AHBW-1:0] d_store_data = '0;
    logic [N-1:0][P.XLEN/8-1:0] d_store_strb = '0;
    multicore_dcache_data #(.P(P), .NCORES(N), .WORDS(W), .LINE_WORDS(L)) data_bank(
        .HCLK(clk), .HRESETn(resetn), .LocalWordIndex(local_index), .LocalReadData(d_local_data),
        .WordReadOwner(word_owner), .LineReadOwner(line_owner), .WordReadIndex(word_index),
        .LineReadIndex(line_index), .WordReadData(word_data), .LineReadData(line_data),
        .Install(install), .Store(store), .WriteOwner(write_owner), .InstallIndex(install_index),
        .InstallLine(install_line), .StoreIndex(store_index), .StoreData(store_data), .StoreStrb(strb),
        .LocalStore(d_local_store), .LocalStoreData(d_store_data), .LocalStoreStrb(d_store_strb));
    task automatic tick();
        @(posedge clk); @(negedge clk);
    endtask
    task automatic lr(input logic [P.PA_BITS-1:0] address);
        query_addr = address; issue = 1; issue_op = 1; tick(); issue = 0;
        complete = 1; completed_op = 1; completed_addr = address; tick(); complete = 0;
    endtask
    task automatic iline(input logic [P.PA_BITS-1:0] address);
        fill_addr = address; invalidate = 1; tick(); invalidate = 0;
        for (int w = 0; w < L; w++) begin
            fill = 1; last = w == L-1;
            fill_word = address + (P.PA_BITS'(w) << OFFSET); fill_data = P.AHBW'('h500+w); tick();
            assert (i_hit[0] == last) else $fatal(1, "Partial I line became visible");
        end
        fill = 0; last = 0;
    endtask
    initial begin
        for (int w = 0; w < L; w++) install_line[w] = P.AHBW'('h100+w);
        tick(); resetn = 1;
        // Replace old LR while a local writer commits to the OLD word.
        lr(A);
        assert (sc_valid) else $fatal(1, "LR was not installed");
        blocked = 1; #1;
        assert (!sc_valid) else $fatal(1, "SC bypassed same-cycle ordering hazard");
        blocked = 0;
        query_size = 0; #1;
        assert (!sc_valid) else $fatal(1, "SC size mismatch matched");
        query_size = 3'(OFFSET); query_addr = B;
        local_addr[1] = A; local_commit[1] = 1;
        complete = 1; completed_addr = B; completed_op = 1; tick(); complete = 0; local_commit = '0;
        assert (sc_valid) else $fatal(1, "Stale LR word cleared replacement reservation");
        // A commit to the NEW word on the same LR edge must win.
        local_addr[1] = B; local_commit[1] = 1; complete = 1; tick(); complete = 0; local_commit = '0;
        assert (!sc_valid) else $fatal(1, "LR survived a same-edge conflicting local store");
        issue = 1; issue_op = 2; tick(); issue = 0;
        assert (sc_fail[0]) else $fatal(1, "Failed SC did not latch result");
        lr(B);
        assert (sc_fail[0]) else $fatal(1, "Unrelated LR overwrote sticky SC result");
        issue = 1; issue_op = 2; tick(); issue = 0;
        assert (!sc_valid && sc_fail[0]) else $fatal(1, "SC issue did not consume LR or changed result early");
        complete = 1; completed_op = 2; completed_write = 1; tick(); complete = 0; completed_write = 0;
        assert (!sc_fail[0]) else $fatal(1, "Successful SC did not replace result");
        complete = 1; completed_op = 1; clear[0] = 1; tick(); complete = 0; clear = '0;
        assert (!sc_valid) else $fatal(1, "Cross-home clear lost priority over LR");
        lr(B); complete = 1; completed_op = 0; completed_write = 1; completed_addr = B+1; tick();
        complete = 0; completed_write = 0;
        assert (!sc_valid) else $fatal(1, "Partial ordinary write did not invalidate XLEN granule");
        // I-bank refill visibility, victim alias invalidation and broadcast.
        probe_addr[0] = A; iline(A);
        assert (i_data[0] == 'h500) else $fatal(1, "I word lookup changed");
        probe_addr[0] = A + (P.PA_BITS'(2) << OFFSET); #1;
        assert (i_hit[0] && i_data[0] == 'h502) else $fatal(1, "I read added latency");
        short_fill = 1; tick(); short_fill = 0;
        assert (short_hit[0]) else $fatal(1, "Victim fixture did not install its old tag");
        short_addr = B; short_data = 'h700; local_addr[1] = A; local_commit[1] = 1;
        short_fill = 1; tick(); short_fill = 0; local_commit = '0;
        assert (short_hit[0] && short_read[0] == 'h700) else $fatal(1, "Victim invalidation erased replacement I fill");
        global_addr = B+1; global_write = 1; tick(); global_write = 0;
        assert (!short_hit[0]) else $fatal(1, "Global partial store retained I copy");
        probe_addr[0] = B;
        iline(B); invalidate = 1; tick(); invalidate = 0;
        fill = 1; last = 0; tick(); fill = 0; invalidate = 1; tick(); invalidate = 0;
        assert (!i_hit[0]) else $fatal(1, "Cancelled I fill exposed data");
        // Data install + byte merge, independent local writers and async ports.
        install = 1; tick(); install = 0;
        assert (word_data == 'h100) else $fatal(1, "Data installation changed");
        for (int w = 0; w < L; w++) install_line[w] = P.AHBW'(64'h89abcdef12340200+w);
        install = 1; store = 1; store_index = 2; strb = (P.XLEN/8)'(3); store_data = 'hcafe;
        d_local_store = 3'b110; d_store_strb = '1; d_store_data[1] = 'h1111; d_store_data[2] = 'h2222;
        word_index = 2; #1;
        assert (word_data == 'h102) else $fatal(1, "Writes changed RAM before the edge");
        tick(); install = 0; store = 0; d_local_store = '0;
        assert (word_data == P.AHBW'(64'h89abcdef1234cafe) && d_local_data[1] == 'h1111 && d_local_data[2] == 'h2222)
            else $fatal(1, "Fill/store merge or parallel local writes changed");
        for (int w = 0; w < L; w++)
            assert (line_data[w] == (w == 2 ? P.AHBW'(64'h89abcdef1234cafe) : P.AHBW'(64'h89abcdef12340200+w)))
                else $fatal(1, "Full-line port lost a word");
        word_index = 3; #1;
        assert (word_data == P.AHBW'(64'h89abcdef12340203)) else $fatal(1, "Word read added a cycle");
        probe_addr[0] = B; iline(B);
        issue = 1; issue_op = 2; tick(); issue = 0;
        lr(B);
        assert (i_hit[0] && sc_fail[0] && sc_valid) else $fatal(1, "Reset fixture did not establish live metadata");
        resetn = 0; tick(); resetn = 1;
        assert (i_hit == 0 && sc_fail == 0 && !sc_valid && word_data == P.AHBW'(64'h89abcdef12340203))
            else $fatal(1, "Reset did not clear metadata or incorrectly reset RAM contents");
        $display("PASS: extracted reservations and I/D storage contracts, RV%0d", P.XLEN);
        $finish;
    end
    initial begin
        repeat (200) @(posedge clk);
        $fatal(1, "Engine fixture timed out");
    end
endmodule
