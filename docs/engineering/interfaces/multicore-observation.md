# Passive multicore test observation

Scope: experimental multicore Verilator fixtures, implemented on parent
`4986fa5f8` under proposed [ADR 0021](../decisions/0021-multicore-test-observation.md).
This is a simulation-only boundary, not a synthesizable debug interface.

## Ownership and API

| Adapter | Contract supplied to scenarios |
| --- | --- |
| observation_pkg.sv | Test-owned OBS_INVALID/SHARED/MODIFIED/EXCLUSIVE permission vocabulary, independent of DUT enum values |
| cache_observer.sv | Bound cache snapshot; semantic Permissions, line_state(hart, word_index), has_line(hart, physical_address); TransactionActive, LookupAccepted, FillDataAccepted |
| bridge_observer.sv | Bound GlobalData/Read/WriteActive, GlobalOrRefillActive, LRReply, InstructionReply, LocalReply, LocalDataReply and LocalStoreCommitted events; local completion count |
| word_observer.sv | Architectural-word lookup from a RAM word plus normalized private-cache snapshots; rejects multiple matching dirty owners |
| soc_observer.svh | SoC topology bindings, image loading, architectural_word(index), passive memory/local/UART counters |
| fabric_observer.svh | Generated-home bindings, activity/lookup vectors and semantic line_state for fabric scenarios |

Implementation files live in [tests/multicore](../../../tests/multicore).
Only adapters access raw cache arrays, FSM/transfer symbols or generated
cache hierarchy. Cache bindings compare against DUT enum **symbols**, then map
permissions into the separate test vocabulary. Reordering internal enum values
therefore does not change scenario code. The type-bound adapters attach only
when explicitly supplied as simulation sources; production RTL is unchanged.

TransactionActive excludes IDLE and REPLY, preserving the former overlap
counter semantics. LookupAccepted is high for a LOOKUP execution cycle; it
counts coherence lookups rather than hart address admissions. FillDataAccepted
is DATA with FILL/IFILL and downstream HREADY, including the original test's
error-cycle behavior. Bridge events are combinational observations of existing
signals, sampled on the same edges as before. Counts retain their previous
initialization/reset behavior; no test scheduling cycle is added.

## Architectural lookup and independent checking

architectural_word takes a word index relative to physical RAM. It reads the
existing RAM array and, for active multi-hart private-cache modes, replaces
that value with the sole matching Modified owner's word. Shared/Exclusive
copies are clean and do not override RAM. Native single-hart, uncached and
shared write-through modes use RAM. Private options with one hart retain the
native bypass. Home mapping accounts for the larger per-home I/D capacity;
data indices/tags use the private D geometry.

For each queried word, more than one matching dirty owner is a fatal observation
error, rather than choosing the last owner. This query check is not a global
proof of every cache invariant. Unknown permission mappings also fail rather
than silently returning RAM. The adapter performs no flush, eviction, retry,
coherence transaction or DUT assignment to obtain a result.

The lookup is an observation of architectural signatures, not the reference
model for coherence. Expected load values, byte-store updates, permissions,
writeback/traffic/overlap expectations and scenario sequencing remain in the
benches and their independent reference arrays. Bridge lock/conflict assertions
reside with the raw bridge probes; their expected region size is independently
derived from public line geometry, not copied from the DUT's derived decode.

## Retained checks and limits

check_observation.py is selected once by the ordinary CI bus case. It runs:

- RV32/RV64 snapshots with one/two homes, one/four-word lines and unequal I/D
  capacities; fixed sentinel values check home/index/tag/data selection.
- A duplicate dirty-owner injection for every snapshot configuration, requiring
  the exact diagnostic `observation contract: multiple dirty owners`.
- An ignored copy with a deliberately shifted data-word mapping, requiring
  the independent sentinel assertion to report a word mapping mismatch.
- Unchanged real one-home and banked scenarios on RV32/RV64, both original
  and altered permission/FSM/transfer encodings, comparing semantic and SEQ
  signatures. Reencoded RTL is confined to ignored experiment copies.

Expected failures require the named assertion and a nonzero status; arbitrary
build/run failures do not count as successful negative coverage. Builds,
commands, source/mutation/binary hashes and verdicts are retained by the runner.
Full-core and controller comparisons additionally preserve the pre-extraction
PASS/traffic/cycle signatures. See the [execution record](../experiments/2026-10-22-multicore-test-observation.md).

The adapters do not change the production topology, qualify new cache profiles,
implement a generic debugger or replace protocol/architectural verification.
Four-state/commercial simulator support, synthesis and FPGA behavior are not
established by these Verilator checks. Shared downstream test-driver extraction
and a full feature-interaction coverage plan remain recommendations 12 and 10.
