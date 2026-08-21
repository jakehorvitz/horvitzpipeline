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
#   SEAL-ON-READ (2.0): a run whose state.sha256 is missing lets ONLY a bare
#     `bones.sh status|doctor` through (so it can re-seal itself); everything else blocks.
#   STAGE 8 (2.0): a VALID owner token in gates/8-promote.authorized — signed by the
#     pinned owner key (.bones/owner.pub) and bound to the CURRENT git HEAD — lifts the
#     pre-promote rules below (8a authorized). Anything else at stage 8 is blocked like 1..7.
#   PRE-PROMOTE (stage 1..8, unless 8a-authorized for the current HEAD):
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
auth_why=""

block() { # block <rule> <why>
  printf 'bones-guard: BLOCKED [%s]. Pipeline "%s" is at stage %s/10. %s Run `bones status` for the open gate. Do NOT reword the command to get around this guard — that is gate evasion and it goes on the record.\n' \
    "$1" "$name" "$stage" "$2${auth_why:+ ($auth_why)}" >&2
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
# Seal-on-read (2.0): an unsealed run may still be inspected and healed — allow ONLY a bare
# `bones.sh status|doctor` (optionally after a cd into the tree); anything else stays blocked.
if [ "$tool" = "Bash" ] && [ ! -f "$bones/state.sha256" ]; then
  # Only literal paths: no $, backticks, parentheses, redirects or chaining may appear anywhere.
  if printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cd[[:space:]]+["'\'']?[A-Za-z0-9._/~ -]+["'\'']?[[:space:]]*&&[[:space:]]*)?(bash[[:space:]]+)?["'\'']?[A-Za-z0-9._/~-]*bones(\.sh)?["'\'']?[[:space:]]+(status|doctor)[[:space:]]*$' \
     && ! printf '%s' "$cmd" | grep -qE '[$`();|<>\\]'; then
    exit 0
  fi
fi
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

# ---- 8a authorization (2.0): at stage 8 a VALID owner token bound to the current HEAD lifts
#      the promote rules (G1/D1/D2). Anything else at stage 8 is blocked exactly like stages 1..7.
auth_ok=0
if [ "$stage" -eq 8 ]; then
  auth_why="no 8a authorization on record — bones approve (Touch ID) first"
  if [ -f "$bones/gates/8-promote.authorized" ]; then
    auth_why="8a authorization invalid or STALE (HEAD moved since the tap) — re-authorize"
    tok="$(sed -n 's/^owner-token:[[:space:]]*//p' "$bones/gates/8-promote.authorized" | head -1)"
    if [ -n "$tok" ] && [ -f "$bones/owner.pub" ] && command -v openssl >/dev/null 2>&1; then
      tgt="$(dirname "$bones")"; head_now="$(git -C "$tgt" rev-parse HEAD 2>/dev/null || printf nogit)"
      # F-02: the authorization binds the COMMITTED tree. Uncommitted edits outside the audit trail
      # (.bones/) and build logs (.loop/) make the tree dirty and the authorization unusable.
      dirty_now=""
      if [ "$head_now" != nogit ]; then dirty_now="$(git -C "$tgt" status --porcelain 2>/dev/null | grep -vE '^.. (\.bones|\.loop)(/|$)' | head -1)"; fi
      payload="$(printf '%s' "$tok" | jq -r '.payload // empty' 2>/dev/null)"
      sig="$(printf '%s' "$tok" | jq -r '.sig_b64 // empty' 2>/dev/null)"
      pub="$(printf '%s' "$tok" | jq -r '.pub_b64 // empty' 2>/dev/null)"
      IFS='|' read -r tv tn ts th tq tz tt <<<"$payload"
      if [ -n "$dirty_now" ]; then auth_why="working tree has uncommitted changes — commit or stash; 8a binds the committed tree"; fi
      if [ -z "$dirty_now" ] && [ "$tv" = "v1" ] && [ "$tn" = "$name" ] && [ "$ts" = "8" ] && [ "$th" = "$head_now" ] && [ -n "$sig" ] && [ -n "$pub" ]; then
        gw="$(mktemp -d "${TMPDIR:-/tmp}/bones-guard-auth.XXXXXX")"
        sed -n '/^-----BEGIN PUBLIC KEY-----/,/^-----END PUBLIC KEY-----/p' "$bones/owner.pub" > "$gw/pinned.pem"
        { printf '3059301306072a8648ce3d020106082a8648ce3d030107034200' | xxd -r -p; printf '%s' "$pub" | base64 -d 2>/dev/null; } > "$gw/pub.der"
        if openssl pkey -pubin -inform DER -in "$gw/pub.der" -outform PEM -out "$gw/pub.pem" >/dev/null 2>&1 \
           && [ -s "$gw/pinned.pem" ] \
           && [ "$(openssl pkey -pubin -in "$gw/pub.pem" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')" = "$(openssl pkey -pubin -in "$gw/pinned.pem" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')" ] \
           && printf '%s' "$sig" | base64 -d > "$gw/sig.der" 2>/dev/null && printf '%s' "$payload" > "$gw/payload" \
           && openssl dgst -sha256 -verify "$gw/pinned.pem" -signature "$gw/sig.der" "$gw/payload" >/dev/null 2>&1; then
          auth_ok=1; auth_why=""
        fi
        rm -rf "$gw"
      fi
    fi
  fi
fi
# Past the promote gate (stage 9+): promote-shaped commands are legitimate.
[ "$stage" -le 8 ] || exit 0
# 8a authorized for the CURRENT head: promote-shaped commands are legitimate.
[ "$auth_ok" -eq 1 ] && exit 0

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
