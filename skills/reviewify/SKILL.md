---
name: reviewify
description: "Owns the Horvitz pipeline review artifacts — the Stage 4 council/second-pass critique and the Stage 5.5 conformance + Stage 6 adversarial review. Use inside a run at those gates, or when Jake says 'review this', 'red-team it', 'does the build match the spec'. Produces the verdict, conformance report, and review file the gates are held to."
---

# reviewify — council, conformance, and adversarial review

Second opinions, not tests: executable checks are the truth; review is the independent skeptic. This skill owns the review artifacts at stages 4, 5.5, and 6.

## Produces
**Stage 4:** a council record (`council-verdict: BUILD|REVISE|KILL`; >=2 `voice: <name> — NN/100` lines with >=1 `finding:`, or a `second-pass-critique:` block with `risk-triggers:` and >=3 findings; `dissent:`), validated by `contracts/council.sh`; a REVISE/KILL record is accepted as evidence but `next` refuses until a BUILD record exists. **Stage 5.5:** a conformance report (`contracts/conformance.sh`) whose first line pins the signed spec's sha and which marks **every** `AC-nn` MATCHES/DRIFTED/MISSING with `evidence: <path[:line]>` or `test: <id>` — zero drift, mandatory `plan-deviations:` line. **Stage 6:** a review file (`contracts/review.sh`) with `findings:`, `F-nn [must-fix|should|nit]:` lines (every must-fix carries `resolved:`, or the literal `must-fix: none found`), and a `security-gate: triggered|not-triggered — <reason>` line; a risk-triggered `/security-review` fires if the build touches auth/payments/PII/uploads/webhooks/admin/multi-tenant/public-write.

## Procedure
1. Stage 4: run claude-council when stakes warrant (multiple architectures, irreversible data/schema, auth/payments/PII, cost risk); else a cheap second-pass critique. Rejection means `bones back -s 3`.
2. Stage 5.5: re-read the SIGNED spec top to bottom; any DRIFTED/MISSING means `bones back -s 5` or a re-signed amendment.
3. Stage 6: cross-model adversarial review of the diff vs spec + anti-requirements, on a different model/lens than the builder. Findings feed back to Stage 5.

## Activates
Stages 4 and 6 (and the 5.5 conformance check) of any Horvitz/ship run; or when Jake asks to review or red-team a build.
