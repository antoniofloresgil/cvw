// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Shared directed checks for the one-home and banked private-cache paths.
    task automatic mesi_reset();
        @(negedge HCLK);
        HRESETn = 0;
        CoreHTRANS = '0;
        CoreHATOMIC = '0;
        CoreHMASTLOCK = '0;
        repeat (3) @(negedge HCLK);
        HRESETn = 1;
        // Reset intentionally discards dirty cache data, just as in hardware.
        for (int w = 0; w < 4096; w++) reference[w] = mem[w];
    endtask
    task automatic mesi_checks();
        int requests_before, ram_before, wb_before;
        logic [P.XLEN-1:0] changed;
        $display("MESI checks: exclusive=%0d local writes=%0d", MESI, LOCAL_DCACHE_WRITES);
        load(0, 0, reference[0]);
        assert (line_state(0, 0) == (MESI ? OBS_EXCLUSIVE : OBS_SHARED)) else $fatal(1, "Unshared read state");
        requests_before = coherence_requests;
        ram_before = transfers;
        changed = (reference[0] & ~P.XLEN'('hff00)) | P.XLEN'('haa00);
        access(0, 1, BASE+1, changed, (P.XLEN/8)'(2), 0, 0, 0, 0, 0, 0);
        reference[0] = changed;
        assert (line_state(0, 0) == OBS_MODIFIED && transfers == ram_before)
            else $fatal(1, "E/S-to-M byte store fetched memory or lost ownership");
        assert (coherence_requests == requests_before + ((MESI && LOCAL_DCACHE_WRITES) ? 0 : 1))
            else $fatal(1, "Exclusive store did not use the expected local/global path");
        load(1, 0, changed);
        assert (line_state(0, 0) == OBS_SHARED && line_state(1, 0) == OBS_SHARED && mem[0] == changed)
            else $fatal(1, "M-to-S sharing must make RAM current");
        mesi_reset();
        load(0, 0, reference[0]);
        wb_before = writebacks;
        load(0, WORDS, reference[WORDS]);
        assert (writebacks == wb_before) else $fatal(1, "Clean exclusive eviction wrote RAM");
        mesi_reset();
        load(0, 0, reference[0]);
        wb_before = writebacks;
        load(1, 0, reference[0]);
        assert (line_state(0, 0) == OBS_SHARED && line_state(1, 0) == OBS_SHARED && writebacks == wb_before)
            else $fatal(1, "E-to-S read sharing failed");
        store(0, 0, 'h42); reference[0] = 'h42;
        assert (line_state(0, 0) == OBS_MODIFIED && line_state(1, 0) == OBS_INVALID)
            else $fatal(1, "Shared upgrade did not invalidate peer");
        mesi_reset();
        load(0, 0, reference[0]);
        store(1, 0, 'h43); reference[0] = 'h43;
        assert (line_state(0, 0) == OBS_INVALID && line_state(1, 0) == OBS_MODIFIED)
            else $fatal(1, "Remote write failed to invalidate exclusive peer");
        mesi_reset();
        // An instruction copy does not revoke D exclusivity. A subsequent
        // local E-to-M store must still invalidate that instruction copy.
        load(0, 0, reference[0]);
        load(1, 0, reference[0], 0, 1);
        assert (line_state(0, 0) == (MESI ? OBS_EXCLUSIVE : OBS_SHARED) && line_state(1, 0) == OBS_INVALID)
            else $fatal(1, "IFU allocated a D copy or revoked exclusivity");
        store(0, 0, 'h44); reference[0] = 'h44;
        load(1, 0, 'h44, 0, 1);
        mesi_reset();
        // A peer acquiring S after LR must observe the subsequent invalidation.
        load(0, 0, reference[0], 1);
        load(1, 0, reference[0]);
        store(0, 0, 'h45, 2); reference[0] = 'h45;
        load(1, 0, 'h45);
        load(0, 0, 'h45, 1);
        store(1, 0, 'h46); reference[0] = 'h46;
        store(0, 0, 'hbad, 2, 1);
        load(0, 0, 'h46);
        mesi_reset();
        // A failed peer fill must not publish a shared copy or revoke E.
        load(0, 0, reference[0]);
        fault_addr = BASE + (P.PA_BITS'(int'(LINE_WORDS-1)) << OFFSET);
        fault_read = 1;
        access(1, 0, BASE, 0, '0, 0, 0, 0, 1);
        assert (line_state(0, 0) == (MESI ? OBS_EXCLUSIVE : OBS_SHARED) && line_state(1, 0) == OBS_INVALID)
            else $fatal(1, "Failed read changed exclusive ownership");
        fault_read = 0;
        load(1, 0, reference[0]);
        assert (line_state(0, 0) == OBS_SHARED && line_state(1, 0) == OBS_SHARED)
            else $fatal(1, "Successful retry failed to share exclusive line");
        mesi_reset();
        // Independent requests must not grant E to two readers of one line.
        fork
            load(0, 0, reference[0]);
            load(1, 0, reference[0]);
        join
        assert (line_state(0, 0) == OBS_SHARED && line_state(1, 0) == OBS_SHARED)
            else $fatal(1, "Concurrent readers acquired exclusive copies");
        mesi_reset();
        $display("PASS: directed MESI/MSI permissions, byte stores, clean eviction, IFU and LR/SC");
    endtask
