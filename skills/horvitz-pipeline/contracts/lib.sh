#!/usr/bin/env bash
# contracts/lib.sh — shared helpers for artifact contracts (sourced, not executed).
#
# Contract protocol (every contracts/<name>.sh):
#   <name>.sh <evidence files...>   exit 0 = artifact satisfies the contract
#                                   exit 1 = refused; ONE line on stderr names the missing/bad field
# The orchestrator (bones.sh run_contract) calls these by name with BONES_DIR exported so a
# contract can locate the SIGNED stage-3 spec through the gate record (never a free path).
# No env overrides are honored for spec location: a forged env var must not redirect a contract.
set -u
creason() { printf 'contract[%s]: %s\n' "${CONTRACT_NAME:-?}" "$1" >&2; exit 1; }
csha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
# first "key: value" line (key is case-sensitive, anchored at line start)
cfield() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
ccount() { local c; c="$(grep -cE "$2" "$1" 2>/dev/null || true)"; printf '%s\n' "${c:-0}"; }
# signed_spec_path: the first *.html evidence of gates/3-spec.ok under $BONES_DIR, re-hashed.
# rc 0 + path; rc 1 = no signed spec; rc 2 = spec changed since sign-off.
signed_spec_path() {
  local gf="${BONES_DIR:-}/gates/3-spec.ok" ln path want
  [ -f "$gf" ] || return 1
  while IFS= read -r ln; do
    path="$(printf '%s' "$ln" | sed -E 's/^evidence: (.*) \(sha256:[a-f0-9-]+\)$/\1/')"
    want="$(printf '%s' "$ln" | sed -E 's/^.*\(sha256:([a-f0-9-]+)\)$/\1/')"
    case "$path" in
      *.html|*.htm)
        [ -f "$path" ] || return 1
        [ "$(csha "$path")" = "$want" ] || return 2
        printf '%s\n' "$path"; return 0 ;;
    esac
  done < <(grep '^evidence: ' "$gf")
  return 1
}
spec_ac_ids() { grep -oE 'AC-[0-9]{2}' "$1" | sort -u; }
# image_kind <file> -> png|jpeg|webp|"" from magic bytes (extension is never trusted)
image_kind() {
  local m; m="$(head -c 12 "$1" 2>/dev/null | xxd -p | tr -d '\n')"
  case "$m" in
    89504e47*) printf 'png\n' ;;
    ffd8ff*) printf 'jpeg\n' ;;
    52494646????????57454250) printf 'webp\n' ;;
    *) printf '\n' ;;
  esac
}
# image_dims <file> -> "W H" via sips (macOS); empty when unreadable
image_dims() {
  command -v sips >/dev/null 2>&1 || { printf '\n'; return; }
  local w h
  w="$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  h="$(sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  if [ -n "$w" ] && [ -n "$h" ]; then printf '%s %s\n' "$w" "$h"; else printf '\n'; fi
}
# hollow_token <string> -> rc 0 for a bare placeholder token (no length rule: file names like test.sh are evidence)
hollow_token() {
  local t; t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[.]+$//')"
  case "$t" in
    ""|tbd|todo|n/a|na|none|-|x|xx|xxx|ok|okay|done|fine|good|yes|pass|passed|"see code"|"see above"|"see below"|"looks good"|"as above"|same) return 0 ;;
  esac
  return 1
}
# hollow_text <string> -> rc 0 when the text is a placeholder, not evidence
hollow_text() {
  local t; t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[.]+$//')"
  case "$t" in
    ""|tbd|todo|n/a|na|none|-|"see code"|"see above"|"see below"|"looks good"|ok|okay|done|fine|good|yes|x|xxx|"as above"|"same"|pass|passed) return 0 ;;
  esac
  [ "${#t}" -lt 8 ] && return 0
  return 1
}
