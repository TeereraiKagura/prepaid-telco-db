#!/usr/bin/env sh
# Loads reference data and the synthetic dataset. Uses the standard PG* env vars.
set -eu
cd "$(dirname "$0")/.."

for f in db/seed/*.sql; do
    echo "==> $f"
    psql -X -q -v ON_ERROR_STOP=1 -f "$f"
done
