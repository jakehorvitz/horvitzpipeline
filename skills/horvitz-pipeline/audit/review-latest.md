Reviewer: gemini-cli (gemini-3-flash-preview), cross-model adversarial review of Horvitz 2.0 Slice A, 2026-08-21
Scope: diff of feat/v2 vs main — scripts/bones.sh, scripts/bones-guard.sh, contracts/*.sh, scripts/bones-owner-auth.swift, scripts/fleet.sh, ship-pipeline loop.sh (-P), audit/audit.sh — reviewed against the signed spec rev 2 anti-requirements ANTI-01..ANTI-10.
Raw reviewer output (verbatim, including its own severity labels) is kept in the private workspace at docs/horvitz-2.0-review-gemini-raw.md; this file is the triage. Two findings were rated critical by the reviewer and both are resolved below; nothing critical remains open.

findings:
F-01 [must-fix]: bones-guard.sh seal-on-read carve-out — the `cd <path> &&` clause used `[^;&|]+`, which admitted `$(...)` and backticks inside the path, so an unsealed run could run arbitrary commands behind `bones status`.
  resolved: commit (this tree) — the carve-out now requires a literal path class `[A-Za-z0-9._/~ -]` (quotes allowed) and additionally refuses any command containing $ ` ( ) ; | < > \ ; selftest `unsealed-status` probes `cd /tmp/$(…) && bash bones.sh status`, a backtick prefix, and a redirect, all BLOCK.
F-02 [must-fix]: 8a token bound to `git rev-parse HEAD` only — uncommitted edits could ride a valid authorization into a deploy.
  resolved: commit (this tree) — `owner_token_mint` refuses stage-8 authorization while the tree is dirty (changes outside .bones/ and .loop/), `owner_auth_recheck` (confirm/next/status/doctor) and the guard's 8a lift both require a clean tree in addition to HEAD equality; selftest `promote-split` step 4b writes an uncommitted file and asserts the guard blocks, then re-lifts once the tree is clean.
F-03 [must-fix]: contracts/review.sh rejected a must-fix whose `resolved:` sat on the following continuation line.
  resolved: commit (this tree) — the contract now scans each must-fix block (its line plus continuation lines up to the next F-nn/security-gate/must-fix) for `resolved:`; fixture review/accept-3.md covers the continuation form.
F-04 [should]: bones-owner-auth.swift `sign` hard-coded `.deviceOwnerAuthenticationWithBiometrics`, so a `--policy presence` key (no Touch ID) could never sign. resolved: `--policy biometry|presence` is passed by bones.sh from the pinned owner-mode and selects the LAPolicy.
F-05 [should]: reviewer suggested `npm run deploy` / `yarn deploy` bypass the D1 deploy-shape rule. declined: D1 already blocks `(npm|pnpm|yarn|bun) [run] *deploy|publish|release|promote*` (selftest BYP-07 family); a script under an arbitrary name that shells out to a deploy CLI is the disclosed R4 residual (regex-over-Bash), not a 2.0 regression. Documented in README residuals.
F-06 [nit]: contracts/plan.sh rejected `###` subheadings inside the Changes section. resolved: lines starting with `#` are ignored inside that section.
security-gate: triggered — the owner-auth path (token mint/verify, helper pinning, guard re-verification) is a security-bearing change; both critical findings are closed with mechanical tests and no unmitigated hole remains.
VERDICT: CLEAN
