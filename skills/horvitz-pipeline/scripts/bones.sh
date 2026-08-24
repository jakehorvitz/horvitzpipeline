#!/usr/bin/env bash
#
# bones.sh — enforced-orchestration state machine for the 9.5 ship-pipeline.
#
# Where the ship-pipeline SKILL.md describes the gates in prose (an agent might
# skip one), bones.sh ENFORCES them: it tracks the current stage in
# .bones/state.json and REFUSES to advance past a gate until that gate is
# satisfied.
#
# Gate types:
#   owner  — Jake's call. Needs his VERBATIM words recorded via `approve -q "<quote>"`.
#            At stage 8 (promote) it ALSO needs his Touch-ID-signed owner token, bound to the
#            current git HEAD (bones owner-setup, one-time per machine). Strict mode (init -H)
#            requires the token at every owner gate. A pseudo-TTY proves nothing and is not
#            consulted. Stage 8 is two-phase: approve = 8a authorize, confirm = 8b (smoke record).
#   agent  — agent judgment. Needs a substantive note (evidence file(s) via -e
#            strongly encouraged; warned when missing on evidence-heavy stages).
#   auto   — machine-verified. Only `bones build` + loop.sh exit 0 opens it.
#   step   — no approval; `next` advances and records the step.
#
# The 10 stages:
#   1  brainstorm        [agent]  prompt interrogation done, prompt tightened
#   2  kill-or-commit    [owner]  Jake cleared the brutal <=30-min check (or killed it)
#   3  spec              [owner]  Jake signed off the HTML spec
#   4  council           [agent]  council verdict or second-pass critique recorded
#   5  build-loop        [AUTO]   loop.sh + independent pinned acceptance both exit 0
#   6  review-security   [agent]  adversarial review done + security gate cleared/NA
#   7  staging           [agent]  staging e2e + click + competitor green BEFORE promote
#   8  promote           [owner 8a + agent 8b]  8a: Jake's signed go lifts the guard for the
#                                authorized HEAD; deploy + smoke; 8b: bones confirm with the smoke
#                                record; the 7-day operate clock starts only at next
#   9  present           [step]   presented to the user
#   10 operate           [owner]  Jake's operate/learn decision (double-down/park/kill)
#
# Usage:
#   bones.sh init  -t <target_dir> [-c <acceptance_cmd>] [-n <name>] [-S] [-f]
#                         # without -c, pins `false` so the build gate fails closed
#                         # STRICT by default; -S = soft owner gates
#   bones.sh status
#   bones.sh artifacts                  # list every pinned artifact (path, sha, VERIFIED/CHANGED/MISSING)
#   bones.sh approve [-q "<verbatim owner quote>"] [-e <evidence_file>]... "<note>"
#   bones.sh build  [loop.sh args...]   # stage 5 only: runs ship-pipeline loop.sh
#                         # -B auto|codex|prime picks the builder agent (default auto:
#                         # codex, else prime-agent). The builder never holds the gate —
#                         # bones re-runs the pinned acceptance command itself either way.
#   bones.sh plan -e <plan.md> "<note>"     # stage 5, BEFORE build: pin the validated plan artifact
#                                        # (contracts/plan.sh + LLM judge); build refuses without it
#   bones.sh confirm [--failed] -e <smoke record> "<note>"   # stage 8b: smoke contract -> 8-promote.ok;
#                                        # bones next afterwards starts the 7-day operate clock
#   bones.sh owner-setup [--policy biometry|presence] [--passphrase --accept-degraded] [--reset]
#                                        # one-time per machine: Touch ID / Secure-Enclave owner key + helper pin
#   bones.sh owner-pin [--rotate]        # pin ~/.bones-owner/owner.pub (+ helper hash/cdhash) into this run
#   bones.sh acceptance-path             # print the pinned acceptance command path
#   bones.sh selftest [--only <case>]     # prove the v1 bypass corpus blocks
#   bones.sh license --check <signed-key> # verify an Ed25519 Pro key offline
#   bones.sh package [-s giftcandidate] [-o bones-package.tar.gz] [-a allowlist]
#                                           # scan first; archive only after every privacy check passes
#   bones.sh next                       # advance one stage IF the current gate is satisfied
#   bones.sh back -s <stage_n> -r "<reason>"   # regress (archives cleared gates, keeps audit)
#   bones.sh note "<text>"              # append an observation to the journal (stage-stamped)
#   bones.sh nudge [-n] ["<extra>"]     # iMessage the owner about the current gate (-n = dry run)
#   bones.sh doctor                     # consistency check: state vs gates vs journal
#   bones.sh contracts-repin -r "<reason>"  # re-pin contract hashes after a DELIBERATE contract upgrade (contracts selftests must PASS)
#   bones.sh guard-repin -r "<reason>"  # re-pin guard hash after a DELIBERATE guard upgrade;
#                                       # refuses unless the live guard BLOCKS the full bypass corpus; journaled
#   bones.sh log                        # full audit trail (gates + archive + journal)
#   bones.sh reset [-f]                 # delete .bones state
#
set -uo pipefail

LOOP_SH="${BONES_LOOP_SH:-$HOME/.claude/skills/ship-pipeline/scripts/loop.sh}"
# Default stage-5 builder. "run bones" should not require remembering -B.
# Override per-run with -B, or globally with BONES_BUILDER=codex|prime|auto.
BONES_BUILDER="${BONES_BUILDER:-prime}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
GUARD_SH="${BONES_GUARD_SH:-$SCRIPT_DIR/bones-guard.sh}"
SECRET_SCANNER="${BONES_SECRET_SCANNER:-$SCRIPT_DIR/bones-secret-scan.pl}"
# 2.0: contracts live next to bones.sh and the owner key/helper live per machine in ~/.bones-owner.
# Neither location takes an env override — a forged variable must not redirect a gate.
CONTRACTS_DIR="$SCRIPT_DIR/../contracts"
# 2.0 Slice B: stage policy lives in composable skills under the skills parent dir (installed:
# ~/.claude/skills; in-repo: <repo>/skills). status reads a stage's rich brief from its owning skill.
SKILLS_DIR="${BONES_SKILLS_DIR:-$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)}"
OWNER_DIR="$HOME/.bones-owner"
OWNER_AUTH_SRC="$SCRIPT_DIR/bones-owner-auth.swift"
OWNER_TOKEN_WINDOW=600
DEFAULT_SECRET_ALLOWLIST="$SCRIPT_DIR/../packaging/secret-allowlist.txt"
BASH_BIN="${BASH_BIN:-$(command -v bash || printf /bin/bash)}"
STATE_SCHEMA=2

STAGE_KEYS=(brainstorm kill-or-commit spec council build-loop review-security staging promote present operate)
STAGE_TITLES=(
  "Brainstorm + prompt interrogation"
  "Kill-or-commit"
  "Spec sign-off"
  "Council / second-pass critique"
  "Build loop (acceptance gate)"
  "Adversarial review + security"
  "Staging validation"
  "Promote + production smoke test"
  "Present"
  "Operate + learn"
)
# gate type per stage: owner | agent | auto | step (see header)
STAGE_GATE=(agent owner owner agent auto agent agent owner step owner)
# what satisfies each stage — printed by `status` so no sub-part silently drops out
STAGE_SKILL=("" goalify specify reviewify implementify reviewify "" "" "" goalify)
# One-line orchestrator notes; the RICH per-stage policy lives in the owning skill's `## Produces`
# block (Bones 2.0: keep the orchestrator thin). `status` prints the skill block when present.
STAGE_NOTE=(
  "brainstorm + the 7-dimension prompt interrogation (score >=85); brains recon FIRST (mem-search persistent memory + matching vaults, ship-pipeline/references/brains.md). Approve -e <interrogation file>."
  "the brutal <=30-min kill-or-commit check; record scope / 7-day metric / kill-condition (they feed stages 3 and 10)."
  "the signed HTML spec: non-goals + an executable AC-nn acceptance checklist + spec-time API validation. Jake signs it. Approve -e <spec.html>."
  "council if stakes warrant, else a second-pass critique; verdict BUILD|REVISE|KILL + dissent (contracts/council.sh). Approve -e <council record>."
  "pin the plan (bones plan -e docs/plan.md), then bones build -c <the command pinned at init>; the independent pinned-acceptance re-run is the gate."
  "the stage-5.5 conformance report vs the SIGNED spec (zero DRIFTED/MISSING) + a cross-model adversarial review. Approve -e <conformance> -e <review>."
  "staging on FRESH/SEEDED data (never real): tests -> click-control screenshot -> e2e -> competitor read. Approve -e <staging record> -e <screenshot>."
  "8a authorize (bones approve -q \"<his words>\", Touch ID, HEAD-bound) -> deploy + production smoke -> 8b confirm (bones confirm -e <smoke record>)."
  "present to Jake: what shipped, acceptance-checklist status, competitor read, live URL."
  "within 7 days make the double-down / park / kill call against the stage-2 metric, then write learnings back to the brains (memory + vaults)."
)
stage_brief() { # stage_brief <n> — rich brief from the owning skill's ## Produces, else the note
  local idx=$(( $1 - 1 )) note skill prod f
  note="${STAGE_NOTE[$idx]}"; skill="${STAGE_SKILL[$idx]}"
  [ -n "$skill" ] || { printf '%s' "$note"; return; }
  f="$SKILLS_DIR/$skill/SKILL.md"
  if [ -f "$f" ]; then
    prod="$(awk '/^## Produces/{p=1;next} /^## /{p=0} p' "$f" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    [ -n "$prod" ] && { printf '%s  [%s] %s' "$note" "$skill" "$prod"; return; }
  fi
  printf '%s  [%s: see %s/SKILL.md]' "$note" "$skill" "$skill"
}
NSTAGES=${#STAGE_KEYS[@]}

die() { printf 'horvitz: %s\n' "$1" >&2; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Locate .bones by walking up from CWD (so subcommands work anywhere in the target).
find_bones() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    [ -d "$d/.bones" ] && { printf '%s\n' "$d/.bones"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

json_get() { # json_get <file> <key>
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null
  else
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"?[^,\"}]*\"?" "$1" 2>/dev/null \
      | head -1 | sed -E "s/.*:[[:space:]]*//; s/^\"//; s/\"$//"
  fi
}

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

write_state() { # write_state <dir> <name> <target> <stage> <created> <strict>
  printf '{\n  "schema_version": %s,\n  "name": "%s",\n  "target": "%s",\n  "stage": %s,\n  "created": "%s",\n  "updated": "%s",\n  "strict": %s\n}\n' \
    "$STATE_SCHEMA" "$(json_esc "$2")" "$(json_esc "$3")" "$4" "$5" "$(now)" "${6:-false}" > "$1/state.json"
  sha_of "$1/state.json" > "$1/state.sha256"
}

state_get() { json_get "$BONES_DIR/state.json" "$1"; }

seal_missing_state() {
  local schema name target stage created strict
  schema="$(json_get "$BONES_DIR/state.json" schema_version)"
  name="$(json_get "$BONES_DIR/state.json" name)"
  target="$(json_get "$BONES_DIR/state.json" target)"
  stage="$(json_get "$BONES_DIR/state.json" stage)"
  created="$(json_get "$BONES_DIR/state.json" created)"
  strict="$(json_get "$BONES_DIR/state.json" strict)"
  [ -n "$name" ] && [ -n "$target" ] && [ -n "$stage" ] || die "state.json is corrupt or unreadable at $BONES_DIR"
  [ -n "$created" ] || created="$(now)"
  [ "$strict" = "true" ] || strict=false
  case "$schema" in
    ""|"$STATE_SCHEMA") write_state "$BONES_DIR" "$name" "$target" "$stage" "$created" "$strict" ;;
    *) die "unsupported state schema_version=$schema at $BONES_DIR" ;;
  esac
}

verify_state_integrity() {
  [ -f "$BONES_DIR/state.json" ] || die "state.json missing at $BONES_DIR"
  if [ ! -f "$BONES_DIR/state.sha256" ]; then
    seal_missing_state
    return 0
  fi
  local want got
  want="$(head -1 "$BONES_DIR/state.sha256" 2>/dev/null | awk '{print $1}')"
  got="$(sha_of "$BONES_DIR/state.json")"
  [ "$want" = "$got" ] || die "state integrity check failed at $BONES_DIR/state.json (expected $want, actual $got). Refusing forged or downgraded state."
  local schema; schema="$(state_get schema_version)"
  case "$schema" in
    "$STATE_SCHEMA") ;;
    1|"")
      # v1 (or a pre-seal state with no schema_version) -> v2 adds no semantic fields; rewrite
      # through the canonical writer so
      # the in-flight stage, strict flag, and target survive with a fresh seal.
      local name target stage created strict
      name="$(state_get name)"; target="$(state_get target)"; stage="$(state_get stage)"
      created="$(state_get created)"; strict="$(state_get strict)"
      [ -n "$name" ] && [ -n "$target" ] && [ -n "$stage" ] \
        || die "cannot migrate corrupt schema v1 state at $BONES_DIR"
      [ "$strict" = "true" ] || strict=false
      write_state "$BONES_DIR" "$name" "$target" "$stage" "$created" "$strict"
      printf 'horvitz: migrated in-flight state schema v1 -> v%s (stage %s preserved).\n' "$STATE_SCHEMA" "$stage" >&2
      ;;
    *) die "unsupported or downgraded state schema_version='${schema:-missing}' at $BONES_DIR" ;;
  esac
}

record_guard_hash() {
  [ -f "$GUARD_SH" ] && sha_of "$GUARD_SH" > "$1/guard.sha256"
}

verify_guard_integrity() {
  [ -f "$BONES_DIR/guard.sha256" ] || { record_guard_hash "$BONES_DIR"; return 0; }
  [ -f "$GUARD_SH" ] || die "guard script missing at $GUARD_SH"
  local want got
  want="$(head -1 "$BONES_DIR/guard.sha256" 2>/dev/null | awk '{print $1}')"
  got="$(sha_of "$GUARD_SH")"
  [ "$want" = "$got" ] || die "guard integrity check failed (expected $want, actual $got). Refusing to run with a tampered guard."
}

verify_acceptance_file() {
  [ -f "$BONES_DIR/acceptance.cmd" ] \
    || die "pinned acceptance command missing at $BONES_DIR/acceptance.cmd — refusing to invent a new root of trust; re-init with owner-approved -c"
  [ -s "$BONES_DIR/acceptance.cmd" ] \
    || die "pinned acceptance command is empty at $BONES_DIR/acceptance.cmd — re-init with owner-approved -c"
}

verify_runtime_integrity() {
  verify_state_integrity
  verify_guard_integrity
  verify_acceptance_file
}

# Current stage, validated. Dies loudly on corrupt state instead of misreporting.
require_stage() {
  verify_runtime_integrity
  local cur; cur="$(state_get stage)"
  case "$cur" in
    (''|*[!0-9]*) die "state.json is corrupt or unreadable (stage='$cur') at $BONES_DIR — inspect it or 'bones reset -f' and re-init" ;;
  esac
  printf '%s\n' "$cur"
}

journal() { printf '%s | %s | %s\n' "$(now)" "$1" "$2" >> "$BONES_DIR/journal.log"; }

gate_file() { printf '%s/gates/%s-%s.ok\n' "$BONES_DIR" "$1" "${STAGE_KEYS[$(( $1 - 1 ))]}"; }
gate_satisfied() { [ -f "$(gate_file "$1")" ]; }

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else echo "sha-unavailable"; fi
}

# Pin the target's git state to a gate record: "git-sha: <sha> (clean|dirty)".
# Empty if the target isn't a git repo.
git_pin() {
  local sha state
  sha="$(git -C "$1" rev-parse --short=12 HEAD 2>/dev/null)" || return 0
  [ -n "$sha" ] || return 0
  if [ -n "$(git -C "$1" status --porcelain 2>/dev/null | head -1)" ]; then state=dirty; else state=clean; fi
  printf 'git-sha: %s (%s)\n' "$sha" "$state"
}

# Portable timeout (macOS has no `timeout`). Same perl-alarm helper as loop.sh.
run_timeout() {
  local secs="$1"; shift
  perl -e 'my $s=shift; my $pid=fork; if(!defined $pid){exit 127}
           if($pid==0){exec @ARGV; exit 127}
           local $SIG{ALRM}=sub{kill "TERM",$pid; sleep 1; kill "KILL",$pid; exit 124};
           alarm $s; waitpid $pid,0; exit($? >> 8)' "$secs" "$@"
}

# --- 2.0: artifact contracts, atomic gate writes, signed-spec lookup ----------------
# Contracts are standalone executables next to bones.sh (contracts/<name>.sh <files>); no env
# override is honored for their location, so a forged variable cannot redirect a gate.
# Contract integrity (council #2, F-02): every contract's sha256 is pinned per run in
# .bones/contracts.sha256 (first use or init); an edited contract refuses until a deliberate
# `bones contracts-repin -r "<why>"`, which itself requires the contracts selftests to PASS.
record_contracts_hash() { # record_contracts_hash <bones dir>
  local c; : > "$1/contracts.sha256.tmp"
  for c in "$CONTRACTS_DIR"/*.sh; do [ -f "$c" ] && printf '%s %s\n' "$(basename "$c")" "$(sha_of "$c")" >> "$1/contracts.sha256.tmp"; done
  mv -f "$1/contracts.sha256.tmp" "$1/contracts.sha256"
}
verify_contract_pin() { # verify_contract_pin <name>
  local c="$CONTRACTS_DIR/$1.sh" want
  [ -f "$BONES_DIR/contracts.sha256" ] || { record_contracts_hash "$BONES_DIR"; journal contracts-pin "contracts pinned on first use"; return 0; }
  want="$(awk -v n="$1.sh" '$1==n{print $2}' "$BONES_DIR/contracts.sha256" | head -1)"
  [ -n "$want" ] || die "contract $1.sh is not in this run's contracts pin — bones contracts-repin -r \"<why>\" after verifying the contracts"
  [ "$want" = "$(sha_of "$c")" ] || die "contract $1.sh CHANGED since it was pinned for this run (pinned ${want:0:12}, actual $(sha_of "$c" | cut -c1-12)) — a contract edited mid-run cannot judge evidence; if the upgrade is deliberate: bones contracts-repin -r \"<why>\""
}
run_contract() { # run_contract <name> <files...> — die with the contract's one-line reason on refusal
  local name="$1"; shift
  local c="$CONTRACTS_DIR/$name.sh" out
  [ -x "$c" ] || die "contract missing or not executable: $c (2.0 ships contracts/ next to bones.sh)"
  [ -f "$CONTRACTS_DIR/lib.sh" ] || die "contracts/lib.sh missing"
  verify_contract_pin "$name"; verify_contract_pin lib
  if ! out="$(SMOKE_AFTER="${SMOKE_AFTER:-}" BONES_DIR="$BONES_DIR" "$BASH_BIN" "$c" "$@" 2>&1)"; then
    die "evidence REJECTED by the $name contract — ${out:-no reason given}"
  fi
  return 0
}
# Gate records are written atomically (temp + mv) so a reader never sees a half-written record.
write_gate_atomic() { # write_gate_atomic <path>   (content on stdin)
  local gf="$1" tmp
  tmp="$(mktemp "$(dirname "$gf")/.tmp.XXXXXX")" || die "cannot create a temp gate file"
  cat > "$tmp" && mv -f "$tmp" "$gf"
}
# The SIGNED spec = first *.html evidence of the stage-3 gate, re-hashed. rc 1 none, rc 2 changed.
signed_spec_path() {
  local gf="$BONES_DIR/gates/3-spec.ok" ln path want
  [ -f "$gf" ] || return 1
  while IFS= read -r ln; do
    path="$(printf '%s' "$ln" | sed -E 's/^evidence: (.*) \(sha256:[a-f0-9-]+\)$/\1/')"
    want="$(printf '%s' "$ln" | sed -E 's/^.*\(sha256:([a-f0-9-]+)\)$/\1/')"
    case "$path" in
      *.html|*.htm)
        [ -f "$path" ] || return 1
        [ "$(sha_of "$path")" = "$want" ] || return 2
        printf '%s\n' "$path"; return 0 ;;
    esac
  done < <(grep '^evidence: ' "$gf")
  return 1
}

# --- 2.0: owner authorization (Touch ID / Secure Enclave) --------------------------------
# .bones/owner.pub pins the owner's P-256 public key (SPKI PEM) plus owner-mode:, owner-label:,
# helper-sha256:, helper-codesign: lines. bones.sh refuses to invoke a helper whose hash or code
# signature differ from the pin, so a swapped helper cannot even raise the prompt. Tokens:
# payload v1|name|stage|git-sha|sha256(quote)|nonce|unix-ts, ECDSA-SHA256, verified by openssl
# against the pinned key, bound to the live HEAD, one-use (the nonce is recorded in used-nonces).
# No env override (BONES_OWNER_AUTH_BIN / BONES_OWNER_PUB / BONES_OWNER_DIR) is honored anywhere.
OWNER_TOKEN_JSON=""
owner_pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$BONES_DIR/owner.pub" 2>/dev/null | head -1; }
owner_pem_of() { sed -n '/^-----BEGIN PUBLIC KEY-----/,/^-----END PUBLIC KEY-----/p' "$1"; }
owner_mode() { owner_pin_field owner-mode; }
owner_refuse_overrides() {
  [ -z "${BONES_OWNER_AUTH_BIN:-}${BONES_OWNER_PUB:-}${BONES_OWNER_DIR:-}" ] \
    || die "owner-auth overrides (BONES_OWNER_AUTH_BIN / BONES_OWNER_PUB / BONES_OWNER_DIR) are not honored — bones uses only the helper and key pinned in .bones/owner.pub"
}
owner_helper_bin() {
  owner_refuse_overrides
  case "$(owner_mode)" in
    selftest)
      # minted only by cmd_selftest inside its own temp workspace; refused anywhere else
      local root here; root="$(owner_pin_field selftest-root)"
      root="$(cd "$root" 2>/dev/null && pwd)"; here="$(cd "$BONES_DIR" 2>/dev/null && pwd)"
      [ -n "$root" ] && [ -n "$here" ] || die "selftest owner mode: workspace paths unresolvable"
      case "$here" in "$root"/*) ;; *) die "selftest owner mode is only valid inside the selftest workspace that minted it" ;; esac
      case "$root" in "${TMPDIR:-/tmp}"*|/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;; *) die "selftest owner mode outside a temp dir is refused" ;; esac
      owner_pin_field helper-path ;;
    *) printf '%s/bones-owner-auth\n' "$OWNER_DIR" ;;
  esac
}
owner_helper_verify() { # the helper's hash AND code signature must match the pin
  local h want got wcs gcs
  h="$(owner_helper_bin)" || exit 1
  [ -x "$h" ] || die "owner-auth helper missing at $h — run: bones owner-setup (one-time per machine, one Touch ID tap)"
  want="$(owner_pin_field helper-sha256)"; got="$(sha_of "$h")"
  [ -n "$want" ] && [ "$want" = "$got" ] \
    || die "owner-auth helper hash mismatch (pinned ${want:-none}, actual $got) — a swapped or patched helper cannot authorize; re-run bones owner-setup from a trusted state, then bones owner-pin --rotate"
  wcs="$(owner_pin_field helper-codesign)"
  if [ -n "$wcs" ] && [ "$wcs" != "none" ]; then
    gcs="$(codesign -dvvv "$h" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
    [ "$wcs" = "$gcs" ] || die "owner-auth helper code signature mismatch (pinned $wcs, actual ${gcs:-none})"
  fi
}
# owner_token_verify <json> <name> <stage> <head> <nonce|""> <mint|recheck>
#   mint:    nonce must match, timestamp inside the window, nonce consumed (one-use)
#   recheck: signature + name/stage/HEAD only (confirm/next/status use it to detect a stale 8a)
owner_token_verify() {
  local json="$1" name="$2" stage="$3" head="$4" nonce="$5" mode="$6"
  local payload sig pub
  payload="$(printf '%s' "$json" | jq -r '.payload // empty' 2>/dev/null)"
  sig="$(printf '%s' "$json" | jq -r '.sig_b64 // empty' 2>/dev/null)"
  pub="$(printf '%s' "$json" | jq -r '.pub_b64 // empty' 2>/dev/null)"
  [ -n "$payload" ] && [ -n "$sig" ] && [ -n "$pub" ] || die "owner token malformed (payload / sig_b64 / pub_b64 required)"
  local v n s h q z t
  IFS='|' read -r v n s h q z t <<<"$payload"
  [ "$v" = "v1" ] || die "owner token version '$v' unsupported"
  [ "$n" = "$name" ] || die "owner token is for pipeline '$n', not '$name'"
  [ "$s" = "$stage" ] || die "owner token is for stage $s, not $stage"
  [ "$h" = "$head" ] || die "owner token is bound to git HEAD ${h:0:12}; current HEAD is ${head:0:12} — STALE authorization (a commit landed after the tap): re-authorize"
  if [ "$mode" = "mint" ]; then
    [ "$z" = "$nonce" ] || die "owner token nonce mismatch (the token was not minted for this approval)"
    case "$t" in (''|*[!0-9]*) die "owner token timestamp malformed" ;; esac
    local nowts; nowts="$(date -u +%s)"
    [ $((nowts - t)) -le "$OWNER_TOKEN_WINDOW" ] && [ $((nowts - t)) -ge -60 ] || die "owner token outside the ${OWNER_TOKEN_WINDOW}s window — re-authorize"
    grep -qx -- "$z" "$BONES_DIR/used-nonces" 2>/dev/null && die "owner token REPLAY refused (nonce already consumed)"
  fi
  [ -f "$BONES_DIR/owner.pub" ] || die "no owner key pinned in this run — bones owner-pin"
  local w a b
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-owner.XXXXXX")" || die "mktemp failed"
  owner_pem_of "$BONES_DIR/owner.pub" > "$w/pinned.pem"
  [ -s "$w/pinned.pem" ] || { rm -rf "$w"; die "pinned owner.pub carries no PEM public key"; }
  { printf '3059301306072a8648ce3d020106082a8648ce3d030107034200' | xxd -r -p; printf '%s' "$pub" | base64 -d 2>/dev/null; } > "$w/pub.der"
  if ! openssl pkey -pubin -inform DER -in "$w/pub.der" -outform PEM -out "$w/pub.pem" >/dev/null 2>&1; then rm -rf "$w"; die "owner token public key unparseable"; fi
  a="$(openssl pkey -pubin -in "$w/pub.pem" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  b="$(openssl pkey -pubin -in "$w/pinned.pem" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  [ -n "$a" ] && [ "$a" = "$b" ] || { rm -rf "$w"; die "owner token public key does not match the pinned owner.pub — refused"; }
  printf '%s' "$sig" | base64 -d > "$w/sig.der" 2>/dev/null; printf '%s' "$payload" > "$w/payload"
  if ! openssl dgst -sha256 -verify "$w/pinned.pem" -signature "$w/sig.der" "$w/payload" >/dev/null 2>&1; then rm -rf "$w"; die "owner token SIGNATURE INVALID"; fi
  rm -rf "$w"
  [ "$mode" = "mint" ] && printf '%s\n' "$z" >> "$BONES_DIR/used-nonces"
  return 0
}
owner_token_mint() { # owner_token_mint <stage> <quote> -> OWNER_TOKEN_JSON (exits on refusal)
  [ -f "$BONES_DIR/owner.pub" ] || die "stage $1 needs the owner's signed token and no owner key is pinned in this run — one-time: bones owner-setup (Touch ID), then bones owner-pin"
  owner_helper_verify
  local helper name target head nonce ts qsha out
  helper="$(owner_helper_bin)"; name="$(state_get name)"; target="$(state_get target)"
  head="$(git -C "$target" rev-parse HEAD 2>/dev/null || printf 'nogit')"
  # F-02: promote authorization binds the COMMITTED tree — refuse while edits outside .bones/.loop are uncommitted.
  if [ "$1" = 8 ] && [ "$head" != nogit ] && [ -n "$(tree_dirty "$target")" ]; then
    die "stage 8 authorization binds an exact committed tree and the working tree is dirty ($(tree_dirty "$target" | head -1)) — commit or stash first"
  fi
  nonce="$(openssl rand -hex 16)"; ts="$(date -u +%s)"
  qsha="$(printf '%s' "$2" | shasum -a 256 | awk '{print $1}')"
  printf '%s|%s\n' "$nonce" "$ts" > "$BONES_DIR/pending-auth"
  printf 'horvitz: owner authorization — Touch ID prompt for %s @ %s (stage %s). Tap to sign, Refuse to decline.\n' "$name" "${head:0:12}" "$1" >&2
  if ! out="$("$helper" sign --label "$(owner_pin_field owner-label)" --policy "$(owner_mode)" --pipeline "$name" --stage "$1" --git-sha "$head" --quote-sha "$qsha" --nonce "$nonce" --ts "$ts" --quote "$(printf '%s' "$2" | cut -c1-60)" 2>/dev/null)"; then
    rm -f "$BONES_DIR/pending-auth"
    die "owner authorization did not complete — no signature (Touch ID cancelled or failed, or the helper errored). The gate stays open."
  fi
  rm -f "$BONES_DIR/pending-auth"
  owner_token_verify "$out" "$name" "$1" "$head" "$nonce" mint
  OWNER_TOKEN_JSON="$out"
}
# Re-verify a recorded 8a authorization against the live HEAD (confirm, next, status, doctor).
owner_auth_recheck() { # owner_auth_recheck <authorized file>; 0 valid, 1 stale/invalid (reason on stderr)
  local f="$1" tok name target head err
  tok="$(sed -n 's/^owner-token:[[:space:]]*//p' "$f" | head -1)"
  [ -n "$tok" ] || { printf 'no owner-token in %s\n' "$f" >&2; return 1; }
  name="$(state_get name)"; target="$(state_get target)"
  head="$(git -C "$target" rev-parse HEAD 2>/dev/null || printf 'nogit')"
  if [ "$head" != nogit ] && [ -n "$(tree_dirty "$target")" ]; then
    printf '8a authorization binds the committed tree and the working tree is dirty (%s) — commit or stash\n' "$(tree_dirty "$target" | head -1)" >&2; return 1
  fi
  if err="$( ( owner_token_verify "$tok" "$name" 8 "$head" "" recheck ) 2>&1 )"; then return 0; fi
  printf '%s\n' "$err" >&2; return 1
}
# Dirty = uncommitted changes outside the audit trail (.bones/) and build logs (.loop/).
tree_dirty() { git -C "$1" status --porcelain 2>/dev/null | grep -vE '^.. (\.bones|\.loop)(/|$)' | head -3; }
# Evidence paths are pinned ABSOLUTE so doctor/next re-hash them from any cwd; older relative
# records are resolved against the target as a fallback.
abs_path() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$(cd "$(dirname "$1")" 2>/dev/null && pwd)" "$(basename "$1")" ;; esac; }
resolve_evidence() { # resolve_evidence <path> <target> -> existing path (or the input)
  if [ -e "$1" ]; then printf '%s\n' "$1"; elif [ -e "$2/$1" ]; then printf '%s/%s\n' "$2" "$1"; else printf '%s\n' "$1"; fi
}

# LLM substance check: shape checks (grep) catch missing structure; this catches
# hollow structure — seven band keywords pasted around no actual thinking.
# Returns 0 pass, 1 fail (LLM_REASON set), 2 unavailable (caller falls back to
# shape checks with a loud warning; BONES_LLM=off skips deliberately, journaled).
LLM_REASON=""
llm_verdict() { # llm_verdict "<question>" <files...>
  local q="$1"; shift
  if [ "${BONES_LLM:-on}" = "off" ]; then
    journal llm "substance check SKIPPED via BONES_LLM=off for stage evidence: $*"
    return 2
  fi
  command -v claude >/dev/null 2>&1 || return 2
  # LLM judges are probabilistic; a single vote lets ~1-in-3 hollow artifacts
  # slip. Run N votes (default 2), ALL must pass, and uncertainty = fail.
  local votes="${BONES_LLM_VOTES:-2}" v out ok
  local content; content="$(cat "$@" 2>/dev/null | head -c 24000)"
  [ -n "$content" ] || return 2
  v=1
  while [ "$v" -le "$votes" ]; do
    out="$(printf '%s' "$content" | run_timeout 120 claude -p \
      "$q Judge substance, not formatting. You are a skeptical auditor: if you are uncertain the real work was done, pass=false. Answer ONLY with JSON: {\"pass\": true|false, \"reason\": \"<one sentence>\"}" \
      --model "${BONES_LLM_MODEL:-sonnet}" 2>/dev/null)" || return 2
    if printf '%s' "$out" | grep -q '"pass"[[:space:]]*:[[:space:]]*false'; then
      LLM_REASON="$(printf '%s' "$out" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      return 1
    fi
    printf '%s' "$out" | grep -q '"pass"[[:space:]]*:[[:space:]]*true' || return 2
    v=$((v+1))
  done
  return 0
}

llm_gate() { # llm_gate <stage> "<question>" <files...> — die on fail, warn on unavailable
  local st="$1" q="$2"; shift 2
  local rc=0
  llm_verdict "$q" "$@" || rc=$?
  case "$rc" in
    0) journal llm "stage $st evidence passed substance check" ;;
    1) die "stage $st evidence FAILED the substance check: ${LLM_REASON:-artifact does not demonstrate the real work}. Do the work, don't decorate the file." ;;
    2) printf 'horvitz: WARNING — substance check unavailable for stage %s (claude CLI missing/timeout/BONES_LLM=off). Shape checks only; this approval is weaker.\n' "$st" >&2 ;;
  esac
}

# Stage-specific evidence validation — the ARTIFACT is the gate, the note is commentary.
validate_evidence() { # validate_evidence <stage> [evidence files...]
  local st="$1"; shift
  local f
  case "$st" in
    1)
      [ $# -ge 1 ] || die "stage 1 needs -e <interrogation record> — the 7-dimension prompt interrogation IS the deliverable (see ship-pipeline/references/prompt-interrogation.md)"
      local bands=0
      for f in "$@"; do
        bands=$((bands + $(grep -oiE 'covered|partial|missing' "$f" 2>/dev/null | wc -l | tr -d ' ')))
      done
      [ "$bands" -ge 7 ] || die "stage 1 evidence doesn't look like a completed interrogation — all 7 dimensions must be banded covered/partial/missing (found $bands band markers across the evidence)"
      # Brains recon is enforced, not suggested: the record must show Jake's brains
      # were consulted (or state explicitly that none applies to this build).
      local brainrefs=0
      for f in "$@"; do
        brainrefs=$((brainrefs + $(grep -ciE 'mem-search|persistent memory|AI-Brain|hormozi-vault|video-brain|Brain vault|brains\.md|no relevant brain' "$f" 2>/dev/null | tr -d ' ')))
      done
      [ "$brainrefs" -ge 1 ] || die "stage 1 evidence has no brains-recon record — consult Jake's brains first (mem-search persistent memory + matching vaults, per ship-pipeline/references/brains.md) and record what was found, or state 'no relevant brain' with why"
      # Rubric score is the interrogation's stop condition (Bones 8/13): no score, no gate.
      local scoremark=0
      for f in "$@"; do
        grep -qiE 'score:?[[:space:]]*[0-9]{1,3}[[:space:]]*/[[:space:]]*100' "$f" 2>/dev/null && scoremark=1
      done
      [ "$scoremark" -eq 1 ] || die "stage 1 evidence has no rubric score — score the tightened prompt against the weighted rubric (covered=full, partial=half, missing=0; deferred excluded) and record 'score: NN/100'. Below 85 the interrogation is not done — keep asking the gaps."
      llm_gate 1 "This should be a completed prompt-interrogation record: the 7 dimensions (task specificity, context sufficiency, constraints/non-goals, verification criteria, output contract, role/framing, examples) each banded covered/partial/missing with a substantive per-dimension assessment, ending in a tightened prompt. PASS if the per-dimension assessments show genuine engagement with a specific build (concrete details, real tradeoffs) and a tightened prompt exists — gap questions may be summarized rather than transcribed, and consciously-deferred dimensions are fine. FAIL only if it is hollow: keywords or bands with no specific reasoning behind them, or no tightened prompt." "$@"
      ;;
    3)
      [ $# -ge 1 ] || die "stage 3 needs -e <spec.html> — Jake signs a spec, not a summary"
      local ok=0
      for f in "$@"; do
        case "$f" in *.html|*.htm) grep -qiE 'acceptance' "$f" 2>/dev/null && ok=1 ;; esac
      done
      [ "$ok" -eq 1 ] || die "stage 3 evidence must include an HTML spec with an acceptance checklist (an *.html file mentioning 'acceptance')"
      # API contract gate (Bones 8/13): external APIs are curl-proven at spec time, not mid-build.
      local apiok=0
      for f in "$@"; do
        grep -qiE 'curl[[:space:]]|api[- ]validation|no external api' "$f" 2>/dev/null && apiok=1
      done
      [ "$apiok" -eq 1 ] || die "stage 3 spec has no API-validation record — live-curl every external API the build depends on (request + confirmed response captured in the spec) or state 'no external APIs' explicitly. An API first tested mid-build guarantees buggy software."
      llm_gate 3 "This should be a real build spec: goal, users, scope, explicit non-goals/anti-requirements, and an acceptance checklist whose items are EXECUTABLE or observable checks (commands, routes, behaviors) — not vibes. If the build depends on external APIs, the spec must show they were probed live at spec time (actual request + response shape confirmed to carry the needed data), or explicitly state no external APIs are involved — an unprobed API dependency fails. Is this a genuine spec a builder could be held to?" "$@"
      ;;
    4)
      [ $# -ge 1 ] || die "stage 4 needs -e <council record> (FIRST) — council-verdict: / voice: … — NN/100 / finding: / dissent: (or second-pass-critique: + risk-triggers:), per contracts/council.sh"
      run_contract council "$1"
      ;;
    6)
      [ $# -ge 2 ] || die "stage 6 needs -e <conformance report> -e <review file> — contracts/conformance.sh + contracts/review.sh (either order)"
      local conf="" rev=""
      for f in "$@"; do
        if head -1 "$f" 2>/dev/null | grep -qE '^conformance:'; then conf="$f"
        elif grep -qE '^findings:' "$f" 2>/dev/null; then rev="$f"; fi
      done
      [ -n "$conf" ] || die "stage 6: no conformance report among the evidence (its first line must be 'conformance: <signed spec> (sha256:…)' — re-read the SIGNED spec and mark every AC-nn MATCHES/DRIFTED/MISSING with evidence)"
      [ -n "$rev" ] || die "stage 6: no review file among the evidence (needs a 'findings:' section with F-nn lines and a security-gate: line)"
      run_contract conformance "$conf"
      run_contract review "$rev"
      ;;
    7)
      [ $# -ge 2 ] || die "stage 7 needs at least 2 -e files — the staging record AND a real click-through screenshot (contracts/staging.sh)"
      run_contract staging "$@"
      ;;
  esac
}

stage_line() { # stage_line <n> <current>
  local n="$1" cur="$2" mark key title extra=""
  key="${STAGE_KEYS[$((n-1))]}"; title="${STAGE_TITLES[$((n-1))]}"
  if [ "$n" -lt "$cur" ] || gate_satisfied "$n"; then
    mark="✓"
    if [ -f "$(gate_file "$n")" ]; then
      extra="$(head -1 "$(gate_file "$n")" | cut -d'|' -f4- | sed -E 's/^ +//' | cut -c1-56)"
      [ -n "$extra" ] && extra="  — ${extra}"
    fi
  elif [ "$n" -eq "$cur" ]; then mark="▶"
  else mark="·"; fi
  printf '  %s  %s. %-32s [%s]%s\n' "$mark" "$n" "$title" "${STAGE_GATE[$((n-1))]}" "$extra"
}

# --- subcommands -----------------------------------------------------------

cmd_init() {
  # STRICT is the default: owner gates demand a real TTY, so Jake records his own
  # approvals. -S (soft) lets an agent shell record owner quotes — explicit opt-out.
  local target="" name="" acceptance_cmd="" force=0 strict=true
  while getopts ":t:n:c:fHS" o; do case "$o" in
    t) target="$OPTARG" ;; n) name="$OPTARG" ;; c) acceptance_cmd="$OPTARG" ;; f) force=1 ;; H) strict=true ;; S) strict=false ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  [ -n "$target" ] || die "init needs -t <target_dir>"
  # Keep old/guard-only callers working without inventing a passing root of
  # trust. A pipeline initialized without an owner-selected command can be
  # inspected and guarded, but its stage-5 auto gate is permanently closed.
  # Re-initializing with -c before work begins is the explicit upgrade path.
  local guard_only=false
  if [ -z "$acceptance_cmd" ]; then
    acceptance_cmd=false
    guard_only=true
  fi
  [ -d "$target" ] || die "target dir not found: $target"
  target="$(cd "$target" && pwd)"
  [ -z "$name" ] && name="$(basename "$target")"
  local dir="$target/.bones"
  if [ -d "$dir" ] && [ "$force" -ne 1 ]; then
    die "already initialized at $dir (use 'init -f' to reset, or 'status')"
  fi
  rm -rf "$dir"; mkdir -p "$dir/gates"
  write_state "$dir" "$name" "$target" 1 "$(now)" "$strict"
  printf '%s\n' "$acceptance_cmd" > "$dir/acceptance.cmd"
  chmod 444 "$dir/acceptance.cmd" 2>/dev/null || true
  record_guard_hash "$dir"
  [ -d "$CONTRACTS_DIR" ] && record_contracts_hash "$dir"
  # 2.0: pin this machine's owner key at init when one exists (bones owner-setup ran before).
  if [ -f "$OWNER_DIR/owner.pub" ] && grep -qE '^owner-mode: (biometry|presence|passphrase)$' "$OWNER_DIR/owner.pub"; then cp "$OWNER_DIR/owner.pub" "$dir/owner.pub"; fi
  BONES_DIR="$dir"
  journal init "pipeline \"$name\" initialized (strict=$strict; guard_only=$guard_only; acceptance_sha256=$(sha_of "$dir/acceptance.cmd"))"
  printf 'horvitz: initialized pipeline "%s" at %s (strict=%s)\n\n' "$name" "$dir" "$strict"
  if [ "$guard_only" = true ]; then
    printf 'horvitz: WARNING — no -c was supplied; pinned fail-closed command `false`. This guard-only run cannot pass stage 5. Re-initialize with an owner-approved -c before beginning pipeline work.\n\n' >&2
  fi
  cmd_status
}

cmd_status() {
  BONES_DIR="${BONES_DIR:-$(find_bones)}" || die "no .bones here — run 'bones init -t <dir>' first"
  local cur name target strict
  cur="$(require_stage)" || exit 1; name="$(state_get name)"; target="$(state_get target)"; strict="$(state_get strict)"
  printf '== Horvitz pipeline: %s ==\n target=%s  strict=%s\n' "$name" "$target" "${strict:-false}"
  if [ "$cur" -gt "$NSTAGES" ] 2>/dev/null; then
    printf ' status: ALL STAGES COMPLETE ✓\n\n'
    local n=1; while [ "$n" -le "$NSTAGES" ]; do stage_line "$n" "$((NSTAGES+1))"; n=$((n+1)); done
    return 0
  fi
  printf ' stage: %s/%s — %s\n\n' "$cur" "$NSTAGES" "${STAGE_TITLES[$((cur-1))]}"
  local n=1; while [ "$n" -le "$NSTAGES" ]; do stage_line "$n" "$cur"; n=$((n+1)); done
  printf '\n'
  if [ -f "$BONES_DIR/operate-due" ] && [ "$cur" -ge 9 ]; then
    local due; due="$(head -1 "$BONES_DIR/operate-due")"
    if [ "$(now)" \> "$due" ]; then
      printf ' !! OPERATE CHECK OVERDUE (was due %s) — make the stage-10 double-down/park/kill call NOW.\n\n' "$due"
    else
      printf ' operate/learn call due by %s (7-day clock from promote)\n\n' "$due"
    fi
  fi
  # 2.0 surface: owner-auth mode, plan state at 5, 8a/8b at 8.
  if [ -f "$BONES_DIR/owner.pub" ]; then
    local om; om="$(sed -n 's/^owner-mode:[[:space:]]*//p' "$BONES_DIR/owner.pub" | head -1)"
    case "$om" in
      passphrase) printf ' owner-auth: passphrase (DEGRADED — typed secret, no biometric binding)\n' ;;
      biometry|presence) printf ' owner-auth: %s (Touch ID token at stage 8%s)\n' "$om" "$([ "$strict" = true ] && printf ' and at every owner gate' || printf '')" ;;
      selftest) printf ' owner-auth: selftest key\n' ;;
    esac
  elif [ "$cur" -ge 5 ] && [ "$cur" -le 8 ]; then
    printf ' owner-auth: NO KEY PINNED — stage 8 will refuse until: bones owner-setup (one time per machine), then bones owner-pin\n'
  fi
  if [ "$cur" -eq 5 ]; then
    if [ -f "$BONES_DIR/gates/5-build-loop.plan" ]; then printf ' plan: pinned %s\n' "$(sed -n 's/^plan: //p' "$BONES_DIR/gates/5-build-loop.plan" | head -1)"
    else printf ' plan: MISSING -> bones plan -e docs/plan.md "<note>"   (build refuses until a plan is pinned)\n'; fi
  fi
  if [ "$cur" -eq 8 ]; then
    local auth="$BONES_DIR/gates/8-promote.authorized"
    if [ -f "$auth" ]; then
      local ah; ah="$(sed -n 's/^authorized-head:[[:space:]]*//p' "$auth" | head -1)"
      if owner_auth_recheck "$auth" 2>/dev/null; then
        printf '  8a authorize  DONE %s  HEAD %s  (token verified)\n  guard: promote-shaped commands ALLOWED while HEAD == %s\n' "$(sed -n 's/^authorized-at:[[:space:]]*//p' "$auth" | head -1)" "${ah:0:12}" "${ah:0:12}"
      else
        printf '  8a authorize  STALE (HEAD moved since %s) — bones back -s 8, then approve again\n  guard: promote-shaped commands BLOCKED (stale authorization)\n' "${ah:0:12}"
      fi
      if gate_satisfied 8; then printf '  8b confirm    DONE — run bones next (starts the 7-day clock)\n'
      else printf '  8b confirm    OPEN -> deploy, run the production smoke, then: bones confirm -e <smoke record> "<note>"\n'; fi
    else
      printf '  8a authorize  [owner · Touch ID]  OPEN -> bones approve -q "<his words>" "<note>"\n  8b confirm    [agent · smoke contract]  LOCKED until 8a\n  guard: promote-shaped commands BLOCKED (no authorization on record)\n'
    fi
    printf '\n'
  fi
  local gt="${STAGE_GATE[$((cur-1))]}"
  printf 'stage %s requires: %s\n\n' "$cur" "$(stage_brief "$cur")" | fold -s -w 96
  if gate_satisfied "$cur"; then
    printf 'current gate satisfied ✓ — run `bones next` to advance.\n'
  else
    case "$gt" in
      owner) printf 'GATE OPEN [owner] — this is JAKE'\''S call. Do stage %s, ask him, then record his\n  verbatim words: `bones approve -q "<his exact words>" "<note>"`.\n  No quote = no approval. If he'\''s unreachable, the gate stays open.\n' "$cur" ;;
      agent) printf 'GATE OPEN [agent] — do stage %s, then record a substantive note (+ evidence):\n  `bones approve [-e <file>]... "<what was done and verified>"`.\n' "$cur" ;;
      auto)  printf 'GATE OPEN [auto] — machine-verified. Run `bones build -c "<command pinned at init>" -s <spec> [...]`;\n  -c must exactly match `bones acceptance-path`; bones independently re-runs it before opening the gate.\n' ;;
      step)  printf 'STEP — do stage %s, then `bones next` (no approval needed).\n' "$cur" ;;
    esac
  fi
}

cmd_mode() {
  # Flip an in-flight pipeline between STRICT (-H, Jake types owner approvals at a
  # real TTY) and SOFT (-S, the agent may record Jake's stated words for him).
  # Mode is Jake's call by design; the switch is journaled so the audit trail shows
  # exactly when it changed, why, and at which stage.
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local want="" reason=""
  while [ $# -gt 0 ]; do case "$1" in
    -S) want=false; shift ;;
    -H) want=true;  shift ;;
    -r) reason="${2:-}"; [ -n "$reason" ] || die "mode: -r needs a reason"; shift 2 ;;
    *)  die "mode: unknown arg '$1' (usage: mode -S|-H -r \"<reason>\")" ;;
  esac; done
  [ -n "$want" ] || die "mode: pick one — -S (soft) or -H (strict)"
  [ -n "$reason" ] || die "mode requires -r \"<reason>\" — the switch goes on the permanent record"

  local cur name target created old
  cur="$(require_stage)" || exit 1
  name="$(state_get name)"; target="$(state_get target)"; created="$(state_get created)"
  old="$(state_get strict)"; [ "$old" = "true" ] || old=false
  if [ "$old" = "$want" ]; then
    printf 'horvitz: already %s mode — no change.\n' "$([ "$want" = true ] && echo STRICT || echo SOFT)"
    return 0
  fi
  journal mode "strict ${old} -> ${want} at stage ${cur}; reason: ${reason}" \
    || die "mode: journal write failed — mode NOT changed"
  write_state "$BONES_DIR" "$name" "$target" "$cur" "$created" "$want"
  printf 'horvitz: mode %s -> %s (stage %s). Reason recorded: %s\n' \
    "$([ "$old" = true ] && echo STRICT || echo SOFT)" \
    "$([ "$want" = true ] && echo STRICT || echo SOFT)" "$cur" "$reason"
  [ "$want" = false ] && printf 'horvitz: owner gates may now be recorded by the agent from Jake'"'"'s stated words. They still REQUIRE his actual say-so — soft mode relaxes the typing, never the consent.\n'
  return 0
}

cmd_approve() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local cur quote="" evidence=() strict
  cur="$(require_stage)" || exit 1; strict="$(state_get strict)"
  [ "$cur" -le "$NSTAGES" ] || die "pipeline already complete"
  local gt="${STAGE_GATE[$((cur-1))]}"
  case "$gt" in
    auto) die "stage $cur is machine-verified — run 'bones build', you cannot approve past the build gate" ;;
    step) die "stage $cur is a step, not a gate — just run 'bones next'" ;;
  esac

  while getopts ":q:e:" o; do case "$o" in
    q) quote="$OPTARG" ;;
    e) evidence+=("$OPTARG") ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  shift $((OPTIND-1))
  local note="${*:-}"

  # A gate record must say something. "approved" says nothing.
  case "$(printf '%s' "$note" | tr '[:upper:]' '[:lower:]')" in
    ""|approved|approve|ok|done|lgtm|yes)
      die "note too thin — record WHAT was decided/verified, not just that it was" ;;
  esac

  # Stage 8 is two-phase: approve = 8a (authorize), confirm = 8b. Single-writer, atomic, never overwritten.
  local gf
  if [ "$cur" -eq 8 ]; then
    gf="$BONES_DIR/gates/8-promote.authorized"
    [ -f "$gf" ] && die "8a is already authorized (single-writer) — deploy, run the production smoke, then: bones confirm -e <smoke record> \"<note>\"; or bones back -s 8 to clear it"
    [ -f "$(gate_file 8)" ] && die "stage 8 is already confirmed (8b) — run bones next"
  else
    gf="$(gate_file "$cur")"
  fi

  OWNER_TOKEN_JSON=""
  if [ "$gt" = "owner" ]; then
    [ -n "$quote" ] || die "stage $cur is an OWNER gate — it needs Jake's verbatim words: approve -q \"<his exact words>\" \"<note>\". Ask him; do not paraphrase or infer."
    # Promote ALWAYS needs the owner's signed token (Touch ID, bound to HEAD). Strict mode needs it at
    # every owner gate. A pseudo-TTY proves nothing and is no longer consulted.
    if [ "$cur" -eq 8 ] || [ "$strict" = "true" ]; then
      owner_token_mint "$cur" "$quote"
    fi
  fi

  # Evidence: every -e must exist; record path + sha256.
  local ev_lines="" f i
  if [ ${#evidence[@]} -gt 0 ]; then
    i=0
    while [ "$i" -lt ${#evidence[@]} ]; do
      [ -e "${evidence[$i]}" ] || die "evidence file not found: ${evidence[$i]}"
      evidence[$i]="$(abs_path "${evidence[$i]}")"; i=$((i+1))
    done
    for f in "${evidence[@]}"; do
      ev_lines="${ev_lines}evidence: $f (sha256:$(sha_of "$f"))
"
    done
  fi
  # Stage-specific validation: the artifact is the gate, not the note (contracts/ for 4, 6, 7).
  validate_evidence "$cur" ${evidence[@]+"${evidence[@]}"}

  local target head; target="$(state_get target)"
  head="$(git -C "$target" rev-parse HEAD 2>/dev/null || printf 'nogit')"
  {
    if [ "$cur" -eq 8 ]; then printf '%s | promote | owner-8a | %s\n' "$(now)" "$note"
    else printf '%s | %s | %s | %s\n' "$(now)" "${STAGE_KEYS[$((cur-1))]}" "$gt" "$note"; fi
    [ -n "$quote" ] && printf 'owner-quote: "%s"\n' "$quote"
    [ -n "$OWNER_TOKEN_JSON" ] && printf 'owner-token: %s\n' "$OWNER_TOKEN_JSON"
    [ "$cur" -eq 8 ] && printf 'authorized-at: %s\nauthorized-head: %s\n' "$(now)" "$head"
    if [ "$cur" -eq 4 ] && [ ${#evidence[@]} -gt 0 ]; then printf 'council-verdict: %s\n' "$(sed -n 's/^council-verdict:[[:space:]]*//p' "${evidence[0]}" | head -1)"; fi
    [ -n "$ev_lines" ] && printf '%s' "$ev_lines"
    git_pin "$target"
  } | write_gate_atomic "$gf"
  if [ "$cur" -eq 8 ]; then
    journal approve "stage 8a (promote AUTHORIZED — owner token verified, HEAD ${head:0:12}) — $note"
    printf 'horvitz: 8a AUTHORIZED — "%s"\n       owner quote on record: "%s"\n       the guard now allows promote-shaped commands while HEAD == %s. Deploy, run the production smoke, then:\n       bones confirm -e <smoke record> "<note>"   (8b — bones next afterwards starts the 7-day clock)\n' "$note" "$quote" "${head:0:12}"
  else
    journal approve "stage $cur (${STAGE_KEYS[$((cur-1))]}) — $note"
    printf 'horvitz: gate %s. %s approved — "%s"\n' "$cur" "${STAGE_TITLES[$((cur-1))]}" "$note"
    [ -n "$quote" ] && printf '       owner quote on record: "%s"\n' "$quote"
    printf 'run `bones next` to advance.\n'
  fi
}

cmd_plan() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local cur; cur="$(require_stage)" || exit 1
  [ "$cur" -eq 5 ] || die "plan is pinned at stage 5, before the build (you are at stage $cur)"
  local plan=""
  while getopts ":e:" o; do case "$o" in
    e) plan="$OPTARG" ;; :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  shift $((OPTIND-1))
  local note="${*:-}"
  [ -n "$plan" ] || die "plan needs -e <plan.md> — architecture, file-level changes, order, test seams, acceptance map (contracts/plan.sh)"
  [ -f "$plan" ] || die "plan file not found: $plan"
  plan="$(abs_path "$plan")"
  case "$(printf '%s' "$note" | tr '[:upper:]' '[:lower:]')" in
    ""|approved|approve|ok|done|lgtm|yes|plan|planned) die "note too thin — say what the plan commits to" ;;
  esac
  local pf="$BONES_DIR/gates/5-build-loop.plan"
  [ -f "$pf" ] && die "a plan is already pinned (single-writer): $(sed -n 's/^plan: //p' "$pf" | head -1). To re-plan: bones back -s 5 -r \"<why>\" (archives it), then plan again"
  gate_satisfied 5 && die "the build gate is already stamped — a plan after the fact is not a plan"
  run_contract plan "$plan"
  llm_gate 5 "This should be a real implementation plan derived from a signed spec: concrete architecture decisions, a file-level change list with reasons, an execution order, test seams, and an acceptance map tying every acceptance id to a step. PASS if a builder could execute it without inventing architecture, order, or test seams. FAIL if it is headings around placeholders, or restates the spec without committing to files, order, and seams." "$plan"
  local spec; spec="$(signed_spec_path)" || die "signed spec missing or changed since sign-off"
  local target; target="$(state_get target)"
  {
    printf '%s | build-loop | plan | %s\n' "$(now)" "$note"
    printf 'plan: %s (sha256:%s)\n' "$plan" "$(sha_of "$plan")"
    printf 'spec-sha256: %s\n' "$(sha_of "$spec")"
    git_pin "$target"
  } | write_gate_atomic "$pf"
  journal plan "plan pinned: $plan (sha256:$(sha_of "$plan")) — $note"
  printf 'horvitz: plan pinned (sha256:%s). bones build hands it to the builder with -P and re-checks it first.\n' "$(sha_of "$plan")"
}

cmd_confirm() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local cur; cur="$(require_stage)" || exit 1
  [ "$cur" -eq 8 ] || die "confirm is stage 8b (promote confirmation) only — you are at stage $cur"
  local failed=0 evidence=()
  while [ $# -gt 0 ]; do case "$1" in
    --failed) failed=1; shift ;;
    -e) [ -n "${2:-}" ] || die "-e needs a file"; evidence+=("$2"); shift 2 ;;
    --) shift; break ;;
    -*) die "confirm: unknown flag $1 (usage: confirm [--failed] -e <smoke record> [-e ...] \"<note>\")" ;;
    *) break ;;
  esac; done
  local note="${*:-}"
  case "$(printf '%s' "$note" | tr '[:upper:]' '[:lower:]')" in
    ""|approved|approve|ok|done|lgtm|yes|confirmed|confirm) die "note too thin — record what was promoted, where, and what the smoke test hit" ;;
  esac
  local auth="$BONES_DIR/gates/8-promote.authorized"
  [ -f "$auth" ] || die "8b needs 8a first: no owner authorization on record — bones approve -q \"<Jake's words>\" \"<note>\" (Touch ID)"
  [ ${#evidence[@]} -ge 1 ] || die "confirm needs -e <smoke record> (smoke-target / smoke-result / smoke-at, per contracts/smoke.sh)"
  local f i=0; for f in "${evidence[@]}"; do [ -e "$f" ] || die "evidence file not found: $f"; done
  while [ "$i" -lt ${#evidence[@]} ]; do evidence[$i]="$(abs_path "${evidence[$i]}")"; i=$((i+1)); done
  local at; at="$(sed -n 's/^authorized-at:[[:space:]]*//p' "$auth" | head -1)"
  owner_auth_recheck "$auth" || die "8b refused: the 8a authorization is no longer valid for the current HEAD — roll back the extra commit, or bones back -s 8 and authorize again"
  if [ "$failed" -eq 1 ]; then
    journal confirm "8b smoke FAILED — gate stays open: $note (evidence: ${evidence[*]})"
    printf 'horvitz: 8b recorded as FAILED — roll back production, then fix forward (bones back -s 7 if staging must be redone). The operate clock has NOT started.\n'
    return 1
  fi
  [ -f "$(gate_file 8)" ] && die "8b already confirmed (single-writer). bones back -s 8 to redo the promote"
  SMOKE_AFTER="$at" run_contract smoke "${evidence[0]}"
  local target; target="$(state_get target)"
  local ev_lines=""
  for f in "${evidence[@]}"; do ev_lines="${ev_lines}evidence: $f (sha256:$(sha_of "$f"))
"; done
  {
    printf '%s | promote | agent-8b | %s\n' "$(now)" "$note"
    printf '%s' "$ev_lines"
    printf 'confirmed-head: %s\n' "$(git -C "$target" rev-parse HEAD 2>/dev/null || printf nogit)"
    git_pin "$target"
  } | write_gate_atomic "$(gate_file 8)"
  journal confirm "8b confirmed — promote + production smoke complete: $note"
  printf 'horvitz: 8b confirmed ✓ — run `bones next` (that starts the 7-day operate clock).\n'
}

cmd_owner_setup() {
  local policy=biometry passphrase=0 accept=0 reset=0
  while [ $# -gt 0 ]; do case "$1" in
    --policy) policy="${2:-}"; shift 2 ;;
    --passphrase) passphrase=1; shift ;;
    --accept-degraded) accept=1; shift ;;
    --reset) reset=1; shift ;;
    *) die "owner-setup: unknown arg '$1' (usage: owner-setup [--policy biometry|presence] [--passphrase --accept-degraded] [--reset])" ;;
  esac; done
  owner_refuse_overrides
  mkdir -p "$OWNER_DIR" && chmod 700 "$OWNER_DIR"
  local helper="$OWNER_DIR/bones-owner-auth" label mode="$policy" cdh pub_b64
  label="bones-owner-$(hostname -s 2>/dev/null || printf mac)"
  if [ "$passphrase" -eq 1 ]; then
    [ "$accept" -eq 1 ] || die "passphrase mode is DEGRADED (a typed secret, no hardware or biometric binding). Re-run: bones owner-setup --passphrase --accept-degraded to proceed knowingly — and prefer a Touch ID Mac for production."
    mode=passphrase
    cat > "$helper" <<'HEOF'
#!/usr/bin/env bash
# bones-owner-auth (passphrase mode, DEGRADED): openssl P-256 key encrypted with a passphrase the owner types.
set -u; D="$(cd "$(dirname "$0")" && pwd)"; KEY="$D/owner-key.pem"
cmd="${1:-}"; shift || true
val() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "${2:-}"; return; }; shift; done; }
pub() { openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr -d '\n'; }
case "$cmd" in
  setup) if [ ! -f "$KEY" ] || [ -n "$(val --reset "$@")" ]; then openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkey -aes256 -out "$KEY" >/dev/null || exit 3; chmod 600 "$KEY"; fi
         printf '{"pub_b64":"%s"}\n' "$(pub)" ;;
  pubkey) printf '{"pub_b64":"%s"}\n' "$(pub)" ;;
  sign) payload="v1|$(val --pipeline "$@")|$(val --stage "$@")|$(val --git-sha "$@")|$(val --quote-sha "$@")|$(val --nonce "$@")|$(val --ts "$@")"
        printf 'Horvitz owner passphrase (authorize %s @ %s, stage %s): ' "$(val --pipeline "$@")" "$(val --git-sha "$@" | cut -c1-12)" "$(val --stage "$@")" >&2
        sig="$(printf '%s' "$payload" | openssl dgst -sha256 -sign "$KEY" 2>/dev/null | base64 | tr -d '\n')" || exit 4
        [ -n "$sig" ] || exit 4
        printf '{"payload":"%s","sig_b64":"%s","pub_b64":"%s"}\n' "$payload" "$sig" "$(pub)" ;;
  *) exit 2 ;;
esac
HEOF
    chmod 755 "$helper"; cdh=none
    printf 'horvitz: generating a passphrase-protected owner key (you will be asked for the passphrase)...\n' >&2
    pub_b64="$("$helper" setup $([ "$reset" -eq 1 ] && printf -- '--reset 1') | jq -r .pub_b64)" || die "owner-setup: key generation failed"
  else
    case "$policy" in biometry|presence) ;; *) die "--policy must be biometry|presence" ;; esac
    command -v swiftc >/dev/null 2>&1 || die "owner-setup needs swiftc (Xcode Command Line Tools): xcode-select --install"
    [ -f "$OWNER_AUTH_SRC" ] || die "helper source missing: $OWNER_AUTH_SRC"
    printf 'horvitz: building the Touch ID helper from %s ...\n' "$OWNER_AUTH_SRC" >&2
    swiftc -O "$OWNER_AUTH_SRC" -o "$helper" >/dev/null 2>&1 || die "owner-setup: swiftc build failed (run: swiftc -O $OWNER_AUTH_SRC -o $helper to see why)"
    chmod 755 "$helper"
    cdh="$(codesign -dvvv "$helper" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"; [ -n "$cdh" ] || cdh=none
    local setup_args=(setup --label "$label" --policy "$policy"); [ "$reset" -eq 1 ] && setup_args+=(--reset)
    pub_b64="$("$helper" "${setup_args[@]}" | jq -r .pub_b64)" || die "owner-setup: Secure Enclave key creation failed"
  fi
  [ -n "$pub_b64" ] && [ "$pub_b64" != "null" ] || die "owner-setup: no public key returned by the helper"
  local w; w="$(mktemp -d "${TMPDIR:-/tmp}/bones-setup.XXXXXX")"
  { printf '3059301306072a8648ce3d020106082a8648ce3d030107034200' | xxd -r -p; printf '%s' "$pub_b64" | base64 -d; } > "$w/pub.der"
  openssl pkey -pubin -inform DER -in "$w/pub.der" -outform PEM -out "$w/pub.pem" >/dev/null 2>&1 || { rm -rf "$w"; die "owner-setup: public key unparseable"; }
  {
    cat "$w/pub.pem"
    printf 'owner-mode: %s\nowner-label: %s\nhelper-sha256: %s\nhelper-codesign: %s\ncreated: %s\nhost: %s\n' \
      "$mode" "$label" "$(sha_of "$helper")" "$cdh" "$(now)" "$(hostname 2>/dev/null || printf unknown)"
  } > "$OWNER_DIR/owner.pub"; chmod 600 "$OWNER_DIR/owner.pub"; rm -rf "$w"
  printf 'horvitz: owner key ready (%s mode). helper=%s sha256=%s cdhash=%s\n' "$mode" "$helper" "$(sha_of "$helper")" "$cdh"
  # Prove the chain once: a real signature (Touch ID tap / passphrase), verified the way every gate verifies.
  local proof_dir nonce ts out
  proof_dir="$(mktemp -d "${TMPDIR:-/tmp}/bones-proof.XXXXXX")"; mkdir -p "$proof_dir/.bones"
  cp "$OWNER_DIR/owner.pub" "$proof_dir/.bones/owner.pub"
  printf 'horvitz: one-tap proof — signing a setup-test payload now...\n' >&2
  nonce="$(openssl rand -hex 16)"; ts="$(date -u +%s)"
  if out="$("$helper" sign --label "$label" --pipeline setup-test --stage 0 --git-sha nogit --quote-sha "$(printf 'setup' | shasum -a 256 | awk '{print $1}')" --nonce "$nonce" --ts "$ts" --quote "owner-setup proof" 2>/dev/null)" \
     && ( BONES_DIR="$proof_dir/.bones" owner_token_verify "$out" setup-test 0 nogit "$nonce" mint ) >/dev/null 2>&1; then
    printf 'horvitz: PROOF OK — the owner key signs and verifies end to end.\n'
  else
    rm -rf "$proof_dir"; die "owner-setup: proof signature failed (no tap, or verification mismatch) — the key is NOT ready; fix and re-run"
  fi
  rm -rf "$proof_dir"
  [ "$mode" = passphrase ] && printf 'horvitz: WARNING — passphrase mode is DEGRADED; status and doctor say so on every run that pins this key.\n' >&2
  if BONES_DIR="$(find_bones)"; then cmd_owner_pin; fi
  printf 'horvitz: next — pin into every live run: scripts/fleet.sh pin-owner\n'
}

cmd_owner_pin() {
  local rotate=0; [ "${1:-}" = "--rotate" ] && rotate=1
  BONES_DIR="${BONES_DIR:-$(find_bones)}" || die "no .bones here — run 'bones init' first"
  owner_refuse_overrides
  [ -f "$OWNER_DIR/owner.pub" ] || die "no owner key on this machine — run bones owner-setup first"
  local mode; mode="$(sed -n 's/^owner-mode:[[:space:]]*//p' "$OWNER_DIR/owner.pub" | head -1)"
  case "$mode" in biometry|presence|passphrase) ;; *) die "refusing to pin an owner key in mode '${mode:-missing}' (selftest-mode keys are minted only by bones selftest)" ;; esac
  if [ -f "$BONES_DIR/owner.pub" ] && ! cmp -s "$BONES_DIR/owner.pub" "$OWNER_DIR/owner.pub"; then
    if [ "$rotate" -eq 1 ]; then
      local cur; cur="$(require_stage)" || exit 1
      printf 'horvitz: rotating the pinned owner key requires a signature from the CURRENTLY pinned key...\n' >&2
      owner_token_mint "$cur" "rotate owner key"
      journal owner-pin "owner key ROTATED at stage $cur (old-key token verified)"
    else
      die "a different owner key is already pinned in this run — refusing to replace it silently. Deliberate rotation: bones owner-pin --rotate (needs a tap from the OLD key)"
    fi
  fi
  cp "$OWNER_DIR/owner.pub" "$BONES_DIR/owner.pub"
  journal owner-pin "owner key pinned (mode=$mode helper-sha256=$(sed -n 's/^helper-sha256:[[:space:]]*//p' "$OWNER_DIR/owner.pub" | head -1))"
  printf 'horvitz: owner key pinned into %s (mode=%s)\n' "$BONES_DIR/owner.pub" "$mode"
  [ "$mode" = passphrase ] && printf 'horvitz: owner-auth: passphrase (DEGRADED)\n'
  return 0
}

# prime-agent lands in an npm global prefix that is not always on a non-interactive
# PATH; check there too before declaring the default builder missing.
have_prime() {
  command -v prime-agent >/dev/null 2>&1 && return 0
  local d
  # `npm prefix -g` is the accurate answer but needs npm ON PATH, which a minimal
  # non-interactive PATH lacks — so also probe the standard global-bin locations.
  for d in "$(npm prefix -g 2>/dev/null)/bin" "${NPM_CONFIG_PREFIX:-}/bin" \
           "$HOME/.npm-global/bin" "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
    [ -n "$d" ] && [ -x "$d/prime-agent" ] && return 0
  done
  return 1
}

cmd_build() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local cur target
  cur="$(require_stage)" || exit 1; target="$(state_get target)"
  local build_idx=5
  [ "$cur" -eq "$build_idx" ] || die "build is only valid at stage 5 (build-loop); you are at stage $cur. Advance to it first."
  [ -x "$LOOP_SH" ] || [ -f "$LOOP_SH" ] || die "loop.sh not found at $LOOP_SH (set BONES_LOOP_SH to override)"
  # The auto gate is only "machine-verified" if the ORCHESTRATOR runs the acceptance
  # command. Without -c, loop.sh degrades to codex's self-report — gameable — so the
  # bones gate refuses to accept it.
  local a has_c=0
  for a in "$@"; do case "$a" in -c|-c?*) has_c=1 ;; esac; done
  [ "$has_c" -eq 1 ] || die "build needs -c \"<acceptance_cmd>\" — without it the gate would rest on codex's self-report, which is not machine-verified. For non-code ops, wrap the checks in a script: -c \"./check.sh\"."
  local accept_cmd="" prev=""
  for a in "$@"; do
    if [ "$prev" = "-c" ]; then accept_cmd="$a"; break; fi
    case "$a" in -c*) accept_cmd="${a#-c}"; [ -n "$accept_cmd" ] && break ;; esac
    prev="$a"
  done
  local pinned_cmd; pinned_cmd="$(cat "$BONES_DIR/acceptance.cmd")"
  [ "$accept_cmd" = "$pinned_cmd" ] \
    || die "acceptance command differs from the command pinned at init. Refusing to move the goalposts; inspect $(cmd_acceptance_path)."
  local acceptance_sha; acceptance_sha="$(sha_of "$BONES_DIR/acceptance.cmd")"
  # 2.0: a pinned plan is a precondition of the build (Bones: the builder should not invent architecture).
  local pf="$BONES_DIR/gates/5-build-loop.plan" plan plan_sha spec
  [ -f "$pf" ] || die "build refuses without a pinned plan — bones plan -e docs/plan.md \"<note>\" first (architecture, file-level changes, order, test seams, acceptance map; contracts/plan.sh + LLM judge)"
  plan="$(sed -n 's/^plan: \(.*\) (sha256:[a-f0-9]*)$/\1/p' "$pf" | head -1)"
  plan_sha="$(sed -n 's/^plan: .* (sha256:\([a-f0-9]*\))$/\1/p' "$pf" | head -1)"
  [ -f "$plan" ] || die "pinned plan is missing on disk: $plan"
  [ "$(sha_of "$plan")" = "$plan_sha" ] || die "pinned plan changed after pinning ($plan) — bones back -s 5, then plan again"
  spec="$(signed_spec_path)" || die "signed spec missing or changed since sign-off — re-sign (back -s 3) before building"
  [ "$(sed -n 's/^spec-sha256:[[:space:]]*//p' "$pf" | head -1)" = "$(sha_of "$spec")" ] || die "the pinned plan was written for a different spec revision (the spec was re-signed since) — bones back -s 5, then plan again"

  # Builder default: bones drives prime-agent unless told otherwise, so `run bones`
  # needs no -B. An explicit -B always wins. A DEFAULT may fall back (it was not an
  # instruction); an explicit choice never does — loop.sh hard-errors on that.
  local has_b=0
  for a in "$@"; do case "$a" in -B|-B?*) has_b=1 ;; esac; done
  local builder_args=() builder_used="(explicit -B)"
  if [ "$has_b" -eq 0 ]; then
    if [ "$BONES_BUILDER" = "prime" ] && ! have_prime; then
      printf 'horvitz: default builder prime-agent is not on PATH — deferring to loop.sh auto-resolution.\n' >&2
      journal build "default builder prime unavailable; deferred to loop.sh auto"
      builder_used="auto (prime unavailable)"
    else
      builder_args=(-B "$BONES_BUILDER")
      builder_used="$BONES_BUILDER"
      printf 'horvitz: builder=%s (default — pass -B codex|prime|auto to override)\n' "$BONES_BUILDER"
    fi
  fi

  printf 'horvitz: running build loop (ship-pipeline loop.sh) — a successful loop is followed by an independent pinned acceptance check...\n\n'
  if bash "$LOOP_SH" -t "$target" -P "$plan" ${builder_args[@]+"${builder_args[@]}"} "$@"; then
    # loop.sh is an orchestrator, not the root of trust. Re-run the pinned
    # acceptance command here before minting the gate so an overridden,
    # replaced, or buggy loop cannot turn its own exit 0 into approval.
    printf '\nhorvitz: loop exited 0; independently running pinned acceptance command (sha256:%s)...\n' "$acceptance_sha"
    if (cd "$target" && eval "$pinned_cmd"); then
      :
    else
      local accept_rc=$?
      journal build "loop.sh exit 0; independent pinned acceptance failed — gate stays closed (acceptance_sha256=$acceptance_sha)"
      printf '\nhorvitz: build gate NOT passed (independent pinned acceptance command exit %s). Gate stays closed.\n' "$accept_rc"
      return "$accept_rc"
    fi
    {
      printf '%s | build-loop | auto | loop.sh exit 0 + independent pinned acceptance exit 0\n' "$(now)"
      printf 'builder: %s\n' "$builder_used"
      printf 'acceptance-command: %s (sha256:%s)\n' "$BONES_DIR/acceptance.cmd" "$acceptance_sha"
      printf 'plan: %s (sha256:%s)\n' "$plan" "$plan_sha"
      git_pin "$target"
    } > "$(gate_file "$build_idx")"
    journal build "loop.sh exit 0 + independent pinned acceptance exit 0 (acceptance_sha256=$acceptance_sha)"
    printf '\nhorvitz: build gate PASSED (loop + independent pinned acceptance both exited 0). Run `bones next`.\n'
  else
    local rc=$?
    journal build "loop.sh exit $rc — gate stays closed"
    printf '\nhorvitz: build gate NOT passed (loop.sh exit %s). Gate stays closed; fix and re-run `bones build`.\n' "$rc"
    return "$rc"
  fi
}

cmd_acceptance_path() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  require_stage >/dev/null
  printf '%s/acceptance.cmd\n' "$BONES_DIR"
}

# Release license verification key. The corresponding private key is never
# read from disk by bones and must not ship with the client.
write_license_public_key() {
  cat <<'EOF'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAbQPJuQWdweUs7gzZDr2F1Ljd6pBKu5EBfNHeXZw0wOA=
-----END PUBLIC KEY-----
EOF
}

base64url_decode_to() { # base64url_decode_to <text> <output-file>
  local encoded="$1" output="$2" padding
  case "$encoded" in (''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  case $((${#encoded} % 4)) in
    0) padding="" ;; 2) padding="==" ;; 3) padding="=" ;; *) return 1 ;;
  esac
  printf '%s%s' "$encoded" "$padding" | tr '_-' '/+' | openssl base64 -d -A > "$output" 2>/dev/null
}

base64url_encode_file() { # base64url_encode_file <input-file>
  openssl base64 -A -in "$1" 2>/dev/null | tr '/+' '_-' | tr -d '='
}

license_invalid() {
  printf 'horvitz: INVALID SIGNATURE\n' >&2
  return 1
}

verify_license_with_key() { # internal: <signed-key> <public-pem> <audience>
  local key="$1" public_pem="$2" audience="$3"
  local prefix payload64 signature64 extra tmp payload signature license_id
  IFS='.' read -r prefix payload64 signature64 extra <<< "$key"
  [ "$prefix" = "bones1" ] && [ -n "$payload64" ] && [ -n "$signature64" ] && [ -z "${extra:-}" ] \
    || { license_invalid; return 1; }
  command -v openssl >/dev/null 2>&1 \
    || die "license verification needs openssl (no network call is made)"
  command -v jq >/dev/null 2>&1 \
    || die "license verification needs jq (install jq or use the signed bones installer)"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/bones-license.XXXXXX")" || die "could not create license verification workspace"
  payload="$tmp/payload.json"; signature="$tmp/signature.bin"
  printf '%s\n' "$public_pem" > "$tmp/public.pem"
  if ! base64url_decode_to "$payload64" "$payload" \
    || ! base64url_decode_to "$signature64" "$signature" \
    || ! openssl pkeyutl -verify -pubin -inkey "$tmp/public.pem" -rawin \
         -in "$payload" -sigfile "$signature" >/dev/null 2>&1; then
    rm -rf "$tmp"
    license_invalid
    return 1
  fi

  if ! jq -e --arg audience "$audience" \
    'type == "object" and .version == 1 and .tier == "pro" and .audience == $audience and (.license_id | type == "string" and length > 0)' \
    "$payload" >/dev/null 2>&1; then
    rm -rf "$tmp"
    printf 'horvitz: INVALID LICENSE PAYLOAD\n' >&2
    return 1
  fi
  license_id="$(jq -r '.license_id' "$payload")"
  rm -rf "$tmp"
  printf 'horvitz: VALID LICENSE — Pro unlocked (license_id=%s)\n' "$license_id"
}

cmd_license() {
  [ "${1:-}" = "--check" ] && [ -n "${2:-}" ] && [ $# -eq 2 ] \
    || die "license usage: bones license --check <signed-key>"
  verify_license_with_key "$2" "$(write_license_public_key)" "bones-pro"
}

scanner_bin() { # scanner_bin <configured override> <default command>
  local configured="$1" fallback="$2"
  if [ -n "$configured" ]; then
    if [ -x "$configured" ]; then printf '%s\n' "$configured"
    else command -v "$configured" 2>/dev/null
    fi
  else
    command -v "$fallback" 2>/dev/null
  fi
}

cmd_package() {
  local source="giftcandidate" output="bones-package.tar.gz"
  local allowlist="$DEFAULT_SECRET_ALLOWLIST"
  while getopts ":s:o:a:" o; do case "$o" in
    s) source="$OPTARG" ;; o) output="$OPTARG" ;; a) allowlist="$OPTARG" ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  shift $((OPTIND-1))
  [ $# -eq 0 ] || die "package usage: bones package [-s <giftcandidate>] [-o <archive.tar.gz>] [-a <secret-allowlist>]"
  [ -d "$source" ] || die "package source directory not found: $source"
  [ -f "$allowlist" ] || die "secret allowlist manifest not found: $allowlist"
  [ -f "$SECRET_SCANNER" ] || die "built-in entropy scanner missing: $SECRET_SCANNER"

  source="$(cd "$source" && pwd)"
  case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
  [ ! -e "$output" ] || die "package output already exists (refusing to overwrite): $output"

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/bones-package.XXXXXX")" \
    || die "could not create package scan workspace"
  local rc=0 gitleaks_bin="" trufflehog_bin="" external_count=0

  # Scan the entire candidate, not only manifest-listed files: an omitted secret
  # must block packaging rather than silently remain beside the clean archive.
  if ! perl "$SECRET_SCANNER" "$source" "$allowlist"; then
    rm -rf "$tmp"
    return 1
  fi

  gitleaks_bin="$(scanner_bin "${BONES_GITLEAKS_BIN:-}" gitleaks || true)"
  trufflehog_bin="$(scanner_bin "${BONES_TRUFFLEHOG_BIN:-}" trufflehog || true)"
  if [ -z "$gitleaks_bin" ] && [ -z "$trufflehog_bin" ]; then
    rm -rf "$tmp"
    printf 'bones package: BLOCKED scanner-unavailable rule=EXTERNAL_SECRET_SCANNER_REQUIRED — install gitleaks or trufflehog; packaging fails closed.\n' >&2
    return 1
  fi

  if [ -n "$gitleaks_bin" ]; then
    external_count=$((external_count+1)); rc=0
    "$gitleaks_bin" detect --source "$source" --no-git --report-format json \
      --report-path "$tmp/gitleaks.json" >"$tmp/gitleaks.log" 2>&1 || rc=$?
    if [ -s "$tmp/gitleaks.json" ] && jq -e 'type == "array" and length > 0' "$tmp/gitleaks.json" >/dev/null 2>&1; then
      jq -r '.[] | "bones package: BLOCKED gitleaks \(.File // "unknown"):\(.StartLine // 0) rule=\(.RuleID // "unknown")"' \
        "$tmp/gitleaks.json" >&2
      rm -rf "$tmp"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'bones package: BLOCKED gitleaks scanner error (exit %s); archive not created.\n' "$rc" >&2
      sed -n '1,12p' "$tmp/gitleaks.log" >&2
      rm -rf "$tmp"
      return 1
    fi
    printf 'bones package: gitleaks clean\n'
  fi

  if [ -n "$trufflehog_bin" ]; then
    external_count=$((external_count+1)); rc=0
    "$trufflehog_bin" filesystem --json --no-update "$source" \
      >"$tmp/trufflehog.jsonl" 2>"$tmp/trufflehog.log" || rc=$?
    if [ -s "$tmp/trufflehog.jsonl" ]; then
      if jq -s -e 'length > 0' "$tmp/trufflehog.jsonl" >/dev/null 2>&1; then
        jq -sr '.[] | "bones package: BLOCKED trufflehog \(.SourceMetadata.Data.Filesystem.file // "unknown") rule=\(.DetectorName // "unknown")"' \
          "$tmp/trufflehog.jsonl" >&2
      else
        printf 'bones package: BLOCKED trufflehog returned an unreadable report.\n' >&2
      fi
      rm -rf "$tmp"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'bones package: BLOCKED trufflehog scanner error (exit %s); archive not created.\n' "$rc" >&2
      sed -n '1,12p' "$tmp/trufflehog.log" >&2
      rm -rf "$tmp"
      return 1
    fi
    printf 'bones package: trufflehog clean\n'
  fi
  [ "$external_count" -gt 0 ] || { rm -rf "$tmp"; die "internal error: external scanner was not run"; }

  local manifest="$source/.bones-package-manifest" package_list="$tmp/package-files.txt"
  [ -f "$manifest" ] || { rm -rf "$tmp"; die "package manifest missing: $manifest (list one relative file path per line)"; }
  : > "$package_list"
  local entry count=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="${entry%$'\r'}"
    case "$entry" in ""|'#'*) continue ;; esac
    case "$entry" in
      /*|../*|*/../*|-*|*'//'*) rm -rf "$tmp"; die "unsafe package manifest entry: $entry" ;;
    esac
    [ -f "$source/$entry" ] && [ ! -L "$source/$entry" ] \
      || { rm -rf "$tmp"; die "manifest entry is missing, not a regular file, or a symlink: $entry"; }
    printf '%s\n' "$entry" >> "$package_list"
    count=$((count+1))
  done < "$manifest"
  [ "$count" -gt 0 ] || { rm -rf "$tmp"; die "package manifest contains no files: $manifest"; }
  printf '%s\n' '.bones-package-manifest' >> "$package_list"

  if ! tar -czf "$tmp/bones-package.tar.gz" -C "$source" -T "$package_list"; then
    rm -rf "$tmp"
    die "archive creation failed after clean scans"
  fi
  mkdir -p "$(dirname "$output")"
  mv "$tmp/bones-package.tar.gz" "$output"
  rm -rf "$tmp"
  printf 'bones package: PASS — %s file(s), entropy + %s external scanner(s) clean; archive=%s\n' \
    "$count" "$external_count" "$output"
}

guard_json() { # guard_json <tool> <cwd> <command> [file_path]
  local tool="$1" cwd="$2" cmd="$3" file="${4:-}"
  printf '{"tool_name":"%s","cwd":"%s","tool_input":{"command":"%s","file_path":"%s"}}\n' \
    "$(json_esc "$tool")" "$(json_esc "$cwd")" "$(json_esc "$cmd")" "$(json_esc "$file")"
}

selftest_workspace() {
  local d="${TMPDIR:-/tmp}/bones-selftest-$$-$RANDOM"
  mkdir -p "$d/project/.bones/gates" "$d/bin"
  ln -s /bin/cat "$d/bin/cat" 2>/dev/null || true
  printf '{\n  "schema_version": 1,\n  "name": "selftest",\n  "target": "%s/project",\n  "stage": 5,\n  "created": "%s",\n  "updated": "%s",\n  "strict": false\n}\n' "$(json_esc "$d/project")" "$(now)" "$(now)" > "$d/project/.bones/state.json"
  printf '%s\n' "$(sha_of "$d/project/.bones/state.json")" > "$d/project/.bones/state.sha256"
  printf '%s\n' "$(sha_of "$GUARD_SH")" > "$d/project/.bones/guard.sha256"
  printf 'true\n' > "$d/project/.bones/acceptance.cmd"
  chmod 444 "$d/project/.bones/acceptance.cmd" 2>/dev/null || true
  printf '%s\n' "$d"
}

expect_guard_block() { # expect_guard_block <id> <json> [path]
  local id="$1" payload="$2" path_prefix="${3:-}"
  local out rc=0
  if [ -n "$path_prefix" ]; then
    out="$(PATH="$path_prefix" "$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$payload")" || rc=$?
  else
    out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$payload")" || rc=$?
  fi
  if [ "$rc" -eq 2 ]; then
    printf '%s BLOCK\n' "$id"
    return 0
  fi
  printf '%s FAIL expected BLOCK, got rc=%s output=%s\n' "$id" "$rc" "$out"
  return 1
}

selftest_byp_01() { local w rc; w="$(selftest_workspace)"; expect_guard_block BYP-01 "$(guard_json Write "$w/project" "" "$w/project/.bones/state.json")"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_02() { local w rc; w="$(selftest_workspace)"; expect_guard_block BYP-02 "$(guard_json Bash "$w/project" "ls; git push origin main")"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_03() { local w rc; w="$(selftest_workspace)"; expect_guard_block BYP-03 "$(guard_json Bash "$w" "cd project; git push origin main")"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_04() { local w rc; w="$(selftest_workspace)"; expect_guard_block BYP-04 "$(guard_json Bash "$w/project" "git push origin main")" "$w/bin"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_05() { local w rc; w="$(selftest_workspace)"; expect_guard_block BYP-05 "$(guard_json Bash "$w/project" "git push -u o HEAD:main")"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_06() {
  local w rc=0 probe out probe_rc
  w="$(selftest_workspace)"
  for probe in \
    "ssh git@github.com" \
    "gh api repos/acme/app/git/refs/heads/main -X PATCH -f sha=deadbeef" \
    "curl -X PATCH https://api.github.com/repos/acme/app/git/refs/heads/main" \
    "git push production feature-branch" \
    "shipit(){ git push origin main; }; shipit"
  do
    probe_rc=0
    out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Bash "$w/project" "$probe")")" || probe_rc=$?
    if [ "$probe_rc" -ne 2 ]; then
      printf 'BYP-06 FAIL expected BLOCK for %s, got rc=%s output=%s\n' "$probe" "$probe_rc" "$out"
      rc=1
    fi
  done
  rm -rf "$w"
  [ "$rc" -eq 0 ] && printf 'BYP-06 BLOCK\n'
  return "$rc"
}
selftest_byp_07() { local w rc; w="$(selftest_workspace)"; expect_guard_block BYP-07 "$(guard_json Bash "$w/project" "newhost deploy --prod")"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_08() { local w rc; w="$(selftest_workspace)"; printf 'production\n' > "$w/project/.bones/protected-branches"; expect_guard_block BYP-08 "$(guard_json Bash "$w/project" "git push origin production")"; rc=$?; rm -rf "$w"; return "$rc"; }
selftest_byp_09() {
  local w ev rc=0
  w="$(selftest_workspace)"; ev="$w/project/evidence.txt"
  sed -E 's/"stage": 5/"stage": 1/' "$w/project/.bones/state.json" > "$w/project/.bones/state.json.next"
  mv "$w/project/.bones/state.json.next" "$w/project/.bones/state.json"
  printf '%s\n' "$(sha_of "$w/project/.bones/state.json")" > "$w/project/.bones/state.sha256"
  printf 'before\n' > "$ev"
  printf '%s | brainstorm | agent | selftest\n' "$(now)" > "$w/project/.bones/gates/1-brainstorm.ok"
  printf 'evidence: %s (sha256:%s)\n' "$ev" "$(sha_of "$ev")" >> "$w/project/.bones/gates/1-brainstorm.ok"
  printf 'after\n' > "$ev"
  (cd "$w/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" next >/tmp/bones-selftest-evidence.$$ 2>&1) || rc=$?
  rm -f /tmp/bones-selftest-evidence.$$
  rm -rf "$w"
  [ "$rc" -ne 0 ] && { printf 'BYP-09 BLOCK\n'; return 0; }
  printf 'BYP-09 FAIL expected next to reject changed evidence\n'; return 1
}
selftest_byp_10() {
  local w rc=0 probe out probe_rc
  w="$(selftest_workspace)"
  for probe in "printf x > .bones/state.json" "bash $SELF reset -f" "bash $SELF init -t . -c true -f -S"; do
    probe_rc=0
    out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Bash "$w/project" "$probe")")" || probe_rc=$?
    if [ "$probe_rc" -ne 2 ]; then
      printf 'BYP-10 FAIL expected BLOCK for %s, got rc=%s output=%s\n' "$probe" "$probe_rc" "$out"
      rc=1
    fi
  done
  rm -rf "$w"
  [ "$rc" -eq 0 ] && printf 'BYP-10 BLOCK\n'
  return "$rc"
}
selftest_byp_14() {
  local w w2 rc=0 guard_rc=0 downgrade_rc=0 downgrade_guard_rc=0
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-state.XXXXXX")"
  mkdir -p "$w/project"
  "$SELF" init -t "$w/project" -n selftest -c true -S >/dev/null
  chmod u+w "$w/project/.bones/state.json" 2>/dev/null || true
  sed -i.bak 's/"stage": 1/"stage": 9/' "$w/project/.bones/state.json" 2>/dev/null || perl -0pi -e 's/"stage": 1/"stage": 9/' "$w/project/.bones/state.json"
  (cd "$w/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" status >/tmp/bones-selftest-state.$$ 2>&1) || rc=$?
  "$BASH_BIN" "$GUARD_SH" >/tmp/bones-selftest-state-guard.$$ 2>&1 <<<"$(guard_json Bash "$w/project" "git push origin main")" || guard_rc=$?
  rm -f /tmp/bones-selftest-state.$$
  rm -f /tmp/bones-selftest-state-guard.$$
  rm -rf "$w"

  w2="$(mktemp -d "${TMPDIR:-/tmp}/bones-schema.XXXXXX")"; mkdir -p "$w2/project"
  "$SELF" init -t "$w2/project" -n selftest -c true -S >/dev/null
  sed -E 's/"schema_version": 2/"schema_version": 0/' "$w2/project/.bones/state.json" > "$w2/project/.bones/state.json.next"
  mv "$w2/project/.bones/state.json.next" "$w2/project/.bones/state.json"
  (cd "$w2/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" status >/tmp/bones-selftest-schema.$$ 2>&1) || downgrade_rc=$?
  "$BASH_BIN" "$GUARD_SH" >/tmp/bones-selftest-schema-guard.$$ 2>&1 <<<"$(guard_json Bash "$w2/project" "git push origin main")" || downgrade_guard_rc=$?
  rm -f /tmp/bones-selftest-schema.$$ /tmp/bones-selftest-schema-guard.$$
  rm -rf "$w2"

  [ "$rc" -ne 0 ] && [ "$guard_rc" -eq 2 ] && [ "$downgrade_rc" -ne 0 ] && [ "$downgrade_guard_rc" -eq 2 ] \
    && { printf 'BYP-14 BLOCK\n'; return 0; }
  printf 'BYP-14 FAIL expected CLI+guard to reject forged stage and schema downgrade (stage_status=%s stage_guard=%s schema_status=%s schema_guard=%s)\n' \
    "$rc" "$guard_rc" "$downgrade_rc" "$downgrade_guard_rc"
  return 1
}
selftest_pinned_acceptance() {
  local w w_pass rc=0 build_rc=0 before after log_sha fake_loop output
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-acceptance.XXXXXX")"; mkdir -p "$w/project"
  "$SELF" init -t "$w/project" -n selftest -c false -S >/dev/null
  before="$(sha_of "$w/project/.bones/acceptance.cmd")"
  expect_guard_block pinned-acceptance "$(guard_json Bash "$w/project" "printf 'exit 0\n' >> \"\$($SELF acceptance-path)\"")" || rc=1
  fake_loop="$w/loop.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_loop"; chmod +x "$fake_loop"
  sed -E 's/"stage": 1/"stage": 5/' "$w/project/.bones/state.json" > "$w/project/.bones/state.json.next"
  mv "$w/project/.bones/state.json.next" "$w/project/.bones/state.json"
  printf '%s\n' "$(sha_of "$w/project/.bones/state.json")" > "$w/project/.bones/state.sha256"
  selftest_pin_plan "$w/project"
  (cd "$w/project" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c true -s spec.html >/tmp/bones-selftest-acceptance.$$ 2>&1) || build_rc=$?
  [ "$build_rc" -ne 0 ] || { printf 'pinned-acceptance FAIL build accepted a replacement command\n'; rc=1; }
  after="$(sha_of "$w/project/.bones/acceptance.cmd")"
  [ "$before" = "$after" ] || { printf 'pinned-acceptance FAIL pinned file changed\n'; rc=1; }

  # Reproduce the iteration-1 exploit exactly: an attacker-selected loop exits
  # 0 while the genuinely pinned command is false. No gate may be created.
  build_rc=0
  (cd "$w/project" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c false -s missing-spec.html >/tmp/bones-selftest-acceptance.$$ 2>&1) || build_rc=$?
  output="$(cat /tmp/bones-selftest-acceptance.$$ 2>/dev/null)"
  if [ "$build_rc" -eq 0 ] || [ -f "$w/project/.bones/gates/5-build-loop.ok" ] \
    || ! printf '%s' "$output" | grep -q 'independent pinned acceptance command exit'; then
    printf 'pinned-acceptance FAIL attacker-selected loop bypassed or was not independently checked (rc=%s gate=%s)\n' \
      "$build_rc" "$([ -f "$w/project/.bones/gates/5-build-loop.ok" ] && printf yes || printf no)"
    rc=1
  else
    printf 'pinned-acceptance fake-loop-bypass BLOCK\n'
  fi

  # A successful pinned command still opens the gate and records its hash.
  w_pass="$(mktemp -d "${TMPDIR:-/tmp}/bones-acceptance-pass.XXXXXX")"; mkdir -p "$w_pass/project"
  "$SELF" init -t "$w_pass/project" -n selftest -c true -S >/dev/null
  sed -E 's/"stage": 1/"stage": 5/' "$w_pass/project/.bones/state.json" > "$w_pass/project/.bones/state.json.next"
  mv "$w_pass/project/.bones/state.json.next" "$w_pass/project/.bones/state.json"
  printf '%s\n' "$(sha_of "$w_pass/project/.bones/state.json")" > "$w_pass/project/.bones/state.sha256"
  selftest_pin_plan "$w_pass/project"
  (cd "$w_pass/project" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c true -s spec.html >/tmp/bones-selftest-acceptance.$$ 2>&1) || rc=1
  log_sha="$(grep -oE 'sha256:[a-f0-9]+' "$w_pass/project/.bones/gates/5-build-loop.ok" 2>/dev/null | head -1 | cut -d: -f2)"
  [ "$log_sha" = "$(sha_of "$w_pass/project/.bones/acceptance.cmd")" ] || { printf 'pinned-acceptance FAIL build did not log pinned file hash\n'; rc=1; }
  rm -f /tmp/bones-selftest-acceptance.$$
  rm -rf "$w" "$w_pass"
  return "$rc"
}
selftest_guard_tamper() {
  local w rc=0 out
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-guard.XXXXXX")"
  mkdir -p "$w/project"
  "$SELF" init -t "$w/project" -n selftest -c true -S >/dev/null
  printf '0000000000000000000000000000000000000000000000000000000000000000\n' > "$w/project/.bones/guard.sha256"
  out="$(cd "$w/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" status 2>&1)" || rc=$?
  rm -rf "$w"
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qE 'expected [a-f0-9]+, actual [a-f0-9]+'; then
    printf 'guard-tamper BLOCK\n'; return 0
  fi
  printf 'guard-tamper FAIL expected refusal with expected vs actual sha256, got rc=%s output=%s\n' "$rc" "$out"; return 1
}

selftest_license() {
  local w payload payload64 signature64 key tampered valid_out invalid_out invalid_rc=0
  command -v openssl >/dev/null 2>&1 || { printf 'license FAIL openssl unavailable\n'; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'license FAIL jq unavailable\n'; return 1; }
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-license-test.XXXXXX")" || return 1
  openssl genpkey -algorithm ED25519 -out "$w/private.pem" >/dev/null 2>&1 \
    || { rm -rf "$w"; printf 'license FAIL could not generate test key\n'; return 1; }
  openssl pkey -in "$w/private.pem" -pubout -out "$w/public.pem" >/dev/null 2>&1 \
    || { rm -rf "$w"; printf 'license FAIL could not derive test public key\n'; return 1; }
  payload='{"version":1,"tier":"pro","audience":"bones-selftest","license_id":"lic_selftest"}'
  printf '%s' "$payload" > "$w/payload.json"
  openssl pkeyutl -sign -inkey "$w/private.pem" -rawin -in "$w/payload.json" -out "$w/signature.bin" >/dev/null 2>&1 \
    || { rm -rf "$w"; printf 'license FAIL could not sign test license\n'; return 1; }
  payload64="$(base64url_encode_file "$w/payload.json")"
  signature64="$(base64url_encode_file "$w/signature.bin")"
  key="bones1.$payload64.$signature64"
  valid_out="$(verify_license_with_key "$key" "$(cat "$w/public.pem")" "bones-selftest" 2>&1)" \
    || { rm -rf "$w"; printf 'license FAIL valid key rejected: %s\n' "$valid_out"; return 1; }

  tampered="bones1.A${payload64#?}.$signature64"
  invalid_out="$(verify_license_with_key "$tampered" "$(cat "$w/public.pem")" "bones-selftest" 2>&1)" || invalid_rc=$?
  rm -rf "$w"
  if [ "$invalid_rc" -ne 0 ] && printf '%s' "$valid_out" | grep -q 'Pro unlocked' \
    && printf '%s' "$invalid_out" | grep -q 'INVALID SIGNATURE'; then
    printf 'license PASS valid Ed25519 key unlocked Pro; one-byte tamper INVALID SIGNATURE\n'
    return 0
  fi
  printf 'license FAIL tampered key was not rejected correctly (rc=%s output=%s)\n' "$invalid_rc" "$invalid_out"
  return 1
}

selftest_package() {
  local w fake out rc=0 clean_rc=0 external_rc=0 missing_rc=0
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-package-test.XXXXXX")" || return 1
  mkdir -p "$w/leaky" "$w/clean"
  printf 'README.md\n' > "$w/leaky/.bones-package-manifest"
  printf 'candidate\n' > "$w/leaky/README.md"
  printf 'AKIAIOSFODNN7EXAMPLE\n' > "$w/leaky/leak.env"
  printf 'README.md\n' > "$w/clean/.bones-package-manifest"
  printf 'clean candidate\n' > "$w/clean/README.md"
  fake="$w/gitleaks"
  printf '%s\n' '#!/usr/bin/env bash' \
    'report=""' \
    'while [ $# -gt 0 ]; do if [ "$1" = "--report-path" ]; then report="$2"; shift 2; else shift; fi; done' \
    'if [ "${FAKE_GITLEAKS_FINDING:-0}" = 1 ]; then printf '\''[{"File":"README.md","StartLine":1,"RuleID":"TEST_RULE"}]\n'\'' > "$report"; exit 1; fi' \
    'printf "[]\n" > "$report"' > "$fake"
  chmod +x "$fake"

  out="$(BONES_GITLEAKS_BIN="$fake" BONES_TRUFFLEHOG_BIN=/definitely/missing \
    "$SELF" package -s "$w/leaky" -o "$w/leak.tar.gz" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] || [ -e "$w/leak.tar.gz" ] \
    || ! printf '%s' "$out" | grep -q 'leak.env:.*rule=AWS_ACCESS_KEY_ID'; then
    printf 'package FAIL planted secret did not block with file+rule (rc=%s archive=%s output=%s)\n' \
      "$rc" "$([ -e "$w/leak.tar.gz" ] && printf yes || printf no)" "$out"
    rm -rf "$w"; return 1
  fi
  printf 'package planted-secret BLOCK file=leak.env rule=AWS_ACCESS_KEY_ID archive=no\n'

  BONES_GITLEAKS_BIN="$fake" BONES_TRUFFLEHOG_BIN=/definitely/missing \
    "$SELF" package -s "$w/clean" -o "$w/clean.tar.gz" >/dev/null 2>&1 || clean_rc=$?
  if [ "$clean_rc" -ne 0 ] || [ ! -s "$w/clean.tar.gz" ] \
    || ! tar -tzf "$w/clean.tar.gz" | grep -q '^README.md$'; then
    printf 'package FAIL clean manifest did not produce the expected archive\n'
    rm -rf "$w"; return 1
  fi

  out="$(FAKE_GITLEAKS_FINDING=1 BONES_GITLEAKS_BIN="$fake" BONES_TRUFFLEHOG_BIN=/definitely/missing \
    "$SELF" package -s "$w/clean" -o "$w/external.tar.gz" 2>&1)" || external_rc=$?
  if [ "$external_rc" -eq 0 ] || [ -e "$w/external.tar.gz" ] \
    || ! printf '%s' "$out" | grep -q 'gitleaks README.md:1 rule=TEST_RULE'; then
    printf 'package FAIL external finding was not normalized to file+rule (rc=%s output=%s)\n' "$external_rc" "$out"
    rm -rf "$w"; return 1
  fi

  BONES_GITLEAKS_BIN=/definitely/missing BONES_TRUFFLEHOG_BIN=/definitely/missing \
    "$SELF" package -s "$w/clean" -o "$w/missing.tar.gz" >/dev/null 2>&1 || missing_rc=$?
  if [ "$missing_rc" -eq 0 ] || [ -e "$w/missing.tar.gz" ]; then
    printf 'package FAIL missing external scanner did not fail closed\n'
    rm -rf "$w"; return 1
  fi
  rm -rf "$w"
  printf 'package PASS clean archive created; external finding + missing scanner BLOCK\n'
}

selftest_upgrade() {
  local w out rc=0 schema stage
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-upgrade.XXXXXX")"; mkdir -p "$w/project/.bones/gates"
  printf '{\n  "schema_version": 1,\n  "name": "upgrade-test",\n  "target": "%s",\n  "stage": 5,\n  "created": "%s",\n  "updated": "%s",\n  "strict": false\n}\n' \
    "$(json_esc "$w/project")" "$(now)" "$(now)" > "$w/project/.bones/state.json"
  printf '%s\n' "$(sha_of "$w/project/.bones/state.json")" > "$w/project/.bones/state.sha256"
  printf '%s\n' "$(sha_of "$GUARD_SH")" > "$w/project/.bones/guard.sha256"
  printf 'true\n' > "$w/project/.bones/acceptance.cmd"; chmod 444 "$w/project/.bones/acceptance.cmd" 2>/dev/null || true
  printf 'pre-upgrade gate survives\n' > "$w/project/.bones/gates/4-council.ok"
  printf 'pre-upgrade journal survives\n' > "$w/project/.bones/journal.log"
  out="$(cd "$w/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" status 2>&1)" || rc=$?
  schema="$(json_get "$w/project/.bones/state.json" schema_version)"
  stage="$(json_get "$w/project/.bones/state.json" stage)"
  if [ "$rc" -eq 0 ] && [ "$schema" = "$STATE_SCHEMA" ] && [ "$stage" = "5" ] \
    && [ -f "$w/project/.bones/gates/4-council.ok" ] && printf '%s' "$out" | grep -q 'stage: 5/10'; then
    rm -rf "$w"; printf 'upgrade PASS schema v1 -> v%s, in-flight stage 5 preserved\n' "$STATE_SCHEMA"; return 0
  fi
  rm -rf "$w"
  printf 'upgrade FAIL rc=%s schema=%s stage=%s output=%s\n' "$rc" "$schema" "$stage" "$out"; return 1
}

# ---- 2.0 selftest helpers ------------------------------------------------------------------
FIXTURES="$SCRIPT_DIR/../selftest/fixtures"
selftest_set_stage() { # <project> <stage>
  sed -E "s/\"stage\": [0-9]+/\"stage\": $2/" "$1/.bones/state.json" > "$1/.bones/state.json.next" && mv "$1/.bones/state.json.next" "$1/.bones/state.json"
  printf '%s\n' "$(sha_of "$1/.bones/state.json")" > "$1/.bones/state.sha256"
}
# selftest_sign_spec <project>: copies the fixture spec in and writes a stage-3 gate that signs it.
selftest_sign_spec() {
  cp "$FIXTURES/spec/spec-fixture.html" "$1/spec-fixture.html"
  { printf '%s | spec | owner | selftest signed fixture spec\nowner-quote: "selftest"\n' "$(now)"
    printf 'evidence: %s (sha256:%s)\n' "$1/spec-fixture.html" "$(sha_of "$1/spec-fixture.html")"; } > "$1/.bones/gates/3-spec.ok"
}
# selftest_pin_plan <project>: signs the fixture spec and pins the accept plan directly (no LLM judge).
selftest_pin_plan() {
  selftest_sign_spec "$1"
  sed "s/@SPEC_SHA@/$(sha_of "$1/spec-fixture.html")/" "$FIXTURES/plan/accept-1.md" > "$1/plan.md"
  { printf '%s | build-loop | plan | selftest pinned fixture plan\n' "$(now)"
    printf 'plan: %s (sha256:%s)\nspec-sha256: %s\n' "$1/plan.md" "$(sha_of "$1/plan.md")" "$(sha_of "$1/spec-fixture.html")"; } > "$1/.bones/gates/5-build-loop.plan"
}
# selftest_owner_workspace: git project at stage 8 with a selftest-mode owner key (openssl P-256, no biometry).
selftest_owner_workspace() {
  local w; w="$(mktemp -d "${TMPDIR:-/tmp}/bones-owner-ws.XXXXXX")"; w="$(cd "$w" && pwd)"
  mkdir -p "$w/project" "$w/helper"
  ( cd "$w/project" && git init -q && printf '.bones/\n.loop/\n' > .gitignore && git add .gitignore && git -c user.email=s@t -c user.name=selftest commit -q -m init ) >/dev/null 2>&1
  "$SELF" init -t "$w/project" -n selftest -c true -S >/dev/null 2>&1
  openssl ecparam -name prime256v1 -genkey -noout -out "$w/helper/test-key.pem" 2>/dev/null
  cat > "$w/helper/bones-owner-auth-test" <<'HEOF'
#!/usr/bin/env bash
# SELFTEST owner-auth helper: signs with an openssl P-256 test key. No biometry. Selftest only.
set -u; KEY="$(cd "$(dirname "$0")" && pwd)/test-key.pem"; cmd="${1:-}"; shift || true
val() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "${2:-}"; return; }; shift; done; }
pub() { openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr -d '\n'; }
case "$cmd" in
  pubkey) printf '{"pub_b64":"%s"}\n' "$(pub)" ;;
  sign) payload="v1|$(val --pipeline "$@")|$(val --stage "$@")|$(val --git-sha "$@")|$(val --quote-sha "$@")|$(val --nonce "$@")|$(val --ts "$@")"
        printf '{"payload":"%s","sig_b64":"%s","pub_b64":"%s"}\n' "$payload" "$(printf '%s' "$payload" | openssl dgst -sha256 -sign "$KEY" | base64 | tr -d '\n')" "$(pub)" ;;
  *) exit 2 ;;
esac
HEOF
  chmod 755 "$w/helper/bones-owner-auth-test"
  { openssl pkey -in "$w/helper/test-key.pem" -pubout 2>/dev/null
    printf 'owner-mode: selftest\nowner-label: selftest\nhelper-path: %s\nhelper-sha256: %s\nhelper-codesign: none\nselftest-root: %s\n' \
      "$w/helper/bones-owner-auth-test" "$(sha_of "$w/helper/bones-owner-auth-test")" "$w"; } > "$w/project/.bones/owner.pub"
  selftest_set_stage "$w/project" 8
  printf '%s\n' "$w"
}
selftest_smoke_record() { # <file> <PASS|FAIL>
  printf 'smoke-target: https://example.test/health (GET, expect 200)\nsmoke-result: %s\nsmoke-at: %s\n' "$2" \
    "$(date -u -v+1M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)" > "$1"
}
guard_rc() { # guard_rc <json> -> prints the guard's exit code
  local rc=0; "$BASH_BIN" "$GUARD_SH" >/dev/null 2>&1 <<<"$1" || rc=$?; printf '%s\n' "$rc"
}

selftest_promote_split() {
  local w p rc out
  w="$(selftest_owner_workspace)"; p="$w/project"
  ps_fail() { printf 'promote-split FAIL step %s: %s\n' "$1" "$2"; rm -rf "$w"; }
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 2 ] || { ps_fail 1 "deploy-shaped command not blocked before 8a"; return 1; }
  mv "$p/.bones/owner.pub" "$w/owner.pub.bak"
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: promote without an owner key" >/dev/null 2>&1); then ps_fail 2 "approve at 8 succeeded without an owner key"; return 1; fi
  [ -f "$p/.bones/gates/8-promote.authorized" ] && { ps_fail 2 "authorized file written without a key"; return 1; }
  mv "$w/owner.pub.bak" "$p/.bones/owner.pub"
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: promote authorized with the selftest key" >/dev/null 2>&1) || { ps_fail 3 "approve with a valid owner token failed"; return 1; }
  [ -f "$p/.bones/gates/8-promote.authorized" ] || { ps_fail 3 "no 8-promote.authorized written"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 0 ] || { ps_fail 4 "guard still blocks after a valid 8a"; return 1; }
  printf 'uncommitted payload\n' > "$p/dirty.txt"
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 2 ] || { ps_fail 4b "guard lifted with uncommitted changes in the tree (F-02)"; return 1; }
  mv "$p/dirty.txt" "$w/dirty.txt"
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 0 ] || { ps_fail 4b "guard did not re-lift after the tree was clean again"; return 1; }
  ( cd "$p" && git -c user.email=s@t -c user.name=selftest commit -q --allow-empty -m more ) >/dev/null 2>&1
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 2 ] || { ps_fail 5 "guard did not block after HEAD moved"; return 1; }
  selftest_smoke_record "$w/smoke-good.md" PASS
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" confirm -e "$w/smoke-good.md" "selftest: smoke after HEAD moved" >/dev/null 2>&1); then ps_fail 5 "confirm accepted a stale authorization"; return 1; fi
  ( cd "$p" && git reset -q --hard HEAD~1 ) >/dev/null 2>&1
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" next >/dev/null 2>&1); then ps_fail 6 "next advanced without 8b"; return 1; fi
  selftest_smoke_record "$w/smoke-bad.md" FAIL
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" confirm -e "$w/smoke-bad.md" "selftest: failing smoke record" >/dev/null 2>&1); then ps_fail 7 "confirm accepted a FAIL smoke record"; return 1; fi
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" confirm -e "$w/smoke-good.md" "selftest: production smoke green at example.test" >/dev/null 2>&1) || { ps_fail 7 "confirm refused a valid smoke record"; return 1; }
  [ -f "$p/.bones/gates/8-promote.ok" ] || { ps_fail 7 "no 8-promote.ok after confirm"; return 1; }
  [ -f "$p/.bones/operate-due" ] && { ps_fail 8 "operate clock started before next"; return 1; }
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" next >/dev/null 2>&1) || { ps_fail 9 "next refused after 8b"; return 1; }
  [ "$(json_get "$p/.bones/state.json" stage)" = "9" ] || { ps_fail 9 "stage is not 9 after next"; return 1; }
  [ -f "$p/.bones/operate-due" ] || { ps_fail 9 "operate clock not started after next from 8"; return 1; }
  rm -rf "$w"
  printf 'promote-split PASS (10 steps: blocked → no-key refused → authorized → allowed → dirty tree blocked → HEAD moved: blocked + confirm refused → next refused → FAIL smoke refused → confirmed → next + clock)\n'
}

selftest_contracts() {
  local w p n=0 fails=0 c f rc
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-contracts.XXXXXX")"; mkdir -p "$w/project/.bones/gates"; p="$w/project"
  selftest_sign_spec "$p"
  local sha; sha="$(sha_of "$p/spec-fixture.html")"
  run_c() { # run_c <contract> <expected rc 0|1> <files...>
    local c="$1" want="$2"; shift 2; local rc=0
    BONES_DIR="$p/.bones" "$BASH_BIN" "$CONTRACTS_DIR/$c.sh" "$@" >/dev/null 2>&1 || rc=$?
    n=$((n+1))
    if [ "$want" -eq 0 ] && [ "$rc" -ne 0 ]; then printf 'contracts FAIL %s rejected an accept fixture: %s\n' "$c" "$*"; fails=$((fails+1)); fi
    if [ "$want" -eq 1 ] && [ "$rc" -eq 0 ]; then printf 'contracts FAIL %s accepted a reject fixture: %s\n' "$c" "$*"; fails=$((fails+1)); fi
  }
  for c in council review smoke; do
    for f in "$FIXTURES/$c"/accept-*.md; do run_c "$c" 0 "$f"; done
    for f in "$FIXTURES/$c"/reject-*.md; do run_c "$c" 1 "$f"; done
  done
  for c in plan conformance; do
    for f in "$FIXTURES/$c"/accept-*.md; do sed "s/@SPEC_SHA@/$sha/" "$f" > "$w/$(basename "$f")"; run_c "$c" 0 "$w/$(basename "$f")"; done
    for f in "$FIXTURES/$c"/reject-*.md; do sed "s/@SPEC_SHA@/$sha/" "$f" > "$w/$(basename "$f")"; run_c "$c" 1 "$w/$(basename "$f")"; done
  done
  run_c staging 0 "$FIXTURES/staging/accept-1.md" "$FIXTURES/staging/screenshot-accept.png"
  run_c staging 1 "$FIXTURES/staging/reject-1.md" "$FIXTURES/staging/screenshot-accept.png"
  run_c staging 1 "$FIXTURES/staging/reject-2.md" "$FIXTURES/staging/screenshot-accept.png"
  run_c staging 1 "$FIXTURES/staging/accept-1.md" "$FIXTURES/staging/not-an-image.png"
  run_c staging 1 "$FIXTURES/staging/accept-1.md" "$FIXTURES/staging/screenshot-black-100.png"
  run_c staging 1 "$FIXTURES/staging/accept-1.md"
  # smoke-at must be after the 8a timestamp when SMOKE_AFTER is given
  local late; late="$w/smoke-late.md"; printf 'smoke-target: https://example.test/health\nsmoke-result: PASS\nsmoke-at: 2020-01-01T00:00:00Z\n' > "$late"
  n=$((n+1)); if SMOKE_AFTER="2026-01-01T00:00:00Z" BONES_DIR="$p/.bones" "$BASH_BIN" "$CONTRACTS_DIR/smoke.sh" "$late" >/dev/null 2>&1; then printf 'contracts FAIL smoke accepted a record dated before the authorization\n'; fails=$((fails+1)); fi
  rm -rf "$w"
  [ "$fails" -eq 0 ] || { printf 'contracts FAIL %s of %s fixtures misjudged\n' "$fails" "$n"; return 1; }
  printf 'contracts PASS (6 validators, %s fixtures)\n' "$n"
}

selftest_hollow() {
  local w p n=0 fails=0 c f rc sha
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-hollow.XXXXXX")"; mkdir -p "$w/project/.bones/gates"; p="$w/project"
  selftest_sign_spec "$p"; sha="$(sha_of "$p/spec-fixture.html")"
  for c in council plan conformance review smoke; do
    for f in "$FIXTURES/$c"/hollow-*.md; do
      [ -f "$f" ] || continue
      sed "s/@SPEC_SHA@/$sha/" "$f" > "$w/$c-$(basename "$f")"; n=$((n+1)); rc=0
      BONES_DIR="$p/.bones" "$BASH_BIN" "$CONTRACTS_DIR/$c.sh" "$w/$c-$(basename "$f")" >/dev/null 2>&1 || rc=$?
      [ "$rc" -ne 0 ] || { printf 'hollow FAIL %s accepted hollow fixture %s\n' "$c" "$(basename "$f")"; fails=$((fails+1)); }
    done
  done
  n=$((n+1)); if BONES_DIR="$p/.bones" "$BASH_BIN" "$CONTRACTS_DIR/staging.sh" "$FIXTURES/staging/hollow-1.md" "$FIXTURES/staging/screenshot-black-640.png" >/dev/null 2>&1; then printf 'hollow FAIL staging accepted an all-black screenshot record\n'; fails=$((fails+1)); fi
  rm -rf "$w"
  [ "$fails" -eq 0 ] || { printf 'hollow FAIL %s of %s hollow fixtures accepted\n' "$fails" "$n"; return 1; }
  printf 'hollow PASS (%s syntactically valid but hollow artifacts refused)\n' "$n"
}

selftest_plan_artifact() {
  local w p out rc fake_loop argv
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-plan.XXXXXX")"; mkdir -p "$w/project"; p="$w/project"
  "$SELF" init -t "$p" -n selftest -c true -S >/dev/null 2>&1; selftest_set_stage "$p" 5; selftest_sign_spec "$p"
  fake_loop="$w/loop.sh"; argv="$w/argv.log"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\nexit 0\n' "$argv" > "$fake_loop"; chmod +x "$fake_loop"
  out="$(cd "$p" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c true -s spec-fixture.html 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'without a pinned plan' || { printf 'plan-artifact FAIL build did not refuse without a plan (rc=%s)\n' "$rc"; rm -rf "$w"; return 1; }
  local sha; sha="$(sha_of "$p/spec-fixture.html")"
  sed "s/@SPEC_SHA@/$sha/" "$FIXTURES/plan/reject-1.md" > "$w/plan-bad.md"
  if (cd "$p" && BONES_LLM=off BONES_GUARD_SH="$GUARD_SH" "$SELF" plan -e "$w/plan-bad.md" "selftest: plan missing an acceptance id" >/dev/null 2>&1); then printf 'plan-artifact FAIL plan accepted a plan whose acceptance map misses an id\n'; rm -rf "$w"; return 1; fi
  [ -f "$p/.bones/gates/5-build-loop.plan" ] && { printf 'plan-artifact FAIL a refused plan was pinned\n'; rm -rf "$w"; return 1; }
  sed "s/@SPEC_SHA@/$sha/" "$FIXTURES/plan/accept-1.md" > "$w/plan.md"
  (cd "$p" && BONES_LLM=off BONES_GUARD_SH="$GUARD_SH" "$SELF" plan -e "$w/plan.md" "selftest: fixture plan with full acceptance map" >/dev/null 2>&1) || { printf 'plan-artifact FAIL a valid plan was refused\n'; rm -rf "$w"; return 1; }
  [ -f "$p/.bones/gates/5-build-loop.plan" ] || { printf 'plan-artifact FAIL valid plan not pinned\n'; rm -rf "$w"; return 1; }
  out="$(cd "$p" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c true -s spec-fixture.html 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'plan-artifact FAIL build with a pinned plan failed (rc=%s): %s\n' "$rc" "$(printf '%s' "$out" | tail -1)"; rm -rf "$w"; return 1; }
  grep -qx -- '-P' "$argv" && grep -qx -- "$w/plan.md" "$argv" || { printf 'plan-artifact FAIL loop.sh did not receive -P <plan>\n'; rm -rf "$w"; return 1; }
  grep -q '^plan: ' "$p/.bones/gates/5-build-loop.ok" || { printf 'plan-artifact FAIL build gate record lacks the plan line\n'; rm -rf "$w"; return 1; }
  printf 'tampered\n' >> "$w/plan.md"
  out="$(cd "$p" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c true -s spec-fixture.html 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'changed after pinning' || { printf 'plan-artifact FAIL build accepted a plan edited after pinning\n'; rm -rf "$w"; return 1; }
  rm -rf "$w"; printf 'plan-artifact PASS (build refused without plan; bad map refused; valid plan pinned; -P passed to loop; build record carries plan; post-pin edit refused)\n'
}

selftest_owner_auth() {
  local w p head tok rc
  w="$(selftest_owner_workspace)"; p="$w/project"
  head="$(git -C "$p" rev-parse HEAD)"
  mint() { "$w/helper/bones-owner-auth-test" sign --pipeline "$1" --stage "$2" --git-sha "$3" --quote-sha q --nonce "$4" --ts "$5"; }
  oa_fail() { printf 'owner-auth FAIL %s\n' "$1"; rm -rf "$w"; }
  tok="$(mint selftest 8 "$head" n1 "$(date -u +%s)")"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n1 mint ) >/dev/null 2>&1 || { oa_fail "a valid token was refused"; return 1; }
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n1 mint ) >/dev/null 2>&1 && { oa_fail "replay of a consumed nonce accepted"; return 1; }
  tok="$(mint other-run 8 "$head" n2 "$(date -u +%s)")"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n2 mint ) >/dev/null 2>&1 && { oa_fail "token for another pipeline accepted"; return 1; }
  tok="$(mint selftest 3 "$head" n3 "$(date -u +%s)")"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n3 mint ) >/dev/null 2>&1 && { oa_fail "token for another stage accepted"; return 1; }
  tok="$(mint selftest 8 deadbeef n4 "$(date -u +%s)")"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n4 mint ) >/dev/null 2>&1 && { oa_fail "token bound to another HEAD accepted"; return 1; }
  tok="$(mint selftest 8 "$head" n5 $(( $(date -u +%s) - 1000 )))"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n5 mint ) >/dev/null 2>&1 && { oa_fail "expired token accepted"; return 1; }
  tok="$(mint selftest 8 "$head" n6 "$(date -u +%s)" | sed 's/"sig_b64":"A/"sig_b64":"B/; s/"sig_b64":"M/"sig_b64":"N/')"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$head" n6 mint ) >/dev/null 2>&1 && { oa_fail "tampered signature accepted"; return 1; }
  if (cd "$p" && BONES_OWNER_AUTH_BIN=/tmp/fake BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: env override attempt" >/dev/null 2>&1); then oa_fail "env override BONES_OWNER_AUTH_BIN was honored"; return 1; fi
  [ -f "$p/.bones/gates/8-promote.authorized" ] && { oa_fail "authorized written under an env override"; return 1; }
  mv "$w/helper/bones-owner-auth-test" "$w/helper/gone"
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: helper missing" >/dev/null 2>&1); then oa_fail "approve succeeded with the helper missing"; return 1; fi
  mv "$w/helper/gone" "$w/helper/bones-owner-auth-test"
  rm -rf "$w"; printf 'owner-auth PASS (valid accepted; replay, other pipeline, other stage, other HEAD, expired, tampered sig, env override, missing helper all refused)\n'
}

selftest_helper_integrity() {
  local w p tok
  w="$(selftest_owner_workspace)"; p="$w/project"
  printf '\n# patched\n' >> "$w/helper/bones-owner-auth-test"
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: patched helper" >/dev/null 2>&1); then printf 'helper-integrity FAIL a patched helper authorized\n'; rm -rf "$w"; return 1; fi
  [ -f "$p/.bones/gates/8-promote.authorized" ] && { printf 'helper-integrity FAIL authorized file written by a patched helper\n'; rm -rf "$w"; return 1; }
  # restore exact bytes by re-pinning the hash of the patched helper would be cheating — re-create the helper instead
  rm -rf "$w"; w="$(selftest_owner_workspace)"; p="$w/project"
  cp "$w/helper/bones-owner-auth-test" "$w/helper/swapped"; printf '#!/usr/bin/env bash\nprintf "{\\"payload\\":\\"v1|selftest|8|x|q|n|1\\",\\"sig_b64\\":\\"AA==\\",\\"pub_b64\\":\\"AA==\\"}\\n"\n' > "$w/helper/bones-owner-auth-test"
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: swapped helper" >/dev/null 2>&1); then printf 'helper-integrity FAIL a swapped helper authorized\n'; rm -rf "$w"; return 1; fi
  cp "$w/helper/swapped" "$w/helper/bones-owner-auth-test"
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: genuine helper after swap attempt" >/dev/null 2>&1) || { printf 'helper-integrity FAIL genuine helper refused after restore\n'; rm -rf "$w"; return 1; }
  tok="$(sed -n 's/^owner-token:[[:space:]]*//p' "$p/.bones/gates/8-promote.authorized" | head -1)"
  local nonce; nonce="$(printf '%s' "$tok" | jq -r .payload | cut -d'|' -f6)"
  ( BONES_DIR="$p/.bones" owner_token_verify "$tok" selftest 8 "$(git -C "$p" rev-parse HEAD)" "$nonce" mint ) >/dev/null 2>&1 && { printf 'helper-integrity FAIL a consumed 8a token was accepted again (replay)\n'; rm -rf "$w"; return 1; }
  rm -rf "$w"; printf 'helper-integrity PASS (patched helper refused; swapped helper refused; genuine helper authorizes; consumed token replay refused)\n'
}

selftest_staleness() {
  local w p out rc fake_loop
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-stale.XXXXXX")"; mkdir -p "$w/project"; p="$w/project"
  "$SELF" init -t "$p" -n selftest -c true -S >/dev/null 2>&1; selftest_set_stage "$p" 5; selftest_pin_plan "$p"
  printf '<!-- amended and re-signed -->\n' >> "$p/spec-fixture.html"
  sed -E "s/\(sha256:[a-f0-9]+\)/(sha256:$(sha_of "$p/spec-fixture.html"))/" "$p/.bones/gates/3-spec.ok" > "$p/.bones/gates/3-spec.ok.next" && mv "$p/.bones/gates/3-spec.ok.next" "$p/.bones/gates/3-spec.ok"
  fake_loop="$w/loop.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_loop"; chmod +x "$fake_loop"
  out="$(cd "$p" && BONES_LOOP_SH="$fake_loop" BONES_GUARD_SH="$GUARD_SH" "$SELF" build -c true -s spec-fixture.html 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] || ! printf '%s' "$out" | grep -q 'different spec revision'; then printf 'staleness FAIL build did not refuse a plan pinned for a superseded spec (rc=%s: %s)\n' "$rc" "$(printf '%s' "$out" | tail -1)"; rm -rf "$w"; return 1; fi
  rm -rf "$w"
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-degraded.XXXXXX")"; mkdir -p "$w/project"; p="$w/project"
  "$SELF" init -t "$p" -n selftest -c true -S >/dev/null 2>&1
  { openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkey -pubout 2>/dev/null; printf 'owner-mode: passphrase\nowner-label: x\nhelper-sha256: 0\nhelper-codesign: none\n'; } > "$p/.bones/owner.pub"
  out="$(cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" status 2>&1)"; printf '%s' "$out" | grep -q 'DEGRADED' || { printf 'staleness FAIL status does not flag passphrase mode as DEGRADED\n'; rm -rf "$w"; return 1; }
  out="$(cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" doctor 2>&1)"; printf '%s' "$out" | grep -q 'DEGRADED' || { printf 'staleness FAIL doctor does not flag passphrase mode as DEGRADED\n'; rm -rf "$w"; return 1; }
  rm -rf "$w"
  w="$(selftest_owner_workspace)"; p="$w/project"
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: authorize then move HEAD" >/dev/null 2>&1) || { printf 'staleness FAIL could not authorize\n'; rm -rf "$w"; return 1; }
  ( cd "$p" && git -c user.email=s@t -c user.name=selftest commit -q --allow-empty -m more ) >/dev/null 2>&1
  [ "$(guard_rc "$(guard_json Bash "$p" "vercel --prod")")" = 2 ] || { printf 'staleness FAIL guard allowed a deploy after HEAD moved\n'; rm -rf "$w"; return 1; }
  selftest_smoke_record "$w/smoke.md" PASS
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" confirm -e "$w/smoke.md" "selftest: smoke after HEAD moved" >/dev/null 2>&1); then printf 'staleness FAIL confirm accepted a stale 8a\n'; rm -rf "$w"; return 1; fi
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" next >/dev/null 2>&1); then printf 'staleness FAIL next advanced on a stale 8a\n'; rm -rf "$w"; return 1; fi
  rm -rf "$w"; printf 'staleness PASS (plan for a superseded spec refused at build; passphrase DEGRADED in status + doctor; HEAD moved after 8a → guard blocks, confirm and next refused)\n'
}

selftest_unsealed_status() {
  local w p
  w="$(selftest_workspace)"; p="$w/project"; rm -f "$p/.bones/state.sha256"
  [ "$(guard_rc "$(guard_json Bash "$p" "bash $SELF status")")" = 0 ] || { printf 'unsealed-status FAIL guard blocked bones status on an unsealed run\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "cd $p && bash $SELF doctor")")" = 0 ] || { printf 'unsealed-status FAIL guard blocked bones doctor on an unsealed run\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "ls")")" = 2 ] || { printf 'unsealed-status FAIL guard allowed ls on an unsealed run\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 2 ] || { printf 'unsealed-status FAIL guard allowed a push on an unsealed run\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "bash $SELF status; git push origin main")")" = 2 ] || { printf 'unsealed-status FAIL guard allowed a chained push behind status\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "cd /tmp/\$(touch /tmp/pwned) && bash $SELF status")")" = 2 ] || { printf 'unsealed-status FAIL guard allowed command substitution in the cd clause (F-01)\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "\`touch /tmp/pwned\` bash $SELF status")")" = 2 ] || { printf 'unsealed-status FAIL guard allowed a backtick prefix (F-01)\n'; rm -rf "$w"; return 1; }
  [ "$(guard_rc "$(guard_json Bash "$p" "bash $SELF status > /tmp/x")")" = 2 ] || { printf 'unsealed-status FAIL guard allowed a redirect on the carve-out\n'; rm -rf "$w"; return 1; }
  rm -rf "$w"; printf 'unsealed-status PASS (status/doctor allowed to self-heal; ls, push, chained commands, command substitution, backticks and redirects still blocked)\n'
}

# upgrade (2.0): schema-null (sealed and unsealed) and schema-2 fixtures at stages 3, 8, 9 keep working.
selftest_upgrade_fixtures() {
  local w p schema seal stage n rc out fails=0 cases=0
  for schema in null 2; do for seal in 0 1; do for stage in 3 8 9; do
    [ "$schema" = 2 ] && [ "$seal" = 0 ] && continue
    cases=$((cases+1))
    w="$(mktemp -d "${TMPDIR:-/tmp}/bones-fixture.XXXXXX")"; mkdir -p "$w/project/.bones/gates"; p="$(cd "$w/project" && pwd)"
    if [ "$schema" = null ]; then
      printf '{\n  "name": "fixture",\n  "target": "%s",\n  "stage": %s,\n  "created": "%s",\n  "updated": "%s",\n  "strict": false\n}\n' "$(json_esc "$p")" "$stage" "$(now)" "$(now)" > "$p/.bones/state.json"
    else
      printf '{\n  "schema_version": 2,\n  "name": "fixture",\n  "target": "%s",\n  "stage": %s,\n  "created": "%s",\n  "updated": "%s",\n  "strict": false\n}\n' "$(json_esc "$p")" "$stage" "$(now)" "$(now)" > "$p/.bones/state.json"
    fi
    [ "$seal" = 1 ] && printf '%s\n' "$(sha_of "$p/.bones/state.json")" > "$p/.bones/state.sha256"
    printf '%s\n' "$(sha_of "$GUARD_SH")" > "$p/.bones/guard.sha256"
    printf 'true\n' > "$p/.bones/acceptance.cmd"; printf 'fixture journal\n' > "$p/.bones/journal.log"
    n=1; while [ "$n" -lt "$stage" ]; do printf '%s | %s | fixture | pre-2.0 record\n' "$(now)" "${STAGE_KEYS[$((n-1))]}" > "$p/.bones/gates/$n-${STAGE_KEYS[$((n-1))]}.ok"; n=$((n+1)); done
    out="$(cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" status 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -q "stage: $stage/10"; then printf 'upgrade FAIL schema=%s seal=%s stage=%s: status rc=%s (%s)\n' "$schema" "$seal" "$stage" "$rc" "$(printf '%s' "$out" | tail -1)"; fails=$((fails+1)); rm -rf "$w"; continue; fi
    [ "$(json_get "$p/.bones/state.json" schema_version)" = "$STATE_SCHEMA" ] || { printf 'upgrade FAIL schema=%s seal=%s stage=%s: schema not migrated in place\n' "$schema" "$seal" "$stage"; fails=$((fails+1)); }
    n=1; while [ "$n" -lt "$stage" ]; do [ -f "$p/.bones/gates/$n-${STAGE_KEYS[$((n-1))]}.ok" ] || { printf 'upgrade FAIL gate %s lost\n' "$n"; fails=$((fails+1)); }; n=$((n+1)); done
    out="$(cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" doctor 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then printf 'upgrade FAIL schema=%s seal=%s stage=%s: doctor rc=%s (%s)\n' "$schema" "$seal" "$stage" "$rc" "$(printf '%s' "$out" | grep -E 'WARN|FAIL' | head -1)"; fails=$((fails+1)); fi
    if [ "$stage" = 9 ] && ! printf '%s' "$out" | grep -q 'promoted pre-2.0'; then printf 'upgrade FAIL stage-9 pre-2.0 run not labeled "promoted pre-2.0"\n'; fails=$((fails+1)); fi
    rm -rf "$w"
  done; done; done
  [ "$fails" -eq 0 ] || { printf 'upgrade FAIL %s problem(s) across %s fixtures\n' "$fails" "$cases"; return 1; }
  printf 'upgrade PASS (%s fixtures: schema null unsealed/sealed + schema 2, stages 3/8/9; gates preserved; pre-2.0 promote labeled)\n' "$cases"
}

selftest_byp_18() { # out-of-tree: cd .. and act on the run via paths / -C must still be guarded
  local w p rc=0 probe out probe_rc
  w="$(selftest_owner_workspace)"; p="$w/project"
  for probe in \
    "cd .. && git -C project push origin main" \
    "cd $w && git -C project push origin main" \
    "cd .. && printf 'x' > project/.bones/gates/8-promote.ok" \
    "cd .. && rm project/.bones/used-nonces" \
    "cd $w && make -C project deploy" \
    "git -C $p push origin main"
  do
    probe_rc=0
    out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Bash "$p" "$probe")")" || probe_rc=$?
    [ "$probe_rc" -eq 2 ] || { printf 'BYP-18 FAIL expected BLOCK for %s, got rc=%s output=%s\n' "$probe" "$probe_rc" "$out"; rc=1; }
  done
  probe_rc=0; out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Bash "$w" "git -C project push origin main")")" || probe_rc=$?
  [ "$probe_rc" -eq 2 ] || { printf 'BYP-18 FAIL expected BLOCK for out-of-tree git -C push, got rc=%s\n' "$probe_rc"; rc=1; }
  probe_rc=0; out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Bash "$w" "printf 'x' > project/.bones/owner.pub")")" || probe_rc=$?
  [ "$probe_rc" -eq 2 ] || { printf 'BYP-18 FAIL expected BLOCK for out-of-tree .bones write, got rc=%s\n' "$probe_rc"; rc=1; }
  rm -rf "$w"
  [ "$rc" -eq 0 ] && printf 'BYP-18 BLOCK\n'
  return "$rc"
}
selftest_byp_19() { # contract tamper: an edited contract cannot judge; the installed skill is read-only inside a run
  local w p rc=0 out probe probe_rc
  w="$(selftest_owner_workspace)"; p="$w/project"
  [ -f "$p/.bones/contracts.sha256" ] || { printf 'BYP-19 FAIL contracts pin not recorded at init\n'; rm -rf "$w"; return 1; }
  for probe in "printf 'exit 0' > $HOME/.claude/skills/horvitz-pipeline/contracts/smoke.sh" "cp /tmp/x $HOME/.claude/skills/horvitz-pipeline/scripts/bones.sh" "sed -i '' 's/x/y/' ~/.claude/skills/ship-pipeline/scripts/loop.sh"; do
    probe_rc=0; out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Bash "$p" "$probe")")" || probe_rc=$?
    [ "$probe_rc" -eq 2 ] || { printf 'BYP-19 FAIL expected BLOCK for %s, got rc=%s\n' "$probe" "$probe_rc"; rc=1; }
  done
  probe_rc=0; out="$("$BASH_BIN" "$GUARD_SH" 2>&1 <<<"$(guard_json Write "$p" "" "$HOME/.claude/skills/horvitz-pipeline/contracts/smoke.sh")")" || probe_rc=$?
  [ "$probe_rc" -eq 2 ] || { printf 'BYP-19 FAIL Write tool edit of an installed contract was not blocked (rc=%s)\n' "$probe_rc"; rc=1; }
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: authorize for BYP-19" >/dev/null 2>&1) || { printf 'BYP-19 FAIL could not authorize\n'; rm -rf "$w"; return 1; }
  selftest_smoke_record "$w/smoke.md" PASS
  sed -E 's/^(smoke\.sh) [0-9a-f]+$/\1 0000000000000000000000000000000000000000000000000000000000000000/' "$p/.bones/contracts.sha256" > "$p/.bones/contracts.sha256.next" && mv "$p/.bones/contracts.sha256.next" "$p/.bones/contracts.sha256"
  out="$(cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" confirm -e "$w/smoke.md" "selftest: smoke with a tampered contract pin" 2>&1)"; probe_rc=$?
  if [ "$probe_rc" -eq 0 ] || ! printf '%s' "$out" | grep -q 'CHANGED since it was pinned'; then printf 'BYP-19 FAIL confirm accepted a contract that no longer matches its pin (rc=%s)\n' "$probe_rc"; rc=1; fi
  [ -f "$p/.bones/gates/8-promote.ok" ] && { printf 'BYP-19 FAIL 8b written under a tampered contract pin\n'; rc=1; }
  rm -rf "$w"
  [ "$rc" -eq 0 ] && printf 'BYP-19 BLOCK\n'
  return "$rc"
}
selftest_byp_15() {
  local w p rc=0 tok
  w="$(selftest_owner_workspace)"; p="$w/project"
  printf '%s | promote | owner-8a | forged\nowner-quote: "x"\nowner-token: {"payload":"v1|selftest|8|%s|q|n|1","sig_b64":"AAAA","pub_b64":"AAAA"}\nauthorized-at: %s\nauthorized-head: %s\n' "$(now)" "$(git -C "$p" rev-parse HEAD)" "$(now)" "$(git -C "$p" rev-parse HEAD)" > "$p/.bones/gates/8-promote.authorized"
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 2 ] || { printf 'BYP-15 FAIL forged authorization lifted the guard\n'; rm -rf "$w"; return 1; }
  rm -f "$p/.bones/gates/8-promote.authorized"
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: valid 8a for BYP-15" >/dev/null 2>&1) || { printf 'BYP-15 FAIL could not authorize\n'; rm -rf "$w"; return 1; }
  ( cd "$p" && git -c user.email=s@t -c user.name=selftest commit -q --allow-empty -m more ) >/dev/null 2>&1
  [ "$(guard_rc "$(guard_json Bash "$p" "git push origin main")")" = 2 ] || { printf 'BYP-15 FAIL stale authorization (HEAD moved) lifted the guard\n'; rm -rf "$w"; return 1; }
  rm -rf "$w"; printf 'BYP-15 BLOCK\n'
}
selftest_byp_16() {
  local w p
  w="$(selftest_workspace)"; p="$w/project"; selftest_set_stage "$p" 8
  ( cd "$p" && git init -q && git -c user.email=s@t -c user.name=selftest commit -q --allow-empty -m init ) >/dev/null 2>&1
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" script -q /dev/null "$BASH_BIN" "$SELF" approve -q "go" "selftest: pty trick" </dev/null >/dev/null 2>&1) || true
  if [ -f "$p/.bones/gates/8-promote.authorized" ] || [ -f "$p/.bones/gates/8-promote.ok" ]; then printf 'BYP-16 FAIL a pseudo-TTY opened the promote gate without an owner token\n'; rm -rf "$w"; return 1; fi
  rm -rf "$w"; printf 'BYP-16 BLOCK\n'
}
selftest_byp_17() {
  local w p
  w="$(selftest_owner_workspace)"; p="$w/project"
  [ "$(guard_rc "$(guard_json Bash "$p" "vercel --prod")")" = 2 ] || { printf 'BYP-17 FAIL deploy allowed at stage 8 before 8a\n'; rm -rf "$w"; return 1; }
  (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" approve -q "go" "selftest: 8a for BYP-17" >/dev/null 2>&1) || { printf 'BYP-17 FAIL could not authorize\n'; rm -rf "$w"; return 1; }
  if (cd "$p" && BONES_GUARD_SH="$GUARD_SH" "$SELF" next >/dev/null 2>&1); then printf 'BYP-17 FAIL next advanced after 8a but before 8b\n'; rm -rf "$w"; return 1; fi
  rm -rf "$w"; printf 'BYP-17 BLOCK\n'
}

cmd_artifacts() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  require_stage >/dev/null
  local target; target="$(state_get target)"
  printf '== Horvitz artifacts: %s ==\n' "$(state_get name)"
  local any=0 gf st ln path want status
  for gf in "$BONES_DIR"/gates/*.ok "$BONES_DIR"/gates/5-build-loop.plan "$BONES_DIR"/gates/8-promote.authorized; do
    [ -f "$gf" ] || continue
    st="$(basename "$gf")"
    while IFS= read -r ln; do
      path="$(printf '%s' "$ln" | sed -E 's/^(evidence|plan): (.*) \(sha256:[a-f0-9-]+\)$/\2/')"
      want="$(printf '%s' "$ln" | sed -E 's/^.*\(sha256:([a-f0-9-]+)\)$/\1/')"
      path="$(resolve_evidence "$path" "$target")"
      if [ ! -e "$path" ]; then status=MISSING
      elif [ "$(sha_of "$path")" = "$want" ]; then status=VERIFIED
      else status=CHANGED; fi
      printf '  %-22s %-9s %s\n' "$st" "$status" "$path"
      any=1
    done < <(grep -hE '^(evidence|plan): ' "$gf")
  done
  [ "$any" -eq 1 ] || printf '  (no pinned artifacts yet)\n'
}

selftest_thin() {
  grep -q "STAGE_""BRIEF" "$SELF" && { printf 'thin FAIL the stage-policy array is still present in bones.sh\n'; return 1; }
  local w out
  w="$(mktemp -d "${TMPDIR:-/tmp}/bones-thin.XXXXXX")"; mkdir -p "$w/project" "$w/skills/specify"
  "$SELF" init -t "$w/project" -n selftest -c true -S >/dev/null 2>&1
  selftest_set_stage "$w/project" 3
  printf -- '---\nname: specify\ndescription: x\n---\n## Produces\nSENTINEL_PRODUCES_XYZZY marks the spec artifact for this run.\n## Procedure\nx\n' > "$w/skills/specify/SKILL.md"
  out="$(cd "$w/project" && BONES_SKILLS_DIR="$w/skills" BONES_GUARD_SH="$GUARD_SH" "$SELF" status 2>&1)"
  printf '%s' "$out" | grep -q 'SENTINEL_PRODUCES_XYZZY' || { printf 'thin FAIL status at stage 3 did not read the specify skill Produces block\n'; rm -rf "$w"; return 1; }
  selftest_set_stage "$w/project" 4
  printf 'evidence file\n' > "$w/project/ev.txt"
  printf '%s | spec | owner | selftest\nevidence: %s (sha256:%s)\n' "$(now)" "$w/project/ev.txt" "$(sha_of "$w/project/ev.txt")" > "$w/project/.bones/gates/3-spec.ok"
  out="$(cd "$w/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" artifacts 2>&1)"
  printf '%s' "$out" | grep -q 'VERIFIED' || { printf 'thin FAIL artifacts did not report VERIFIED for an intact evidence file\n'; rm -rf "$w"; return 1; }
  printf 'mutated\n' >> "$w/project/ev.txt"
  out="$(cd "$w/project" && BONES_GUARD_SH="$GUARD_SH" "$SELF" artifacts 2>&1)"
  printf '%s' "$out" | grep -q 'CHANGED' || { printf 'thin FAIL artifacts did not report CHANGED after the evidence file was mutated\n'; rm -rf "$w"; return 1; }
  rm -rf "$w"
  printf 'thin PASS (stage-policy array removed from the orchestrator; status reads the owning skill Produces; artifacts reports VERIFIED/CHANGED)\n'
}

selftest_skills() {
  local base rc=0 s f h rows
  base="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
  for s in specify goalify planify implementify reviewify; do
    f="$base/$s/SKILL.md"
    [ -f "$f" ] || { printf 'skills FAIL missing %s\n' "$f"; rc=1; continue; }
    grep -qE '^name:' "$f" && grep -qE '^description:' "$f" || { printf 'skills FAIL %s front-matter\n' "$s"; rc=1; }
    for h in '^## Produces' '^## Procedure' '^## Activates'; do grep -qE "$h" "$f" || { printf 'skills FAIL %s lacks %s\n' "$s" "$h"; rc=1; }; done
  done
  f="$base/README.md"
  if [ ! -f "$f" ]; then printf 'skills FAIL skills/README.md missing\n'; rc=1
  else
    grep -qiE '\|[[:space:]]*activates' "$f" || { printf 'skills FAIL README has no activation column\n'; rc=1; }
    rows="$(grep -cE '^\| \*\*[a-z]+\*\* \|' "$f")"
    [ "$rows" -ge 17 ] || { printf 'skills FAIL README lists %s skill rows, need >=17\n' "$rows"; rc=1; }
  fi
  [ "$rc" -eq 0 ] && printf 'skills PASS (five stage-owning skills with Produces/Procedure/Activates; README lists 17 with an activation column)\n'
  return "$rc"
}

cmd_selftest() {
  local only="" failures=0 id fn
  if [ "${1:-}" = "--only" ]; then only="${2:-}"; [ -n "$only" ] || die "selftest --only needs a case name"; fi
  local corpus="${BONES_SELFTEST_CORPUS:-$SCRIPT_DIR/../selftest/corpus.txt}"
  if [ "$only" = "" ]; then
    [ -f "$corpus" ] || die "canonical bypass corpus missing: $corpus"
    for id in BYP-01 BYP-02 BYP-03 BYP-04 BYP-05 BYP-06 BYP-07 BYP-08 BYP-09 BYP-10 BYP-14 BYP-15 BYP-16 BYP-17 BYP-18 BYP-19; do
      if ! grep -qE "^${id}[[:space:]]+BLOCK([[:space:]]|$)" "$corpus"; then
        printf '%s FAIL corpus missing required BLOCK marker\n' "$id"
        failures=$((failures+1))
      fi
    done
  fi
  case "$only" in
    "") for id in BYP-01 BYP-02 BYP-03 BYP-04 BYP-05 BYP-06 BYP-07 BYP-08 BYP-09 BYP-10 BYP-14 BYP-15 BYP-16 BYP-17 BYP-18 BYP-19; do
          fn="selftest_byp_${id#BYP-}"; fn="${fn/-/_}"
          "$fn" || failures=$((failures+1))
        done ;;
    pinned-acceptance) selftest_pinned_acceptance || failures=$((failures+1)) ;;
    guard-tamper) selftest_guard_tamper || failures=$((failures+1)) ;;
    license) selftest_license || failures=$((failures+1)) ;;
    package) selftest_package || failures=$((failures+1)) ;;
    upgrade) { selftest_upgrade && selftest_upgrade_fixtures; } || failures=$((failures+1)) ;;
    promote-split) selftest_promote_split || failures=$((failures+1)) ;;
    contracts) selftest_contracts || failures=$((failures+1)) ;;
    hollow) selftest_hollow || failures=$((failures+1)) ;;
    plan-artifact) selftest_plan_artifact || failures=$((failures+1)) ;;
    owner-auth) selftest_owner_auth || failures=$((failures+1)) ;;
    helper-integrity) selftest_helper_integrity || failures=$((failures+1)) ;;
    staleness) selftest_staleness || failures=$((failures+1)) ;;
    unsealed-status) selftest_unsealed_status || failures=$((failures+1)) ;;
    thin) selftest_thin || failures=$((failures+1)) ;;
    skills) selftest_skills || failures=$((failures+1)) ;;
    BYP-01|BYP-02|BYP-03|BYP-04|BYP-05|BYP-06|BYP-07|BYP-08|BYP-09|BYP-10|BYP-14|BYP-15|BYP-16|BYP-17|BYP-18|BYP-19)
      fn="selftest_byp_${only#BYP-}"; fn="${fn/-/_}"; "$fn" || failures=$((failures+1)) ;;
    *) die "unknown selftest case: $only" ;;
  esac
  [ "$failures" -eq 0 ] || { printf 'bones selftest: %s failure(s)\n' "$failures"; return 1; }
  printf 'bones selftest: PASS\n'
}

cmd_next() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local cur name target created strict
  cur="$(require_stage)" || exit 1; name="$(state_get name)"
  target="$(state_get target)"; created="$(state_get created)"; strict="$(state_get strict)"
  [ "$cur" -le "$NSTAGES" ] || die "pipeline already complete"
  local gt="${STAGE_GATE[$((cur-1))]}"
  # A sign-off is tied to the exact evidence bytes recorded in its gate. Detect
  # drift on the enforced advancement path, not only when someone runs doctor.
  local ln path want got
  while IFS= read -r ln; do
    path="$(printf '%s' "$ln" | sed -E 's/^evidence: (.*) \(sha256:[a-f0-9-]+\)$/\1/')"
    want="$(printf '%s' "$ln" | sed -E 's/^.*\(sha256:([a-f0-9-]+)\)$/\1/')"
    path="$(resolve_evidence "$path" "$target")"
    [ -e "$path" ] || die "evidence integrity check failed: signed-off file is missing: $path"
    got="$(sha_of "$path")"
    [ "$got" = "$want" ] || die "evidence integrity check failed: $path changed after sign-off (expected $want, actual $got). Refusing to advance."
  done < <(grep -h '^evidence: ' "$BONES_DIR"/gates/*.ok 2>/dev/null)
  if [ "$gt" = "step" ]; then
    # steps advance freely, but still leave an audit record
    {
      printf '%s | %s | step | step completed\n' "$(now)" "${STAGE_KEYS[$((cur-1))]}"
      git_pin "$target"
    } > "$(gate_file "$cur")"
    journal step "stage $cur (${STAGE_KEYS[$((cur-1))]}) completed"
  elif ! gate_satisfied "$cur"; then
    case "$gt" in
      auto)  die "GATE CLOSED: stage $cur (build-loop) not verified. Run 'bones build ...' until loop.sh exits 0." ;;
      owner) if [ "$cur" -eq 8 ] && [ -f "$BONES_DIR/gates/8-promote.authorized" ]; then die "GATE CLOSED: 8a is authorized but 8b is not confirmed — deploy, run the production smoke, then: bones confirm -e <smoke record> \"<note>\""; fi
             die "GATE CLOSED: stage $cur (${STAGE_TITLES[$((cur-1))]}) is JAKE'S call. Ask him, then: bones approve -q \"<his exact words>\" \"<note>\"$([ "$cur" -eq 8 ] && printf ' (8a — prompts Touch ID)')" ;;
      *)     die "GATE CLOSED: stage $cur (${STAGE_TITLES[$((cur-1))]}) needs sign-off. Run: bones approve \"<note>\"" ;;
    esac
  fi
  # 2.0: a council record that says REVISE/KILL is evidence, not a pass.
  if [ "$cur" -eq 4 ] && gate_satisfied 4; then
    local cv; cv="$(sed -n 's/^council-verdict:[[:space:]]*//p' "$(gate_file 4)" | head -1)"
    [ -z "$cv" ] || [ "$cv" = "BUILD" ] || die "GATE CLOSED: the recorded council verdict is $cv — bones back -s 3, revise, re-sign, and re-enter stage 4 with a BUILD record"
  fi
  # 2.0: leaving stage 8 needs 8a (still valid for HEAD) AND 8b.
  if [ "$cur" -eq 8 ]; then
    [ -f "$BONES_DIR/gates/8-promote.authorized" ] || die "GATE CLOSED: stage 8 has no 8a authorization record — bones approve -q \"<Jake's words>\" \"<note>\" (Touch ID), deploy + smoke, then bones confirm"
    owner_auth_recheck "$BONES_DIR/gates/8-promote.authorized" || die "GATE CLOSED: the 8a authorization is stale for the current HEAD — bones back -s 8, then authorize again"
  fi
  local nxt=$((cur+1))
  write_state "$BONES_DIR" "$name" "$target" "$nxt" "$created" "$strict"
  # Promote just passed: start the 7-day operate/learn clock (stage 10's deadline).
  if [ "$cur" -eq 8 ]; then
    local due; due="$(date -u -v+7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+7 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    if [ -n "$due" ]; then
      printf '%s\n' "$due" > "$BONES_DIR/operate-due"
      journal operate-clock "promote passed — operate/learn call due by $due"
      printf 'horvitz: 7-day operate clock started — stage 10 call due by %s.\n       Schedule a day-7 check-in agent now (e.g. /schedule) so the double-down/park/kill call actually happens.\n' "$due"
    fi
  fi
  if [ "$nxt" -gt "$NSTAGES" ]; then
    journal done "all $NSTAGES stages complete"
    printf 'horvitz: stage %s complete. 🎉 ALL STAGES DONE — pipeline shipped & gated end to end.\n' "$cur"
  else
    printf 'horvitz: advanced to stage %s/%s — %s\n\n' "$nxt" "$NSTAGES" "${STAGE_TITLES[$((nxt-1))]}"
    cmd_status
  fi
}

cmd_back() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local to="" reason=""
  while getopts ":s:r:" o; do case "$o" in
    s) to="$OPTARG" ;; r) reason="$OPTARG" ;;
    :) die "-$OPTARG needs an argument" ;; \?) die "unknown flag -$OPTARG" ;;
  esac; done
  case "$to" in (''|*[!0-9]*) die "back needs -s <stage_number> to return to" ;; esac
  [ -n "$reason" ] || die "back needs -r \"<reason>\" — regressions are part of the audit trail"
  local cur name target created strict
  cur="$(require_stage)" || exit 1; name="$(state_get name)"
  target="$(state_get target)"; created="$(state_get created)"; strict="$(state_get strict)"
  [ "$to" -ge 1 ] && [ "$to" -le "$NSTAGES" ] || die "stage must be 1..$NSTAGES"
  [ "$to" -le "$cur" ] || die "back only goes backward (you are at stage $cur); use gates + next to go forward"
  # Archive (don't delete) every gate record from the target stage on — audit trail survives.
  local arch="$BONES_DIR/gates/archive/$(now | tr ':' '-')-back-to-$to"
  local n="$to" moved=0
  while [ "$n" -le "$NSTAGES" ]; do
    if [ -f "$(gate_file "$n")" ]; then
      mkdir -p "$arch"; mv "$(gate_file "$n")" "$arch/"; moved=$((moved+1))
    fi
    n=$((n+1))
  done
  # 2.0: the pinned plan (stage 5) and the 8a authorization (stage 8) are archived with their stage.
  local extra sn
  for extra in 5-build-loop.plan 8-promote.authorized; do
    case "$extra" in 5-*) sn=5 ;; *) sn=8 ;; esac
    if [ "$sn" -ge "$to" ] && [ -f "$BONES_DIR/gates/$extra" ]; then mkdir -p "$arch"; mv "$BONES_DIR/gates/$extra" "$arch/"; moved=$((moved+1)); fi
  done
  write_state "$BONES_DIR" "$name" "$target" "$to" "$created" "$strict"
  journal back "regressed stage $cur -> $to ($moved gate record(s) archived): $reason"
  printf 'horvitz: went back to stage %s — %s (archived %s gate record(s); reason on the journal)\n\n' "$to" "${STAGE_TITLES[$((to-1))]}" "$moved"
  cmd_status
}

cmd_note() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local text="${*:-}" cur name
  [ -n "$text" ] || die "note needs text"
  cur="$(require_stage)" || exit 1; name="$(state_get name)"
  if [ "$cur" -gt "$NSTAGES" ]; then
    printf 'horvitz: WARNING — pipeline "%s" is COMPLETE. If this note belongs to different work, you are probably in the wrong .bones (%s); init one in the right target instead.\n' "$name" "$BONES_DIR" >&2
    journal note "[post-completion] $text"
  else
    journal note "[stage $cur/${STAGE_KEYS[$((cur-1))]}] $text"
  fi
  printf 'horvitz: noted (pipeline "%s").\n' "$name"
}

cmd_log() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  printf '== Horvitz audit trail: %s ==\n\n-- gate records --\n' "$(state_get name)"
  local n=1 gf
  while [ "$n" -le "$NSTAGES" ]; do
    gf="$(gate_file "$n")"
    if [ -f "$gf" ]; then printf '[stage %s]\n' "$n"; sed 's/^/  /' "$gf"; fi
    n=$((n+1))
  done
  if [ -d "$BONES_DIR/gates/archive" ]; then
    printf '\n-- archived (superseded by back) --\n'
    find "$BONES_DIR/gates/archive" -type f -name '*.ok' | sort | while IFS= read -r f; do
      printf '[%s]\n' "${f#"$BONES_DIR"/gates/archive/}"; sed 's/^/  /' "$f"
    done
  fi
  if [ -f "$BONES_DIR/journal.log" ]; then
    printf '\n-- journal --\n'; sed 's/^/  /' "$BONES_DIR/journal.log"
  fi
}

cmd_nudge() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local dry=0; [ "${1:-}" = "-n" ] && { dry=1; shift; }
  local cur name gt title extra="${*:-}"
  cur="$(require_stage)" || exit 1; name="$(state_get name)"
  [ "$cur" -le "$NSTAGES" ] || die "pipeline complete — nothing to nudge about"
  gt="${STAGE_GATE[$((cur-1))]}"; title="${STAGE_TITLES[$((cur-1))]}"
  local handle="${BONES_OWNER_HANDLE:-jakeharrisonhorvitz@gmail.com}"
  local msg="bones[$name] stage $cur/$NSTAGES ($title) — [$gt] gate open."
  case "$gt" in
    owner) msg="$msg Your call is needed: reply here with your decision (the agent records your words verbatim)$([ "$cur" -eq 8 ] && printf '; promote also needs your Touch ID tap on the Mac' || printf '')." ;;
    *)     msg="$msg Heads-up only." ;;
  esac
  [ -n "$extra" ] && msg="$msg $extra"
  if [ "$dry" -eq 1 ]; then
    printf 'horvitz: DRY RUN — would iMessage %s:\n  %s\n' "$handle" "$msg"
    return 0
  fi
  osascript - "$handle" "$msg" <<'EOF' >/dev/null || die "nudge failed — is Messages signed in? (set BONES_OWNER_HANDLE to override the target)"
on run argv
  set h to item 1 of argv
  set m to item 2 of argv
  tell application "Messages"
    set svc to 1st account whose service type = iMessage
    send m to participant h of svc
  end tell
end run
EOF
  journal nudge "iMessaged $handle re stage $cur gate"
  printf 'horvitz: nudged %s about the stage %s gate. His REPLY is the approval — record it verbatim with approve -q.\n' "$handle" "$cur"
}

cmd_doctor() {
  BONES_DIR="$(find_bones)" || die "no .bones here — run 'bones init' first"
  local cur issues=0 n
  cur="$(require_stage)" || exit 1
  printf '== Horvitz doctor: %s ==\n' "$(state_get name)"
  if [ "$cur" -lt 1 ] || [ "$cur" -gt $((NSTAGES+1)) ]; then
    printf ' FAIL stage %s out of range 1..%s\n' "$cur" "$((NSTAGES+1))"; issues=$((issues+1))
  fi
  n=1
  while [ "$n" -le "$NSTAGES" ]; do
    if [ "$n" -lt "$cur" ] && ! gate_satisfied "$n"; then
      printf ' WARN stage %s (%s) was passed but has NO gate record — advanced by an old version or tampered\n' "$n" "${STAGE_KEYS[$((n-1))]}"; issues=$((issues+1))
    fi
    if [ "$n" -gt "$cur" ] && gate_satisfied "$n"; then
      printf ' WARN stage %s (%s) has a gate record but hasn'\''t been reached — stale record, should be archived via back\n' "$n" "${STAGE_KEYS[$((n-1))]}"; issues=$((issues+1))
    fi
    n=$((n+1))
  done
  local target; target="$(state_get target)"
  [ -d "$target" ] || { printf ' FAIL target dir missing: %s\n' "$target"; issues=$((issues+1)); }
  case "$PWD/" in
    "$target"/*|"$target/") : ;;
    *) printf ' WARN you are running bones from outside the target (%s) — wrong .bones? (journal pollution risk)\n' "$target"; issues=$((issues+1)) ;;
  esac
  [ -f "$BONES_DIR/journal.log" ] || { printf ' WARN journal.log missing\n'; issues=$((issues+1)); }
  if [ -f "$BONES_DIR/operate-due" ] && [ "$cur" -ge 9 ] && [ "$cur" -le "$NSTAGES" ]; then
    local due; due="$(head -1 "$BONES_DIR/operate-due")"
    [ "$(now)" \> "$due" ] && { printf ' WARN operate/learn call OVERDUE (was due %s)\n' "$due"; issues=$((issues+1)); }
  fi
  [ -f "$LOOP_SH" ] || { printf ' WARN loop.sh not found at %s\n' "$LOOP_SH"; issues=$((issues+1)); }
  # 2.0: pre-2.0 promotes are labeled, not warned; a stale 8a is a real issue; passphrase mode is shown.
  if [ "$cur" -ge 9 ] && gate_satisfied 8 && [ ! -f "$BONES_DIR/gates/8-promote.authorized" ]; then
    printf ' note stage 8 promoted pre-2.0 (no 8a authorization record) — accepted\n'
  fi
  if [ "$cur" -eq 8 ] && [ -f "$BONES_DIR/gates/8-promote.authorized" ] && ! owner_auth_recheck "$BONES_DIR/gates/8-promote.authorized" 2>/dev/null; then
    printf ' WARN 8a authorization is STALE for the current HEAD — re-authorize before 8b\n'; issues=$((issues+1))
  fi
  if [ -f "$BONES_DIR/owner.pub" ] && [ "$(sed -n 's/^owner-mode:[[:space:]]*//p' "$BONES_DIR/owner.pub" | head -1)" = passphrase ]; then
    printf ' note owner-auth: passphrase (DEGRADED)\n'
  fi
  if [ -f "$BONES_DIR/contracts.sha256" ]; then
    local cn cs
    while read -r cn cs; do
      [ -f "$CONTRACTS_DIR/$cn" ] || { printf ' WARN pinned contract missing from the skill: %s\n' "$cn"; issues=$((issues+1)); continue; }
      [ "$(sha_of "$CONTRACTS_DIR/$cn")" = "$cs" ] || { printf ' WARN contract CHANGED since pinned for this run: %s (bones contracts-repin if deliberate)\n' "$cn"; issues=$((issues+1)); }
    done < "$BONES_DIR/contracts.sha256"
  fi
  # Evidence integrity: re-hash every pinned artifact; a mismatch means the file
  # changed AFTER sign-off (or the record was forged).
  local ln path want got
  while IFS= read -r ln; do
    path="$(printf '%s' "$ln" | sed -E 's/^evidence: (.*) \(sha256:[a-f0-9-]+\)$/\1/')"
    want="$(printf '%s' "$ln" | sed -E 's/^.*\(sha256:([a-f0-9-]+)\)$/\1/')"
    path="$(resolve_evidence "$path" "$target")"
    if [ ! -e "$path" ]; then
      printf ' WARN evidence file GONE since sign-off: %s\n' "$path"; issues=$((issues+1))
    else
      got="$(sha_of "$path")"
      if [ "$got" != "$want" ]; then
        printf ' WARN evidence CHANGED after sign-off (sha mismatch): %s\n' "$path"; issues=$((issues+1))
      fi
    fi
  done < <(grep -h '^evidence: ' "$BONES_DIR"/gates/*.ok 2>/dev/null)
  if [ "$issues" -eq 0 ]; then printf ' PASS — state, gates, journal, evidence hashes all consistent.\n'
  else printf ' %s issue(s) found.\n' "$issues"; return 1; fi
}

cmd_reset() {
  BONES_DIR="$(find_bones)" || die "no .bones here"
  local force=0; [ "${1:-}" = "-f" ] && force=1
  if [ "$force" -ne 1 ]; then die "this deletes $BONES_DIR — re-run 'bones reset -f' to confirm"; fi
  rm -rf "$BONES_DIR"; printf 'horvitz: reset (removed %s)\n' "$BONES_DIR"
}

cmd_guard_repin() {
  BONES_DIR="$(find_bones)" || die "no .bones here"
  local reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -r) reason="${2:-}"; [ -n "$reason" ] || die "guard-repin: -r needs a reason"; shift 2 ;;
      *) die "guard-repin: unknown arg '$1' (usage: guard-repin -r \"<reason>\")" ;;
    esac
  done
  [ -n "$reason" ] || die "guard-repin requires -r \"<reason>\" — the repin goes on the permanent record"
  # journal is line-oriented: a multiline reason could forge extra journal lines
  reason="$(printf '%s' "$reason" | tr '\r\n' '  ' | tr -d '\000-\010\013\014\016-\037')"
  verify_state_integrity
  verify_acceptance_file
  [ -f "$GUARD_SH" ] || die "guard script missing at $GUARD_SH"
  local old new final
  old="$(head -1 "$BONES_DIR/guard.sha256" 2>/dev/null | awk '{print $1}')"
  new="$(sha_of "$GUARD_SH")"
  if [ "$old" = "$new" ]; then printf 'horvitz: guard pin already current (%s)\n' "$new"; return 0; fi
  # A guard earns a new pin only by proving it still BLOCKS the full bypass corpus.
  cmd_selftest >/dev/null 2>&1 \
    || die "guard-repin refused: live guard FAILS the bypass corpus (run 'bones selftest' to see). A guard that cannot block the corpus does not get pinned."
  # Journal the intent BEFORE moving the pin — a failed repin must still be on record.
  journal guard-repin "pin ${old:-none} -> ${new}; reason: ${reason} (bypass corpus verified BLOCK)" \
    || die "guard-repin: journal write failed — pin NOT changed"
  record_guard_hash "$BONES_DIR"
  # Post-verify (TOCTOU): the pinned hash must equal the corpus-verified hash.
  final="$(head -1 "$BONES_DIR/guard.sha256" 2>/dev/null | awk '{print $1}')"
  if [ "$final" != "$new" ] || [ "$(sha_of "$GUARD_SH")" != "$new" ]; then
    journal guard-repin "REPIN POST-VERIFY FAILED: pinned=${final:-none} expected=${new} — guard changed mid-repin"
    die "guard-repin: post-verify failed — guard changed while re-pinning; inspect $GUARD_SH before retrying"
  fi
  printf 'horvitz: guard re-pinned %s -> %s (bypass corpus verified)\n' "${old:-none}" "$new"
}

cmd_contracts_repin() {
  BONES_DIR="$(find_bones)" || die "no .bones here"
  local reason=""
  while [ $# -gt 0 ]; do case "$1" in
    -r) reason="${2:-}"; [ -n "$reason" ] || die "contracts-repin: -r needs a reason"; shift 2 ;;
    *) die "contracts-repin: unknown arg '$1' (usage: contracts-repin -r \"<reason>\")" ;;
  esac; done
  [ -n "$reason" ] || die "contracts-repin requires -r \"<reason>\" — the repin goes on the permanent record"
  reason="$(printf '%s' "$reason" | tr '\r\n' '  ' | tr -d '\000-\010\013\014\016-\037')"
  verify_state_integrity
  # A changed contract earns a new pin only by proving it still judges the fixture corpus correctly.
  cmd_selftest --only contracts >/dev/null 2>&1 && cmd_selftest --only hollow >/dev/null 2>&1 \
    || die "contracts-repin refused: the contracts FAIL their fixture selftests (run: bones selftest --only contracts / --only hollow)"
  journal contracts-repin "contracts re-pinned; reason: ${reason} (contracts + hollow selftests PASS)" || die "contracts-repin: journal write failed — pin NOT changed"
  record_contracts_hash "$BONES_DIR"
  printf 'horvitz: contracts re-pinned for this run (%s entries)\n' "$(wc -l < "$BONES_DIR/contracts.sha256" | tr -d ' ')"
}

# --- dispatch --------------------------------------------------------------
BONES_DIR="${BONES_DIR:-}"
sub="${1:-status}"; shift || true
case "$sub" in
  init)    cmd_init "$@" ;;
  status)  cmd_status ;;
  artifacts) cmd_artifacts ;;
  approve) cmd_approve "$@" ;;
  build)   cmd_build "$@" ;;
  acceptance-path) cmd_acceptance_path ;;
  selftest) cmd_selftest "$@" ;;
  license) cmd_license "$@" ;;
  package) cmd_package "$@" ;;
  plan)    cmd_plan "$@" ;;
  confirm) cmd_confirm "$@" ;;
  owner-setup) cmd_owner_setup "$@" ;;
  owner-pin) cmd_owner_pin "$@" ;;
  next)    cmd_next ;;
  back)    cmd_back "$@" ;;
  mode)    cmd_mode "$@" ;;
  note)    cmd_note "$@" ;;
  nudge)   cmd_nudge "$@" ;;
  doctor)  cmd_doctor ;;
  guard-repin) cmd_guard_repin "$@" ;;
  contracts-repin) cmd_contracts_repin "$@" ;;
  log)     cmd_log ;;
  reset)   cmd_reset "$@" ;;
  -h|--help|help) grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand: $sub (try: init status artifacts approve plan build confirm owner-setup owner-pin acceptance-path selftest license package next back note nudge doctor guard-repin contracts-repin log reset)" ;;
esac
