#!/bin/bash
# Measure `ddev start` time when a project's brand-new (empty) database volume
# is seeded from a base_db seed BAKED INTO THE DBIMAGE ITSELF -- as opposed to
# test-initializer-snapshot.sh, which uses a project-level `initializer`
# snapshot file. See
#   https://docs.ddev.com/en/stable/users/extend/customizing-images/#seeding-a-custom-starter-database-in-dbimage
#   pkg/ddevapp/base_db_seed.go (CustomBaseDBSeedPathPrefix, getDerivedDBImageSeed)
#   containers/ddev-dbserver/files/docker-entrypoint.sh (candidate seed list)
#
# ddev-dbserver looks for /mysqlbase/custom/base_db.{zst,gz,mbstream,xbstream}
# (compressed .zst/.gz preferred over the raw, uncompressed .mbstream/
# .xbstream streams added by ddev/ddev#8704) and restores it instead of the
# stock starter database whenever the mariadb/mysql datadir has not yet been
# initialized (i.e. a fresh volume), UNLESS a project-level `initializer`
# snapshot is also present (that one wins -- see test-initializer-snapshot.sh).
# This script assumes the caller has ALREADY built a dbimage with the seed
# baked in, either via:
#
#   A) a project `.ddev/db-build/Dockerfile` containing
#        COPY base_db.zst /mysqlbase/custom/base_db.zst
#      (built automatically by `ddev start`/`ddev restart`, tagged
#      <dbimage>-<project>-built), or
#
#   B) a standalone `docker build` of an image FROM the stock dbimage plus
#        COPY base_db.zst /mysqlbase/custom/base_db.zst
#      with the resulting tag set as `dbimage:` in .ddev/config.yaml or
#      .ddev/config.local.yaml.
#
# Either way, by the time this script runs, `ddev describe` should already
# show the right image in use -- this script just forces a fresh volume and
# times/verifies the seed.
#
# WARNING: this is destructive to the project's current live database (the
# volume is removed). Only run this after taking a `ddev snapshot` you can
# restore from, or after you no longer need the current DB state.
#
# Usage: test-baked-image-seed.sh <label>
#   <label>  Free-form label recorded in the results CSV (e.g. the snapshot
#            tier name and technique, "medium-db-build" or "xlarge-standalone-image").
#
# Appends one row per run to baked_image_seed_start_times.<platform>.csv in
# the current directory (same shape as test-initializer-snapshot.sh's results
# file).

set -eu -o pipefail

LABEL=${1:?label required, e.g. "medium-db-build" or "xlarge-standalone-image"}

PROJECT_DIR=$PWD
DB_TYPE=$(ddev describe -j | jq -r '.raw.database_type')
DB_VERSION=$(ddev describe -j | jq -r '.raw.database_version')
PROJECT_NAME=$(ddev describe -j | jq -r '.raw.name')
DOCKER_PLATFORM=$(ddev version -j | jq -r '.raw["docker-platform"]')

# Make sure there's no project-level initializer snapshot shadowing the
# baked-in seed -- that would make this test silently measure the wrong path.
for ext in zst gz; do
  candidate="${PROJECT_DIR}/.ddev/db_snapshots/initializer-${DB_TYPE}_${DB_VERSION}.${ext}"
  if [ -f "$candidate" ]; then
    echo "ERROR: an initializer snapshot exists at $candidate and would take priority over the baked-in image seed. Remove it before running this test." >&2
    exit 1
  fi
done

echo "Stopping this project and removing its db volume to force a fresh-volume start..."
ddev stop
docker volume rm "${PROJECT_NAME}-mariadb" 2>/dev/null || docker volume rm "${PROJECT_NAME}-${DB_TYPE}" 2>/dev/null || true

echo "Timing ddev start with baked-in image seed present..."
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

# Same principle as test-initializer-snapshot.sh: trust ddev's own
# announcement (Go-side announceBaseDBSeed), not a reconstruction from
# container logs after the fact.
ddev_start_output=$(cat "$ddev_start_log")
rm -f "$ddev_start_log"
if [[ "$ddev_start_output" == *"baked into dbimage"* ]]; then
  restore_ok=1
else
  echo "FAIL: ddev start never announced a seed baked into dbimage -- it did not use our seed." >&2
  echo "This usually means the dbimage in use doesn't actually have /mysqlbase/custom/base_db.* (check: docker run --rm <dbimage> ls -la /mysqlbase/custom/)." >&2
  echo "Timing/results below reflect whatever it actually restored (likely the stock seed), NOT the baked-in seed -- do not record this as a valid result." >&2
  restore_ok=0
fi

echo "Verifying seeded data..."
row_counts=$(ddev drush sqlq "SELECT (SELECT COUNT(*) FROM node_field_data) AS nodes, (SELECT COUNT(*) FROM users_field_data) AS users;" 2>&1) || row_counts="<query failed: tables likely don't exist -- seed did not happen as expected>"
echo "$row_counts"

# Read this AFTER start (not before), and from the container that's actually
# running now -- querying it beforehand would report the PREVIOUS run's image
# if config.local.yaml just changed the dbimage, since that only takes effect
# on this start.
DBIMAGE_IN_USE=$(ddev describe -j | jq -r '.raw.services.db.image // empty')

if [ "$restore_ok" != "1" ]; then
  echo "Not recording a results row (seed source unverified)." >&2
  exit 1
fi

results_file="${PROJECT_DIR}/baked_image_seed_start_times.${DOCKER_PLATFORM}.csv"
if [ ! -f "$results_file" ]; then
  echo "# hostname: $(hostname)" > "$results_file"
  echo "ddev_version,db_type,db_version,dbimage,label,elapsed_seconds" >> "$results_file"
fi
echo "$(ddev --version | head -1 | awk '{print $3}'),${DB_TYPE},${DB_VERSION},${DBIMAGE_IN_USE:-default},${LABEL},${elapsed}" >> "$results_file"
echo "Recorded in $results_file"
