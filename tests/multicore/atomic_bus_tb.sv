// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module atomic_bus_tb import cvw::*; ();
    `include "parameter-defs.vh"
    localparam NCORES = 3;
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
    ahbmulticore #(.P(P), .NCORES(NCORES)) dut(.HOWNER(), .*);
    logic [63:0] Memory[512];
    int Transfers = 0, Writes = 0;
    assign HREADY = !Active || Delay == 0;
    assign HRESP = Active && SavedAddr[11:0] == 'h3f0 && Delay <= 1;
    assign HRDATA = Memory[SavedAddr[11:3]];
    initial foreach (Memory[i]) Memory[i] = 0;
    always @(posedge HCLK) begin
        if (!HRESETn) begin
            Active <= 0;
            Delay <= 0;
        end else if (!Active && HTRANS[1]) begin
            Active <= 1;
            SavedAddr <= HADDR;
            SavedWrite <= HWRITE;
            Delay <= 2;
            Transfers <= Transfers + 1;
        end else if (Active) begin
            if (Delay == 0) begin
                Active <= 0;
                if (SavedWrite && !HRESP) begin
                    Writes <= Writes + 1;
                    for (int b = 0; b < 8; b++)
                        if (HWSTRB[b]) Memory[SavedAddr[11:3]][8*b +: 8] <= HWDATA[8*b +: 8];
                end
            end else Delay <= Delay - 1;
        end
    end
    task automatic issue(input int h, input int a, input bit wr, input logic [1:0] op,
                         input logic [63:0] value = 0, input int size = 3, input logic [7:0] mask = '1);
        @(negedge HCLK);
        CoreHADDR[h] = P.PA_BITS'(a); CoreHWRITE[h] = wr;
        CoreHSIZE[h] = 3'(size); CoreHATOMIC[h] = op; CoreHTRANS[h] = 2'b10;
        do @(posedge HCLK); while (!CoreHREADY[h]);
        @(negedge HCLK);
        CoreHTRANS[h] = 0; CoreHWDATA[h] = value; CoreHWSTRB[h] = mask;
    endtask
    task automatic reply(input int h, input bit scfail = 0, input bit error = 0);
        bit first_error;
        first_error = 0;
        do begin
            @(posedge HCLK);
            if (CoreHRESP[h] && !CoreHREADY[h]) first_error = 1;
        end while (!CoreHREADY[h]);
        assert (CoreHRESP[h] == error && (!error || first_error)) else $fatal(1, "Wrong ERROR response");
        if (CoreHATOMIC[h] == 2)
            assert (CoreSCFail[h] == scfail) else $fatal(1, "Wrong SC result for hart %0d", h);
    endtask
    task automatic access(input int h, input int a, input bit wr, input logic [1:0] op,
                          input logic [63:0] value = 0, input bit scfail = 0,
                          input int size = 3, input logic [7:0] mask = '1, input bit error = 0);
        issue(h,a,wr,op,value,size,mask);
        reply(h,scfail,error);
    endtask
    initial begin
        int count;
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        access(0,'h100,1,0,5);
        count = Transfers;
        access(0,'h100,1,2,99,1);
        assert (Transfers == count && Memory['h20] == 5) else $fatal(1, "SC without LR touched memory");
        access(0,'h100,0,1);
        access(1,'h100,1,0,5); // Same-value write still invalidates a reservation (ABA).
        count = Transfers;
        access(0,'h100,1,2,99,1);
        assert (Transfers == count) else $fatal(1, "Invalidated SC reached memory");
        access(0,'h100,0,1);
        access(1,'h108,1,0,17); // A different granule must not invalidate it.
        access(0,'h100,1,2,9);
        assert (Memory['h20] == 9) else $fatal(1, "Successful SC did not store");
        access(0,'h100,1,2,99,1); // SC always consumes the reservation.
        access(0,'h100,0,1);
        access(0,'h108,0,1); // A new LR replaces the previous reservation.
        access(0,'h100,1,2,99,1);
        access(0,'h108,1,2,99,1); // Even a failed SC consumes it.
        access(0,'h104,0,1,0,0,2);
        access(1,'h100,1,0,0,0,0,8'h01); // Byte store in the other half of the granule.
        access(0,'h104,1,2,64'h0100000000,1,2,8'hf0);
        access(0,'h100,0,1,0,0,2);
        access(0,'h100,1,2,99,1,3); // Different size must fail.

        // AMO lock covers both transfers, and allows owner instruction fetches.
        access(2,'h100,0,1);
        access(1,'h100,0,3);
        assert (HMASTLOCK) else $fatal(1, "AMO did not retain the lock after its read");
        issue(0,'h100,1,0,77);
        access(1,'h180,0,0); // Owner can fetch while another hart is queued.
        assert (!CoreHREADY[0]) else $fatal(1, "Another hart passed the AMO lock");
        access(1,'h100,1,3,10);
        reply(0);
        assert (Memory['h20] == 77) else $fatal(1, "AMO/store ordering incorrect");
        access(2,'h100,1,2,99,1); // AMO and ordinary stores invalidate LR.

        // A queued SC must be rechecked AFTER a preceding AMO write commits.
        access(0,'h100,0,1);
        access(1,'h100,0,3);
        issue(0,'h100,1,2,99);
        access(1,'h100,1,3,12);
        reply(0,1);
        assert (Memory['h20] == 12) else $fatal(1, "Queued SC used a stale reservation");

        // Failed reads do not establish reservations; errors release AMO locks.
        access(0,'h3f0,0,1,0,0,3,'1,1);
        access(0,'h3f0,1,2,99,1);
        access(0,'h3f0,0,3,0,0,3,'1,1);
        access(1,'h100,0,0);
        count = Transfers;
        access(0,'h3f0,1,3,99,0,3,'1,1);
        assert (Transfers == count) else $fatal(1, "Aborted AMO wrote memory");
        access(0,'h100,0,1);
        @(negedge HCLK); HRESETn = 0;
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        access(0,'h100,1,2,99,1);
        $display("PASS: LR/SC invalidation, consumption, lanes, stale queued SC, AMO exclusion and error/reset recovery");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"Atomic bus test timed out");
    end
endmodule
