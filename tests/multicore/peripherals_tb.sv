// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "config.vh"
module peripherals_tb import cvw::*;();
    `include "parameter-defs.vh"
    localparam N = 3;
    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;
    logic sel = 0, enable = 0, write = 0;
    logic [27:0] addr = 0;
    logic [P.XLEN-1:0] data = 0, crdata, prdata;
    logic [P.XLEN/8-1:0] strb = '1;
    logic [N-1:0] msip, mtip, meip, seip;
    logic [63:0] mtime;
    logic uart = 0;
    logic clintsel = 0;
    clint_apb #(.P(P), .NCORES(N)) clint(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && clintsel),
        .PADDR(addr[15:0]), .PWDATA(data), .PSTRB(strb), .PWRITE(write), .PENABLE(enable),
        .PRDATA(crdata), .PREADY(), .MTIME(mtime), .MTimerInt(mtip), .MSwInt(msip));
    plic_apb #(.P(P), .NCORES(N)) plic(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && !clintsel),
        .PADDR(addr), .PWDATA(data), .PSTRB(strb), .PWRITE(write), .PENABLE(enable),
        .PRDATA(prdata), .PREADY(), .UARTIntr(uart), .GPIOIntr(1'b0), .SPIIntr(1'b0), .SDCIntr(1'b0),
        .PWMIntr('0), .MExtInt(meip), .SExtInt(seip));

    task automatic access(input bit cl, input bit wr, input int a, input logic [P.XLEN-1:0] d,
                                                input logic [P.XLEN/8-1:0] st, output logic [P.XLEN-1:0] q);
        @(negedge clk);
        clintsel = cl; sel = 1; enable = 0; write = wr; addr = 28'(a); data = d; strb = st;
        @(negedge clk);
        q = cl ? crdata : prdata;
        enable = 1;
        @(negedge clk);
        sel = 0; enable = 0;
    endtask
    task automatic put(input bit cl, input int a, input logic [P.XLEN-1:0] d);
        logic [P.XLEN-1:0] q;
        access(cl, 1, a, d, '1, q);
    endtask
    task automatic checkread(input bit cl, input int a, input logic [31:0] expected);
        logic [P.XLEN-1:0] q;
        access(cl, 0, a, '0, '1, q);
        assert (q[31:0] == expected) else $fatal(1, "Read %h: got %h expected %h", a, q, expected);
    endtask
    initial begin
        logic [P.XLEN-1:0] q;
        logic [63:0] before_write;
        repeat (3) @(negedge clk);
        rstn = 1;
        // Hart 1 occupies the upper half of the first RV64 word.
        if (P.XLEN == 64) begin
            access(1, 1, 0, P.XLEN'(64'h0000000100000000), (P.XLEN/8)'(8'h10), q);
            assert (msip == 3'b010) else $fatal(1, "RV64 paired MSIP write failed");
            access(1, 1, 0, 0, (P.XLEN/8)'(8'h01), q);
            assert (msip == 3'b010) else $fatal(1, "MSIP byte strobes failed");
            access(1, 0, 0, 0, '1, q);
            assert (q == P.XLEN'(64'h0000000100000000)) else $fatal(1, "Paired MSIP read failed");
            access(1, 1, 0, 0, (P.XLEN/8)'(8'h10), q);
        end else begin
            put(1, 4, 1);
            assert (msip == 3'b010) else $fatal(1, "RV32 MSIP write failed");
            checkread(1, 4, 1);
            put(1, 4, 0);
        end
        put(1, 8, 1);
        assert (msip == 3'b100) else $fatal(1, "Hart 2 MSIP isolated incorrectly");
        // Expire hart 2 only; untouched comparators must remain at maximum.
        if (P.XLEN == 32) put(1, 'h4014, 0);
        put(1, 'h4010, 0);
        assert (mtip == 3'b100) else $fatal(1, "Per-hart timer compare failed");
        if (P.XLEN == 32) put(1, 'h4014, '1);
        put(1, 'h4010, '1);
        assert (mtip == 0) else $fatal(1, "Timer clear failed");
        checkread(1, 'h4010, '1);
        checkread(1, 'h5000, 0); // unimplemented comparator must not alias a hart

        // Partial MTIME writes preserve unstrobed bytes and pause the counter.
        @(negedge clk);
        sel = 1; clintsel = 1; enable = 0; write = 1;
        addr = 'hbff8; data = P.XLEN'('h12000000); strb = (P.XLEN/8)'('h08);
        @(negedge clk);
        enable = 1; before_write = mtime;
        @(negedge clk);
        assert (mtime[23:0] == before_write[23:0] && mtime[31:24] == 'h12)
            else $fatal(1, "MTIME write changed unstrobed bytes");
        sel = 0; enable = 0;

        // Every M/S context can route, mask, claim and complete the same source.
        put(0, 4*P.PLIC_UART_ID, 3);
        for (int c = 0; c < 2*N; c++) begin
            put(0, 'h2000+'h80*c, P.XLEN'(1 << P.PLIC_UART_ID));
            put(0, 'h200000+'h1000*c, 3);
            uart = 1;
            repeat (3) @(negedge clk);
            assert ({meip,seip} == 0) else $fatal(1, "PLIC threshold isolation failed");
            put(0, 'h200000+'h1000*c, 0);
            assert (meip == (c%2 == 0 ? N'(1 << (c/2)) : '0) &&
                            seip == (c%2 == 1 ? N'(1 << (c/2)) : '0))
                else $fatal(1, "PLIC context %0d routed to the wrong hart/mode", c);
            checkread(0, 'h200004+'h1000*c, P.PLIC_UART_ID);
            uart = 0;
            repeat (3) @(negedge clk);
            assert ({meip,seip} == 0) else $fatal(1, "Claim did not mask the source");
            checkread(0, 'h200004+'h1000*c, 0);
            put(0, 'h200004+'h1000*c, P.XLEN'(P.PLIC_UART_ID));
            put(0, 'h2000+'h80*c, 0);
        end
        // High address bits must not alias context zero.
        put(0, 'h200000, 5);
        checkread(0, 'h1200000, 0);
        put(0, 'h200000, 0);
        $display("PASS: RV%0d CLINT lanes/strobes/timers and all six PLIC contexts", P.XLEN);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Peripheral test timed out");
    end
endmodule
