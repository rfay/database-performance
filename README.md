# database-performance
Experimental database performance tools

This repo is to explore database performance tests with DDEV.

Importing large database has sometimes been an area of concern because they can take a long time and it's hard to understand why and what the differences are between DDEV versions and database types.

Areas of exploration:
* Creation and availability of large database dumps
* Scripts to compare import performance across database types and DDEV versions
* Scripts to compare snapshot restore performance

## Scripts

* [create-large-db.sh](scripts/create-large-db.sh) - Allows creating or adding to existing database. 
* [compare-imports.sh](scripts/compare-imports.sh) - Minor adjustments allow comparing imports with different DDEV versions, database versions, and import files. It can be run against a variety of docker providers to compare docker provider performance.
* [genu_topup.sh](scripts/genu_topup.sh) - Retry-until-target wrapper around `drush genu`, for growing a user table by a moderate amount without hitting devel_generate's username-collision bug (see notes below).
* [genu_fast.php](scripts/genu_fast.php) - Collision-proof user generator (`drush php:script`) for growing a user table by a large amount quickly; recommended once the existing user count makes `genu_topup.sh`'s retry yield too small to be practical.
* [test-initializer-snapshot.sh](scripts/test-initializer-snapshot.sh) - Measures `ddev start` time when a project's fresh database volume is seeded from a reserved `initializer` snapshot ([ddev/ddev#8608](https://github.com/ddev/ddev/pull/8608), `pkg/ddevapp/base_db_seed.go`). Destructive to the project's live DB (removes the db volume) -- only run after saving a snapshot you can restore from.
* [test-baked-image-seed.sh](scripts/test-baked-image-seed.sh) - Same measurement as above, but for a base_db seed baked into the **dbimage** itself (either via a project `.ddev/db-build/Dockerfile` or a standalone image set via `dbimage:` config -- see [dockerfiles/db-with-seed](dockerfiles/db-with-seed)). Also destructive to the project's live DB.

See [notes/devel-generate-scale-findings.md](notes/devel-generate-scale-findings.md) for a full writeup: `password.options.cost` tuning for fast disposable-DB hashing, why `genu` degrades badly at scale and how the two scripts above address it, why `--kill` is a trap for iterative builds, using `ddev snapshot` to checkpoint between size tiers instead of full DB export/import, and a comparison of all three ways to seed a fresh database volume (`initializer` snapshot vs. the two baked-into-dbimage techniques).

## Available db dumps

These dumps have no confidential data and are entirely generated using publicly available information. Database snapshots/dumps are hosted externally (not committed -- too large for git) and linked here.

* [Drupal CMS 100K node 100k.sql.gz](https://drive.google.com/file/d/1Atwvqo8OH0PMoOYq-9l8Tnrc5SNYz_5I/view?usp=sharing) (download with web browser, not curl). Created by `create-large-db.sh`
* [Drupal CMS 1M node 1M.sql.gz](https://drive.google.com/file/d/1Atwvqo8OH0PMoOYq-9l8Tnrc5SNYz_5I/view?usp=sharing)
* [Drupal CMS MariaDB 10.11 DDEV snapshot](https://drive.google.com/file/d/1-UYSzfF_ybEFlLu6I4txbHGlWbiimo70/view?usp=sharing) (download with web browser)
* Drupal 11 / Umami, generated with `genu_fast.php` + `genc` (see notes), MariaDB 11.8 DDEV snapshots (download with web browser, not curl):
  * [Medium: 100k-nodes-20k-users (141MB)](https://drive.google.com/file/d/1Za7Y5-E7KXIFGHhshvRGs8TMOoKrhiMF/view?usp=drive_link)
  * [Large: 500k-nodes-100k-users (678MB)](https://drive.google.com/file/d/1y3Ax9y01f2HC4v3o_OYQCKJMXTtXkyF4/view?usp=drive_link)
  * [Xlarge: 2m-nodes-500k-users (2.61GB)](https://drive.google.com/file/d/1NItXgX_o1QRvlidqd8AfTRr60FEIGw_l/view?usp=drive_link)

