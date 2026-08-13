#!/usr/bin/env bash
#
# loop.sh — ship-pipeline build loop (Ralph-style build loop).
#
# Iterates a builder agent (codex or prime-agent) until the spec's ACCEPTANCE CHECKS
# pass or max iterations is hit. The binding gate is an EXECUTABLE acceptance command
# the ORCHESTRATOR runs itself (-c "<cmd>") — its real exit code decides pass/fail, so
# the builder cannot mark its own homework. If no -c command is given, it falls back
# to the builder's self-reported .loop/acceptance.json and loudly flags the gate as
# UNVERIFIED.
#
# Each iteration:
#   1) the builder implements the next increment toward the spec
#   2) the builder writes advisory .loop/acceptance.json + .loop/score.json
#   3) a DIFFERENT-model reviewer (gemini/prime/codex) critiques the diff
#   4) the orchestrator runs the acceptance command -> real exit code = the gate
#   5) stop when the gate is green; else loop
#
# The rubric score (score.json) is advisory guidance + audit trail, never the gate
# (a self-scored number can be gamed — Goodhart's Law).
#
# Builders:
#   codex — sandboxed via `codex exec --full-auto --cd <target>`.
#   prime — PrimeIntellect prime-agent, one-shot print mode run from inside <target>.
#           When -c is set, each iteration also gets prime's HOST-enforced
#           `--autonomous --autonomous-gate "<cmd>"` (bounded by prime's default
#           turn/token/time budgets), so prime keeps repairing within an iteration
#           until the gate passes or budgets exhaust. NOTE: prime-agent is NOT
#           sandboxed — it runs with user permissions inside the target; the
#           orchestrator (and Horvitz) re-run the acceptance command independently
#           either way. Set LOOP_PRIME_AUTONOMOUS=off for plain single-shot
#           iterations.
#
# Guardrails: operates only inside the target dir; refuses to run if the target
# looks like a production data store; never deletes data. This is a thin
# orchestrator — the builder does the work.
#
# Usage:
#   loop.sh -t <target_dir> -s <spec.html> -r <rubric.html> -c "<acceptance_cmd>" \
#           [-a <anti_reqs.md>] [-m 8] [-p 90] [-M model] [-B auto|codex|prime] \
#           [-R auto|codex|gemini|prime]
#   -c  acceptance command the orchestrator runs as the BINDING gate (e.g. "npm test").
#   -B  builder agent (default auto: codex if installed, else prime if ready).
#       An explicit -B prime with prime not ready is a hard error, not a fallback.
#   -R  per-iteration reviewer model (default auto: prefers a model DIFFERENT from
#       the builder — gemini if authed, else prime/codex).
#   -p  ADVISORY rubric target shown in output; does NOT gate the loop.
#
set -uo pipefail

TARGET="."
SPEC=""
RUBRIC="$HOME/.claude/skills/ship-pipeline/templates/rubric-seo.html"
ANTI=""
MAX_ITERS=8
THRESHOLD=90   # advisory rubric target only — the acceptance command is the real gate
MODEL=""
ACCEPT_CMD=""
REVIEWER="auto"
BUILDER="auto"
REVIEW_TIMEOUT=180

die() { printf 'loop.sh: %s\n' "$1" >&2; exit 1; }

ALLOW_UNVERIFIED=0
while getopts ":t:s:r:a:m:p:M:c:R:B:Uh" opt; do
  case "$opt" in
    t) TARGET="$OPTARG" ;;
    s) SPEC="$OPTARG" ;;
    r) RUBRIC="$OPTARG" ;;
    a) ANTI="$OPTARG" ;;
    m) MAX_ITERS="$OPTARG" ;;
    p) THRESHOLD="$OPTARG" ;;
    M) MODEL="$OPTARG" ;;
    c) ACCEPT_CMD="$OPTARG" ;;
    R) REVIEWER="$OPTARG" ;;
    B) BUILDER="$OPTARG" ;;
    U) ALLOW_UNVERIFIED=1 ;;
    h) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    :) die "option -$OPTARG requires an argument" ;;
    \?) die "unknown option -$OPTARG" ;;
  esac
done

# The acceptance command is the binding gate. Without it the loop degrades to the
# builder's self-report, which is gameable — require an explicit -U to accept that.
[ -n "$ACCEPT_CMD" ] || [ "$ALLOW_UNVERIFIED" -eq 1 ] || \
  die "no -c acceptance command. The gate would be builder self-report (gameable). Pass -c \"<cmd>\" (e.g. \"npm test\"), or -U to explicitly run UNVERIFIED/advisory."

[ -d "$TARGET" ] || die "target dir not found: $TARGET"
[ -f "$RUBRIC" ] || die "rubric not found: $RUBRIC"
[ -n "$SPEC" ] && [ ! -f "$SPEC" ] && die "spec not found: $SPEC"
case "$MAX_ITERS" in (''|*[!0-9]*) die "max-iters must be an integer" ;; esac
case "$THRESHOLD" in (''|*[!0-9]*) die "threshold must be an integer" ;; esac
case "$REVIEWER" in (auto|codex|gemini|prime) ;; (*) die "reviewer must be auto|codex|gemini|prime" ;; esac
case "$BUILDER" in (auto|codex|prime) ;; (*) die "builder must be auto|codex|prime" ;; esac

# --- builder availability -------------------------------------------------
# prime-agent installs into an npm global prefix that is not always on a
# non-interactive PATH; look there before declaring it missing.
if ! command -v prime-agent >/dev/null 2>&1; then
  # `npm prefix -g` needs npm itself on PATH, which a minimal non-interactive PATH
  # lacks — so also probe the standard global-bin locations.
  for _d in "$(npm prefix -g 2>/dev/null)/bin" "${NPM_CONFIG_PREFIX:-}/bin" \
            "$HOME/.npm-global/bin" "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
    if [ -n "$_d" ] && [ -x "$_d/prime-agent" ]; then PATH="$PATH:$_d"; break; fi
  done
fi

codex_ready() { command -v codex >/dev/null 2>&1; }
prime_ready() { command -v prime-agent >/dev/null 2>&1; }

# Resolve the builder. An EXPLICIT choice that is unavailable is a hard error:
# silently falling back would change who wrote the code without saying so.
case "$BUILDER" in
  codex) codex_ready || die "-B codex but the codex CLI is not on PATH" ;;
  prime) prime_ready || die "-B prime but prime-agent is not on PATH (install: curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh)" ;;
  auto)
    if codex_ready; then BUILDER=codex
    elif prime_ready; then BUILDER=prime
    else die "no builder available: neither codex nor prime-agent is on PATH"
    fi ;;
esac

TARGET="$(cd "$TARGET" && pwd)"

# Fresh-data guardrail: refuse obvious production data stores.
case "$TARGET" in
  *prod*|*production*|*/data/live*|*/var/lib/*)
    die "refusing to loop inside what looks like a production/data path: $TARGET (fresh-data rule)" ;;
esac

LOOP_DIR="$TARGET/.loop"
mkdir -p "$LOOP_DIR"
SCORE_FILE="$LOOP_DIR/score.json"
ACCEPT_FILE="$LOOP_DIR/acceptance.json"

model_flag=()
[ -n "$MODEL" ] && model_flag=(--model "$MODEL")

# prime-agent also takes --model <id>, but its IDs are namespaced (provider/id),
# so -M must name a model that belongs to whichever builder is running.
prime_model_flag=()
[ -n "$MODEL" ] && prime_model_flag=(--model "$MODEL")

# prime's host-enforced inner gate: it keeps repairing within one iteration until
# the acceptance command passes or its own budgets run out. This is ADDITIVE to —
# never a substitute for — the orchestrator's independent acceptance run below.
prime_auto_flags=()
if [ -n "$ACCEPT_CMD" ] && [ "${LOOP_PRIME_AUTONOMOUS:-on}" != "off" ]; then
  prime_auto_flags=(--autonomous --autonomous-gate "$ACCEPT_CMD"
                    --autonomous-gate-timeout-ms "${LOOP_PRIME_GATE_TIMEOUT_MS:-300000}")
fi

# Portable timeout (macOS has no `timeout`/`gtimeout`). Uses perl's alarm.
run_with_timeout() {
  local secs="$1"; shift
  perl -e 'my $s=shift; my $pid=fork; if(!defined $pid){exit 127}
           if($pid==0){exec @ARGV; exit 127}
           local $SIG{ALRM}=sub{kill "TERM",$pid; sleep 1; kill "KILL",$pid; exit 124};
           alarm $s; waitpid $pid,0; exit($? >> 8)' "$secs" "$@"
}

# Is the gemini CLI usable headlessly (installed AND an auth method configured)?
gemini_ready() {
  command -v gemini >/dev/null 2>&1 || return 1
  [ -n "${GEMINI_API_KEY:-}" ] && return 0
  [ -n "${GOOGLE_API_KEY:-}" ] && return 0
  grep -qiE '"(selectedAuthType|authType)"' "$HOME/.gemini/settings.json" 2>/dev/null && return 0
  return 1
}

# Resolve the per-iteration reviewer: prefer a DIFFERENT model than the builder,
# so the critique is not the builder grading its own diff.
other_builder() {
  # The builder-family agent that is NOT doing the building, if it is available.
  if [ "$BUILDER" = "codex" ]; then prime_ready && echo prime || echo ""
  else codex_ready && echo codex || echo ""
  fi
}
resolve_reviewer() {
  local alt
  case "$REVIEWER" in
    codex)  codex_ready && echo codex || echo "$BUILDER" ;;
    prime)  prime_ready && echo prime || echo "$BUILDER" ;;
    gemini) gemini_ready && echo gemini || echo "$BUILDER" ;;
    auto)
      if gemini_ready; then echo gemini; return; fi
      alt="$(other_builder)"
      [ -n "$alt" ] && echo "$alt" || echo "$BUILDER"
      ;;
  esac
}

# Advisory: weighted rubric total from .loop/score.json. Prefers jq; falls back to grep.
read_score() {
  [ -f "$SCORE_FILE" ] || { echo 0; return; }
  if command -v jq >/dev/null 2>&1; then
    jq -r '.score // 0' "$SCORE_FILE" 2>/dev/null | head -1
  else
    grep -oE '"score"[[:space:]]*:[[:space:]]*[0-9.]+' "$SCORE_FILE" 2>/dev/null \
      | grep -oE '[0-9.]+' | head -1
  fi
}

# Fallback gate (only when no -c command): codex's SELF-REPORTED acceptance.json.
# "yes" only when every criterion passes and there are zero blocking failures.
acceptance_self_report() {
  [ -f "$ACCEPT_FILE" ] || { echo "no"; return; }
  if command -v jq >/dev/null 2>&1; then
    local blocking fails
    blocking="$(jq -r '(.blocking_failures // []) | length' "$ACCEPT_FILE" 2>/dev/null)"
    fails="$(jq -r '[(.acceptance // {}) | to_entries[] | select(.value != "pass")] | length' "$ACCEPT_FILE" 2>/dev/null)"
    if [ "${blocking:-1}" = "0" ] && [ "${fails:-1}" = "0" ]; then echo "yes"; else echo "no"; fi
  else
    if grep -qE '"(fail|blocked|error|pending)"' "$ACCEPT_FILE" 2>/dev/null; then echo "no"
    elif grep -qE '"blocking_failures"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$ACCEPT_FILE" 2>/dev/null; then echo "yes"
    elif grep -q '"blocking_failures"' "$ACCEPT_FILE" 2>/dev/null; then echo "no"
    else echo "yes"; fi
  fi
}

# BINDING gate: orchestrator runs the acceptance command and trusts its exit code.
run_acceptance_gate() {
  local i="$1"
  if [ -z "$ACCEPT_CMD" ]; then
    local self; self="$(acceptance_self_report)"
    printf '  gate(SELF-REPORTED, unverified — pass -c "<cmd>" to make this binding): %s\n' "$self" >&2
    [ "$self" = "yes" ] && return 0 || return 1
  fi
  printf '  running acceptance command: %s\n' "$ACCEPT_CMD" >&2
  ( cd "$TARGET" && eval "$ACCEPT_CMD" ) >"$LOOP_DIR/accept-run-$i.log" 2>&1
  local rc=$?
  printf '  acceptance command exit=%s\n' "$rc" >&2
  return "$rc"
}

# Per-iteration review by a different-model reviewer where possible.
run_review() {
  local i="$1" who; who="$(resolve_reviewer)"
  local out="$LOOP_DIR/review-$i.md"
  local prompt="Review ONLY the iteration-$i changes. Check: correctness, drift from the spec (${SPEC:-repo intent}), violations of the anti-requirements${ANTI:+ in $ANTI}, security issues, and any acceptance criterion in .loop/acceptance.json marked pass without a real proving check (reject self-congratulatory passes). Be blunt; list must-fix items first."
  printf '  reviewer: %s\n' "$who" >&2
  if [ "$who" = "gemini" ]; then
    { git -C "$TARGET" --no-pager diff; git -C "$TARGET" --no-pager diff --cached; } 2>/dev/null \
      | run_with_timeout "$REVIEW_TIMEOUT" gemini --approval-mode plan -p "$prompt" \
        >"$out" 2>"$LOOP_DIR/review-$i.err" \
      && return 0
    printf '  (gemini review unavailable; falling back to a builder-family reviewer)\n' >&2
    who="$(other_builder)"; [ -n "$who" ] || who="$BUILDER"
  fi
  if [ "$who" = "prime" ]; then
    # Read-only review: no tools, no session, no autonomous continuation.
    run_with_timeout "$REVIEW_TIMEOUT" env PRIME_DIFF_REVIEW=1 prime-agent -p \
      --cwd "$TARGET" --no-session --no-tools --offline \
      ${prime_model_flag[@]+"${prime_model_flag[@]}"} \
      "$prompt Base your review on this diff:
$( { git -C "$TARGET" --no-pager diff; git -C "$TARGET" --no-pager diff --cached; } 2>/dev/null )" \
      </dev/null >"$out" 2>"$LOOP_DIR/review-$i.err" && return 0
    printf '  (prime review unavailable; falling back to codex)\n' >&2
    codex_ready || return 0
    who=codex
  fi
  # </dev/null: codex exec otherwise inherits the caller's open pipe and blocks on
  # "Reading additional input from stdin..." — same hazard as prime print mode.
  codex exec --full-auto ${model_flag[@]+"${model_flag[@]}"} --cd "$TARGET" \
    "$prompt Write your findings to .loop/review-$i.md." \
    </dev/null >"$LOOP_DIR/review-$i.log" 2>&1 || true
}

gate_desc="$BUILDER self-report (UNVERIFIED)"
[ -n "$ACCEPT_CMD" ] && gate_desc="orchestrator runs: $ACCEPT_CMD"
builder_desc="$BUILDER"
[ "$BUILDER" = "prime" ] && [ ${#prime_auto_flags[@]} -gt 0 ] \
  && builder_desc="prime (+host autonomous-gate, advisory inner loop)"
printf '== ship-pipeline loop ==\n target=%s\n spec=%s\n rubric=%s\n max=%s  rubric-target=%s%% (advisory)\n builder=%s\n gate=%s\n reviewer=%s\n\n' \
  "$TARGET" "${SPEC:-<none>}" "$RUBRIC" "$MAX_ITERS" "$THRESHOLD" "$builder_desc" "$gate_desc" "$(resolve_reviewer)"

[ "$BUILDER" = "prime" ] && printf 'NOTE: prime-agent is not sandboxed — it runs with your user permissions inside %s.\n\n' "$TARGET" >&2

[ -z "$ACCEPT_CMD" ] && printf 'WARNING: no -c acceptance command — the gate is %s self-reported and gameable. Pass -c "<cmd>" (e.g. "npm test") to make it binding.\n\n' "$BUILDER" >&2

anti_block=""
[ -n "$ANTI" ] && [ -f "$ANTI" ] && anti_block="Honor the anti-requirements (hard do-NOTs) in: $ANTI"

i=1
while [ "$i" -le "$MAX_ITERS" ]; do
  printf '\n--- iteration %s/%s ---\n' "$i" "$MAX_ITERS"

  # 0) disk guard: builder iterations churn runtimes/node_modules/logs and this
  #    Mac swap-dies when the Data volume fills. janitor.sh fast-exits <1s when
  #    >=15GB is free. Best-effort by design: a missing or failing janitor must
  #    never kill a build, so this line can only ever help.
  [ -x "$HOME/.disk-janitor/janitor.sh" ] && "$HOME/.disk-janitor/janitor.sh" >>"$LOOP_DIR/janitor.log" 2>&1 || true

  # 1) implement + 2) write advisory acceptance.json + advisory score.json
  build_prompt="You are in ship-pipeline build loop iteration $i/$MAX_ITERS.
Spec (source of acceptance criteria): ${SPEC:-(infer from repo + .loop logs)}. Advisory quality rubric: $RUBRIC.
$anti_block
Do: (1) implement the single highest-value next increment toward the spec; keep changes focused.
(2) Run the project's real tests/build, and verify each acceptance criterion from the spec by an
EXECUTABLE check or observable behavior — not opinion. Write ONLY JSON to .loop/acceptance.json:
{\"iteration\": $i, \"acceptance\": {\"<criterion>\": \"pass\"|\"fail\", ..}, \"blocking_failures\": [\"<criterion>\", ..], \"notes\": \"..\"}.
A criterion is \"pass\" ONLY if a command/test/observation proves it. NOTE: the orchestrator independently
re-runs the real acceptance command as the binding gate, so do not fake passes.
(3) Separately, score the build against EVERY rubric criterion (weighted 0-100) and write ONLY JSON to
.loop/score.json: {\"iteration\": $i, \"score\": <weighted_total_0_100>, \"per_criterion\": {..}, \"notes\": \"..\", \"next\": \"..\"}.
The rubric score is advisory. Never run destructive operations against real/production data; use seeded/throwaway data only."

  if [ "$BUILDER" = "prime" ]; then
    # </dev/null is REQUIRED: in print mode prime-agent merges piped stdin into the
    # prompt, so an inherited open pipe makes it block forever waiting for EOF.
    prime-agent -p --cwd "$TARGET" --no-session \
      ${prime_model_flag[@]+"${prime_model_flag[@]}"} \
      ${prime_auto_flags[@]+"${prime_auto_flags[@]}"} \
      "$build_prompt" \
      </dev/null 2>&1 | tee "$LOOP_DIR/iter-$i.log"
  else
    codex exec --full-auto ${model_flag[@]+"${model_flag[@]}"} --cd "$TARGET" "$build_prompt" \
      </dev/null 2>&1 | tee "$LOOP_DIR/iter-$i.log"
  fi

  # 3) independent review (different model than the builder where possible)
  run_review "$i"

  # 4) BINDING gate: orchestrator runs the real acceptance command
  score="$(read_score)"; score="${score:-0}"
  if run_acceptance_gate "$i"; then
    printf '\nPASS: acceptance gate green after %s iteration(s) (advisory rubric %s).\n' "$i" "$score"
    printf 'Artifacts in %s (acceptance.json, accept-run-*.log, score.json, iter-*.log, review-*.md). Fill the rubric HTML and commit.\n' "$LOOP_DIR"
    exit 0
  fi
  printf 'iteration %s: gate=fail | advisory rubric score %s (target %s)\n' "$i" "$score" "$THRESHOLD"

  i=$((i + 1))
done

printf '\nSTOP: hit max iterations (%s) without the acceptance gate passing. Last advisory score: %s.\n' "$MAX_ITERS" "${score:-0}"
printf 'Check %s/accept-run-*.log + acceptance.json + review-*.md; raise max-iters, adjust the spec, or escalate to claude-council.\n' "$LOOP_DIR"
exit 2
