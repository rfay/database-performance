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

Bcrypt embeds its cost factor in the hash string itself (`$2y$05$...` vs
`$2y$12$...`), so lowering `services.yml`'s configured cost has no effect on
already-hashed passwords either way -- it only governs the cost used for
passwords hashed *after* the change. In the d11 test project specifically,
`web/sites/default/services.yml` was committed as-is (not reverted): every
generated user's password is the known value `test`, and the project is
explicitly testing-only, so there's no real secret the weaker cost would be
exposing. Don't carry this file into anything that isn't disposable test
data -- the comment at the top of the committed file says as much.

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
needs to be built from the feature branch/PR, not the stock release. Turns
out a no-build shortcut exists here: the feature branch's CI already
publishes its image, so once the *matching CLI binary* is on `PATH` (this
environment has one at `/home/coder/bin/ddev`, version
`v1.25.3-56-gf8cf6a3a9` -- `source ~/.bash_profile` if the stock
`/usr/bin/ddev` v1.25.3 shadows it), `ddev describe` reports `dbimg:
ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db`, and
`docker pull` on that exact tag succeeds directly -- no local `make` build
needed. Confirmed via `docker exec <db-container> grep -n initializer
/docker-entrypoint.sh` that this pulled image *does* carry the initializer
logic (unlike the stock v1.25.3 image above).

### Second run: a false failure in the *verification*, not the feature

With the correct binary/image, `ddev start`'s own output clearly showed:

```
Initializing new database volume from the 'initializer' snapshot
~/workspace/d11/.ddev/db_snapshots/initializer-mariadb_11.8.zst (2.6GB)...
```

...and the seeded row counts came back correct (2,000,000 / 500,000) -- the
feature genuinely worked. But the script's own post-hoc verification (`docker
logs <container> | grep -q "initializer-..."`) reported FAIL anyway, twice in
a row, even after adding a generous 60s retry loop. Manually re-running the
exact same `docker logs | grep` command moments later matched instantly,
which ruled out a real timing lag.

The actual culprit, on reflection: `grep -q` exits as soon as it finds one
match, closing its end of the pipe. If `docker logs` (piped live, not yet
finished writing) is still producing output at that instant, it gets
`SIGPIPE` and exits non-zero -- and with `pipefail` set, bash reports the
*pipeline's* exit status as that non-zero code even though `grep` itself
succeeded. (Capturing `docker logs` into a variable first, removing the live
pipe, didn't fix it either in this instance, which is a good reminder that
"looks like it should be the SIGPIPE thing" and "actually is" aren't the
same -- don't stop at the first plausible theory without re-testing.) The
robust fix ended up being to stop reconstructing the answer from container
logs at all, and instead check `ddev start`'s own stdout for the exact
Go-side announcement string (`AnnounceBaseDBSeed` in
`pkg/ddevapp/base_db_seed.go`) -- ddev already tells you authoritatively
whether it used the initializer snapshot; parsing dbserver's internal log
trace after the fact was solving an already-solved problem, and solving it
worse.

### Final, verified result

| Snapshot | Size (compressed) | Live DB size | `ddev start` (initializer seed) | `ddev snapshot restore` (for comparison) |
|---|---|---|---|---|
| `2m-nodes-500k-users` (Xlarge: 2M nodes/500K users) | 2.6GiB | 11.85GB | **76s** | 84s |

The initializer-seed path (fresh volume, first boot) came in slightly faster
than a normal snapshot restore against an already-existing project (which
has to stop/tear down a running db container first) -- roughly in the same
ballpark, as expected, since both use the same zstd-decompress +
`mariabackup --copy-back` mechanism under the hood.

Only one tier was tested end-to-end here (time budget); repeating
`test-initializer-snapshot.sh` against the `100k-nodes-20k-users` and
`500k-nodes-100k-users` snapshots would fill out the by-size-tier comparison
this was meant to produce.

## Baking a seed into the dbimage itself (two more techniques from ddev/ddev#8608)

The `initializer` snapshot above is a *project-level* seed: it lives in
`.ddev/db_snapshots/initializer-<type>_<version>.zst` and only affects that
one project's fresh-volume starts. ddev/ddev#8608 also supports baking the
same kind of seed into the **dbimage** itself, so a team or CI pipeline can
ship a ready-to-use database as part of the image, with no snapshot file or
import step required at all. See
[Seeding a Custom Starter Database in `dbimage`](https://docs.ddev.com/en/stable/users/extend/customizing-images/#seeding-a-custom-starter-database-in-dbimage)
and `pkg/ddevapp/base_db_seed.go` (`CustomBaseDBSeedPathPrefix =
"/mysqlbase/custom/base_db"`).

Precedence, confirmed by reading `containers/ddev-dbserver/files/docker-entrypoint.sh`:
on a fresh (uninitialized) db volume, ddev-dbserver checks, in order:

1. `/mnt/snapshots/initializer-<type>_<version>.{zst,gz}` -- the project-level `initializer` snapshot
2. `/mysqlbase/custom/base_db.{zst,gz}` -- baked into a derived dbimage (either technique below)
3. `/mysqlbase/base_db.{zst,gz}` -- the stock DDEV starter database

So an `initializer` snapshot always wins if present, even when the dbimage
also has a seed baked in -- a teammate can override a shared baked-in-image
seed for their own project just by dropping in an `initializer` snapshot,
without rebuilding anything.

The seed file format is identical to an `initializer` snapshot or a regular
`ddev snapshot` file -- a zstd- or gzip-compressed `mariabackup`/`xtrabackup`
stream (physical copy, not a SQL dump) -- so any existing named `ddev
snapshot` file can be renamed/copied straight into either technique below
with no conversion step.

There are two ways to get a seed baked into a dbimage:

### Technique A: project-level `.ddev/db-build/Dockerfile`

Drop the snapshot file into `.ddev/db-build/` (that directory is the Docker
build "context") and add a `.ddev/db-build/Dockerfile`:

```dockerfile
COPY base_db.zst /mysqlbase/custom/base_db.zst
```

`ddev start`/`ddev restart` builds this automatically into a derived image
tagged `<dbimage>-<project>-built` -- no manual `docker build`, no `dbimage:`
config change needed. This is the path of least resistance for "I have a
project-specific dataset and want teammates' fresh checkouts to start
already seeded," since it's committed alongside the project (though the
seed file itself is large and shouldn't be committed to git -- see below).

Verified with `scripts/test-baked-image-seed.sh`, after `ddev stop` +
`docker volume rm <project>-mariadb` to force a truly fresh volume:

| Tier | Seed size (compressed) | Rebuild time (`ddev utility rebuild -s db`, cold) | `ddev start` (fresh volume) | Verified rows (nodes/users) |
|---|---|---|---|---|
| Medium (100k-nodes-20k-users) | 141MB | (built inline during `ddev restart`, a few seconds) | **19s** | 100,038 / 20,015 |
| Xlarge (2m-nodes-500k-users) | 2.6GB | 2m5s (`docker build` unpacking the new layer) | **90s** | 2,000,000 / 500,000 |

The rebuild step (re-running whenever the seed file's content changes) is
separate from and prior to the timed `ddev start` -- in CI you'd do this
once when publishing an image, not on every developer's machine.

### Technique B: a standalone alternate dbimage via `dbimage:` config

For a seed that should be reusable across *multiple* projects/checkouts
(e.g. a QA or CI dataset published as its own image, independent of any one
project's `.ddev` directory), build a standalone image directly with `docker
build` and point `dbimage:` at it:

```dockerfile
# dockerfiles/db-with-seed/Dockerfile
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY base_db.zst /mysqlbase/custom/base_db.zst
```

```bash
cp some-snapshot-mariadb_11.8.zst dockerfiles/db-with-seed/base_db.zst
docker build --build-arg BASE_IMAGE=ddev/ddev-dbserver-mariadb-11.8:<tag> \
  -t ddev-db-seed-d11:medium-100k-nodes-20k-users dockerfiles/db-with-seed
```

Then set the tag in `.ddev/config.yaml` (shared with the team) or
`.ddev/config.local.yaml` (gitignored, personal-only override -- what was
used for this test, so other tiers could be swapped in without touching
shared config):

```yaml
dbimage: ddev-db-seed-d11:medium-100k-nodes-20k-users
```

Each such image was built with a clearly-named, persistent tag (rather than
a throwaway one) specifically so it stays around for manual testing later,
not just for this one run -- swapping tiers is just editing `dbimage:` and
restarting, no rebuild needed as long as the image already exists locally
(or is pulled from a registry).

Note ddev *still* builds one more derived layer on top of this
(`<dbimage>-<project>-built`, same as technique A) even though the seed is
already baked in one layer down -- that's why this technique's `ddev start`
runs a bit slower than technique A's for the same tier, despite both landing
on an identical final seed file.

| Tier | Seed size (compressed) | Standalone `docker build` time | `ddev start` (fresh volume) | Verified rows (nodes/users) |
|---|---|---|---|---|
| Medium (100k-nodes-20k-users) | 141MB | ~7s | **29s** | 100,038 / 20,015 |
| Xlarge (2m-nodes-500k-users) | 2.6GB | ~113s (mostly the 2.8GB build-context transfer + layer export) | **85s** | 2,000,000 / 500,000 |

### Comparison across all three seeding techniques (Xlarge tier, 2.6GB seed)

| Technique | `ddev start` (fresh volume) |
|---|---|
| Project-level `initializer` snapshot | 76s |
| Baked into dbimage, technique A (`.ddev/db-build/Dockerfile`) | 90s |
| Baked into dbimage, technique B (standalone image + `dbimage:` config) | 85s |

All three land in the same rough ballpark (76-90s) for an 11.85GB live
database from a 2.6GB compressed seed -- unsurprising, since all three use
the identical zstd-decompress + `mariabackup --copy-back` restore path in
`docker-entrypoint.sh`; the differences are noise-level plus whatever small
overhead comes from ddev building one extra derived image layer on top in
the two baked-image techniques. The meaningful choice between them is
therefore about *seed distribution and lifecycle*, not raw restore speed:

* **`initializer` snapshot** -- fastest to iterate with (drop a file, `ddev
  start`), but it's per-project and per-checkout; nothing to publish or
  version as an image.
* **Technique A (`db-build`)** -- seed travels with the project's own repo
  history/checkout convention (though the seed file itself must be
  distributed out-of-band, e.g. via the same external hosting used for the
  snapshots in this repo's README -- it's far too large for git). Good
  default when the dataset is specific to one project.
* **Technique B (standalone image + `dbimage:`)** -- seed is a
  publishable, versionable artifact independent of any project checkout,
  the same way a CI-built application image is. Best fit for a shared
  QA/CI dataset meant to be pulled by name across multiple projects or
  machines, or distributed via a registry instead of a snapshot file.

Only the Medium and Xlarge tiers were tested for the two baked-image
techniques (time budget, and the Large tier's initializer-snapshot number
was also never captured); repeating both scripts against
`500k-nodes-100k-users` would fill out the middle row.
