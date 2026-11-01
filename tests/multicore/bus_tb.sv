// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module bus_tb import cvw::*;();
    `include "parameter-defs.vh"
    localparam NCORES = 3;
    localparam TRANSFERS = 20;
    logic HCLK = 0, HRESETn = 0;
    always #5 HCLK = ~HCLK;
    logic [NCORES-1:0][P.PA_BITS-1:0] CoreHADDR = '0;
    logic [NCORES-1:0][P.AHBW-1:0] CoreHWDATA = '0, CoreHRDATA;
    logic [NCORES-1:0][P.XLEN/8-1:0] CoreHWSTRB = '0;
    logic [NCORES-1:0] CoreHWRITE = '0, CoreHMASTLOCK = '0, CoreHREADY, CoreHRESP;
    logic [NCORES-1:0][2:0] CoreHSIZE = '0, CoreHBURST = '0;
    logic [NCORES-1:0][3:0] CoreHPROT = '0;
    logic [NCORES-1:0][1:0] CoreHTRANS = '0;
    logic [NCORES-1:0][1:0] CoreHATOMIC = '0;
    logic [NCORES-1:0] CoreSCFail;
    logic [P.PA_BITS-1:0] HADDR, SavedAddr;
    logic [P.AHBW-1:0] HWDATA, HRDATA;
    logic [P.XLEN/8-1:0] HWSTRB;
    logic HWRITE, HMASTLOCK, HREADY, HRESP, Active = 0, SavedWrite;
    logic [2:0] HSIZE, HBURST;
    logic [3:0] HPROT;
    logic [1:0] HTRANS;
    int Delay = 0;
    int Served[NCORES] = '{default:0};
    logic [NCORES-1:0] Done = '0;
    ahbmulticore #(.P(P), .NCORES(NCORES)) dut(.ReservationClear('0), .HOWNER(), .CacheReadAddr(), .CacheReadHit('0), .CacheReadData('0), .CacheWriteHit('0), .CacheWriteCommit(), .CacheWriteData(), .CacheWriteStrb(), .InstrMiss(), .*);
    assign HREADY = !Active || Delay == 0;
    assign HRESP = Active && SavedAddr[4:3] == 2'b11 && Delay <= 1;
    assign HRDATA = P.AHBW'(SavedAddr) ^ P.AHBW'('h12345678);
    // A slave with different wait lengths, including two-cycle ERROR responses.
    always @(posedge HCLK) begin
        if (!HRESETn) begin
            Active <= 0;
            Delay <= 0;
        end else if (!Active && HTRANS[1]) begin
            Active <= 1;
            SavedAddr <= HADDR;
            SavedWrite <= HWRITE;
            Delay <= 1 + int'(HADDR[4:3]);
            Served[HADDR[9:8]] <= Served[HADDR[9:8]] + 1;
            assert (HSIZE == 3 && HBURST == 0 && !HMASTLOCK)
                else $fatal(1, "Address control corrupted");
        end else if (Active) begin
            assert (HTRANS == 0 && HADDR == SavedAddr)
                else $fatal(1, "Shared address changed during stalled data phase");
            if (SavedWrite) begin
                assert (HWDATA == (P.AHBW'(SavedAddr) ^ P.AHBW'('hfeed0000)) && HWSTRB == '1)
                    else $fatal(1, "Write data/strobes came from the wrong hart");
            end
            if (Delay == 0) Active <= 0;
            else Delay <= Delay - 1;
        end
    end
    for (genvar h = 0; h < NCORES; h++) begin : masters
        initial begin
            wait (HRESETn);
            @(negedge HCLK);
            CoreHTRANS[h] = 2'b10;
            CoreHADDR[h] = P.PA_BITS'(h*256);
            CoreHWRITE[h] = 0;
            CoreHSIZE[h] = 3;
            CoreHWSTRB[h] = '1;
            do @(posedge HCLK); while (!CoreHREADY[h]);
            for (int seq = 0; seq < TRANSFERS; seq++) begin
                bit saw_error_wait;
                // Present the NEXT address during this data phase to stress reply +
                // next-address acceptance at the same edge. Keep current write data.
                @(negedge HCLK);
                CoreHWDATA[h] = P.AHBW'(h*256+seq*8) ^ P.AHBW'('hfeed0000);
                CoreHADDR[h] = P.PA_BITS'(int'(h*256+(seq+1)*8));
                CoreHWRITE[h] = 1'((seq+1)%2);
                CoreHTRANS[h] = seq == TRANSFERS-1 ? 2'b00 : 2'b10;
                saw_error_wait = 0;
                do begin
                    @(posedge HCLK);
                    if (CoreHRESP[h] && !CoreHREADY[h]) saw_error_wait = 1;
                end while (!CoreHREADY[h]);
                assert (CoreHRDATA[h] == (P.AHBW'(h*256+seq*8) ^ P.AHBW'('h12345678)))
                    else $fatal(1, "Read response delivered to wrong hart/address");
                assert (CoreHRESP[h] == (seq%4 == 3)) else $fatal(1, "ERROR response lost");
                assert (!CoreHRESP[h] || saw_error_wait) else $fatal(1, "Missing first ERROR cycle");
                for (int other = 0; other < NCORES; other++)
                    assert (Served[other] <= Served[h]+1) else $fatal(1, "Round-robin starvation");
            end
            Done[h] = 1;
        end
    end
    initial begin
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        wait (&Done);
        $display("PASS: round-robin, back-to-back addresses, delayed writes, waits and ERROR routing");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Bus test timed out");
    end
endmodule
