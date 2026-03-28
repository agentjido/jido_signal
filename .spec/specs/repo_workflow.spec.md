# Repository Workflow

Current-truth contract for repository-level work management and spec checking.

## Intent

Describe the root agent guidance, contributor documentation, and GitHub Actions
entrypoints that keep the Spec Led workflow and Beadwork work management active
in this repository.

```spec-meta
id: jido_signal.workflow
kind: workflow
status: active
summary: Repository instructions tell agents to prime Beadwork before work, CONTRIBUTING.md explains the Spec Led contributor loop, and CI provides a dedicated spec.check entrypoint for current-truth changes.
surface:
  - AGENTS.md
  - CONTRIBUTING.md
  - scripts/check_specs.sh
  - .github/workflows/specs.yml
decisions:
  - jido_signal.decision.spec_led_repo_workflow
```

## Requirements

```spec-requirements
- id: jido_signal.workflow.beadwork_guidance_present
  statement: The root AGENTS.md shall tell agents to use Beadwork work management and run bw prime before starting repository work.
  priority: should
  stability: evolving

- id: jido_signal.workflow.contributor_spec_led_guidance
  statement: CONTRIBUTING.md shall tell contributors how to use the Spec Led loop, including the `.spec/` workspace and the prime, next, check, and status commands.
  priority: should
  stability: evolving

- id: jido_signal.workflow.spec_check_entrypoint
  statement: The repository shall provide a single script entrypoint that runs mix spec.check from the repo root for CI and local automation.
  priority: must
  stability: stable

- id: jido_signal.workflow.spec_check_ci
  statement: The repository shall provide a GitHub Actions workflow that runs the spec check entrypoint when spec-relevant files change and on manual dispatch.
  priority: must
  stability: stable
```

## Verification

```spec-verification
- kind: file
  target: AGENTS.md
  covers:
    - jido_signal.workflow.beadwork_guidance_present

- kind: file
  target: CONTRIBUTING.md
  covers:
    - jido_signal.workflow.contributor_spec_led_guidance

- kind: file
  target: scripts/check_specs.sh
  covers:
    - jido_signal.workflow.spec_check_entrypoint
    - jido_signal.workflow.spec_check_ci

- kind: workflow_file
  target: .github/workflows/specs.yml
  covers:
    - jido_signal.workflow.spec_check_ci
```
