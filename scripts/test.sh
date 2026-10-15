#!/usr/bin/env sh
# Runs each SQL test file in its own session (with the shared helpers loaded).
# Any failed assertion raises an error, which stops the run with a non-zero exit.
set -eu
cd "$(dirname "$0")/.."

for f in tests/[0-9]*.sql; do
    echo "==> $f"
    psql -X -q -v ON_ERROR_STOP=1 -f tests/helpers.sql -f "$f"
done
echo "All tests passed."
