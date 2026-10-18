#!/usr/bin/env bash
# Build the apps the shell shows (ETFs, Stocks) inside their own cloned repos, with the public URL that
# scripts/serve.ts mounts them at (/ETFs/, /Stocks/: each repo's own build-github-pages script).
# Packages are installed first when a repo has no node_modules. A repo that is not cloned is skipped:
# the server then sends that tab to the app's GitHub Pages site.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

{

APPS=(ETFs Stocks)
[ $# -gt 0 ] && APPS=("$@")

FAILED=0
for app in "${APPS[@]}"; do
  if [ ! -f "$app/package.json" ]; then echo "skip    $app (not cloned: ./scripts/install.sh $app)"; continue; fi
  echo "========================================"
  echo "Building $app"
  echo "========================================"
  (
    cd "$app" || exit 1
    [ -d node_modules ] || bun install --frozen-lockfile || exit 1
    bun run build-github-pages
  ) || { echo "FAILED  $app"; FAILED=$((FAILED + 1)); }
done
[ "$FAILED" -eq 0 ] || exit 1
}
exit $?
