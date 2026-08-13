#!/usr/bin/env bash
#
# bones-guard.sh v2 — PreToolUse hook: makes bones gates bind at the HARNESS level.
#
# v1 was a denylist of known deploy commands; it leaked (git push HEAD:main,
# make deploy, bash deploy.sh all slipped). v2 inverts the logic where it counts:
#
#   ACTIVE pipeline (stage 1..10):
#     T1. .bones/ audit-trail tamper protection — only read-only commands may
#         mention .bones paths; writes/deletes/redirects are blocked (a forged
#         gate file is worse than a skipped gate). `bones reset` is Jake's call
#         from his own terminal (hooks only bind the agent's Bash tool, not his).
#   PRE-PROMOTE (stage 1..8):
#     G1. git push ALLOWLIST — a push passes ONLY as `git push [flags] <remote>
#         <branch>` with an explicit non-main/master branch, no force, no
#         delete, no colon refspec. Everything else (bare push, HEAD:main,
#         +main, -f, --delete) is blocked.
#     D1. deploy-task shapes — make/npm/yarn/pnpm/bun tasks, *.sh scripts, or
#         executables whose name contains deploy|publish|release|promote.
#     D2. known deploy CLIs — vercel --prod, netlify --prod, railway up,
#         fly deploy, npm/yarn/pnpm publish, gh release create, firebase
#         deploy, wrangler deploy/publish, eb deploy, heroku push/release.
#
# Contract (Claude Code PreToolUse): stdin JSON {tool_name, tool_input.command,
# cwd}; exit 0 allow, exit 2 block (stderr shown to the model).
#
# Escape hatch: BONES_GUARD=off (for non-pipeline work in a bones-managed tree).

set -u

[ "${BONES_GUARD:-on}" = "off" ] && exit 0

input="$(cat 2>/dev/null)" || exit 0
[ -n "$input" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
  printf 'bones-guard: BLOCKED [missing-jq]. jq is required so the guard can parse tool input safely. Install jq or use the bones installer, which vendors it.\n' >&2
  exit 2
fi

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
case "$tool" in
  Bash|Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

if [ "$tool" != "Bash" ]; then
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
  if [ -n "$file_path" ]; then
    case "$file_path" in
      /*) cwd="$(dirname "$file_path")" ;;
      *) cwd="$(cd "$cwd" 2>/dev/null && pwd)/$(dirname "$file_path")" ;;
    esac
  fi
fi

# If the command starts with `cd`/`pushd`, the work happens THERE — guard the
# target, including relative and home paths.
cd_target="$(printf '%s' "$cmd" | sed -nE "s/^[[:space:]]*(cd|pushd)[[:space:]]+[\"']?([^\"';&| ]+)[\"']?.*/\2/p")"
if [ -n "$cd_target" ]; then
  case "$cd_target" in
    "~"|"~/") cd_target="$HOME" ;;
    "~/"*) cd_target="$HOME/${cd_target#~/}" ;;
    /*) ;;
    *) cd_target="$cwd/$cd_target" ;;
  esac
  [ -d "$cd_target" ] && cwd="$(cd "$cd_target" 2>/dev/null && pwd)"
fi

# Find an active .bones by walking up from cwd.
d="$cwd"; bones=""
while [ "$d" != "/" ] && [ -n "$d" ]; do
  if [ -d "$d/.bones" ]; then bones="$d/.bones"; break; fi
  d="$(dirname "$d")"
done
[ -n "$bones" ] || exit 0
[ -f "$bones/state.json" ] || exit 0

stage="?"
name="?"

block() { # block <rule> <why>
  printf 'bones-guard: BLOCKED [%s]. Pipeline "%s" is at stage %s/10. %s Run `bones status` for the open gate. Do NOT reword the command to get around this guard — that is gate evasion and it goes on the record.\n' \
    "$1" "$name" "$stage" "$2" >&2
  exit 2
}

guard_sha() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else return 1; fi
}

# Never make an allow/block decision from unsealed state. Otherwise changing
# stage 5 to stage 9 disables every pre-promote rule even though bones status
# correctly rejects the same forgery.
[ -f "$bones/state.sha256" ] || block "state-integrity" "state.sha256 is missing; refusing to trust an unsealed stage."
want_state="$(head -1 "$bones/state.sha256" 2>/dev/null | awk '{print $1}')"
got_state="$(guard_sha "$bones/state.json" 2>/dev/null)" || block "state-integrity" "No sha256 tool is available to verify state."
[ -n "$want_state" ] && [ "$want_state" = "$got_state" ] \
  || block "state-integrity" "state.json sha256 does not match its seal; refusing forged or downgraded state."

stage="$(jq -r '.stage // empty' "$bones/state.json" 2>/dev/null)"
name="$(jq -r '.name // "?"' "$bones/state.json" 2>/dev/null)"
schema="$(jq -r '.schema_version // empty' "$bones/state.json" 2>/dev/null)"
case "$stage" in
  (''|*[!0-9]*) block "state-integrity" "state.json is unreadable or forged; bones refuses to trust a corrupted stage." ;;
esac
case "$schema" in 1|2) ;; *) block "state-integrity" "state schema is missing, unsupported, or downgraded." ;; esac

if [ "$tool" != "Bash" ]; then
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
  case "$file_path" in
    */.bones/*|*.bones/*)
      block "tamper" "Only bones.sh may write the .bones/ audit trail — file-edit tools cannot modify gate records, state, or pinned acceptance files."
      ;;
  esac
  exit 0
fi

[ -n "$cmd" ] || exit 0

# ---- T1: audit-trail tamper protection (any active stage 1..10) -------------
if [ "$stage" -le 10 ]; then
  if printf '%s' "$cmd" | grep -qE '\.bones/acceptance\.cmd|acceptance-path' \
  && printf '%s' "$cmd" | grep -qE '(>|>>|tee|sed[[:space:]].*-i|perl[[:space:]].*-i|rm[[:space:]]|mv[[:space:]]|cp[[:space:]]|chmod[[:space:]]|chown[[:space:]])'; then
    printf 'bones-guard: BLOCKED: acceptance command is read-only\n' >&2
    exit 2
  fi
  if printf '%s' "$cmd" | grep -qE '\.bones(/|[[:space:]]|"|'\''|$)'; then
    # read-only single commands are fine (no redirects, no chaining)
    if ! printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cat|ls|head|tail|grep|diff|find|wc|stat|shasum|sha256sum|file)[[:space:]][^;&|<>]*$'; then
      block "tamper" "Only bones.sh may write the .bones/ audit trail — direct edits forge gate records."
    fi
  fi
  if printf '%s' "$cmd" | grep -qE 'bones(\.sh)?([[:space:]]+[^;&|]*)?[[:space:]]reset([[:space:]]|$)'; then
    block "tamper" "bones reset wipes the audit trail mid-run — that is Jake's call, from his own terminal."
  fi
  if printf '%s' "$cmd" | grep -qE 'bones(\.sh)?[[:space:]]+init([^;&|]*[[:space:]])-f([[:space:]]|$)'; then
    block "tamper" "bones init -f replaces the active audit trail — that is an owner action, not an agent command."
  fi
fi

# Past the promote gate (stage 9+): promote-shaped commands are legitimate.
[ "$stage" -le 8 ] || exit 0

# ---- G1: git push allowlist --------------------------------------------------
if printf '%s' "$cmd" | grep -qE '(^|[;&|({][[:space:]]*)git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)'; then
  push_part="$(printf '%s' "$cmd" | sed -E 's/^.*git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)?[[:space:]]+push//' | sed -E 's/[;&|].*$//')"
  protected='(main|master)'
  if [ -f "$bones/protected-branches" ]; then
    extra="$(grep -E '^[A-Za-z0-9._/-]+$' "$bones/protected-branches" 2>/dev/null | paste -sd'|' -)"
    [ -n "$extra" ] && protected="($protected|$extra)"
  fi
  if printf '%s' "$push_part" | grep -qiE -- '(--force|--delete|-f([[:space:]]|$)|-d([[:space:]]|$)|\+|:)'; then
    block "git-push" "Force pushes, deletes, and refspecs are blocked before the promote gate."
  elif printf '%s' "$push_part" | grep -qiE "(^|[[:space:]])${protected}([[:space:]]|$)"; then
    block "git-push" "Pushing to a protected branch IS promotion — stage 8 is an owner gate."
  elif ! printf '%s' "$push_part" | grep -qE '^([[:space:]]+-[A-Za-z-]+)*[[:space:]]+origin[[:space:]]+[A-Za-z0-9._/-]+[[:space:]]*$'; then
    block "git-push" "Before promote, pushes must name an explicit remote AND a non-default branch (git push origin <feature-branch>) — a bare push can land on main."
  fi
fi

if printf '%s' "$cmd" | grep -qiE '(^|[;&|][[:space:]]*)(ssh[[:space:]]+git@|gh[[:space:]]+api([[:space:]]|$)|curl[[:space:]][^;&|]*(api\.github\.com|api\.gitlab\.com|api\.bitbucket\.org))'; then
  block "git-egress" "Raw git hosting egress can promote code outside the git-push allowlist."
fi

# ---- D1: deploy-task shapes ---------------------------------------------------
verbs='(deploy|publish|release|promote)'
if printf '%s' "$cmd" | grep -qiE "(^|[;&|][[:space:]]*)make[[:space:]]([^;&|]*[[:space:]])?${verbs}" \
|| printf '%s' "$cmd" | grep -qiE "(^|[;&|][[:space:]]*)(npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?[A-Za-z0-9:._-]*${verbs}" \
|| printf '%s' "$cmd" | grep -qiE "(^|[;&|/[:space:]])(bash|sh|zsh|source)?[[:space:]]*[A-Za-z0-9._/-]*${verbs}[A-Za-z0-9._-]*\.(sh|bash|zsh)([[:space:]]|$)" \
|| printf '%s' "$cmd" | grep -qiE "(^|[;&|][[:space:]]*)(\./)?([A-Za-z0-9._-]+/)*${verbs}([A-Za-z0-9._-]*)?([[:space:]]|$)" \
|| printf '%s' "$cmd" | grep -qiE "(^|[;&|][[:space:]]*)[A-Za-z0-9._-]+[[:space:]]+${verbs}([[:space:]]|$)"; then
  block "deploy-shape" "This looks like a deploy/publish/release task and the promote gate has not been passed."
fi

# ---- D2: known deploy CLIs ----------------------------------------------------
cli_re='(vercel([[:space:]]+deploy)?[^|;&]*--prod)'
cli_re="$cli_re|(netlify[[:space:]]+deploy[^|;&]*--prod)"
cli_re="$cli_re|(railway[[:space:]]+up)"
cli_re="$cli_re|(fly(ctl)?[[:space:]]+deploy)"
cli_re="$cli_re|(gh[[:space:]]+release[[:space:]]+create)"
cli_re="$cli_re|(firebase[[:space:]]+deploy)"
cli_re="$cli_re|(wrangler[[:space:]]+(deploy|publish))"
cli_re="$cli_re|(eb[[:space:]]+deploy)|(heroku[[:space:]]+.*(push|release))"
if printf '%s' "$cmd" | grep -qiE "$cli_re"; then
  block "deploy-cli" "Known deploy CLI invoked before the promote gate."
fi

exit 0
