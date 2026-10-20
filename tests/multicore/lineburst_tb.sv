// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module lineburst_tb import cvw::*; #(parameter int LATENCY = 0);
    `include "parameter-defs.vh"
    localparam MAX = 32;
    localparam OFFSET = $clog2(P.AHBW/8);
    logic HCLK = 0, HRESETn = 0, Start = 0, Write = 0;
    always #5 HCLK = ~HCLK;
    logic [P.PA_BITS-1:0] Base = '0, HADDR, AddressQ;
    logic [5:0] WordCount = '0;
    logic [P.AHBW-1:0] WriteLine[MAX], ReadLine[MAX], HWDATA, HRDATA, Mem[512];
    logic [P.XLEN/8-1:0] HWSTRB;
    logic HWRITE, Done, Error, HREADY, HRESP;
    logic [2:0] HSIZE, HBURST;
    logic [1:0] HTRANS;
    logic Pending = 0, ErrorQ = 0, ErrorFirst = 0, WriteQ;
    int WaitQ = 0, FaultAt = -1, Accepted = 0, Completed = 0, Writes = 0, Cycle = 0;
    ahblineburst #(.P(P), .MAX_WORDS(MAX)) dut(
        .HCLK, .HRESETn, .Start, .Write, .Base, .WordCount, .Prot(4'b0011),
        .WriteLine, .ReadLine, .Done, .Error, .HADDR, .HWDATA, .HWSTRB,
        .HWRITE, .HSIZE, .HBURST, .HPROT(), .HTRANS, .HRDATA, .HREADY, .HRESP);
    assign HREADY = !Pending || (WaitQ == 0 && (!ErrorQ || ErrorFirst));
    assign HRESP = Pending && WaitQ == 0 && ErrorQ;
    assign HRDATA = Mem[AddressQ[OFFSET +: 9]];
    always @(posedge HCLK) begin
        Cycle <= Cycle+1;
        if (!HRESETn) begin
            Pending <= 0; ErrorFirst <= 0; WaitQ <= 0;
            Accepted <= 0; Completed <= 0; Writes <= 0;
        end else begin
            if (Pending && WaitQ > 0) WaitQ <= WaitQ-1;
            if (Pending && WaitQ == 0 && ErrorQ && !ErrorFirst) ErrorFirst <= 1;
            if (HREADY) begin
                if (Pending && !HRESP) begin
                    Completed <= Completed+1;
                    if (WriteQ) begin
                        assert (HWDATA == WriteLine[Completed] && &HWSTRB)
                            else $fatal(1, "Wrong pipelined write data owner/beat");
                        Mem[AddressQ[OFFSET +: 9]] <= HWDATA;
                        Writes <= Writes+1;
                    end
                end
                Pending <= HTRANS[1];
                if (HTRANS[1]) begin
                    assert (HADDR == Base+(P.PA_BITS'(Accepted) << OFFSET) && HSIZE == 3'(OFFSET))
                        else $fatal(1, "Lost, repeated or misaligned address beat");
                    assert (HTRANS == (Accepted % 16 == 0 ? 2 : 3))
                        else $fatal(1, "Missing NONSEQ/SEQ or chunk restart");
                    assert (HBURST == (WordCount >= 16 ? 7 : WordCount == 8 ? 5 :
                        WordCount == 4 ? 3 : WordCount == 2 ? 1 : 0))
                        else $fatal(1, "Wrong AHB burst encoding");
                    if (HTRANS == 3)
                        assert ((HADDR >> 10) == (HADDR-(P.PA_BITS'(1) << OFFSET)) >> 10)
                            else $fatal(1, "AHB burst crossed 1KiB");
                    AddressQ <= HADDR; WriteQ <= HWRITE; ErrorQ <= Accepted == FaultAt;
                    ErrorFirst <= 0; WaitQ <= LATENCY;
                    Accepted <= Accepted+1;
                end
            end
        end
    end
    task automatic transfer(input int words, input bit wr, input int fault = -1);
        int begin_cycle;
        @(negedge HCLK);
        Accepted = 0; Completed = 0; Writes = 0;
        WordCount = 6'(words); Write = wr; FaultAt = fault;
        Base = P.PA_BITS'('h80000400);
        if (words == 4) Base = Base-(P.PA_BITS'(4) << OFFSET); // End exactly at 1KiB.
        for (int w = 0; w < MAX; w++) WriteLine[w] = P.AHBW'(int'('h1000+words*256+w));
        Start = 1;
        @(negedge HCLK); Start = 0; begin_cycle = Cycle;
        while (!Done) @(negedge HCLK);
        assert (Error == (fault >= 0)) else $fatal(1, "Wrong burst error result");
        assert (Accepted == (fault < 0 ? words : fault+1) && Completed == (fault < 0 ? words : fault))
            else $fatal(1, "Error did not cancel subsequent transfers");
        if (wr) assert (Writes == Completed) else $fatal(1, "Write beat disappeared");
        if (!wr && fault < 0)
            for (int w = 0; w < words; w++)
                assert (ReadLine[w] == Mem[((int'(Base) >> OFFSET)+w) & 511])
                    else $fatal(1, "Read line beat mismatch");
        if (LATENCY == 0 && fault < 0)
            assert (Cycle-begin_cycle == words+1) else $fatal(1, "Zero-wait burst did not pipeline");
        if (fault < 0) $display("BURST: words=%0d write=%0d cycles=%0d", words, wr, Cycle-begin_cycle);
        @(negedge HCLK);
    endtask
    initial begin
        for (int w = 0; w < 512; w++) Mem[w] = P.AHBW'(int'('h8000+w));
        repeat (3) @(negedge HCLK); HRESETn = 1;
        for (int n = 1; n <= MAX; n *= 2) begin
            transfer(n, 0); transfer(n, 1); transfer(n, 0);
            for (int beat = 0; beat < n; beat++) begin
                transfer(n, 0, beat); transfer(n, 1, beat);
            end
        end
        @(negedge HCLK); Accepted = 0; Completed = 0; Writes = 0;
        Start = 1; Write = 0; FaultAt = -1; WordCount = 8;
        @(negedge HCLK); Start = 0;
        repeat (3) @(negedge HCLK);
        HRESETn = 0; repeat (3) @(negedge HCLK); HRESETn = 1;
        assert (!Done && HTRANS == 0) else $fatal(1, "Reset did not abort burst");
        transfer(8, 0);
        $display("PASS: line burst RV%0d waits=%0d, all lengths/error beats/reset", P.XLEN, LATENCY);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "Line burst test timeout");
    end
endmodule
