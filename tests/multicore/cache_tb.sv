// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module cache_tb import cvw::*; ();
    `include "parameter-defs.vh"
    logic clk = 0, resetn = 0;
    always #5 clk = ~clk;
    logic [P.PA_BITS-1:0] addr = '0, downaddr;
    logic [63:0] wdata = 0, rdata, downwdata, downrdata;
    logic [7:0] strb = 0, downstrb;
    logic wr = 0, ready, resp, downwrite, downready, downresp, lock = 0, downlock;
    logic [2:0] size = 3, downsize, downburst;
    logic [3:0] downprot;
    logic [1:0] trans = 0, downtrans;
    logic [63:0] mem [32];
    logic pending = 0, writeq, errorq;
    logic [P.PA_BITS-1:0] addrq;
    integer delayq = 0, transfers = 0, byte_reads = 0;
    ahbsharedcache #(.P(P), .WORDS(4)) dut(
        .HCLK(clk), .HRESETn(resetn), .UpHADDR(addr), .UpHWDATA(wdata), .UpHWSTRB(strb),
        .UpHWRITE(wr), .UpHMASTLOCK(lock), .UpHSIZE(size), .UpHBURST(3'b000),
        .UpHPROT(4'b0011), .UpHTRANS(trans), .UpHRDATA(rdata), .UpHREADY(ready), .UpHRESP(resp),
        .HADDR(downaddr), .HWDATA(downwdata), .HWSTRB(downstrb), .HWRITE(downwrite), .HMASTLOCK(downlock),
        .HSIZE(downsize), .HBURST(downburst), .HPROT(downprot), .HTRANS(downtrans),
        .HRDATA(downrdata), .HREADY(downready), .HRESP(downresp));
    assign downready = !pending || delayq == 0;
    assign downresp = pending && errorq;
    assign downrdata = mem[addrq[7:3]];
    always @(posedge clk) begin
        if (!resetn) begin
            pending <= 0;
            delayq <= 0;
        end else if (pending) begin
            if (delayq != 0) delayq <= delayq - 1;
            else begin
                if (writeq && !errorq)
                    for (int b = 0; b < 8; b++)
                        if (downstrb[b]) mem[addrq[7:3]][8*b +: 8] <= downwdata[8*b +: 8];
                pending <= 0;
            end
        end else if (downtrans[1]) begin
            pending <= 1;
            addrq <= downaddr;
            writeq <= downwrite;
            errorq <= downaddr == P.PA_BITS'('h800000f8);
            delayq <= 3;
            transfers <= transfers + 1;
            if (!downwrite && downaddr < P.PA_BITS'('h80000000)) byte_reads <= byte_reads + 1;
            if (!downwrite && downaddr >= P.PA_BITS'('h80000000))
                assert (downsize == 3 && downaddr[2:0] == 0) else $fatal(1, "Incomplete cache fill");
            if (downaddr == P.PA_BITS'('h10000001))
                assert (downsize == 0) else $fatal(1, "MMIO size changed");
            assert (downlock == lock) else $fatal(1, "Lost AMO lock");
        end
    end
    task automatic access(input bit write_access, input logic [31:0] address,
        input logic [2:0] access_size, input logic [63:0] value,
        input logic [7:0] strobes, input logic [63:0] expected, input bit error_expected = 0);
        @(negedge clk);
        assert (ready) else $fatal(1, "Not ready for address");
        addr = P.PA_BITS'(address);
        wr = write_access;
        size = access_size;
        trans = 2;
        @(negedge clk);
        trans = 0;
        wdata = value;
        strb = strobes;
        while (!ready) @(negedge clk);
        assert (resp == error_expected) else $fatal(1, "Unexpected response");
        if (!write_access && !error_expected)
            assert (rdata == expected) else $fatal(1, "Read %h: got %h expected %h", address, rdata, expected);
        @(negedge clk);
    endtask
    initial begin
        for (int i = 0; i < 32; i++) mem[i] = 64'h12340000 + 64'(i);
        repeat (3) @(negedge clk);
        resetn = 1;
        access(0, 'h80000004, 2, 0, 0, 'h12340000);
        access(0, 'h80000000, 3, 0, 0, 'h12340000);
        assert (transfers == 1) else $fatal(1, "Read hit reached memory");
        access(1, 'h80000001, 0, 'haa00, 'h02, 0);
        access(0, 'h80000000, 3, 0, 0, 'h1234aa00);
        assert (transfers == 3) else $fatal(1, "Partial write failed to invalidate");
        access(0, 'h80000020, 3, 0, 0, 'h12340004);
        access(0, 'h80000000, 3, 0, 0, 'h1234aa00);
        assert (transfers == 5) else $fatal(1, "Collision did not replace");
        access(1, 'h80000008, 3, 'h9988, 'hff, 0);
        access(0, 'h80000008, 3, 0, 0, 'h9988);
        assert (transfers == 7) else $fatal(1, "Write miss allocated a line");
        lock = 1;
        access(0, 'h80000008, 3, 0, 0, 'h9988);
        access(1, 'h80000008, 3, 'h9999, 'hff, 0);
        lock = 0;
        access(0, 'h80000008, 3, 0, 0, 'h9999);
        access(0, 'h10000001, 0, 0, 0, 'h1234aa00);
        access(0, 'h10000001, 0, 0, 0, 'h1234aa00);
        assert (byte_reads == 2) else $fatal(1, "MMIO was cached");
        access(0, 'h800000f8, 3, 0, 0, 0, 1);
        access(0, 'h800000f8, 3, 0, 0, 0, 1);
        assert (!dut.Valid[3]) else $fatal(1, "Failed read allocated a line");
        @(negedge clk);
        resetn = 0;
        @(negedge clk);
        resetn = 1;
        assert (dut.Valid == 0) else $fatal(1, "Reset did not invalidate");
        access(0, 'h80000008, 3, 0, 0, 'h9999);
        $display("PASS: shared cache fills, hits, collisions, partial writes, MMIO, locks, errors and reset");
        $finish;
    end
    initial begin
        #20000;
        $fatal(1, "Cache test timeout");
    end
endmodule
