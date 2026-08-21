#!/usr/bin/env bash
# contracts/review.sh <review file> — stage-6 adversarial review contract.
# Required: a "findings:" section with "F-nn [must-fix|should|nit]: …" lines (or the literal
# "must-fix: none found" when there is none); every must-fix carries "resolved: <commit/change>";
# "security-gate: triggered|not-triggered — <reason>" with a substantive reason.
CONTRACT_NAME=review; . "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || creason "needs the review file"
f="$1"; [ -f "$f" ] || creason "review not found: $f"
grep -qE '^findings:' "$f" || creason "missing 'findings:' section header"
fc="$(ccount "$f" '^F-[0-9]{2}[[:space:]]*\[(must-fix|should|nit)\]:')"
mf="$(ccount "$f" '^F-[0-9]{2}[[:space:]]*\[must-fix\]:')"
if [ "$fc" -eq 0 ] || [ "$mf" -eq 0 ]; then
  grep -qE '^must-fix:[[:space:]]*none found' "$f" || creason "needs 'F-nn [must-fix|should|nit]: …' lines and, when no must-fix exists, the literal 'must-fix: none found'"
fi
while IFS= read -r ln; do
  printf '%s' "$ln" | grep -qE 'resolved:[[:space:]]*[^[:space:]]' || creason "open must-fix (no 'resolved: <commit/change>'): '$ln'"
done < <(grep -E '^F-[0-9]{2}[[:space:]]*\[must-fix\]:' "$f")
sg="$(cfield "$f" security-gate)"
printf '%s' "$sg" | grep -qE '^(triggered|not-triggered)[[:space:]]*—[[:space:]]*[^[:space:]]' || creason "security-gate must read 'triggered|not-triggered — <reason>'"
reason="$(printf '%s' "$sg" | sed -E 's/^[a-z-]+[[:space:]]*—[[:space:]]*//')"
hollow_text "$reason" && creason "security-gate reason is hollow"
while IFS= read -r ln; do
  t="$(printf '%s' "$ln" | sed -E 's/^F-[0-9]{2}[[:space:]]*\[[a-z-]+\]:[[:space:]]*//')"
  hollow_text "$t" && creason "hollow finding: '$ln'"
done < <(grep -E '^F-[0-9]{2}[[:space:]]*\[' "$f")
exit 0
