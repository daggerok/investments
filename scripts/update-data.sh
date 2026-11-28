#!/usr/bin/env bash
# Refresh the data of the repos cloned in the parent folder of scripts/ (the ETFs hub: the ETF brands; investments:
# Stocks and the ETF brands; a repo without data, like the hub itself, is not listed), up to 3 repos at a time,
# with each repo's own updater, then commit and push it the way its update-data.yml workflow does:
#   pull main fast-forward -> bun install --frozen-lockfile -> ./scripts/update-data.ts
#   -> git add api/<feed> -> commit "chore(data): update <Brand> ETF data" -> push (rebase and retry when main moved)
# The feed folder and the commit message are read from the repo's .github/workflows/update-data.yml.
# A repo that is not on main or has uncommitted changes outside its feed folder is skipped and reported, never touched.
# Uncommitted changes inside the feed folder only are the leftover of an interrupted run (the updater writes, the
# commit never came): they are discarded before the pull, since the updater regenerates them anyway.
# A repo whose feed is not in git (Stocks: update-data.yml has no git add/commit and publishes with update-data.ts
# --publish) commits nothing: pull, install, restore the published feed when it is newer than api/<feed> or that is
# empty (./scripts/update-data.ts --restore-from --if-newer, like its workflow), run the updater (with --signals when
# its workflow does), remove the folders of delisted stocks (./scripts/update-data.ts --prune), then publish it with
# ./scripts/update-data.ts --publish (skipped with --no-push).
# Each repo prints when it started and finished and how long it took; the summary repeats it per repo and for the run.
# With no repo named, Stocks starts first (the longest run, owner 2026-11-27), then the ETF brands in name order; named repos run in the order given.
# -p N (--parallel N, also -j N, --jobs N) updates up to N repos at the same time (owner 2026-11-19, -p 2026-11-24); every output line then starts with [<repo>].
# Every run saves its output in logs/update-data/<date>_<time>/: <repo>.log per repo and summary.log (logs/ is
# gitignored, the last 30 runs are kept), so a failed repo can be read afterwards; the summary names each log.
# The same file is ETFs/scripts/update-data.sh (ETFs hub) and scripts/update-data.sh (investments): change both together.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# the whole body is one brace group: bash parses it completely before running anything, so
# replacing this file mid-run (git pull) cannot make bash resume reading at a stale offset
{

usage() {
  cat <<USAGE
Usage: ./scripts/update-data.sh [options] [repo ...]

  (no arguments)            update the data of every cloned repo, up to 3 at a time: Stocks starts first (the
                            longest run), then the ETF brands in name order
  repo ...                  only these repos, separated by spaces and/or commas (case-insensitive):
                              ./scripts/update-data.sh VanEck Tema
                              ./scripts/update-data.sh VanEck,Tema

Options:
  --no-push                 commit the new data but do not push it
  -p N, --parallel N, -j N, --jobs N
                            update up to N repos at the same time (default 3), each output line then starts with
                            [<repo>]; -p 1 updates one after another in plain sections, like a single repo does
                            Also -pN, -jN, --parallel=N, --jobs=N
                            Keep N small (3-4): the repos share the SEC and Yahoo rate limits of your IP
                              ./scripts/update-data.sh -p 4
  -h, --help                show this help

Update controls are environment variables passed to every repo's ./scripts/update-data.ts, e.g.
  REQUEST_SLEEP=1 ./scripts/update-data.sh VanEck
(see "Update controls" in each repo's README). The output streams live; a summary is printed at the end and
the exit code is non-zero if any repo failed. Every run is also saved in logs/update-data/<date>_<time>/
(<repo>.log per repo and summary.log; logs/ is gitignored, the last 30 runs are kept).
USAGE
}

die() { echo "update-data.sh: $*" >&2; exit 2; }

PUSH=1
JOBS=3
SELECTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push) PUSH=0 ;;
    -p|--parallel|-j|--jobs) shift; JOBS="${1:-}"; [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-p needs a positive number of parallel repos" ;;
    --parallel=*|--jobs=*) JOBS="${1#*=}"; [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-p needs a positive number of parallel repos" ;;
    -p[1-9]*|-j[1-9]*) JOBS="${1#-?}"; [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "-p needs a positive number of parallel repos" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see ./scripts/update-data.sh --help)" ;;
    *)
      IFS=',' read -r -a parts <<< "$1"
      for part in ${parts[@]+"${parts[@]}"}; do
        [ -n "$part" ] && SELECTED+=("$part")
      done
      ;;
  esac
  shift
done
command -v git >/dev/null 2>&1 || die "git is required"
command -v bun >/dev/null 2>&1 || die "bun is required (./scripts/install.sh installs it)"

# every cloned repo with data in this folder: a git repo with its own updater and data workflow
CLONED=()
for dir in */; do
  dir="${dir%/}"
  [ -d "$dir/.git" ] && [ -f "$dir/scripts/update-data.ts" ] && [ -f "$dir/.github/workflows/update-data.yml" ] && CLONED+=("$dir")
done
[ ${#CLONED[@]} -gt 0 ] || die "no cloned data repos here: run ./scripts/install.sh first"
# Stocks is the longest single run (about 17 minutes): it starts first, the ETF brands follow in name order (owner 2026-11-27)
FIRST=()
REST=()
for repo in "${CLONED[@]}"; do
  if [ "$repo" = "Stocks" ]; then FIRST+=("$repo"); else REST+=("$repo"); fi
done
CLONED=(${FIRST[@]+"${FIRST[@]}"} ${REST[@]+"${REST[@]}"})

if [ ${#SELECTED[@]} -gt 0 ]; then
  LIST=()
  for want in "${SELECTED[@]}"; do
    lower="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
    match=""
    for repo in "${CLONED[@]}"; do
      [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$lower" ] && match="$repo" && break
    done
    [ -n "$match" ] || die "not cloned: $want (cloned: ${CLONED[*]}); run ./scripts/install.sh $want"
    case " ${LIST[*]-} " in *" $match "*) ;; *) LIST+=("$match") ;; esac
  done
else
  LIST=("${CLONED[@]}")
fi

RESULTS=()
FAILED=0
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
# the output of every run, readable after it: logs/update-data/<date>_<time>/<repo>.log and summary.log (gitignored)
LOGS="logs/update-data/$(date '+%Y-%m-%d_%H%M%S')"
mkdir -p "$LOGS" || die "cannot create $LOGS"
ls -1 logs/update-data | sort -r | tail -n +31 | while read -r old; do rm -rf "logs/update-data/$old"; done

# the reason a repo failed: printed in its section and shown again in the summary line
fail() { UPDATE_STATE="$1"; echo "$1"; }

# the feed is not in git and the workflow publishes it with --publish (Stocks): update it locally and publish, commit nothing
publishes_itself() { grep -qE 'update-data\.ts --publish|actions/upload-pages-artifact' "$1/.github/workflows/update-data.yml"; }
update_local_only() {
  local repo="$1" workflow="$2" feed branch code
  feed="$(sed -nE 's/^[[:space:]]*path: (api\/[A-Za-z0-9._-]+)[[:space:]]*$/\1/p' "$workflow" | head -1)"
  [ -n "$feed" ] || { fail "cannot read the feed folder from $workflow"; return 1; }
  local signals=()
  grep -qE 'update-data\.ts[^#]*--signals' "$workflow" && signals=(--signals)
  cd "$repo" || { fail "cannot enter $repo"; return 1; }
  branch="$(git branch --show-current)"
  [ "$branch" = "main" ] || { fail "on '${branch:-detached HEAD}', not main: skipped (switch to main first)"; return 1; }
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "uncommitted changes: skipped (commit or stash them first)"; git status --short --untracked-files=no; return 1
  fi
  echo "Pulling main (fast-forward only)..."
  git pull --ff-only origin main || { fail "git pull --ff-only failed (local main diverged from origin?)"; return 1; }
  echo "Installing packages..."
  bun install --frozen-lockfile || { fail "bun install --frozen-lockfile failed"; return 1; }
  # like the workflow: start from the published feed when it is newer than the local one (a workflow run on GitHub)
  # or the local one is empty; an up to date local feed is kept as it is
  echo "Restoring the published feed when it is newer (./scripts/update-data.ts --restore-from --if-newer) ..."
  bun ./scripts/update-data.ts --restore-from --if-newer || { fail "restoring the published $feed failed"; return 1; }
  echo "Running ./scripts/update-data.ts ${signals[*]-}..."
  bun ./scripts/update-data.ts ${signals[@]+"${signals[@]}"}
  code=$?
  [ $code -eq 0 ] || { fail "update-data.ts exited $code: $feed updated locally, not published"; return $code; }
  # the folders of delisted stocks the index dropped (no price for 60 days): removed on every run, not by hand once a quarter
  if grep -q -- "'--prune'" scripts/update-data.ts; then
    echo "Removing delisted folders (./scripts/update-data.ts --prune) ..."
    bun ./scripts/update-data.ts --prune || echo "update-data.ts --prune failed: the delisted folders stay, publishing anyway"
  fi
  if [ "$PUSH" -eq 0 ]; then UPDATE_STATE="$feed updated locally, not published (--no-push)"; return 0; fi
  echo "Publishing (./scripts/update-data.ts --publish) ..."
  bun ./scripts/update-data.ts --publish || { fail "$feed updated locally, update-data.ts --publish failed"; return 1; }
  UPDATE_STATE="$feed updated and published, nothing committed"
}

update_repo() {
  local repo="$1" workflow feed message branch attempt code
  workflow="$repo/.github/workflows/update-data.yml"
  feed="$(sed -nE 's/^[[:space:]]*git add (api\/[A-Za-z0-9._-]+).*/\1/p' "$workflow" | head -1)"
  message="$(sed -nE 's/^[[:space:]]*git commit -m "([^"]+)".*/\1/p' "$workflow" | head -1)"
  if [ -z "$feed" ] && publishes_itself "$repo"; then
    update_local_only "$repo" "$workflow"; return $?
  fi
  [ -n "$feed" ] && [ -n "$message" ] || { fail "cannot read the feed folder or the commit message from $workflow"; return 1; }

  cd "$repo" || { fail "cannot enter $repo"; return 1; }
  branch="$(git branch --show-current)"
  [ "$branch" = "main" ] || { fail "on '${branch:-detached HEAD}', not main: skipped (switch to main first)"; return 1; }
  if [ -n "$(git status --porcelain --untracked-files=no -- . ":(exclude)$feed")" ]; then
    fail "uncommitted changes outside $feed: skipped (commit or stash them first)"; git status --short --untracked-files=no -- . ":(exclude)$feed"; return 1
  fi
  if [ -n "$(git status --porcelain -- "$feed")" ]; then
    # only the data folder is dirty: an earlier run wrote it and was interrupted before the commit
    echo "leftover data of an interrupted run in $feed: discarded, the updater regenerates it"
    git checkout -q -- "$feed" && git clean -qfd -- "$feed" || { fail "cannot discard the leftover data in $feed"; return 1; }
  fi

  echo "Pulling main (fast-forward only)..."
  git pull --ff-only origin main || { fail "git pull --ff-only failed (local main diverged from origin?)"; return 1; }
  echo "Installing packages..."
  bun install --frozen-lockfile || { fail "bun install --frozen-lockfile failed"; return 1; }

  echo "Running ./scripts/update-data.ts ..."
  bun ./scripts/update-data.ts
  code=$?
  # like the workflow: a run that failed for some funds still keeps every fund complete, so its data is committed
  [ $code -eq 0 ] || echo "update-data.ts exited with $code: committing what it wrote, like the workflow"

  git add "$feed" || { fail "git add $feed failed"; return 1; }
  if git diff --cached --quiet -- "$feed"; then
    echo "$feed is already up to date"
    UPDATE_STATE="unchanged$( [ $code -eq 0 ] || echo ", update-data.ts exited $code")"
    return $code
  fi
  git commit -q -m "$message" -- "$feed" || { fail "git commit failed"; return 1; }
  UPDATE_STATE="committed $(git rev-parse --short HEAD)"
  [ $code -eq 0 ] || UPDATE_STATE="$UPDATE_STATE (update-data.ts exited $code, some funds failed: see the section above)"
  [ "$PUSH" -eq 1 ] || { UPDATE_STATE="$UPDATE_STATE, not pushed (--no-push)"; return $code; }
  # main may have moved while the updater ran (a CI data commit, a merge): rebase the data commit and retry
  for attempt in 1 2 3 4; do
    if git push -q origin main; then UPDATE_STATE="$UPDATE_STATE, pushed"; return $code; fi
    echo "push rejected: rebasing onto origin/main (attempt $attempt)"
    git pull --rebase -q origin main || { git rebase --abort 2>/dev/null; fail "rebase onto origin/main failed: the data commit stays local"; return 1; }
    UPDATE_STATE="committed $(git rev-parse --short HEAD)"
  done
  fail "push failed 4 times: the data commit stays local"
  return 1
}

# 1h02m03s, 4m05s or 7s
dur() { local t=$1; if [ "$t" -ge 3600 ]; then printf '%dh%02dm%02ds' $((t / 3600)) $((t % 3600 / 60)) $((t % 60));
  elif [ "$t" -ge 60 ]; then printf '%dm%02ds' $((t / 60)) $((t % 60)); else printf '%ds' "$t"; fi; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
RUN_START=$(now); RUN_SECONDS=$SECONDS
# one repo, or -p 1: the plain sections, one after another
if [ "$JOBS" -gt 1 ] && [ ${#LIST[@]} -gt 1 ]; then
  # parallel: each repo in its own background job with prefixed output; the results are read from $OUT afterwards
  echo "Updating the data of ${#LIST[@]} repo(s), up to $JOBS at a time, started $RUN_START ..."
  for repo in "${LIST[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || true; done
    (
      UPDATE_STATE=""
      started=$SECONDS; start_at=$(date '+%H:%M:%S')
      echo "Started $(now)"
      ( update_repo "$repo"; echo "$?|$UPDATE_STATE" > "$OUT/$repo" )
      echo "$start_at|$(date '+%H:%M:%S')|$(dur $((SECONDS - started)))" > "$OUT/$repo.time"
      echo "Finished $(now), took $(dur $((SECONDS - started)))"
    ) 2>&1 | tee "$LOGS/$repo.log" | awk -v p="[$repo] " '{ print p $0; fflush() }' &
  done
  wait
  for repo in "${LIST[@]}"; do
    IFS='|' read -r code state < "$OUT/$repo" 2>/dev/null || { code=1; state=""; }
    IFS='|' read -r start_at end_at took < "$OUT/$repo.time" 2>/dev/null || { start_at="?"; end_at="?"; took="?"; }
    if [ "$code" -eq 0 ]; then RESULTS+=("OK      $repo: ${state:-done} ($start_at -> $end_at, $took)")
    else RESULTS+=("FAILED  $repo: ${state:-not committed} (exit $code, $start_at -> $end_at, $took), log: $LOGS/$repo.log"); FAILED=$((FAILED + 1)); fi
  done
  LIST_DONE=1
fi
[ "${LIST_DONE:-0}" -eq 1 ] || echo "Updating the data of ${#LIST[@]} repo(s), one after another, started $RUN_START ..."
[ "${LIST_DONE:-0}" -eq 1 ] || for repo in "${LIST[@]}"; do
  echo "========================================"
  echo "$repo"
  echo "========================================"
  started=$SECONDS; start_at=$(date '+%H:%M:%S')
  {
    UPDATE_STATE=""
    echo "Started $(now)"
    ( update_repo "$repo"; echo "$?|$UPDATE_STATE" > "$OUT/$repo" )
    echo "Finished $(now), took $(dur $((SECONDS - started)))"
  } 2>&1 | tee "$LOGS/$repo.log"
  IFS='|' read -r code state < "$OUT/$repo" 2>/dev/null || { code=1; state=""; }
  took=$(dur $((SECONDS - started))); end_at=$(date '+%H:%M:%S')
  if [ "$code" -eq 0 ]; then RESULTS+=("OK      $repo: ${state:-done} ($start_at -> $end_at, $took)")
  else RESULTS+=("FAILED  $repo: ${state:-not committed} (exit $code, $start_at -> $end_at, $took), log: $LOGS/$repo.log"); FAILED=$((FAILED + 1)); fi
  echo
done

{
  echo "========================================"
  echo "Summary"
  echo "========================================"
  printf '%s\n' "${RESULTS[@]}"
  echo "Done: $((${#LIST[@]} - FAILED)) ok, $FAILED failed."
  echo "Started $RUN_START, finished $(now), took $(dur $((SECONDS - RUN_SECONDS)))"
  echo "Logs: $LOGS"
} | tee "$LOGS/summary.log"
[ "$FAILED" -eq 0 ] || exit 1
}
exit $?
