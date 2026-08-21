#!/usr/bin/env bash
# contracts/council.sh <council record> — stage-4 artifact contract.
# Required: council-verdict: BUILD|REVISE|KILL; either >=2 "voice: <name> — NN/100" lines
# (with >=1 substantive finding:) OR a second-pass-critique: block with a substantive
# risk-triggers: line and >=3 finding: lines; and a dissent: line ("dissent: none" allowed).
CONTRACT_NAME=council; . "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || creason "needs the council record file"
f="$1"; [ -f "$f" ] || creason "record not found: $f"
v="$(cfield "$f" council-verdict)"
case "$v" in BUILD|REVISE|KILL) ;; *) creason "council-verdict must be BUILD|REVISE|KILL (got '${v:-missing}')" ;; esac
voices="$(ccount "$f" '^voice:[[:space:]]*[^[:space:]].*[—-][[:space:]]*[0-9]{1,3}[[:space:]]*/[[:space:]]*100')"
findings="$(ccount "$f" '^finding:[[:space:]]*[^[:space:]]')"
if [ "$voices" -ge 2 ]; then
  [ "$findings" -ge 1 ] || creason "voices without a single finding: line is a hollow record"
elif grep -qE '^second-pass-critique:' "$f"; then
  rt="$(cfield "$f" risk-triggers)"
  hollow_text "$rt" && creason "second-pass-critique needs a substantive risk-triggers: line (why the full council was skipped)"
  [ "$findings" -ge 3 ] || creason "second-pass-critique needs >=3 finding: lines (found $findings)"
else
  creason "needs >=2 'voice: <name> — NN/100' lines or a second-pass-critique: block (found $voices voices)"
fi
grep -qE '^dissent:' "$f" || creason "missing dissent: line (write 'dissent: none' if there was none)"
while IFS= read -r ln; do
  t="${ln#finding:}"; hollow_text "$t" && creason "hollow finding line: '$ln'"
done < <(grep -E '^finding:' "$f")
exit 0
