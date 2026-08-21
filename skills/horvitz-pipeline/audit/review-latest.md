Reviewer: gemini-cli (gemini-3-flash-preview) + second-voice council grok-4.20-reasoning and perplexity sonar-reasoning-pro — cross-model adversarial + security review of Horvitz 2.0 Slice A, 2026-08-21
Scope: diff of feat/v2 vs main — scripts/bones.sh, scripts/bones-guard.sh, contracts/*.sh, scripts/bones-owner-auth.swift, scripts/fleet.sh, ship-pipeline loop.sh (-P), audit/audit.sh — against the signed spec rev 2 and its anti-requirements. Raw reviewer outputs are kept verbatim in the private workspace (docs/horvitz-2.0-review-gemini-raw.md, docs/horvitz-2.0-review2-council.md); this file is the triage. Findings the reviewers rated critical are resolved below with selftests; nothing critical remains open.

findings:
F-01 [must-fix]: (gemini) bones-guard.sh seal-on-read carve-out admitted $(...) and backticks inside the cd clause.
  resolved: literal-path class + forbidden-character check; selftest unsealed-status probes command substitution, backtick prefix, redirect — all BLOCK.
F-02 [must-fix]: (gemini) 8a token bound to HEAD only; uncommitted edits could ride a valid authorization.
  resolved: mint, recheck (confirm/next/status/doctor) and the guard's 8a lift all require a CLEAN tree (changes outside .bones/.loop); selftest promote-split step 4b.
F-03 [must-fix]: (gemini) contracts/review.sh rejected resolved: on a continuation line. resolved: block-scanned; fixture review/accept-3.md.
F-04 [should]: (gemini) Swift helper hard-coded the biometrics LAPolicy. resolved: --policy biometry|presence passed from the pinned owner-mode.
F-05 [should]: (gemini) npm/yarn deploy scripts bypass D1. declined: D1 already blocks (npm|pnpm|yarn|bun) [run] *deploy|publish|release|promote*; arbitrary script names are the disclosed R4 residual.
F-06 [nit]: (gemini) plan.sh rejected ### subheadings in Changes. resolved: # lines ignored inside the section.
F-07 [must-fix]: (perplexity) the guard evaluated only the cd-target tree, so `cd .. && git -C project push origin main`, `cd .. && printf > project/.bones/gates/8-promote.ok`, `make -C project deploy` escaped it.
  resolved: every tree the command touches is evaluated (session cwd, cd/pushd target, git -C / make -C / --cwd targets) and the .bones/ write-tamper rule is global; selftest BYP-18 covers all of these from inside and from outside the tree.
F-08 [must-fix]: (grok) contracts/*.sh live outside .bones with no integrity pin, so an edited smoke.sh (`exit 0`) would let 8b pass.
  resolved: each run pins contract hashes in .bones/contracts.sha256 (init / first use); run_contract refuses a changed contract until `bones contracts-repin -r` (which requires the contracts + hollow selftests to PASS); doctor reports drift; guard T2 makes the installed orchestrator dirs read-only for an agent inside an active run until 8a is authorized; selftest BYP-19.
F-09 [should]: (grok, perplexity) obfuscated-path writes to .bones/owner.pub (e.g. a printf-escaped path) or `used-nonces` defeat the literal .bones regex and allow an attacker key to be pinned.
  resolved: acknowledged as the disclosed R4 class (regex-over-Bash; same as forging any gate file or patching the guard) — README R4 now names these files explicitly and the next frontier (a non-regex write broker); not claimed closed.
F-10 [should]: (perplexity) passphrase mode is treated as authoritative once pinned. declined: by design it is opt-in (--accept-degraded), labeled DEGRADED in status/doctor, and the owner types the passphrase; documented as R3.
F-11 [nit]: (grok, perplexity) bash hygiene remarks (set -e, unquoted expansions, `exit` in a library function, env defaults). reviewed: expansions are quoted, OWNER_* defaults are defined at load, `exit` after owner_helper_bin is intentional fail-closed; no change.
security-gate: triggered — owner-auth, guard, and contract-integrity paths are security-bearing; every critical finding from both reviews is closed with a mechanical selftest (unsealed-status, promote-split, BYP-18, BYP-19) and the residual class is disclosed, not hidden.
VERDICT: CLEAN
