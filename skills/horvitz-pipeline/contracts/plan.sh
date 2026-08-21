#!/usr/bin/env bash
# contracts/plan.sh <plan.md> — the plan artifact between the signed spec and the build loop.
# Required: plan-for: <spec> (sha256:<sha of the SIGNED spec>); sections ## Architecture,
# ## Changes (path — create|edit|delete — why, non-hollow why), ## Order (numbered),
# ## Test seams, ## Acceptance map (AC-nn -> step N[, N] | promote) whose id set equals the spec's.
CONTRACT_NAME=plan; . "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || creason "needs the plan file"
f="$1"; [ -f "$f" ] || creason "plan not found: $f"
for h in '## Architecture' '## Changes' '## Order' '## Test seams' '## Acceptance map'; do
  grep -qE "^$h" "$f" || creason "missing section '$h'"
done
spec="$(signed_spec_path)"; rc=$?
[ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] && creason "the signed stage-3 spec changed since sign-off — re-sign (back -s 3), then plan again"; creason "cannot locate the signed stage-3 spec (gates/3-spec.ok with an *.html evidence line)"; }
psha="$(cfield "$f" plan-for | sed -nE 's/.*sha256:([a-f0-9]+).*/\1/p')"
[ -n "$psha" ] || creason "missing 'plan-for: <spec path> (sha256:…)' line"
[ "$psha" = "$(csha "$spec")" ] || creason "plan-for sha256 does not match the signed spec ($spec) — plan is stale or for another spec"
want="$(spec_ac_ids "$spec")"
have="$(sed -n '/^## Acceptance map/,$p' "$f" | grep -oE '^AC-[0-9]{2}[[:space:]]*->' | grep -oE 'AC-[0-9]{2}' | sort -u)"
[ -n "$want" ] || creason "the signed spec carries no AC-nn ids — acceptance rows must be id'd"
[ "$want" = "$have" ] || creason "acceptance map ids differ from the signed spec (spec: $(printf '%s' "$want" | tr '\n' ' ')| plan: $(printf '%s' "$have" | tr '\n' ' '))"
while IFS= read -r ln; do
  printf '%s' "$ln" | grep -qE '^AC-[0-9]{2}[[:space:]]*->[[:space:]]*(step[[:space:]]*[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*|promote)' \
    || creason "acceptance map line must map to 'step N[, N]' or 'promote': '$ln'"
done < <(sed -n '/^## Acceptance map/,$p' "$f" | grep -E '^AC-')
n=0
while IFS= read -r ln; do
  n=$((n+1))
  nf="$(printf '%s' "$ln" | awk -F' — ' '{print NF}')"
  [ "$nf" -ge 3 ] || creason "Changes line needs 'path — create|edit|delete — why': '$ln'"
  act="$(printf '%s' "$ln" | awk -F' — ' '{print $2}')"
  printf '%s' "$act" | grep -qE '^(create|edit|delete)' || creason "Changes action must be create|edit|delete: '$ln'"
  why="$(printf '%s' "$ln" | awk -F' — ' '{print $NF}')"
  hollow_text "$why" && creason "hollow reason on Changes line: '$ln'"
done < <(sed -n '/^## Changes/,/^## /p' "$f" | grep -vE '^## ' | grep -E '[^[:space:]]')
[ "$n" -ge 1 ] || creason "Changes section is empty"
[ "$(ccount "$f" '^[0-9]+\.')" -ge 1 ] || creason "Order needs numbered steps (1. 2. …)"
ts="$(sed -n '/^## Test seams/,/^## /p' "$f" | grep -vE '^## ' | grep -cE '[^[:space:]]' || true)"
[ "${ts:-0}" -ge 1 ] || creason "Test seams section is empty"
exit 0
