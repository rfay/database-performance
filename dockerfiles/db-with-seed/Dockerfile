# Standalone image build (NOT part of ddev's .ddev/db-build pipeline): bakes a
# base_db seed into a derived dbserver image, for use via `dbimage:` in
# .ddev/config.yaml or .ddev/config.local.yaml. See
# https://docs.ddev.com/en/stable/users/extend/customizing-images/#seeding-a-custom-starter-database-in-dbimage
#
# Build with base_db.zst (a `ddev snapshot` file, renamed) present in this
# same directory, e.g.:
#   cp /path/to/some-snapshot-mariadb_11.8.zst ./base_db.zst
#   docker build --build-arg BASE_IMAGE=ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     -t ddev-db-seed-d11:medium-100k-nodes-20k-users .
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY base_db.zst /mysqlbase/custom/base_db.zst
