#!/bin/bash
# Build (and optionally push) a multi-platform dbimage with a base_db seed
# baked in -- the "standalone alternate dbimage" technique documented in
# notes/devel-generate-scale-findings.md (see dockerfiles/db-with-seed).
#
# Modeled on ddev/ddev's own containers/ddev-dbserver/build_image.sh: use
# `docker buildx build --platform ... --push` for a real multi-arch
# manifest list, `--load` for a fast local single-arch smoke test (the
# docker daemon can't load a multi-platform image locally -- only a
# registry can hold a manifest list).
#
# Because the Dockerfile here is just `COPY base_db.zst ...` -- no RUN
# steps -- multi-platform builds do NOT need QEMU/binfmt emulation. BuildKit
# assembles the filesystem diff for each platform's base image directly; it
# only needs to actually *execute* something in a foreign-arch container for
# RUN instructions, which this Dockerfile has none of. Confirmed: a
# linux/amd64,linux/arm64 build of this Dockerfile completes in ~25s on an
# amd64-only host with no binfmt handlers registered.
#
# One multi-arch image tag covers both architectures -- you don't need (and
# shouldn't make) separate -amd64/-arm64 tags. The seed itself is tied to a
# specific db type/version (a mariadb_11.8 snapshot won't restore cleanly as
# a mariadb_10.11 seed), so encode that in the tag alongside the tier, e.g.:
#
#   <registry>/<org>/ddev-db-seed-<project>:<tier>-<dbtype>_<dbversion>
#   ghcr.io/rfay/ddev-db-seed-d11:medium-100k-nodes-20k-users-mariadb_11.8
#
# Usage:
#   build-and-push-seeded-image.sh --seed-file=<path> --base-image=<image:tag> --tag=<full-tag> [--push] [--platforms=linux/amd64,linux/arm64] [--builder=<name>]
#
# Examples:
#   # Fast local smoke test (single native arch, loaded into local docker):
#   build-and-push-seeded-image.sh \
#     --seed-file=.ddev/db_snapshots/100k-nodes-20k-users-mariadb_11.8.zst \
#     --base-image=ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     --tag=ghcr.io/rfay/ddev-db-seed-d11:medium-100k-nodes-20k-users-mariadb_11.8
#
#   # Real multi-arch push (requires `docker login` to the target registry first):
#   build-and-push-seeded-image.sh \
#     --seed-file=.ddev/db_snapshots/100k-nodes-20k-users-mariadb_11.8.zst \
#     --base-image=ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     --tag=ghcr.io/rfay/ddev-db-seed-d11:medium-100k-nodes-20k-users-mariadb_11.8 \
#     --push

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE_DIR="${SCRIPT_DIR}/../dockerfiles/db-with-seed"

SEED_FILE=""
BASE_IMAGE=""
TAG=""
PUSH=""
PLATFORMS="linux/amd64,linux/arm64"
BUILDER="ddev-db-seed-builder"

while [ $# -gt 0 ]; do
  case "$1" in
    --seed-file=*) SEED_FILE="${1#*=}"; shift ;;
    --seed-file) SEED_FILE="$2"; shift 2 ;;
    --base-image=*) BASE_IMAGE="${1#*=}"; shift ;;
    --base-image) BASE_IMAGE="$2"; shift 2 ;;
    --tag=*) TAG="${1#*=}"; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --platforms=*) PLATFORMS="${1#*=}"; shift ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --builder=*) BUILDER="${1#*=}"; shift ;;
    --builder) BUILDER="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    -h|--help)
      echo "Usage: $0 --seed-file=<path> --base-image=<image:tag> --tag=<full-tag> [--push] [--platforms=linux/amd64,linux/arm64] [--builder=<name>]"
      echo "(--opt=value and --opt value are both accepted.)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

: "${SEED_FILE:?--seed-file is required}"
: "${BASE_IMAGE:?--base-image is required}"
: "${TAG:?--tag is required, e.g. ghcr.io/youruser/ddev-db-seed-<project>:<tier>-<dbtype>_<dbversion>}"

if [ ! -f "$SEED_FILE" ]; then
  echo "ERROR: seed file not found: $SEED_FILE" >&2
  exit 1
fi

# A persistent docker-container builder (not the default docker-driver
# builder, which can't push multi-platform manifest lists) is created once
# and reused -- reused builds get BuildKit's layer cache instead of starting
# cold every time.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "Creating persistent buildx builder '$BUILDER'..."
  docker buildx create --name "$BUILDER" --driver docker-container
fi

cp "$SEED_FILE" "${DOCKERFILE_DIR}/base_db.zst"

if [ -n "$PUSH" ]; then
  echo "Building and pushing multi-platform ($PLATFORMS) image: $TAG"
  docker buildx build --builder "$BUILDER" \
    --platform "$PLATFORMS" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    -t "$TAG" \
    --push \
    "$DOCKERFILE_DIR"
  echo "Pushed $TAG for $PLATFORMS"
else
  # --load only works for a single platform (the docker daemon has no
  # concept of a manifest list), so smoke-test with the host's native arch.
  NATIVE_ARCH="linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
  echo "No --push given: building single-arch ($NATIVE_ARCH) and loading locally for a smoke test: $TAG"
  echo "(Use --push for the real multi-platform manifest list, once you're ready to publish.)"
  docker buildx build --builder "$BUILDER" \
    --platform "$NATIVE_ARCH" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    -t "$TAG" \
    --load \
    "$DOCKERFILE_DIR"
  echo "Loaded $TAG locally ($NATIVE_ARCH only) -- set dbimage: $TAG in .ddev/config.local.yaml to try it."
fi

rm -f "${DOCKERFILE_DIR}/base_db.zst"
