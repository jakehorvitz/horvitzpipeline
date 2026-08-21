#!/usr/bin/env bash
# fleet.sh — run a bones subcommand over every live .bones run on this machine.
#   fleet.sh list                 # every run: path, stage, schema, strict
#   fleet.sh doctor               # bones doctor per run; summary PASS/FAIL counts
#   fleet.sh repin -r "<reason>"  # bones guard-repin per run (after a deliberate guard upgrade)
#   fleet.sh pin-owner            # bones owner-pin per run (after bones owner-setup)
# Roots: ~/projects, ~/.claude/skills, "$HOME/Horvitz Final Folder" (override: BONES_FLEET_ROOTS, colon-separated).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONES="${BONES_SH:-$SCRIPT_DIR/bones.sh}"
IFS=':' read -r -a ROOTS <<<"${BONES_FLEET_ROOTS:-$HOME/projects:$HOME/.claude/skills:$HOME/Horvitz Final Folder}"
sub="${1:-list}"; shift || true
runs=()
for r in "${ROOTS[@]}"; do
  [ -d "$r" ] || continue
  while IFS= read -r d; do runs+=("$(dirname "$d")"); done < <(find "$r" -maxdepth 4 -type d -name .bones 2>/dev/null | sort)
done
[ "${#runs[@]}" -gt 0 ] || { printf 'fleet: no .bones runs found under %s\n' "${ROOTS[*]}"; exit 0; }
pass=0; fail=0
for t in "${runs[@]}"; do
  s="$t/.bones/state.json"
  stage="$(jq -r '.stage // "?"' "$s" 2>/dev/null)"; schema="$(jq -r '.schema_version // "null"' "$s" 2>/dev/null)"; strict="$(jq -r '.strict // "null"' "$s" 2>/dev/null)"; name="$(jq -r '.name // "?"' "$s" 2>/dev/null)"
  case "$sub" in
    list) printf '%-60s stage=%-3s schema=%-5s strict=%-6s %s\n' "${t/#$HOME/~}" "$stage" "$schema" "$strict" "$name" ;;
    doctor|repin|pin-owner)
      case "$sub" in doctor) cmd=(doctor) ;; repin) cmd=(guard-repin "$@") ;; pin-owner) cmd=(owner-pin) ;; esac
      if out="$(cd "$t" && bash "$BONES" "${cmd[@]}" 2>&1)"; then pass=$((pass+1)); printf 'OK    %-60s %s\n' "${t/#$HOME/~}" "$(printf '%s' "$out" | tail -1 | cut -c1-90)"
      else fail=$((fail+1)); printf 'FAIL  %-60s %s\n' "${t/#$HOME/~}" "$(printf '%s' "$out" | grep -vE '^\s*$' | tail -1 | cut -c1-90)"; fi ;;
    *) printf 'fleet: unknown subcommand %s (list|doctor|repin|pin-owner)\n' "$sub" >&2; exit 2 ;;
  esac
done
[ "$sub" = "list" ] && { printf '%s run(s)\n' "${#runs[@]}"; exit 0; }
printf 'fleet %s: %s ok, %s failed, %s total\n' "$sub" "$pass" "$fail" "${#runs[@]}"
[ "$fail" -eq 0 ]
