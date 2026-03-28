---
id: jido_signal.decision.spec_led_repo_workflow
status: accepted
date: 2026-03-28
affects:
  - repo.governance
  - jido_signal.package
  - jido_signal.guides
  - jido_signal.workflow
---

# Adopt Spec Led And Beadwork Repo Workflow

## Context

This repository has package code, maintained guides, root agent instructions,
and GitHub workflows that all shape how contributors make and verify changes.

Before this migration, those surfaces were not tied into one durable
current-truth loop, so repo workflow changes could drift independently from the
package subjects they supported.

Beadwork also introduces durable work-management state for the repo, which
means the repository needs an explicit rule for how `bw prime`, `.spec`, and
CI-based `mix spec.check` fit together.

## Decision

Adopt Spec Led Development as an ongoing repository workflow, not just a
one-time scaffold.

Keep the major package, guide, and repo-workflow surfaces represented in
`.spec/specs/*.spec.md`.

Use Beadwork as the durable work-management layer and require root agent
guidance to point contributors at `bw prime` before starting repository work.

Provide a single script entrypoint plus a dedicated GitHub Actions workflow for
`mix spec.check` so current truth is enforced in CI whenever spec-relevant files
change.

## Consequences

Guide changes, workflow changes, and root operating rules now participate in the
same co-change discipline as code-facing subjects.

Cross-cutting repository changes should update the relevant subject specs and
this ADR-backed workflow instead of relying only on pull request discussion.

The migration is complete when normal repository maintenance keeps `.spec`,
Beadwork state, and the spec-check workflow aligned.
