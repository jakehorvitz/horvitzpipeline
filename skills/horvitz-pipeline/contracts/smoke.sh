#!/usr/bin/env bash
# contracts/smoke.sh <smoke record> — stage-8b (confirm) artifact contract.
# Required: smoke-target: <url or command>, smoke-result: PASS|FAIL, smoke-at: <ISO-8601 UTC>.
# When SMOKE_AFTER is set (the 8a authorization timestamp) smoke-at must be later than it.
CONTRACT_NAME=smoke; . "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || creason "needs the smoke record"
f="$1"; [ -f "$f" ] || creason "record not found: $f"
for k in smoke-target smoke-result smoke-at; do
  grep -qE "^$k:[[:space:]]*[^[:space:]]" "$f" || creason "smoke record missing '$k:'"
done
r="$(cfield "$f" smoke-result)"
case "$r" in
  PASS) ;;
  FAIL) creason "smoke-result: FAIL — roll back; 8b stays open (record it with bones confirm --failed)" ;;
  *) creason "smoke-result must be PASS|FAIL (got '$r')" ;;
esac
at="$(cfield "$f" smoke-at)"
printf '%s' "$at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || creason "smoke-at must be an ISO-8601 UTC timestamp like 2026-08-21T21:00:00Z"
if [ -n "${SMOKE_AFTER:-}" ]; then
  [ "$at" \> "$SMOKE_AFTER" ] || creason "smoke-at ($at) is not after the 8a authorization ($SMOKE_AFTER) — smoke must run after authorize + deploy"
fi
hollow_token "$(cfield "$f" smoke-target)" && creason "smoke-target is hollow"
st="$(cfield "$f" smoke-target)"; [ "${#st}" -ge 8 ] || creason "smoke-target too short to identify what was hit"
exit 0
