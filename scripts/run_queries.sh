#!/usr/bin/env sh
# Runs every business-question query and prints the results.
# Pass a prefix to run a subset, e.g.  sh scripts/run_queries.sh 01
set -eu
cd "$(dirname "$0")/.."

for f in queries/"${1:-}"*.sql; do
    echo
    echo "==> $f"
    psql -X -v ON_ERROR_STOP=1 -P pager=off -f "$f"
done
