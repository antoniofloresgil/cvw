// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive test-only checker for the AHB side downstream of the coherence engine.
module ahb_downstream_checker #(
    parameter int ADDR_WIDTH = 40,
    parameter int DATA_WIDTH = 64,
    parameter int STRB_WIDTH = 8,
    parameter int BYTE_OFFSET = 3
) (
    input logic HCLK,
    input logic HRESETn,
    input logic [ADDR_WIDTH-1:0] HADDR,
    input logic [DATA_WIDTH-1:0] HWDATA,
    input logic [STRB_WIDTH-1:0] HWSTRB,
    input logic [2:0] HSIZE,
    input logic [2:0] HBURST,
    input logic [1:0] HTRANS,
    input logic HREADY,
    input logic HRESP,
    input logic WriteDataWait,
    output int unsigned SequentialBeats
);
    logic waiting = 0, write_wait = 0;
    logic [ADDR_WIDTH-1:0] held_addr, previous_addr;
    logic [DATA_WIDTH-1:0] held_data;
    logic [STRB_WIDTH-1:0] held_strb;
    logic [2:0] previous_burst;
    logic [1:0] held_trans;
    logic previous_valid = 0;

    initial SequentialBeats = 0;

    always @(posedge HCLK) begin
        if (!HRESETn) begin
            waiting <= 0;
            write_wait <= 0;
            previous_valid <= 0;
        end else begin
            if (waiting && !HRESP)
                assert (HADDR == held_addr && HTRANS == held_trans)
                    else $fatal(1, "Address changed during AHB wait");
            if (write_wait)
                assert (HWDATA == held_data && HWSTRB == held_strb)
                    else $fatal(1, "Write data changed during AHB wait");
            waiting <= !HREADY && !HRESP;
            write_wait <= WriteDataWait;
            held_addr <= HADDR;
            held_trans <= HTRANS;
            held_data <= HWDATA;
            held_strb <= HWSTRB;
            if (HREADY && HTRANS[1]) begin
                if (HTRANS == 2'b11) begin
                    SequentialBeats <= SequentialBeats + 1;
                    assert (previous_valid && HBURST != 0 && HBURST == previous_burst &&
                        HADDR == previous_addr+(ADDR_WIDTH'(1) << BYTE_OFFSET) &&
                        HADDR[ADDR_WIDTH-1:10] == previous_addr[ADDR_WIDTH-1:10])
                        else $fatal(1, "Malformed or cross-1KiB sequential beat");
                end
                previous_valid <= 1;
                previous_addr <= HADDR;
                previous_burst <= HBURST;
            end
            if (HREADY && HRESP) previous_valid <= 0;
        end
    end
endmodule
