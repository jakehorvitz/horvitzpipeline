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
#            In strict mode (init -H) it additionally requires a real TTY, i.e.
#            Jake runs the approve himself — an agent shell cannot satisfy it.
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
#   8  promote           [owner]  Jake's explicit go for production + smoke test green
#   9  present           [step]   presented to the user
#   10 operate           [owner]  Jake's operate/learn decision (double-down/park/kill)
#
# Usage:
#   bones.sh init  -t <target_dir> [-c <acceptance_cmd>] [-n <name>] [-S] [-f]
#                         # without -c, pins `false` so the build gate fails closed
#                         # STRICT by default; -S = soft owner gates
#   bones.sh status
#   bones.sh approve [-q "<verbatim owner quote>"] [-e <evidence_file>]... "<note>"
#   bones.sh build  [loop.sh args...]   # stage 5 only: runs ship-pipeline loop.sh
#                         # -B auto|codex|prime picks the builder agent (default auto:
#                         # codex, else prime-agent). The builder never holds the gate —
#                         # bones re-runs the pinned acceptance command itself either way.
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
STAGE_BRIEF=(
  "superpowers brainstorm + recon (Jake's brains FIRST — mem-search persistent memory always, plus the matching vaults: AI-Brain / hormozi-vault / video-brain / Brain, per ship-pipeline/references/brains.md — then deep-research / web-scraping / context7 / graphify), THEN the 7-dimension prompt interrogation (ship-pipeline/references/prompt-interrogation.md): band every dimension covered/partial/missing, ask Jake only the gaps, fold answers back in, and SCORE each round (covered=full weight, partial=half, missing=0; deferred excluded) — below 85/100 the interrogation is not done, keep asking. Record 'score: NN/100' in the record. UI build? deliver the clickable HTML mockup too. Deliverable: tightened prompt + scored interrogation record — approve with -e <interrogation file>."
  "the brutal <=30-min check: painful job + for whom, existing 80% tool, unfair advantage, 1-day version + cuts, 7-day success metric, kill condition, maintenance cost. Record scope/metric/kill-condition — they feed stages 3 and 10."
  "HTML spec from ship-pipeline/templates/spec.html incl. non-goals + EXECUTABLE acceptance checklist + API validation: live-curl every external API AT SPEC TIME (request + confirmed response captured in the spec) or state 'no external APIs' explicitly — an API first tested mid-build ships bugs. UI build? link the stage-1 mockup. Jake grills it; revise until he signs off. Approve with -e <spec.html>."
  "claude-council if stakes warrant (multiple architectures, irreversible data/schema, auth/payments/PII, cost risk); else a second-pass spec critique. Verdict + dissent recorded into the spec. Rejection => bones back -s 3."
  "run \`bones build -c \"<the command pinned at init>\" -s <spec.html> [-r rubric] [-B auto|codex|prime]\` — bones rejects a different command and independently re-runs the pinned command after the loop; both must exit 0; rubric score is advisory. -B picks the builder agent (default auto: codex, else prime-agent); whichever builds, the pinned re-run is still the gate."
  "FIRST the stage-5.5 spec-conformance check: re-read the SIGNED stage-3 spec and mark every scope item / anti-requirement / acceptance criterion MATCHES / DRIFTED / MISSING with evidence (long loops drift — the acceptance command only checks what it encodes); any drift => bones back -s 5 or a spec amendment Jake re-signs. THEN cross-model adversarial review of the diff vs spec + anti-requirements; risk-triggered /security-review if auth/payments/PII/uploads/webhooks/admin/multi-tenant/public-write. Findings => bones back -s 5. Approve with -e <conformance report> -e <review file>."
  "staging with FRESH/SEEDED data (never real): test suite -> migration/seed check -> click-control happy path (screenshot) -> full e2e -> competitor-analysis pass. ALL green before promote. Approve with -e <staging log/screenshot>."
  "Jake's explicit go, then promote + IMMEDIATE production smoke test of the core happy path. Roll back on failure — record either way."
  "present to Jake: what shipped, acceptance checklist status, competitor read, live URL."
  "instrument (activation, core-success, errors, latency + one qualitative channel); within 7 days check the stage-2 metric and record Jake's call: double-down / park / kill. Then write learnings BACK to the brains per ship-pipeline/references/brains.md: new/updated persistent-memory facts (+ MEMORY.md index line), vault notes, stale memories corrected — a run that taught nothing is journaled as such."
)
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
    1)
      # v1 -> v2 adds no semantic fields; rewrite through the canonical writer so
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
    6)
      [ $# -ge 1 ] || die "stage 6 needs -e <review file> — attach the adversarial review findings (and security result if triggered)"
      # Anti-drift gate (Bones 8/13): what was built must be re-checked against the SIGNED spec.
      # Marker is the word "conformance" — MATCHES/DRIFTED alone are too close to common English.
      local conf=0
      for f in "$@"; do
        grep -qiE 'conformance' "$f" 2>/dev/null && conf=1
      done
      [ "$conf" -eq 1 ] || die "stage 6 needs the stage-5.5 spec-conformance report alongside the review — re-read the SIGNED stage-3 spec and mark every scope item / anti-requirement / acceptance criterion MATCHES / DRIFTED / MISSING with evidence. Long loops drift; the acceptance command only checks what it encodes. Approve with -e <conformance report> -e <review file>."
      ;;
    7)
      [ $# -ge 2 ] || die "stage 7 needs at least 2 -e files — a staging/e2e log AND the click-through screenshot"
      local img=0
      for f in "$@"; do case "$f" in *.png|*.jpg|*.jpeg|*.webp) img=1 ;; esac; done
      [ "$img" -eq 1 ] || printf 'horvitz: WARNING — stage 7 evidence has no screenshot (*.png/jpg); the click-control pass should capture one.\n' >&2
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
  local gt="${STAGE_GATE[$((cur-1))]}"
  printf 'stage %s requires: %s\n\n' "$cur" "${STAGE_BRIEF[$((cur-1))]}" | fold -s -w 96
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

  if [ "$gt" = "owner" ]; then
    if [ "$strict" = "true" ] && [ ! -t 0 ]; then
      die "STRICT MODE: stage $cur is an owner gate — Jake must run this approve himself from a real terminal. An agent shell cannot satisfy it."
    fi
    [ -n "$quote" ] || die "stage $cur is an OWNER gate — it needs Jake's verbatim words: approve -q \"<his exact words>\" \"<note>\". Ask him; do not paraphrase or infer."
  fi

  # Evidence: every -e must exist; record path + sha256.
  local ev_lines=""
  if [ ${#evidence[@]} -gt 0 ]; then
    local f
    for f in "${evidence[@]}"; do
      [ -e "$f" ] || die "evidence file not found: $f"
      ev_lines="${ev_lines}evidence: $f (sha256:$(sha_of "$f"))
"
    done
  fi
  # Stage-specific validation: the artifact is the gate, not the note.
  validate_evidence "$cur" ${evidence[@]+"${evidence[@]}"}

  local target; target="$(state_get target)"
  local gf; gf="$(gate_file "$cur")"
  {
    printf '%s | %s | %s | %s\n' "$(now)" "${STAGE_KEYS[$((cur-1))]}" "$gt" "$note"
    [ -n "$quote" ] && printf 'owner-quote: "%s"\n' "$quote"
    [ -n "$ev_lines" ] && printf '%s' "$ev_lines"
    git_pin "$target"
  } > "$gf"
  journal approve "stage $cur (${STAGE_KEYS[$((cur-1))]}) — $note"
  printf 'horvitz: gate %s. %s approved — "%s"\n' "$cur" "${STAGE_TITLES[$((cur-1))]}" "$note"
  [ -n "$quote" ] && printf '       owner quote on record: "%s"\n' "$quote"
  printf 'run `bones next` to advance.\n'
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
  if bash "$LOOP_SH" -t "$target" ${builder_args[@]+"${builder_args[@]}"} "$@"; then
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

cmd_selftest() {
  local only="" failures=0 id fn
  if [ "${1:-}" = "--only" ]; then only="${2:-}"; [ -n "$only" ] || die "selftest --only needs a case name"; fi
  local corpus="${BONES_SELFTEST_CORPUS:-$SCRIPT_DIR/../selftest/corpus.txt}"
  if [ "$only" = "" ]; then
    [ -f "$corpus" ] || die "canonical bypass corpus missing: $corpus"
    for id in BYP-01 BYP-02 BYP-03 BYP-04 BYP-05 BYP-06 BYP-07 BYP-08 BYP-09 BYP-10 BYP-14; do
      if ! grep -qE "^${id}[[:space:]]+BLOCK([[:space:]]|$)" "$corpus"; then
        printf '%s FAIL corpus missing required BLOCK marker\n' "$id"
        failures=$((failures+1))
      fi
    done
  fi
  case "$only" in
    "") for id in BYP-01 BYP-02 BYP-03 BYP-04 BYP-05 BYP-06 BYP-07 BYP-08 BYP-09 BYP-10 BYP-14; do
          fn="selftest_byp_${id#BYP-}"; fn="${fn/-/_}"
          "$fn" || failures=$((failures+1))
        done ;;
    pinned-acceptance) selftest_pinned_acceptance || failures=$((failures+1)) ;;
    guard-tamper) selftest_guard_tamper || failures=$((failures+1)) ;;
    license) selftest_license || failures=$((failures+1)) ;;
    package) selftest_package || failures=$((failures+1)) ;;
    upgrade) selftest_upgrade || failures=$((failures+1)) ;;
    BYP-01|BYP-02|BYP-03|BYP-04|BYP-05|BYP-06|BYP-07|BYP-08|BYP-09|BYP-10|BYP-14)
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
      owner) die "GATE CLOSED: stage $cur (${STAGE_TITLES[$((cur-1))]}) is JAKE'S call. Ask him, then: bones approve -q \"<his exact words>\" \"<note>\"" ;;
      *)     die "GATE CLOSED: stage $cur (${STAGE_TITLES[$((cur-1))]}) needs sign-off. Run: bones approve \"<note>\"" ;;
    esac
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
    owner) msg="$msg Your call is needed. In strict mode, run this yourself from a terminal in $(state_get target): bones approve -q \"<your words>\" \"<what was decided>\" — or reply here and the agent records it (soft mode only)." ;;
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
  # Evidence integrity: re-hash every pinned artifact; a mismatch means the file
  # changed AFTER sign-off (or the record was forged).
  local ln path want got
  while IFS= read -r ln; do
    path="$(printf '%s' "$ln" | sed -E 's/^evidence: (.*) \(sha256:[a-f0-9-]+\)$/\1/')"
    want="$(printf '%s' "$ln" | sed -E 's/^.*\(sha256:([a-f0-9-]+)\)$/\1/')"
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

# --- dispatch --------------------------------------------------------------
BONES_DIR="${BONES_DIR:-}"
sub="${1:-status}"; shift || true
case "$sub" in
  init)    cmd_init "$@" ;;
  status)  cmd_status ;;
  approve) cmd_approve "$@" ;;
  build)   cmd_build "$@" ;;
  acceptance-path) cmd_acceptance_path ;;
  selftest) cmd_selftest "$@" ;;
  license) cmd_license "$@" ;;
  package) cmd_package "$@" ;;
  next)    cmd_next ;;
  back)    cmd_back "$@" ;;
  mode)    cmd_mode "$@" ;;
  note)    cmd_note "$@" ;;
  nudge)   cmd_nudge "$@" ;;
  doctor)  cmd_doctor ;;
  guard-repin) cmd_guard_repin "$@" ;;
  log)     cmd_log ;;
  reset)   cmd_reset "$@" ;;
  -h|--help|help) grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand: $sub (try: init status approve build acceptance-path selftest license package next back note nudge doctor guard-repin log reset)" ;;
esac
