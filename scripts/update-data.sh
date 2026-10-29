#!/usr/bin/env bash
# Refresh the data of the repos cloned in the investments folder (the parent of scripts/): Stocks and the ETF brands
# (the ETFs hub has no data), one repo after another,
# with each repo's own updater, then commit and push it the way its update-data.yml workflow does:
#   pull main fast-forward -> bun install --frozen-lockfile -> ./scripts/update-data.ts
#   -> git add api/<feed> -> commit "chore(data): update <Brand> ETF data" (Stocks: "chore(data): update Stocks data") -> push (rebase and retry when main moved)
# The feed folder and the commit message are read from the repo's .github/workflows/update-data.yml.
# A repo that is not on main or has uncommitted changes outside its feed folder is skipped and reported, never touched.
# Uncommitted changes inside the feed folder only are the leftover of an interrupted run (the updater writes, the
# commit never came): they are discarded before the pull, since the updater regenerates them anyway.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# the whole body is one brace group: bash parses it completely before running anything, so
# replacing this file mid-run (git pull) cannot make bash resume reading at a stale offset
{

usage() {
  cat <<USAGE
Usage: ./scripts/update-data.sh [options] [repo ...]

  (no arguments)            update the data of every cloned repo, one after another
  repo ...                  only these repos, separated by spaces and/or commas (case-insensitive):
                              ./scripts/update-data.sh VanEck Tema
                              ./scripts/update-data.sh VanEck,Tema

Options:
  --no-push                 commit the new data but do not push it
  -h, --help                show this help

Update controls are environment variables passed to every repo's ./scripts/update-data.ts, e.g.
  REQUEST_SLEEP=1 ./scripts/update-data.sh VanEck
(see "Update controls" in each repo's README). The output streams live; a summary is printed at the end and
the exit code is non-zero if any repo failed.
USAGE
}

die() { echo "update-data.sh: $*" >&2; exit 2; }

PUSH=1
SELECTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push) PUSH=0 ;;
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

# the reason a repo failed: printed in its section and shown again in the summary line
fail() { UPDATE_STATE="$1"; echo "$1"; }

update_repo() {
  local repo="$1" workflow feed message branch attempt code
  workflow="$repo/.github/workflows/update-data.yml"
  feed="$(sed -nE 's/^[[:space:]]*git add (api\/[A-Za-z0-9._-]+).*/\1/p' "$workflow" | head -1)"
  message="$(sed -nE 's/^[[:space:]]*git commit -m "([^"]+)".*/\1/p' "$workflow" | head -1)"
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

echo "Updating the data of ${#LIST[@]} repo(s), one after another ..."
for repo in "${LIST[@]}"; do
  echo "========================================"
  echo "$repo"
  echo "========================================"
  UPDATE_STATE=""
  started=$SECONDS
  ( update_repo "$repo"; echo "$?|$UPDATE_STATE" > "$OUT/$repo" )
  IFS='|' read -r code state < "$OUT/$repo" 2>/dev/null || { code=1; state=""; }
  took=$((SECONDS - started))
  if [ "$code" -eq 0 ]; then RESULTS+=("OK      $repo: ${state:-done} (${took}s)")
  else RESULTS+=("FAILED  $repo: ${state:-not committed} (exit $code, ${took}s)"); FAILED=$((FAILED + 1)); fi
  echo
done

echo "========================================"
echo "Summary"
echo "========================================"
printf '%s\n' "${RESULTS[@]}"
echo "Done: $((${#LIST[@]} - FAILED)) ok, $FAILED failed."
[ "$FAILED" -eq 0 ] || exit 1
}
exit $?
