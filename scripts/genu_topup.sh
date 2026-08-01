#!/bin/bash
# Incrementally grow the users table to a target count using `drush genu`.
#
# devel_generate's genu only dedupes usernames *within one batch* (an
# in-memory array) -- it never checks already-existing DB rows. So calling
# genu repeatedly without --kill eventually collides with a previously
# generated username and dies on a DB unique-key violation. Whatever had
# already been inserted before the collision stays committed (no wrapping
# transaction), so the fix is simply: recheck the actual count, ask for only
# the remaining shortfall, and retry. Each retry batch is smaller, so the
# chance of hitting a duplicate keeps shrinking and this converges quickly.
#
# Usage: genu_topup.sh <target_total_users> [pass] [max_retries]
set -uo pipefail

TARGET=${1:?target total user count required}
PASS=${2:-test}
MAX_RETRIES=${3:-50}

for ((i = 1; i <= MAX_RETRIES; i++)); do
  current=$(ddev drush sqlq "SELECT COUNT(*) FROM users_field_data;" | head -1)
  remaining=$((TARGET - current))

  if [ "$remaining" -le 0 ]; then
    echo "Target reached: ${current} users (target ${TARGET})"
    exit 0
  fi

  echo "[attempt ${i}/${MAX_RETRIES}] current=${current} target=${TARGET} remaining=${remaining}"

  if ddev drush genu "$remaining" --pass="$PASS"; then
    echo "Batch of ${remaining} succeeded cleanly."
  else
    echo "Batch failed partway (likely a username collision) -- rechecking count and retrying the remainder."
  fi
done

final=$(ddev drush sqlq "SELECT COUNT(*) FROM users_field_data;" | head -1)
echo "ERROR: did not reach target ${TARGET} after ${MAX_RETRIES} attempts (stuck at ${final})" >&2
exit 1
