# Multicore documentation and decision-status reconciliation

Status: **documentation reconciled** on 2026-10-22, recommendation 8.
Reviewed source: `multicore-support:853418123f91806a8b65a59060288728607f920d`
plus this documentation-only update. No RTL, configuration or simulator code
changed, and no new functional/hardware verification result is claimed.

## Facts and explicit acceptance

The 8 KiB default change and its capacity experiment were already published
in `f9f7a83bebcb4a3f4156f561a7adcdd74628c9ce`. ADR 0012 incorrectly retained
the pre-implementation overlay plan. Its current text records implementation,
links the historical capacity results, identifies the current shared-schema
owner and retains the FPGA limitations. The deferred overlay is historical;
it must not be reapplied as pending work.

After an explanation of ADR purpose and the 8 KiB decision, the user explicitly
instructed “acepta el adr 12” on 2026-10-22. This accepts ADR 0012 for configurable
private I/D capacity defaults on the feature branch. It does not accept other
ADRs, qualify FPGA hardware or authorize synthesis/main integration.

| ADRs | Status after reconciliation | Basis |
| --- | --- | --- |
| 0001–0008, 0013 | Existing accepted status and scope retained | No status transition in this update |
| 0012 | Accepted for configurable 8 KiB private I/D defaults | Explicit user instruction on 2026-10-22 |
| 0009–0011, 0014–0019 | Proposed; implementation/evidence remain separately recorded | No explicit acceptance in this update |

A PASS, a published commit and an accepted decision describe different facts.
Historical experiments retain their revision/tool/profile scope. Original
review findings remain a snapshot, with links to implementation follow-ups.

## Publication check and reproduction

After `git fetch origin`, local HEAD and origin/multicore-support both resolved
to `853418123f91806a8b65a59060288728607f920d`. Historical integration commit
`0533e764dc43e6b6f418fb6189d38211b1c270d1` is an ancestor of that remote
feature head. Thus that integration is published on the feature branch.
Local and remote main resolved to `a6f312a2d8f7ccff54f6353d846751aae0e5c200`;
that current main is not an ancestor of the feature head. Publication of the
historical integration does not mean current main has been incorporated or
that multicore-support has been merged into main. No branch merge was performed.

Commands used for the snapshot (branch refs may subsequently advance):

```bash
git fetch origin
git rev-parse HEAD origin/multicore-support main origin/main
git merge-base --is-ancestor 0533e764d origin/multicore-support # exit 0
git merge-base --is-ancestor main HEAD                      # exit 1
git show --stat f9f7a83be
```

Current schema defaults were inspected: `8192 // (AHBW // 8)` for both private
I/D word counts. The capacity record reports the historical two-hart 8 KiB
Linux PASS at 347,795,562 cycles; it is not a fresh Linux run on this revision.
Scoped pre-commit, relative documentation-link checks and git diff --check
are the validation for this documentation update; no RTL simulations rerun.
