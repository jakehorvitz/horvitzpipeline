---
name: goalify
description: "Owns the Horvitz pipeline goal artifacts at both ends — the Stage 2 kill-or-commit decision and the Stage 10 operate/learn call. Use inside a run at those gates, or when Jake asks 'is this worth building', 'what's the kill condition', 'should I double down or kill this'. Produces the scope/metric/kill-condition that stages 3 and 10 are held to."
---

# goalify — the kill-or-commit and operate/learn decisions

Two gates, one concern: is this worth building, and did it earn its keep. The orchestrator tracks that stages 2 and 10 are owner gates; this skill owns the brutal questions and the decision record.

## Produces
**Stage 2 (kill-or-commit):** a record answering the brutal <=30-minute check — the painful job and for whom, the existing 80% tool, Jake's unfair advantage, the 1-day version and what is cut, the 7-day success metric, the kill condition, and the maintenance cost. Scope, metric, and kill-condition feed the spec (stage 3) and the operate call (stage 10). **Stage 10 (operate + learn):** the double-down / park / kill decision, made within 7 days against the stage-2 metric using real telemetry, then **learnings written BACK to the brains** (new/updated persistent-memory files + a MEMORY.md index line, vault notes, stale memories corrected) per `ship-pipeline/references/brains.md`; a run that taught nothing is journaled as exactly that.

## Procedure
1. Stage 2: answer all seven questions in the open; if it cannot clear them honestly, kill it here — do not build.
2. Instrument before ship: activation, core-success, errors, latency, plus one qualitative channel.
3. Stage 10: within 7 days, check the metric and make the call out loud; then do the brains write-back.

## Activates
Stages 2 and 10 of any Horvitz/ship run; or when Jake weighs whether to start or keep a build.
