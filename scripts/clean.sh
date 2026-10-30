#!/usr/bin/env bash
# Remove the repos cloned in the investments folder (the parent of scripts/): ETFs hub, Stocks and the ETF brands.
# A repo with uncommitted changes, ignored files, unpushed commits, a detached-HEAD commit or stash entries
# is NEVER removed, and neither is a repo on which git itself errors: it is kept with a message (commit/push it,
# or delete it by hand). Untracked .idea/ and the ignored node_modules/, dist/ and .parcel-cache/ do not count.
# Only the known repos are touched; the investments files themselves are never removed.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# the whole body is one brace group: bash parses it completely before running anything, so
# replacing this file mid-run (git pull) cannot make bash resume reading at a stale offset
{

REPOS=(ETFs Stocks AAM aberdeen Amplify ARK Capital-Group Fidelity First-Trust Franklin Global-X Goldman-Sachs Invesco iShares JPMorgan Neos Northern-Trust Pacer Parametric ProShares Schwab SP-Funds SPDR Sprott Tema Themes VanEck Vanguard VictoryShares WisdomTree Xtrackers)

usage() {
  cat <<USAGE
Usage: ./scripts/clean.sh [options] [repo ...]

  (no arguments)            remove every cloned repo
  repo ...                  remove only these repos, separated by spaces and/or commas:
                              ./scripts/clean.sh VanEck Tema
                              ./scripts/clean.sh VanEck,Tema
                              ./scripts/clean.sh VanEck,Tema SPDR       (names are case-insensitive)

Options:
  -p, --parallel N          number of repos removed in parallel (default 1)
  -h, --help                show this help

Clone them again with ./scripts/install.sh
USAGE
}

die() { echo "clean.sh: $*" >&2; exit 2; }
is_number() { case "$1" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }

JOBS=1
SELECTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--parallel) [ $# -ge 2 ] || die "$1 expects a number"; JOBS="$2"; shift ;;
    --parallel=*) JOBS="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see ./scripts/clean.sh --help)" ;;
    *)
      IFS=',' read -r -a parts <<< "$1"
      for part in ${parts[@]+"${parts[@]}"}; do
        [ -n "$part" ] && SELECTED+=("$part")
      done
      ;;
  esac
  shift
done
is_number "$JOBS" || die "--parallel expects a positive number, got '$JOBS'"

# cloned = a real directory (not a symlink) with its own .git
CLONED=()
for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] && [ ! -L "$repo" ] && CLONED+=("$repo")
done

if [ ${#SELECTED[@]} -gt 0 ]; then
  LIST=()
  for want in "${SELECTED[@]}"; do
    lower="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
    match=""
    for repo in "${REPOS[@]}"; do
      [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$lower" ] && match="$repo" && break
    done
    [ -n "$match" ] || die "unknown repo: $want (known: ${REPOS[*]})"
    case " ${LIST[*]-} " in *" $match "*) continue ;; esac # a repo listed twice is removed once
    LIST+=("$match")
  done
else
  LIST=(${CLONED[@]+"${CLONED[@]}"})
fi
[ ${#LIST[@]} -gt 0 ] || { echo "Nothing to remove: no cloned repos here."; exit 0; }

clean_one() {
  repo="$1"
  if [ ! -d "$repo/.git" ] || [ -L "$repo" ]; then echo "skip    $repo (not cloned)"; return 0; fi
  # fail closed: when git itself errors (corrupt repo, dubious ownership, ...), nothing is deleted
  if ! status="$(git -C "$repo" status --porcelain --ignored 2>&1)"; then echo "KEPT    $repo (git status failed: $(printf '%s' "$status" | head -1)): inspect it by hand"; return 1; fi
  if ! unpushed="$(git -C "$repo" log --branches --not --remotes --oneline 2>&1)"; then echo "KEPT    $repo (git log failed): inspect it by hand"; return 1; fi
  if ! stash="$(git -C "$repo" stash list 2>&1)"; then echo "KEPT    $repo (git stash failed): inspect it by hand"; return 1; fi
  # a commit reachable only from HEAD (made on a detached HEAD) is lost with the folder; git log --not would negate HEAD itself
  if ! detached="$(git -C "$repo" rev-list -n1 HEAD --not --branches --remotes 2>&1)"; then echo "KEPT    $repo (git rev-list failed): inspect it by hand"; return 1; fi
  reasons=""
  # untracked/ignored .idea/ and the ignored node_modules/, dist/ and .parcel-cache/ (packages and build output) do not count; any other change or ignored file does
  [ -n "$(printf '%s\n' "$status" | grep -v -e '^$' -e '^?? \.idea/$' -e '^!! \.idea/$' -e '^!! node_modules/$' -e '^!! dist/$' -e '^!! \.parcel-cache/$')" ] && reasons="uncommitted or ignored files"
  [ -n "$unpushed" ] && reasons="${reasons:+$reasons, }unpushed commits"
  [ -n "$detached" ] && reasons="${reasons:+$reasons, }detached HEAD commit"
  [ -n "$stash" ] && reasons="${reasons:+$reasons, }stash entries"
  if [ -n "$reasons" ]; then echo "KEPT    $repo ($reasons): commit/push it first, or remove it by hand with: rm -rf $repo"; return 1; fi
  if rm -rf "$repo"; then echo "removed $repo"; else echo "FAILED  $repo (could not remove)"; return 1; fi
}
export -f clean_one

LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
echo "Removing ${#LIST[@]} repo(s) from $(pwd) with $JOBS parallel job(s) ..."
printf '%s\n' "${LIST[@]}" | xargs -P "$JOBS" -I{} bash -c 'clean_one {}' | tee "$LOG"

removed=$(grep -c '^removed ' "$LOG"); skipped=$(grep -c '^skip ' "$LOG"); kept=$(grep -c '^KEPT ' "$LOG"); failed=$(grep -c '^FAILED ' "$LOG")
echo
echo "Done: $removed removed, $skipped skipped, $kept kept (unsaved work), $failed failed."
[ $((kept + failed)) -eq 0 ] || exit 1
}
exit $?
