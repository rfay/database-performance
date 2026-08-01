#!/bin/bash
# Measure `ddev start` time when a project's brand-new (empty) database volume
# is seeded from a reserved `initializer` snapshot -- see
# https://github.com/ddev/ddev/pull/8608 and pkg/ddevapp/base_db_seed.go
# (InitializerSnapshotName = "initializer") in the ddev/ddev repo.
#
# ddev-dbserver's docker-entrypoint.sh looks for
#   .ddev/db_snapshots/initializer-<db_type>_<db_version>.{zst,gz}
# (zst preferred) and restores it instead of the stock starter database
# whenever the mariadb/mysql datadir has not yet been initialized (i.e. a
# fresh volume). This script:
#
#   1. Copies an existing named `ddev snapshot` to the reserved
#      `initializer-<type>_<version>` filename (the original snapshot is left
#      alone, so it stays restorable the normal way).
#   2. Powers off the project and removes its db volume, forcing a truly
#      fresh-volume `ddev start`.
#   3. Times `ddev start` end-to-end.
#   4. Verifies the seeded data landed (node/user counts) as a sanity check,
#      not just "ddev start returned success".
#   5. Removes the `initializer-*` file again afterward (default), since
#      leaving it in place would seed *every future* fresh-volume start for
#      this project, not just this test run.
#
# WARNING: this is destructive to the project's current live database (the
# volume is removed). Only run this after taking a `ddev snapshot` you can
# restore from, or after you no longer need the current DB state.
#
# Usage: test-initializer-snapshot.sh <ddev-snapshot-name> [--keep-initializer]
#   <ddev-snapshot-name>  Name passed to `ddev snapshot --name=...` earlier
#                         (the script resolves the actual
#                         .ddev/db_snapshots/<name>-<type>_<version>.zst file).
#
# Appends one row per run to initializer_start_times.<platform>.csv in the
# current directory (same shape as compare-imports.sh's results file).

set -eu -o pipefail

SNAPSHOT_NAME=${1:?ddev snapshot name required (as passed to ddev snapshot --name=...)}
KEEP_INITIALIZER=${2:-}

PROJECT_DIR=$PWD
DB_TYPE=$(ddev describe -j | jq -r '.raw.database_type')
DB_VERSION=$(ddev describe -j | jq -r '.raw.database_version')
PROJECT_NAME=$(ddev describe -j | jq -r '.raw.name')
DOCKER_PLATFORM=$(ddev version -j | jq -r '.raw["docker-platform"]')

SNAPSHOT_FILE=""
for ext in zst gz; do
  candidate="${PROJECT_DIR}/.ddev/db_snapshots/${SNAPSHOT_NAME}-${DB_TYPE}_${DB_VERSION}.${ext}"
  if [ -f "$candidate" ]; then
    SNAPSHOT_FILE="$candidate"
    break
  fi
done
if [ -z "$SNAPSHOT_FILE" ]; then
  echo "ERROR: no snapshot file found matching ${SNAPSHOT_NAME}-${DB_TYPE}_${DB_VERSION}.{zst,gz} in .ddev/db_snapshots/" >&2
  exit 1
fi

INITIALIZER_FILE="${PROJECT_DIR}/.ddev/db_snapshots/initializer-${DB_TYPE}_${DB_VERSION}.${SNAPSHOT_FILE##*.}"
SNAPSHOT_SIZE=$(ls -l "$SNAPSHOT_FILE" | awk '{print $5}')

echo "Using snapshot: $SNAPSHOT_FILE ($SNAPSHOT_SIZE bytes) as initializer for ${DB_TYPE}_${DB_VERSION}"
cp "$SNAPSHOT_FILE" "$INITIALIZER_FILE"

echo "Stopping this project and removing its db volume to force a fresh-volume start..."
# Project-scoped (not `ddev poweroff`, which would stop every other DDEV
# project on the machine too) -- matches the pattern ddev's own test suite
# uses (app.Stop() + dockerutil.RemoveVolume(app.Name + "-mariadb")).
ddev stop
docker volume rm "${PROJECT_NAME}-mariadb" 2>/dev/null || docker volume rm "${PROJECT_NAME}-${DB_TYPE}" 2>/dev/null || true

echo "Timing ddev start with initializer seed present..."
ddev_start_log=$(mktemp)
start_time=$(date +%s)
ddev start -y 2>&1 | tee "$ddev_start_log"
ddev_start_status=${PIPESTATUS[0]}
end_time=$(date +%s)
elapsed=$((end_time - start_time))
if [ "$ddev_start_status" -ne 0 ]; then
  echo "ERROR: ddev start exited ${ddev_start_status}" >&2
  rm -f "$ddev_start_log"
  exit 1
fi

echo "ddev start took ${elapsed}s"

# Don't trust a bare "ddev start succeeded" -- the dbserver image silently
# falls back to the stock/derived-image seed if it doesn't recognize the
# initializer file at all (e.g. an image built before this feature existed),
# and that fallback also returns success in well under a minute. The most
# direct, authoritative signal is ddev's OWN announcement (Go-side
# AnnounceBaseDBSeed, printed by `ddev start` itself before the restore even
# begins) -- not something reconstructed after the fact from container logs.
ddev_start_output=$(cat "$ddev_start_log")
rm -f "$ddev_start_log"
if [[ "$ddev_start_output" == *"Initializing new database volume from the 'initializer' snapshot"* ]]; then
  restore_ok=1
else
  echo "FAIL: ddev start never announced using the 'initializer' snapshot -- it did not use our seed file." >&2
  echo "This usually means the running dbserver image's entrypoint predates the initializer-seed feature (check: docker exec ddev-${PROJECT_NAME}-db grep -n initializer /docker-entrypoint.sh)." >&2
  echo "Timing/results below reflect whatever it actually restored (likely the stock/derived-image seed), NOT the initializer snapshot -- do not record this as a valid result." >&2
  restore_ok=0
fi

echo "Verifying seeded data..."
row_counts=$(ddev drush sqlq "SELECT (SELECT COUNT(*) FROM node_field_data) AS nodes, (SELECT COUNT(*) FROM users_field_data) AS users;" 2>&1) || row_counts="<query failed: tables likely don't exist -- seed did not happen as expected>"
echo "$row_counts"

if [ "$restore_ok" != "1" ]; then
  echo "Not recording a results row (seed source unverified) and leaving the initializer file in place for you to investigate." >&2
  exit 1
fi

results_file="${PROJECT_DIR}/initializer_start_times.${DOCKER_PLATFORM}.csv"
if [ ! -f "$results_file" ]; then
  echo "# hostname: $(hostname)" > "$results_file"
  echo "ddev_version,db_type,db_version,snapshot_name,snapshot_size_bytes,elapsed_seconds" >> "$results_file"
fi
echo "$(ddev --version | head -1 | awk '{print $3}'),${DB_TYPE},${DB_VERSION},${SNAPSHOT_NAME},${SNAPSHOT_SIZE},${elapsed}" >> "$results_file"
echo "Recorded in $results_file"

if [ "$KEEP_INITIALIZER" != "--keep-initializer" ]; then
  echo "Removing the initializer file (pass --keep-initializer to leave it in place)..."
  rm -f "$INITIALIZER_FILE"
fi
