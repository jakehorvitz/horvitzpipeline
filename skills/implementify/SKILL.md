---
name: implementify
description: "Owns the Horvitz pipeline Stage 5 build loop — turning the pinned plan into code that passes the acceptance command. Use inside a run at build time, or when Jake says 'build it', 'run the loop', 'implement this'. Produces the build that passes the independently re-run pinned acceptance."
---

# implementify — the build loop (the auto gate)

The orchestrator holds the auto gate: it independently re-runs the pinned acceptance command and requires exit 0 — the builder cannot mark its own homework. This skill owns *how the build gets made*.

## Produces
A working increment on the branch that makes the **pinned acceptance command exit 0** when bones re-runs it. The build is driven by `ship-pipeline/scripts/loop.sh` (prime-agent or codex), handed the signed spec (`-s`), the pinned plan (`-P`), the anti-requirements, and an advisory HTML rubric (`-r`, guidance only — never the gate). Each iteration: builder implements the next increment → a **different-model** review pass → the orchestrator runs the acceptance command → repeat until exit 0 or max iters. The filled rubric, `acceptance.json`, `accept-run-*.log`, and the iteration log are the audit trail, committed with the build.

## Procedure
1. Confirm the anti-requirements (hard don'ts), the acceptance command (`-c`, matches init), the rubric, and max iters.
2. Follow the pinned plan; write any deviation to `.loop/plan-deviations.md`.
3. Split independent workstreams into parallel git worktrees; keep the orchestrator's context clean by pushing implementation detail to subagents. The orchestrator holds the gate and the acceptance run, never the detail.

## Activates
Stage 5 of any Horvitz/ship run; or when Jake says to build/implement against a plan.
