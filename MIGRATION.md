# Migrating a machine from Horvitz pipeline 1.x to 2.0

2.0 renumbers nothing and renames nothing: stage numbers, `bones.sh`, `.bones/`, gate files, `BONES_*`
variables, and CLI verbs are unchanged, and the state schema stays at 2. Every live run keeps working;
the upgrade is additive files plus a changed guard. Do the steps in order; each is journaled per run.

1. **Back up the live skill** — `cp -R ~/.claude/skills/horvitz-pipeline ~/.claude/skills/horvitz-pipeline.v1-backup`
   (this is the rollback target).
2. **Install** — copy `skills/horvitz-pipeline` (and the five new skill dirs when present) into
   `~/.claude/skills/`. The PreToolUse hook path in `~/.claude/settings.json` is unchanged.
3. **Owner key (one time per machine)** — `bones owner-setup` builds the Touch ID helper, creates the
   Secure-Enclave key, records the helper's sha256 + cdhash, and asks for ONE tap to prove the chain.
   Macs without Touch ID: `bones owner-setup --passphrase --accept-degraded` (status/doctor then print
   `owner-auth: passphrase (DEGRADED)`).
4. **Pin the owner key into every run** — `scripts/fleet.sh pin-owner`.
5. **Repin the guard** — the guard changed, so every run refuses until `scripts/fleet.sh repin -r "2.0 install"`
   (each run verifies the full bypass corpus BLOCKs before moving its pin).
6. **Fleet doctor** — `scripts/fleet.sh doctor` must report 0 failed. Pre-2.0 promotes (an `8-promote.ok`
   with no `8-promote.authorized`) are labeled "promoted pre-2.0", not warned.
7. **Smoke** — run `bones status` and `bones selftest` from the installed path in three live runs.

What changes for an in-flight run:
- Stage 8 is two-phase: `bones approve -q "<words>" "<note>"` now prompts Touch ID and writes
  `8-promote.authorized` (the guard lifts while HEAD equals the authorized sha); deploy + smoke; then
  `bones confirm -e <smoke record> "<note>"` writes `8-promote.ok`; `bones next` starts the 7-day clock.
- Stage 5 needs a pinned plan: `bones plan -e docs/plan.md "<note>"` before `bones build`.
- Stages 4, 6, 7 validate evidence through `contracts/` (council, conformance + review, staging).

Rollback: restore the backup dir over `~/.claude/skills/horvitz-pipeline`, then `scripts/fleet.sh repin -r "rollback to 1.x"`
and `scripts/fleet.sh doctor`. Journal it.
