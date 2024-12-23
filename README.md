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

## Available db dumps

These dumps have no confidential data and are entirely generated using publicly available information.

* [Drupal CMS 100K node 100k.sql.gz](https://drive.google.com/file/d/1Atwvqo8OH0PMoOYq-9l8Tnrc5SNYz_5I/view?usp=sharing) (download with web browser, not curl). Created by `create-large-db.sh`
* [Drupal CMS 1M node 1M.sql.gz](https://drive.google.com/file/d/1Atwvqo8OH0PMoOYq-9l8Tnrc5SNYz_5I/view?usp=sharing)
* [Drupal CMS MariaDB 10.11 DDEV snapshot](https://drive.google.com/file/d/1-UYSzfF_ybEFlLu6I4txbHGlWbiimo70/view?usp=sharing) (download with web browser)

