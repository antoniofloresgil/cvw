// Shared master stimulus for one-home and banked private-cache benches.
localparam int ACCESS_TIMEOUT_CYCLES = 10000;

task automatic access(input int hart, input bit wr, input logic [P.PA_BITS-1:0] address,
    input logic [P.XLEN-1:0] value, input logic [P.XLEN/8-1:0] strobes,
    input logic [P.XLEN-1:0] expected, input logic [1:0] atomic_op = 0,
    input bit instruction = 0, input bit error_expected = 0, input bit sc_failed = 0,
    input logic [2:0] access_size = 3'(OFFSET));
    int unsigned wait_cycles;
    @(negedge HCLK);
    assert (CoreHREADY[hart]) else $fatal(1, "Hart %0d not ready", hart);
    CoreHADDR[hart] = address;
    CoreHWRITE[hart] = wr;
    CoreHSIZE[hart] = access_size;
    CoreHPROT[hart] = instruction ? 4'b0010 : 4'b0011;
    CoreHATOMIC[hart] = atomic_op;
    CoreHTRANS[hart] = 2;
    @(negedge HCLK);
    CoreHTRANS[hart] = 0;
    CoreHWDATA[hart] = value;
    CoreHWSTRB[hart] = strobes;
    wait_cycles = 0;
    while (!CoreHREADY[hart] && wait_cycles < ACCESS_TIMEOUT_CYCLES) begin
        @(negedge HCLK);
        wait_cycles++;
    end
    assert (CoreHREADY[hart]) else $fatal(1, "Hart %0d access watchdog expired after %0d cycles", hart, wait_cycles);
    assert (CoreHRESP[hart] == error_expected) else $fatal(1, "Unexpected error response");
    if (!wr && !error_expected)
        assert (CoreHRDATA[hart] == expected)
            else $fatal(1, "Hart %0d read %h: got %h expected %h", hart, address, CoreHRDATA[hart], expected);
    if (atomic_op == 2)
        assert (CoreSCFail[hart] == sc_failed) else $fatal(1, "Unexpected SC verdict");
    @(negedge HCLK);
endtask

task automatic load(input int h, input int word_index, input logic [P.XLEN-1:0] expected,
    input logic [1:0] op = 0, input bit instruction = 0);
    access(h, 0, BASE + (P.PA_BITS'(word_index) << OFFSET), 0, '0, expected, op, instruction);
endtask

task automatic store(input int h, input int word_index, input logic [P.XLEN-1:0] value,
    input logic [1:0] op = 0, input bit sc_failed = 0);
    access(h, 1, BASE + (P.PA_BITS'(word_index) << OFFSET), value, '1, 0, op, 0, 0, sc_failed);
endtask
