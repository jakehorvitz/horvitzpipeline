#!/usr/bin/env bash
# contracts/conformance.sh <conformance report> — stage-5.5/6 artifact contract.
# Required: first line "conformance: <spec> (sha256:<sha of the SIGNED spec>)"; one line per id
# "AC-nn: MATCHES|DRIFTED|MISSING — evidence: <path[:line]>" (or "test: <id>"); id set equals the
# signed spec's; zero DRIFTED/MISSING; "plan-deviations: none|<path>" (+ sha line when a path).
CONTRACT_NAME=conformance; . "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || creason "needs the conformance report"
f="$1"; [ -f "$f" ] || creason "report not found: $f"
head -1 "$f" | grep -qE '^conformance:' || creason "first line must be 'conformance: <signed spec path> (sha256:…)'"
spec="$(signed_spec_path)"; rc=$?
[ "$rc" -eq 0 ] || { [ "$rc" -eq 2 ] && creason "the signed spec changed since sign-off — re-sign before conformance"; creason "cannot locate the signed stage-3 spec"; }
csl="$(head -1 "$f" | sed -nE 's/.*sha256:([a-f0-9]+).*/\1/p')"
[ "$csl" = "$(csha "$spec")" ] || creason "conformance sha256 does not match the signed spec ($spec)"
grep -qE '^plan-deviations:[[:space:]]*[^[:space:]]' "$f" || creason "missing mandatory 'plan-deviations: none|<path>' line"
pd="$(cfield "$f" plan-deviations)"
if [ "$pd" != "none" ]; then
  [ -f "$pd" ] || creason "plan-deviations path not found: $pd"
  grep -qE "^plan-deviations-sha256:[[:space:]]*$(csha "$pd")" "$f" || creason "plan-deviations-sha256 missing or stale for $pd"
fi
want="$(spec_ac_ids "$spec")"
have="$(grep -oE '^AC-[0-9]{2}:' "$f" | tr -d ':' | sort -u)"
[ "$want" = "$have" ] || creason "AC id set differs from the signed spec (spec: $(printf '%s' "$want" | tr '\n' ' ')| report: $(printf '%s' "$have" | tr '\n' ' '))"
while IFS= read -r ln; do
  printf '%s' "$ln" | grep -qE '^AC-[0-9]{2}:[[:space:]]*(MATCHES|DRIFTED|MISSING)[[:space:]]*—' \
    || creason "line must read 'AC-nn: MATCHES|DRIFTED|MISSING — evidence: <path[:line]>': '$ln'"
  printf '%s' "$ln" | grep -qE '(evidence|test):[[:space:]]*[^[:space:]]+' \
    || creason "AC line lacks 'evidence: <path[:line]>' or 'test: <id>': '$ln'"
  ev="$(printf '%s' "$ln" | sed -nE 's/.*(evidence|test):[[:space:]]*([^[:space:]]+).*/\2/p')"
  hollow_token "$ev" && creason "hollow evidence on '$ln'"
done < <(grep -E '^AC-[0-9]{2}:' "$f")
bad="$(ccount "$f" '^AC-[0-9]{2}:[[:space:]]*(DRIFTED|MISSING)')"
[ "$bad" -eq 0 ] || creason "$bad unresolved DRIFTED/MISSING item(s) — bones back -s 5, or re-sign an amended spec (back -s 3)"
n="$(ccount "$f" '^AC-[0-9]{2}:')"
u="$(grep -E '^AC-[0-9]{2}:' "$f" | sed -nE 's/.*(evidence|test):[[:space:]]*([^[:space:]]+).*/\2/p' | sort -u | wc -l | tr -d ' ')"
if [ "$n" -ge 3 ] && [ "${u:-0}" -le 1 ]; then creason "every AC line cites the same evidence — hollow report"; fi
exit 0
