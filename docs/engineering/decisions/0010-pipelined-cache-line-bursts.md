# ADR 0010: Pipelined AHB transfers for private-cache lines

Status: **proposed**, implemented as an optional simulation path on
`multicore-support`, base `b72f8852188560c181b8f1bc06e552d497ccf371`.
Date: 2026-10-20. The user requested bursts to improve cache-line handling.
See [the experiment](../experiments/2026-10-20-cache-line-bursts.md) for results.

## Context and decision

The existing controller performs a separate SINGLE address/data exchange for
every word. The banked fabric additionally buffers/arbitrates every beat.
Changing HBURST alone would retain these costs and would not constitute a
pipelined burst. Conversely, enabling P.BURST_EN in cores would violate the
current core-side ordering interface, which intentionally accepts SINGLEs.

Add independent SoC parameter `CACHE_BURSTS`, default off, requiring private
MSI with multiple harts. The single-core generate path removes this logic.
Core requests and peripheral accesses remain SINGLE. Existing one-home and
multi-home configurations remain available. The CLI option is `--cache-bursts`;
image/model/result/checkpoint metadata carry the option and reject mismatches.

`ahblineburst` transfers a full D line for fills, dirty eviction or modified
intervention. Independent accepted-address and completed-data counters permit
the next address to overlap the preceding data beat. HREADY stalls both
counters, retaining address/control and the preceding write data. Lengths
4/8/16 use INCR4/8/16; length two uses INCR; larger power-of-two lines split
into aligned INCR16 chunks. No chunk crosses a 1 KiB boundary. Full-line
alignment and XLEN-wide words are required.

The controller grants S/M and installs filled lines only after all required
beats succeed. Writeback data remains in its original M owner through the
entire operation. AHB ERROR cancels the following address, waits for the
high-ready ERROR completion, then returns the existing two-cycle upstream
ERROR. Failed/partial fills never become valid and dirty ownership survives
failed writeback. Reset aborts bursts; it does not preserve dirty state.

For multiple homes, `ahbburstmux` replaces the per-word buffered memory bridge
only when this option is enabled. It arbitrates autonomous masters round-robin,
holds a grant through an entire line (including multiple chunks), and drains
the last data phase before rotating. Data ownership is registered separately
from address ownership. Other homes can continue independent coherence work;
physical memory beats still share one port. Global AMO exclusion and per-home
reservation/I-invalidation machinery are unchanged.

## Instruction lines and coherence

An ordered I-line refill may prefetch its whole line only if a physical
lookup across every covered D line in every hart finds no M owner. Mixed I/D
geometries can cover several D lines with different owners; checking only the
requested word would be incorrect. Otherwise the original word-wise snoop and
intervention path is retained. A transient I buffer supplies subsequent words
to the arbiter's existing ordered refill, without D allocation. It is discarded
at the last requested word, on another region/data request or any store commit.
It does not add a persistent instruction-cache entry. Local-write hazard guards
cover the entire I/D refill region. External DMA remains outside coherence.

## Alternatives, compatibility and limits

Always-SINGLE operation is the disabled baseline. Directly streaming ownership
changes before memory acknowledgment was rejected because it would lose dirty
recovery on partial writeback errors. Per-beat grant rotation cannot preserve
fixed-length bursts and is replaced only on the burst-enabled path.

The on-chip RAM already accepts sequential AHB addresses; its data/address
pipeline is exercised by full-core tests at several wait settings. No DDR3
controller, FPGA timing result or external-memory throughput is established.
The receiver must support standard AHB-Lite pipelining. Burst traffic can
increase grant hold time; arbitration is fair between complete bounded lines,
not between individual beats. Same-home misses, global AMOs and each hart's
blocking interface remain. No multiple MSHRs per hart or DMA protocol is added.

Protocol reference: Arm [AMBA AHB Protocol Specification](https://documentation-service.arm.com/static/6141bf0d674a052ae36ca811),
address/data pipelining, incrementing bursts, 1 KiB boundaries and cancellation
following two-cycle ERROR. This design uses AHB-Lite OKAY/ERROR semantics.
