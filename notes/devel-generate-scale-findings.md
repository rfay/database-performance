# Scaling devel_generate to large node/user counts (Drupal 11 / Umami profile)

Context: a DDEV Drupal 11 project (Umami profile: `article`, `page`, `recipe`
node bundles), building progressively larger databases (Medium: 20K
users/100K nodes -> Large: 100K users/500K nodes -> Xlarge: 500K users/2M
nodes) using `drupal/devel` + `devel_generate`, without ever wiping data
between tiers.

## Speeding up generation: bcrypt cost

Password hashing at the default bcrypt cost (12) takes ~300-350ms per hash.
Since `genc` assigns random existing users as node authors, and `genu` hashes
a password per created user, this throttles both commands. Dropping cost to
5 in a project-local `web/sites/default/services.yml` (copy
`default.services.yml` if no override exists yet) took hashing from ~350ms
to ~1.5ms:

```yaml
password.options:
  cost: 5
```

Then `ddev drush cr`. **This is disposable-dev-database-only** -- revert
before this ever goes near production data (delete the file, `ddev drush cr`).

Measured throughput with this tuning, in this environment: **~100-270
users/sec** (varies with batch size / existing table size, see below),
**~70-100 nodes/sec**.

## The `genu` username-collision bug

`devel_generate`'s `UserDevelGenerate::generateElements()`
(`web/modules/contrib/devel/devel_generate/src/Plugin/DevelGenerate/UserDevelGenerate.php`)
generates usernames like this:

```php
$names = [];
while (count($names) < $num) {
  $name = $this->getRandom()->word(mt_rand(6, 12));
  $names[$name] = '';
}
// ...then inserts each one via $account->save()
```

`Random::word()` (`core/lib/Drupal/Component/Utility/Random.php`) has **no
built-in uniqueness tracking** -- it's plain consonant+vowel syllable
concatenation with `mt_rand()`. The `$names[$name]` array only dedupes
*within one call's batch*. There is no query against existing DB rows before
insert.

Consequence: calling `genu` more than once (or once against a table that
already has devel-generated users in it) will, sooner or later, generate a
username that already exists in `users_field_data`, and the whole batch dies
on a `SQLSTATE[23000]` unique-key violation -- after however many rows it
managed to insert before hitting the duplicate (no wrapping transaction, so
partial progress is retained).

Empirically, `Random::word(mt_rand(6,12))`'s effective namespace is roughly
**~5 million combinations** (fit from observed collision points at several
different existing-pool sizes). That means:

- Net new users per `genu` call before a crash is roughly `namespace_size /
  existing_user_count` -- e.g. ~150 at a 30K-user pool, dropping to ~10-45 as
  the pool approaches 100K-500K.
- A **whole-batch retry loop** (see `scripts/genu_topup.sh`) works but scales
  poorly: going from 100K to 500K users this way would need on the order of
  tens of thousands of retries (each `ddev drush genu` invocation has ~1-3s
  of bootstrap overhead on top of whatever it manages to insert), i.e. many
  hours just for the retry churn.

### Fix 1: `scripts/genu_topup.sh` -- retry-until-target wrapper

Good for **topping up moderate amounts** (e.g. 20K -> 100K users). Rechecks
the actual DB count, requests only the shortfall, and retries on failure
(partial inserts from a failed batch are never lost). Needs a large
`max_retries` as the existing pool grows -- yield per attempt shrinks, it
does not stay constant. Do not reach for this past a few hundred K existing
users; see Fix 2.

```bash
scripts/genu_topup.sh <target_total_users> [pass] [max_retries]
```

### Fix 2: `scripts/genu_fast.php` -- collision-proof generator (recommended for big jumps)

Run via `ddev drush php:script genu_fast.php -- <count> [pass]` (the script
must live under the project docroot / be on drush's script path -- it is
not resolved against arbitrary host paths).

Instead of retrying against `genu`'s flawed dedup, this creates users
directly with `Random::word()` **plus a random 8-hex-char suffix**
(`bin2hex(random_bytes(4))`). This can never collide with plain-word()
usernames (they contain no underscore) and has ~4.3 billion possible
suffixes, so collision probability stays negligible at any scale this
project needs. No DB uniqueness check is even necessary.

Measured: 398,000 users (100K -> 500K) in 21m43s (~305/sec, flat -- no
degradation as the pool grew), zero collisions, zero retries. This is the
right tool once the existing user pool is large enough that
`genu_topup.sh`'s retry yield starts dropping into the tens-per-attempt
range.

Note: this script skips `DevelGenerateBase::populateFields()` -- fine here
since the only non-base field on this project's `user` bundle is
`user_picture`, which devel_generate doesn't populate by default anyway. If
a project has meaningful custom user fields, port that call in.

## `genc` (nodes) has no such problem

Node titles/bodies have no uniqueness constraint, so `genc` is naturally
idempotent/additive: just omit `--kill` and call it again with the
additional count needed. No retry wrapper needed. Measured steady-state:
~70-100 nodes/sec regardless of existing table size (no birthday-paradox
degradation, unlike usernames).

## `--kill` is a trap for iterative builds

`ContentDevelGenerate::contentKill()` deletes **all nodes of the given
bundles**, not just devel-generated ones -- and `UserDevelGenerate`'s kill
path deletes **all non-uid-1 users**. Both operate through the full entity
API (load + delete each entity with all hooks/fields/revisions), which is
dramatically slower than generation itself: deleting ~25K accumulated nodes
this way took several minutes and was still not visibly progressing when
checked.

**Don't delete-and-regenerate to fix a bad state.** Instead:

- Keep a known-good `ddev snapshot` (or plain SQL export) from *before* a
  risky operation.
- If something goes wrong mid-run, `ddev snapshot restore <name>` (or
  `ddev import-db --file=...`) is dramatically faster than an entity-API
  bulk delete -- a ~1GB DB restored via `ddev import-db` in ~10s vs. minutes
  for `--kill` to even start showing progress on a fraction of that data.

## Checkpointing tiers with `ddev snapshot`

`ddev snapshot --name=<name>` (zstd-compressed, native DDEV mechanism) is
the right tool for iterative "Medium -> Large -> Xlarge" builds: each tier
takes single-digit seconds to save regardless of DB size (710MB saved in
~9s at the Large tier here), and `ddev snapshot restore <name>` gets back to
that exact checkpoint just as fast if a later step goes wrong -- far better
than re-running generation or `ddev export-db`/`import-db` against a plain
SQL dump for anything beyond a few hundred MB.

## Background-job hygiene

Stopping a harness-tracked background task (`TaskStop`) does **not**
reliably kill detached child processes spawned by `ddev drush` (they
persist as their own process tree on the host / in the container). Verify
with `ps aux | grep drush` after stopping a job and `kill -9` any survivors
before starting a replacement job -- otherwise you can end up with two
generation processes racing against the same tables.

## Rough throughput summary (this environment, bcrypt cost=5)

| Operation | Rate | Notes |
|---|---|---|
| `genu` (small pool) | ~185-270 users/sec | degrades as existing pool approaches word() namespace |
| `genu_fast.php` | ~305 users/sec | flat, no degradation, any pool size (measured 100K->500K) |
| `genc` | ~70-100 nodes/sec | flat, no degradation |
| `ddev snapshot` save | ~9-30s | ~9s for 710MB, ~30s for 2.6GB (compressed) / 11.9GB (live DB) |
| `ddev import-db` | ~10s | for a ~1GB `.sql.gz` |
| entity-API `--kill` delete | minutes+ | avoid; restore a snapshot instead |

## Final tier numbers (this session)

| Tier | Users | Nodes | Live DB size | Snapshot size (zstd) | Generation time (this tier only) |
|---|---|---|---|---|---|
| Medium | 20,015 | 100,038 | ~672MB | 148MB | ~19 min |
| Large | 100,000 | 500,038 | ~3.05GB | 710MB | ~2.6 hrs (incl. one retry-script false start) |
| Xlarge | 500,000 | 2,000,000 | ~11.85GB | 2.61GiB | 21m43s (users, `genu_fast.php`) + 4h17m41s (nodes, `genc`) = ~4.66 hrs |

Each tier was built additively on top of the previous one (no restarts),
checkpointed with `ddev snapshot --name=<tier>` between tiers so a bad step
only costs a restore, not a re-run.

## Next: initializer-snapshot `ddev start` timing

DDEV has a feature (`pkg/ddevapp/base_db_seed.go`, `InitializerSnapshotName
= "initializer"`) where a snapshot file named exactly
`initializer-<dbtype>_<dbversion>.{zst,gz}` in `.ddev/db_snapshots/`
auto-seeds a brand-new (empty) database volume on `ddev start`
(`ddev-dbserver`'s `docker-entrypoint.sh` checks
`/mnt/snapshots/initializer-<type>_<version>.{zst,gz}` before falling back
to any derived-image or stock starter database). This is related to
[ddev/ddev#8608](https://github.com/ddev/ddev/pull/8608) (zstd support for
the adjacent `base_db.gz` derived-image seeding path) -- both landed on the
`ddev/ddev` `main` branch as of this writing, so no special build is needed
to test with, just a normal recent `ddev` binary.

`scripts/test-initializer-snapshot.sh <snapshot-name>` automates the test:
copies an existing named `ddev snapshot` to the reserved
`initializer-<type>_<version>` filename, forces a fresh db volume (`ddev
stop` + `docker volume rm <project>-mariadb`), times `ddev start`
end-to-end, verifies the seeded row counts, and records results to a CSV
(same shape as `compare-imports.sh`'s report).

### First run result: the feature isn't actually reachable with a stock v1.25.3 image

Ran it against the 2M-node/500K-user snapshot. `ddev start` returned success
in **14s** -- suspiciously fast for restoring an 11.85GB database from a
2.6GiB `.zst`. Verifying row counts confirmed why:
`Table 'db.node_field_data' doesn't exist`. `docker logs ddev-d11-db` showed
`Database initialized from /var/tmp/base_db`, and tracing the entrypoint
(`set -x` output) went straight from `target=/var/tmp/base_db` to
`snapshot=/mysqlbase/base_db.gz` -- **no candidate-loop trace at all**, i.e.
it never even looked for an `initializer-*` file.

Root cause: `docker exec ddev-d11-db grep -n initializer /docker-entrypoint.sh`
in the *running container* comes back empty -- the entrypoint script baked
into the released `ddev/ddev-dbserver-mariadb-11.8:v1.25.3` image (built
2026-07-01) predates the initializer-seed feature entirely. It's still the
hardcoded `gunzip -c /mysqlbase/base_db.gz | xbstream -x` path the PR
description talks about. The `ddev` CLI binary in this environment does
carry the Go-side awareness of the feature (`GetInitializerSnapshotFile()`,
etc., from a local checkout of the `20260720_weitzman_zstd_base_db` branch),
but **the CLI and the dbserver container image are versioned/shipped
independently** -- having a CLI that knows about the feature is not
sufficient to exercise it. The container silently falls back to the stock
seed rather than erroring, which made this easy to miss (a naive "did `ddev
start` succeed?" check would have reported false success).

Practical fallout: this cost one fresh-volume/restore round-trip on a live
11.85GB project database (recovered via `ddev snapshot restore
2m-nodes-500k-users` in 84s, confirmed no data loss). Anyone repeating this
test should verify row counts immediately after `ddev start` returns, every
time -- not just check the exit code.

**To actually test this feature end-to-end**, the project's dbserver image
needs to be built from the feature branch/PR, not the stock release:

```bash
cd ~/workspace/ddev/containers/ddev-dbserver
make mariadb_11.8   # or the single-arch variant for your platform
```

then point the project at the resulting image (`.ddev/db-build/` custom
Dockerfile, or override `dbimg` in `.ddev/config.yaml`) before re-running
`test-initializer-snapshot.sh`. Not yet done in this session -- results with
a proper feature-branch image, and the ddev-start-time-by-tier comparison
table this was meant to produce, are still TBD.
