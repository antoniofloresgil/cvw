// Shared test-only pipelined AHB RAM/fault model for one-home and banked benches.
assign downready = !pending || (delayq == 0 && (!errorq || error_first));
assign downresp = pending && delayq == 0 && errorq;
assign downrdata = mem[addrq[OFFSET +: 12]];
always @(posedge HCLK) begin
    if (!HRESETn) begin
        pending <= 0; error_first <= 0; delayq <= 0;
    end else begin
        if (pending && delayq != 0) delayq <= delayq-1;
        if (pending && delayq == 0 && errorq && !error_first) error_first <= 1;
        if (downready) begin
            if (pending && writeq && !errorq) begin
                if (addrq != P.PA_BITS'('h10000001))
                    assert (&downstrb) else $fatal(1, "Incomplete dirty writeback data phase");
                for (int b = 0; b < P.XLEN/8; b++)
                    if (downstrb[b]) mem[addrq[OFFSET +: 12]][8*b +: 8] <= downwdata[8*b +: 8];
            end
            pending <= downtrans[1];
            if (downtrans[1]) begin
`ifdef CVW_DOWNSTREAM_LOCK_CHECK
                assert (downlock == HMASTLOCK) else $fatal(1, "Lost AMO exclusion");
`endif
                addrq <= downaddr; writeq <= downwrite;
                errorq <= downaddr == fault_addr && (downwrite ? fault_write : fault_read);
                error_first <= 0; delayq <= LATENCY;
                transfers <= transfers+1;
                if (downwrite) writebacks <= writebacks+1;
                if (downaddr == P.PA_BITS'('h10000001)) begin
                    mmio <= mmio+1;
                    assert (downsize == 0 && downburst == 0 && downtrans == 2)
                        else $fatal(1, "MMIO burst or access size changed");
                end else
                    assert (downsize == 3'(OFFSET) && downaddr[OFFSET-1:0] == 0)
                        else $fatal(1, "Fill/writeback must use aligned words");
            end
        end
    end
end
