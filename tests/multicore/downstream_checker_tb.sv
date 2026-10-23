// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module downstream_checker_tb;
    logic HCLK = 0, HRESETn = 0;
    logic [39:0] HADDR = '0;
    logic [63:0] HWDATA = '0;
    logic [7:0] HWSTRB = '0;
    logic [2:0] HSIZE = 3, HBURST = 3;
    logic [1:0] HTRANS = 0;
    logic HREADY = 1, HRESP = 0, WriteDataWait = 0;
    int unsigned SequentialBeats;
    string mutation = "none";
    always #5 HCLK = ~HCLK;

    ahb_downstream_checker checker_inst(.*);

    initial begin
        void'($value$plusargs("mutation=%s", mutation));
        repeat (2) @(negedge HCLK);
        HRESETn = 1;
        HTRANS = 2;
        HADDR = 0;
        @(negedge HCLK);
        HTRANS = 0;
        @(negedge HCLK);

        if (mutation == "malformed-seq") begin
            HTRANS = 3;
            HADDR = 16;
            @(negedge HCLK);
        end else begin
            HTRANS = 3;
            HADDR = 8;
            @(negedge HCLK);
            HTRANS = 0;
            WriteDataWait = 1;
            HREADY = 0;
            HWDATA = 'h1234;
            HWSTRB = 'hff;
            @(negedge HCLK);
            if (mutation == "write-data")
                HWDATA = 'h5678;
            @(negedge HCLK);
            WriteDataWait = 0;
            HREADY = 1;
        end
        if (mutation == "none") begin
            repeat (2) @(negedge HCLK);
            assert (SequentialBeats == 1) else $fatal(1, "Expected one accepted SEQ beat");
            $display("PASS: downstream AHB checker accepted stable wait data and valid INCR4 sequence");
            $finish;
        end else begin
            $fatal(1, "Expected checker mutation to fail: %s", mutation);
        end
    end
    initial begin
        #1000;
        $fatal(1, "Downstream checker fixture timeout");
    end
endmodule
