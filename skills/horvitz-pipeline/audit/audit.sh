#!/usr/bin/env bash
# bones-pipeline audit v2 — mechanical scorecard. PASS iff NO hard-required check
# fails AND score >= 95% of max. Binding acceptance command for the 2026-08-07
# "rate + wire brains" audit loop.
# Writes ONLY its own logs under audit/ (selftest-latest.log, doctor-latest.log);
# never touches pipeline state. accept-run-N.log files preserve run history.
set -u

SKILL="$HOME/.claude/skills/horvitz-pipeline"
SHIP="$HOME/.claude/skills/ship-pipeline"
BONES="$SKILL/scripts/bones.sh"
GUARD="$SKILL/scripts/bones-guard.sh"
BRAINS_REF="$SHIP/references/brains.md"
SETTINGS="$HOME/.claude/settings.json"

SCORE=0
MAX=0
FAILS=""
HARDFAIL=0

check() { # check <points> <hard:0|1> <id> <desc> <pass:0|1>
  local pts="$1" hard="$2" id="$3" desc="$4" ok="$5"
  MAX=$((MAX + pts))
  if [ "$ok" -eq 0 ]; then
    SCORE=$((SCORE + pts))
    printf 'PASS %-4s (%3d%s) %s\n' "$id" "$pts" "$([ "$hard" -eq 1 ] && printf ',HARD')" "$desc"
  else
    FAILS="$FAILS $id"
    [ "$hard" -eq 1 ] && HARDFAIL=1
    printf 'FAIL %-4s (%3d%s) %s\n' "$id" "$pts" "$([ "$hard" -eq 1 ] && printf ',HARD')" "$desc"
  fi
}

# ---------- A. Integrity & enforcement (300, all HARD) ----------
bash -n "$BONES" 2>/dev/null && bash -n "$GUARD" 2>/dev/null; check 50 1 A1 "bones.sh + bones-guard.sh parse clean (bash -n)" $?

a2=1
if command -v jq >/dev/null 2>&1; then
  jq -e '.hooks.PreToolUse | tostring | contains("bones-guard.sh")' "$SETTINGS" >/dev/null 2>&1 && a2=0
else
  grep -q 'bones-guard.sh' "$SETTINGS" 2>/dev/null && a2=0
fi
check 50 1 A2 "guard registered as a PreToolUse hook in settings.json" $a2

pin="$(head -1 "$SKILL/.bones/guard.sha256" 2>/dev/null | awk '{print $1}')"
cur="$(shasum -a 256 "$GUARD" 2>/dev/null | awk '{print $1}')"
[ -n "$pin" ] && [ "$pin" = "$cur" ]; check 50 1 A3 "guard hash pin matches live guard (no tamper)" $?

( cd "$SKILL" && bash "$BONES" selftest ) > "$SKILL/audit/selftest-latest.log" 2>&1; check 100 1 A4 "bones selftest: full bypass corpus BLOCKS" $?

( cd "$SKILL" && bash "$BONES" doctor ) > "$SKILL/audit/doctor-latest.log" 2>&1; check 50 1 A5 "bones doctor consistent on live dogfood state" $?

# ---------- B. Brain integration (350) ----------
b1=1
if [ -f "$BRAINS_REF" ]; then
  b1=0
  for token in 'Personal Jarvis/Brain' 'AI-Brain' 'hormozi-vault' 'video-brain' 'memory'; do
    grep -q "$token" "$BRAINS_REF" || b1=1
  done
  for p in "$HOME/Personal Jarvis/Brain" "$HOME/Personal Jarvis/AI-Brain" "$HOME/projects/hormozi-vault" "$HOME/projects/video-brain" "$HOME/.claude/projects/-Users-jakehorvitz-Personal-Jarvis/memory"; do
    [ -d "$p" ] || b1=1
  done
fi
check 100 0 B1 "references/brains.md exists, covers all 5 brains, paths live" $b1

b2=1
grep -q 'references/brains.md' "$SKILL/SKILL.md" && grep -q 'hormozi-vault' "$SKILL/SKILL.md" && grep -q 'video-brain' "$SKILL/SKILL.md" && grep -q 'AI-Brain' "$SKILL/SKILL.md" && b2=0
check 50 0 B2 "bones SKILL.md routes to the brains + reference file" $b2

stage1="$(awk '/^STAGE_BRIEF=\(/,/^\)/' "$BONES" | grep -m1 'interrogation')"
printf '%s' "$stage1" | grep -q 'brains.md'; check 75 0 B3 "stage-1 brief: recon consults memory + brain vaults" $?

stage10="$(awk '/^STAGE_BRIEF=\(/,/^\)/' "$BONES" | grep -m1 -i 'double-down')"
printf '%s' "$stage10" | grep -qi 'learnings back'; check 75 0 B4 "stage-10 brief: learnings written BACK to memory/brains" $?

grep -q 'no relevant brain' "$BONES"; check 50 0 B5 "stage-1 evidence check ENFORCES brains recon (not just prose)" $?

# ---------- C. Gate discipline (200) ----------
grep -q 'verbatim' "$SKILL/SKILL.md"; check 50 0 C1 "owner-gate verbatim-quote protocol documented" $?
grep -q 'enforced, not suggested' "$SKILL/SKILL.md"; check 50 0 C2 "evidence enforcement (stages 1,3,6,7) documented" $?
grep -q 'BONES_LLM' "$BONES"; check 50 0 C3 "LLM substance check wired in bones.sh" $?
grep -q 'operate-due' "$BONES"; check 50 0 C4 "7-day operate clock wired in bones.sh" $?

# ---------- D. Usability (150) ----------
briefs=$(awk '/^STAGE_BRIEF=\(/,/^\)/' "$BONES" | grep -c '^  "')
[ "$briefs" -ge 10 ]; check 50 0 D1 "all 10 stage requirement briefs present ($briefs found)" $?
grep -q 'Non-code' "$SKILL/SKILL.md"; check 50 0 D2 "non-code ops mapping documented" $?
[ -f "$SKILL/audit/rubric.html" ]; check 50 0 D3 "audit scorecard committed alongside the skill" $?

# ---------- E. Cross-model review (50, HARD) ----------
rev="$SKILL/audit/review-latest.md"
e1=1
[ -s "$rev" ] && grep -q '^Reviewer:' "$rev" && grep -q 'VERDICT: CLEAN' "$rev" && ! grep -q 'CRITICAL-OPEN' "$rev" && e1=0
check 50 1 E1 "cross-model review triaged: Reviewer named, VERDICT: CLEAN, no CRITICAL-OPEN" $e1

# ---------- verdict, bound to source state ----------
echo "----------------------------------------"
pct=$((SCORE * 100 / MAX))
norm="$(awk -v s="$SCORE" -v m="$MAX" 'BEGIN{printf "%.2f", s*10/m}')"
printf 'SCORE: %d / %d  (%s / 10, threshold 9.50 + zero HARD fails)\n' "$SCORE" "$MAX" "$norm"
[ -n "$FAILS" ] && printf 'OPEN:%s\n' "$FAILS"
echo "-- source-state stamp --"
date -u +%Y-%m-%dT%H:%M:%SZ
for f in "$BONES" "$GUARD" "$SKILL/SKILL.md" "$BRAINS_REF" "$SKILL/audit/audit.sh" "$rev"; do
  [ -f "$f" ] && shasum -a 256 "$f" | awk '{print $1"  "$2}'
done
if [ "$HARDFAIL" -eq 0 ] && [ "$pct" -ge 95 ]; then echo VERDICT: PASS; exit 0; else echo VERDICT: FAIL; exit 1; fi
