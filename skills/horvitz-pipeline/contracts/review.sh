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
# A must-fix is resolved when 'resolved: <commit/change>' appears on its own line or on any
# continuation line before the next F-nn / security-gate / must-fix line.
open_mf="$(awk 'BEGIN{inb=0;ok=0}
  /^F-[0-9][0-9][[:space:]]*\[must-fix\]:/ { if (inb && !ok) print bad; inb=1; ok=0; bad=$0; if ($0 ~ /resolved:[[:space:]]*[^[:space:]]/) ok=1; next }
  /^(F-[0-9][0-9][[:space:]]*\[|security-gate:|must-fix:|findings:)/ { if (inb && !ok) print bad; inb=0; next }
  { if (inb && $0 ~ /resolved:[[:space:]]*[^[:space:]]/) ok=1 }
  END { if (inb && !ok) print bad }' "$f")"
[ -z "$open_mf" ] || creason "open must-fix (no 'resolved: <commit/change>' on its line or a continuation line): '$(printf '%s' "$open_mf" | head -1)'"
sg="$(cfield "$f" security-gate)"
printf '%s' "$sg" | grep -qE '^(triggered|not-triggered)[[:space:]]*—[[:space:]]*[^[:space:]]' || creason "security-gate must read 'triggered|not-triggered — <reason>'"
reason="$(printf '%s' "$sg" | sed -E 's/^[a-z-]+[[:space:]]*—[[:space:]]*//')"
hollow_text "$reason" && creason "security-gate reason is hollow"
while IFS= read -r ln; do
  t="$(printf '%s' "$ln" | sed -E 's/^F-[0-9]{2}[[:space:]]*\[[a-z-]+\]:[[:space:]]*//')"
  hollow_text "$t" && creason "hollow finding: '$ln'"
done < <(grep -E '^F-[0-9]{2}[[:space:]]*\[' "$f")
exit 0
