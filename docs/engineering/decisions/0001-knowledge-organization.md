# ADR 0001: Keep persistent knowledge as a small documentation layer

Status: **accepted** for this documentation task, 2026-10-18.
Evidence: the user's explicit persistent-knowledge request and inspection of
the existing README, AGENTS, CLAUDE, test plan, FPGA and synthesis documents
at `main:3585ff04e`.

## Context and alternatives

Existing documents contain operational and architectural detail, while recent
work spans independent branches. Replacing AGENTS with a large narrative
would discard instructions and increase context cost. Copying every workflow
into a new handbook would create conflicting sources. Depending only on
session history or ignored logs would lose decisions and evidence provenance.

## Decision and rationale

Append one concise navigation/maintenance section to AGENTS. Use
`docs/engineering/README.md` as the selective index, `current-work.md` as the
checkpoint, ADRs for significant decisions, and compact experiment records
for results. Reference existing documentation and immutable branch revisions.
Keep raw logs/binaries outside permanent documentation and record their
locators, hashes and durability limits. The index defines status vocabulary
and proportional maintenance rules.

## Scope, compatibility and verification

Affected files: AGENTS plus `docs/engineering/`; no RTL, configurations,
tests, build scripts or submodule pointers. Existing AGENTS bytes must remain
an unchanged prefix. This has no hardware area/timing/runtime effect; its
cost is maintaining a few scoped records when engineering facts change.

Verify append-only preservation, links, revision/path references, result
provenance and documentation formatting. Passing these checks does not verify
hardware. A later reorganization should supersede this ADR explicitly.
