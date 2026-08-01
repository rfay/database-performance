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

Measured: 398,000 users (100K -> 500K) in ~25 minutes at a steady
~260-270/sec, zero collisions, zero retries. This is the right tool once the
existing user pool is large enough that `genu_topup.sh`'s retry yield starts
dropping into the tens-per-attempt range.

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
| `genu_fast.php` | ~260-270 users/sec | flat, no degradation, any pool size |
| `genc` | ~70-100 nodes/sec | flat, no degradation |
| `ddev snapshot` save | ~9s | for a ~710MB DB |
| `ddev import-db` | ~10s | for a ~1GB `.sql.gz` |
| entity-API `--kill` delete | minutes+ | avoid; restore a snapshot instead |

## Next: initializer-snapshot `ddev start` timing

DDEV has a feature (`pkg/ddevapp/base_db_seed.go`, `InitializerSnapshotName
= "initializer"`) where a snapshot file named exactly
`initializer-<dbtype>_<dbversion>.{zst,gz}` in `.ddev/db_snapshots/`
auto-seeds a brand-new (empty) database volume on `ddev start`. This is
related to [ddev/ddev#8608](https://github.com/ddev/ddev/pull/8608) (zstd
support for the adjacent `base_db.gz` derived-image seeding path). Next
step: measure `ddev start` time on a fresh DB volume seeded from an
`initializer` snapshot at each of the size tiers generated here, to get real
numbers for this feature's first-boot cost at scale. See
`scripts/test-initializer-snapshot.sh` (to follow).
