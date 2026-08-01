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

See [notes/devel-generate-scale-findings.md](notes/devel-generate-scale-findings.md) for a full writeup: `password.options.cost` tuning for fast disposable-DB hashing, why `genu` degrades badly at scale and how the two scripts above address it, why `--kill` is a trap for iterative builds, and using `ddev snapshot` to checkpoint between size tiers instead of full DB export/import.

## Available db dumps

These dumps have no confidential data and are entirely generated using publicly available information. Database snapshots/dumps are hosted externally (not committed -- too large for git) and linked here.

* [Drupal CMS 100K node 100k.sql.gz](https://drive.google.com/file/d/1Atwvqo8OH0PMoOYq-9l8Tnrc5SNYz_5I/view?usp=sharing) (download with web browser, not curl). Created by `create-large-db.sh`
* [Drupal CMS 1M node 1M.sql.gz](https://drive.google.com/file/d/1Atwvqo8OH0PMoOYq-9l8Tnrc5SNYz_5I/view?usp=sharing)
* [Drupal CMS MariaDB 10.11 DDEV snapshot](https://drive.google.com/file/d/1-UYSzfF_ybEFlLu6I4txbHGlWbiimo70/view?usp=sharing) (download with web browser)
* Drupal 11 / Umami, generated with `genu_fast.php` + `genc` (see notes): Medium (20K users/100K nodes), Large (100K users/500K nodes), Xlarge (500K users/2M nodes) DDEV snapshots -- links to follow.

