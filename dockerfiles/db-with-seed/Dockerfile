# Standalone image build (NOT part of ddev's .ddev/db-build pipeline): bakes a
# base_db seed into a derived dbserver image, for use via `dbimage:` in
# .ddev/config.yaml or .ddev/config.local.yaml. See
# https://docs.ddev.com/en/stable/users/extend/customizing-images/#seeding-a-custom-starter-database-in-dbimage
#
# Build with base_db.<ext> (a `ddev snapshot` file, renamed) present in this
# same directory, e.g.:
#   cp /path/to/some-snapshot-mariadb_11.8.zst ./base_db.zst
#   docker build --build-arg BASE_IMAGE=ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     --build-arg SEED_EXT=zst \
#     -t ddev-db-seed-d11:medium-100k-nodes-20k-users .
# SEED_EXT must match the seed file's real extension -- ddev-dbserver's
# docker-entrypoint.sh dispatches decompression purely by filename, so the
# wrong extension means an uncompressed .mbstream/.xbstream seed gets fed to
# the wrong (or no) decompressor. Valid values, per ddev/ddev#8704: zst, gz
# (compressed), mbstream, xbstream (uncompressed mariabackup/xtrabackup
# streams).
# The BASE_IMAGE default is never actually used -- build-and-push-seeded-image.sh
# always passes --build-arg BASE_IMAGE=... -- it's just a syntactically
# valid placeholder so `docker build`'s linter doesn't warn about an empty
# default resolving an invalid FROM.
ARG BASE_IMAGE=alpine:latest
FROM ${BASE_IMAGE}
# com.ddev.image-tag (see ddev/ddev#8682) records the tag an image was built
# as, so a derived image's provenance survives the retagging that would
# otherwise make it anonymous. Re-stamping it here (rather than relying on
# LABEL inheritance from BASE_IMAGE) lets --image-tag deliberately set a
# stale value, for testing #8682's mismatch warning.
ARG DDEV_IMAGE_TAG
LABEL com.ddev.image-tag=${DDEV_IMAGE_TAG}
ARG SEED_EXT=zst
COPY base_db.${SEED_EXT} /mysqlbase/custom/base_db.${SEED_EXT}
