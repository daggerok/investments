#!/usr/bin/env bash
# Install the investments tooling and clone the ETFs hub, Stocks and the 29 ETF brand repos into this folder
# (the parent of scripts/), so the investments app works locally with all the data. Order: git must exist (fails without it), bun is installed
# with the official script when missing, bun i -E installs the investments packages, then the repos are cloned.
# Run the app afterwards with: bun run serve  ->  http://localhost:1234
# Safe to re-run: repos that are already cloned are skipped, nothing existing is touched.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# the whole body is one brace group: bash parses it completely before running anything, so
# replacing this file mid-run (git pull) cannot make bash resume reading at a stale offset
{

OWNER=daggerok
REPOS=(ETFs Stocks AAM aberdeen Amplify ARK Capital-Group Fidelity First-Trust Franklin Global-X Goldman-Sachs Invesco iShares JPMorgan Neos Northern-Trust Pacer Parametric ProShares Schwab SP-Funds SPDR Sprott Tema Themes VanEck Vanguard VictoryShares WisdomTree Xtrackers)

usage() {
  cat <<USAGE
Usage: ./scripts/install.sh [options] [repo ...]

  (no arguments)            clone all ${#REPOS[@]} repos
  repo ...                  clone only these repos, separated by spaces and/or commas:
                              ./scripts/install.sh VanEck Tema
                              ./scripts/install.sh VanEck,Tema
                              ./scripts/install.sh VanEck,Tema SPDR     (names are case-insensitive)

Options:
  -s, --ssh                 clone over SSH (git@github.com:$OWNER/...) instead of HTTPS (also: -ssh)
  -p, --parallel N          number of parallel clones (default 1)
  -d, --depth N             shallow clone with N commits of history (default: normal full clone),
                            e.g. --depth 1 is the fastest and smallest way to just run the app
  -h, --help                show this help

Update the clones later with ./scripts/update.sh
Repos: ${REPOS[*]}
USAGE
}

die() { echo "install.sh: $*" >&2; exit 2; }
is_number() { case "$1" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }

USE_SSH=0
JOBS=1
DEPTH=""
SELECTED=()

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--ssh|-ssh) USE_SSH=1 ;;
    -p|--parallel) [ $# -ge 2 ] || die "$1 expects a number"; JOBS="$2"; shift ;;
    --parallel=*) JOBS="${1#*=}" ;;
    -d|--depth) [ $# -ge 2 ] || die "$1 expects a number"; DEPTH="$2"; shift ;;
    --depth=*) DEPTH="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see ./scripts/install.sh --help)" ;;
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
[ -z "$DEPTH" ] || is_number "$DEPTH" || die "--depth expects a positive number, got '$DEPTH'"

# map the requested names (case-insensitive) to the canonical repo names
if [ ${#SELECTED[@]} -gt 0 ]; then
  LIST=()
  for want in "${SELECTED[@]}"; do
    lower="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
    match=""
    for repo in "${REPOS[@]}"; do
      [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$lower" ] && match="$repo" && break
    done
    [ -n "$match" ] || die "unknown repo: $want (available: ${REPOS[*]})"
    case " ${LIST[*]-} " in *" $match "*) continue ;; esac # a repo listed twice is cloned once (parallel clones of one folder would race)
    LIST+=("$match")
  done
else
  LIST=("${REPOS[@]}")
fi

# --- prerequisites: git is required (fail without it), bun is installed when missing, then bun i -E
fail() { echo "install.sh: $*" >&2; exit 1; }
command -v git >/dev/null 2>&1 || fail "git is not installed; install git first (https://git-scm.com/downloads)"
export PATH="$HOME/.bun/bin:$PATH"
if ! command -v bun >/dev/null 2>&1; then
  echo "bun not found: installing it with the official script (https://bun.sh/install)"
  command -v curl >/dev/null 2>&1 || fail "curl is required to install bun"
  curl -fsSL https://bun.sh/install | bash || fail "the bun installation failed"
  command -v bun >/dev/null 2>&1 || fail "bun was installed into ~/.bun/bin but is not on PATH"
fi
echo "bun $(bun --version) found; installing the investments packages (bun i -E) ..."
bun i -E || fail "bun i -E failed"

if [ "$USE_SSH" = 1 ]; then PREFIX="git@github.com:$OWNER/"; else PREFIX="https://github.com/$OWNER/"; fi
DEPTH_FLAG=""; [ -n "$DEPTH" ] && DEPTH_FLAG="--depth=$DEPTH"

clone_one() {
  repo="$1"
  if [ -d "$repo/.git" ]; then echo "skip    $repo (already cloned)"; return 0; fi
  if [ -e "$repo" ]; then echo "FAILED  $repo (a non-git path with this name exists)"; return 1; fi
  # shellcheck disable=SC2086
  if err="$(git clone -q $DEPTH_FLAG "$PREFIX$repo.git" "$repo" 2>&1)"; then echo "cloned  $repo"; else rm -rf "$repo"; echo "FAILED  $repo ($PREFIX$repo.git): $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
}
export -f clone_one
export PREFIX DEPTH_FLAG

LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT
echo "Cloning ${#LIST[@]} repo(s) into $(pwd) with $JOBS parallel job(s)${DEPTH:+, depth $DEPTH} ..."
printf '%s\n' "${LIST[@]}" | xargs -P "$JOBS" -I{} bash -c 'clone_one {}' | tee "$LOG"

cloned=$(grep -c '^cloned ' "$LOG"); skipped=$(grep -c '^skip ' "$LOG"); failed=$(grep -c '^FAILED ' "$LOG")
echo
echo "Done: $cloned cloned, $skipped skipped, $failed failed."
if [ "$failed" -gt 0 ]; then echo "Re-run ./scripts/install.sh to retry the failed ones (needs network access to github.com)." >&2; exit 1; fi
echo "Next: bun run serve   (open http://localhost:1234)   |   ./scripts/update.sh pulls fresh data later"
}
exit $?
