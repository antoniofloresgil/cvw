// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Differential APB test: upstream, corrected single-hart, and SMP with one hart.
`include "config.vh"
module singlecore_peripherals_tb import cvw::*; #(
    parameter int NSOURCES = 14
)();
    `include "parameter-defs.vh"
    function automatic cvw_t sourceconfig();
        cvw_t c = P;
        c.PLIC_NUM_SRC = NSOURCES;
        return c;
    endfunction
    localparam cvw_t C = sourceconfig();
    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;
    logic sel = 0, cl = 0, wr = 0, enable = 0, uart = 0;
    logic [27:0] addr = 0;
    logic [P.XLEN-1:0] data = 0;
    logic [P.XLEN/8-1:0] strb = '1;
    logic [2:0][P.XLEN-1:0] cq, pq;
    logic [2:0][63:0] timevalue;
    logic [2:0] msip, mtip, meip, seip, crdy, prdy;
    bit compare_main = 0;
    clint_apb #(C) basecl(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && cl), .PADDR(addr[15:0]),
        .PWDATA(data), .PSTRB(strb), .PWRITE(wr), .PENABLE(enable), .PRDATA(cq[0]),
        .PREADY(crdy[0]), .MTIME(timevalue[0]), .MTimerInt(mtip[0]), .MSwInt(msip[0]));
    clint_multicore_apb #(.P(C), .NCORES(1)) smpcl(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && cl), .PADDR(addr[15:0]),
        .PWDATA(data), .PSTRB(strb), .PWRITE(wr), .PENABLE(enable), .PRDATA(cq[1]),
        .PREADY(crdy[1]), .MTIME(timevalue[1]), .MTimerInt(mtip[1]), .MSwInt(msip[1]));
    clint_upstream_apb #(C) refcl(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && cl), .PADDR(addr[15:0]),
        .PWDATA(data), .PSTRB(strb), .PWRITE(wr), .PENABLE(enable), .PRDATA(cq[2]),
        .PREADY(crdy[2]), .MTIME(timevalue[2]), .MTimerInt(mtip[2]), .MSwInt(msip[2]));
    plic_apb #(C) baseplic(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && !cl), .PADDR(addr),
        .PWDATA(data), .PSTRB(strb), .PWRITE(wr), .PENABLE(enable), .PRDATA(pq[0]), .PREADY(prdy[0]),
        .UARTIntr(uart), .GPIOIntr(1'b0), .SPIIntr(1'b0), .SDCIntr(1'b0), .PWMIntr('0), .MExtInt(meip[0]), .SExtInt(seip[0]));
    plic_multicore_apb #(.P(C), .NCORES(1)) smpplic(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && !cl), .PADDR(addr),
        .PWDATA(data), .PSTRB(strb), .PWRITE(wr), .PENABLE(enable), .PRDATA(pq[1]), .PREADY(prdy[1]),
        .UARTIntr(uart), .GPIOIntr(1'b0), .SPIIntr(1'b0), .SDCIntr(1'b0), .PWMIntr('0), .MExtInt(meip[1]), .SExtInt(seip[1]));
    plic_upstream_apb #(C) refplic(.PCLK(clk), .PRESETn(rstn), .PSEL(sel && !cl), .PADDR(addr),
        .PWDATA(data), .PSTRB(strb), .PWRITE(wr), .PENABLE(enable), .PRDATA(pq[2]), .PREADY(prdy[2]),
        .UARTIntr(uart), .GPIOIntr(1'b0), .SPIIntr(1'b0), .SDCIntr(1'b0), .PWMIntr('0), .MExtInt(meip[2]), .SExtInt(seip[2]));

    // Check both protocol phases and idle cycles, not only software read results.
    always @(negedge clk) if (rstn) begin
        assert ({cq[0], pq[0], timevalue[0], msip[0], mtip[0], meip[0], seip[0], crdy[0], prdy[0]} ==
                {cq[1], pq[1], timevalue[1], msip[1], mtip[1], meip[1], seip[1], crdy[1], prdy[1]})
            else $fatal(1, "Single-hart/SMP peripheral mismatch at %h", addr);
        if (compare_main)
            assert ({cq[0], pq[0], timevalue[0], msip[0], mtip[0], meip[0], seip[0]} ==
                    {cq[2], pq[2], timevalue[2], msip[2], mtip[2], meip[2], seip[2]})
                else $fatal(1, "Unexpected upstream difference at %h", addr);
    end
    task automatic access(input bit iscl, input bit iswrite, input int address,
                          input logic [P.XLEN-1:0] value, input logic [P.XLEN/8-1:0] strobes,
                          output logic [P.XLEN-1:0] actual, reference_value);
        @(posedge clk); #1;
        cl = iscl; sel = 1; wr = iswrite; enable = 0;
        addr = 28'(address); data = value; strb = strobes;
        @(posedge clk); #1;
        actual = iscl ? cq[0] : pq[0]; reference_value = iscl ? cq[2] : pq[2];
        enable = 1;
        @(posedge clk); #1;
        sel = 0; enable = 0;
    endtask
    initial begin
        logic [P.XLEN-1:0] q, refq;
        logic [31:0] rng = 32'h75cd891b;
        int address;
        repeat (3) @(negedge clk);
        rstn = 1;
        // Give the upstream PLIC one non-reset clock to define its read output.
        repeat (2) @(negedge clk);
        compare_main = 1;
        for (int i = 0; i < 3000; i++) begin
            rng = (rng >> 1) ^ (32'(-(int'(rng[0]))) & 32'hd0000001);
            uart = rng[4];
            case (rng[3:0])
                0: address = 0;
                1: address = 'h4000;
                2: address = P.XLEN == 32 ? 'h4004 : 'h4000;
                3: address = 'hbff8;
                4: address = P.XLEN == 32 ? 'hbffc : 'hbff8;
                5,6: address = 4*(1+int'(rng[15:8])%NSOURCES);
                7: address = 'h1000;
                8: address = 'h2000;
                9: address = 'h2080;
                10: address = 'h200000;
                11: address = 'h201000;
                12,13: address = 'h200004;
                default: address = 'h201004;
            endcase
            access(rng[3:0] <= 4, rng[5], address, P.XLEN'(rng), '1, q, refq);
        end
        // Explicitly exercise routing, claim and completion in both contexts.
        for (int c = 0; c < 2; c++) begin
            uart = 0;
            access(0, 1, 4*P.PLIC_UART_ID, 3, '1, q, refq);
            access(0, 1, 'h2000+'h80*c, P.XLEN'(1 << P.PLIC_UART_ID), '1, q, refq);
            access(0, 1, 'h200000+'h1000*c, 0, '1, q, refq);
            // Reset previous random claims before injecting a fresh interrupt.
            access(0, 1, 'h200004+'h1000*c, P.XLEN'(P.PLIC_UART_ID), '1, q, refq);
            uart = 1;
            repeat (3) @(negedge clk);
            access(0, 0, 'h200004+'h1000*c, 0, '1, q, refq);
            assert (q[31:0] == P.PLIC_UART_ID) else $fatal(1, "UART claim failed");
            uart = 0;
            access(0, 1, 'h200004+'h1000*c, P.XLEN'(P.PLIC_UART_ID), '1, q, refq);
        end
        compare_main = 0;
        // Intentional generic corrections, independent of NCORES.
        access(1, 1, 0, 0, '1, q, refq);
        access(1, 1, 0, 1, '0, q, refq);
        assert (!msip[0] && msip[2]) else $fatal(1, "MSIP must honor byte zero's strobe");
        access(1, 1, 0, 1, '1, q, refq);
        access(1, 1, 0, 0, (P.XLEN/8)'(2), q, refq);
        assert (msip[0] && !msip[2]) else $fatal(1, "Other byte strobes must not clear MSIP");
        access(0, 1, 'h200000, 5, '1, q, refq);
        access(0, 0, 'h1200000, 0, '1, q, refq);
        assert (q == 0 && refq[31:0] == 5) else $fatal(1, "PLIC high address must not alias context zero");
        access(0, 1, 'h1200000, 7, '1, q, refq);
        access(0, 0, 'h200000, 0, '1, q, refq);
        assert (q[31:0] == 5 && refq[31:0] == 7) else $fatal(1, "PLIC high-address write alias");
        access(0, 1, 0, 7, '1, q, refq);
        access(0, 0, 0, 0, '1, q, refq);
        assert (q == 0) else $fatal(1, "Source zero must remain hardwired to zero");
        access(0, 1, 4*(NSOURCES+1), 7, '1, q, refq);
        access(0, 0, 4*(NSOURCES+1), 0, '1, q, refq);
        assert (q == 0) else $fatal(1, "Unimplemented priority must read zero");
        access(0, 0, 'h1004, 0, '1, q, refq);
        if (NSOURCES < 32) assert (q == 0) else $fatal(1, "Absent source bank must read zero");
        $display("PASS: RV%0d/%0d sources: 3000 common upstream transactions, routing, explicit corrections, SMP(1) agreement", P.XLEN, NSOURCES);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "Single-hart compatibility test timed out");
    end
endmodule
