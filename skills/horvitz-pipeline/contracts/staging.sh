#!/usr/bin/env bash
# contracts/staging.sh <staging record> <screenshot> [more files] — stage-7 artifact contract.
# Record fields: staging-url, data: fresh|seeded, tests: PASS (<n> passed, 0 failed), e2e: PASS,
# click-control: PASS <screenshot path>, competitor-read: <path or inline>, screenshot-sha256: <sha>.
# Screenshot: real PNG/JPEG/WEBP by magic bytes, >= BONES_MIN_SHOT_BYTES (10240), >= 640x400 (sips).
CONTRACT_NAME=staging; . "$(dirname "$0")/lib.sh"
[ $# -ge 2 ] || creason "needs the staging record AND the screenshot (>=2 files)"
rec=""; shot=""
for f in "$@"; do
  [ -f "$f" ] || creason "file not found: $f"
  k="$(image_kind "$f")"
  if [ -n "$k" ]; then [ -z "$shot" ] && shot="$f"
  elif [ -z "$rec" ] && grep -qE '^staging-url:' "$f"; then rec="$f"; fi
done
[ -n "$rec" ] || creason "no staging record among the files (needs a 'staging-url:' line)"
[ -n "$shot" ] || creason "no screenshot: need a real PNG/JPEG/WEBP by magic bytes (a renamed text file does not count)"
for k in staging-url data tests e2e click-control competitor-read screenshot-sha256; do
  grep -qE "^$k:[[:space:]]*[^[:space:]]" "$rec" || creason "staging record missing '$k:'"
done
printf '%s' "$(cfield "$rec" data)" | grep -qE '^(fresh|seeded)' || creason "data: must be fresh|seeded (never real data)"
printf '%s' "$(cfield "$rec" tests)" | grep -qE '^PASS \([0-9]+ passed, 0 failed\)' || creason "tests: must read 'PASS (<n> passed, 0 failed)'"
printf '%s' "$(cfield "$rec" e2e)" | grep -qE '^PASS' || creason "e2e: must be PASS"
printf '%s' "$(cfield "$rec" click-control)" | grep -qE '^PASS[[:space:]]+[^[:space:]]' || creason "click-control: must read 'PASS <screenshot path>'"
hollow_text "$(cfield "$rec" competitor-read)" && creason "competitor-read is hollow"
grep -qE '(^|[^A-Za-z])FAIL([^A-Za-z]|$)' "$rec" && creason "record contains a FAIL token — staging is not green"
sz="$(wc -c < "$shot" | tr -d ' ')"; min="${BONES_MIN_SHOT_BYTES:-10240}"
[ "$sz" -ge "$min" ] || creason "screenshot too small ($sz B < $min B) — a real click-through capture is larger"
dims="$(image_dims "$shot")"
[ -n "$dims" ] || creason "cannot read screenshot dimensions (sips unavailable or corrupt image)"
w="${dims% *}"; h="${dims#* }"
[ "$w" -ge "${BONES_MIN_SHOT_W:-640}" ] && [ "$h" -ge "${BONES_MIN_SHOT_H:-400}" ] || creason "screenshot dimensions ${w}x${h} below ${BONES_MIN_SHOT_W:-640}x${BONES_MIN_SHOT_H:-400}"
grep -qE "^screenshot-sha256:[[:space:]]*$(csha "$shot")" "$rec" || creason "screenshot-sha256 in the record does not match the attached screenshot"
exit 0
