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
# Because the Dockerfile here is just `COPY base_db.<ext> ...` -- no RUN
# steps -- multi-platform builds do NOT need QEMU/binfmt emulation. BuildKit
# assembles the filesystem diff for each platform's base image directly; it
# only needs to actually *execute* something in a foreign-arch container for
# RUN instructions, which this Dockerfile has none of. Confirmed: a
# linux/amd64,linux/arm64 build of this Dockerfile completed in ~25s on an
# amd64-only host with no binfmt handlers registered, for a compressed .zst
# seed -- an uncompressed .mbstream/.xbstream seed (ddev/ddev#8704) is much
# larger, so expect the per-platform COPY step (still run once per platform;
# BuildKit doesn't dedupe it across platforms since each is a distinct final
# image) to take proportionally longer.
#
# The destination filename inside the image always matches --seed-file's own
# extension (zst, gz, mbstream, or xbstream) -- it is never renamed to
# .zst -- since ddev-dbserver's docker-entrypoint.sh dispatches decompression
# purely by filename (see ddev/ddev#8704): feeding it an uncompressed stream
# under a .zst name would make it try to zstd-decompress raw data and fail.
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
#   build-and-push-seeded-image.sh --seed-file=<path> --base-image=<image:tag> --output-image=<full-tag> [--push] [--platforms=linux/amd64,linux/arm64] [--builder=<name>] [--ddev-image-tag=<value>]
#   build-and-push-seeded-image.sh --snapshot=<short-name> [--project=<path>] [--output-image=<full-tag>] [--push] [...]
#
# Every flag accepts either form: --output-image=value or --output-image value.
# --seed-file supports a leading ~ for $HOME, and must end in .zst, .gz,
# .mbstream, or .xbstream -- that extension is preserved into the image
# unchanged (see above).
#
# --snapshot=<short-name> is a convenience alternative to --seed-file +
# --base-image: given a DDEV project (--project, default the current
# directory -- any subdirectory of the project works, same as any other ddev
# command) and a snapshot name as shown by `ddev snapshot --list`, it:
#   - resolves --seed-file to that project's .ddev/db_snapshots/<name>-*
#     file (whichever compressed/uncompressed extension is actually there);
#   - resolves --base-image from `ddev describe -j`'s "dbimg" field for that
#     project, i.e. whatever dbimage the project is *currently* configured to
#     use -- whether that's DDEV's computed stock default for the project's
#     db type/version, or an explicit `dbimage:` override. (`ddev version -j`
#     is NOT used for this: its "db" field is a hardcoded mariadb-only
#     default that ignores the project's actual db type/version unless
#     `dbimage:` happens to be explicitly overridden -- verified against
#     ddev/ddev's pkg/version/version.go and confirmed empirically: a
#     project configured for mariadb:10.4 still reported a mariadb-11.8
#     image. `ddev describe -j`'s "dbimg", by contrast, calls the same
#     app.GetDBImage() ddev itself uses, so it's correct either way.)
#   - if the resolved --base-image doesn't look like a stock
#     ddev/ddev-dbserver-<type>-<version> image, prints a warning: it's
#     likely already a derived/seeded image from an earlier build (exactly
#     the mistake this flag exists to prevent), so building from it again
#     would stack seeds. Pass --base-image explicitly to confirm or correct.
#   - without --push, defaults --output-image to a local
#     "<project>-db-seed-<snapshot>:<dbtype>_<dbversion>" tag if you don't
#     give one; --push always requires an explicit --output-image, since
#     there's no registry to safely guess.
# --seed-file/--base-image, if also given explicitly, override the
# corresponding --snapshot-derived value (--seed-file and --snapshot
# together is an error -- pick one).
#
# --ddev-image-tag stamps the com.ddev.image-tag label (see ddev/ddev#8682,
# which records the tag an image was built as so a derived image's
# provenance survives retagging). Defaults to the tag portion of
# --base-image, which is correct for a normal seeded build: the seed doesn't
# change what DDEV generation the image belongs to, so the label should keep
# saying whatever generation the base image says. Override it to
# deliberately produce a stale-labeled image, e.g. for testing #8682's
# mismatch warning:
#   --ddev-image-tag=some-older-generation-tag
#
# Examples:
#   # Fast local smoke test (single native arch, loaded into local docker):
#   build-and-push-seeded-image.sh \
#     --seed-file=~/.ddev/db_snapshots/100k-nodes-20k-users-mariadb_11.8.zst \
#     --base-image=ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     --output-image=ghcr.io/rfay/ddev-db-seed-d11:medium-100k-nodes-20k-users-mariadb_11.8
#
#   # Real multi-arch push (requires `docker login` to the target registry first):
#   build-and-push-seeded-image.sh \
#     --seed-file=~/.ddev/db_snapshots/100k-nodes-20k-users-mariadb_11.8.zst \
#     --base-image=ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     --output-image=ghcr.io/rfay/ddev-db-seed-d11:medium-100k-nodes-20k-users-mariadb_11.8 \
#     --push
#
#   # Same thing with space-separated flags instead of --flag=value:
#   build-and-push-seeded-image.sh \
#     --seed-file ~/workspace/d11/.ddev/db_snapshots/100k-nodes-20k-users-mariadb_11.8.zst \
#     --base-image ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db \
#     --output-image randyfay/dbserver-100k:latest \
#     --platforms linux/arm64,linux/amd64 \
#     --push
#
#   # Snapshot-name shortcut: resolves --seed-file and --base-image from the
#   # d11 project's own config and .ddev/db_snapshots/ (smoke test, no --push):
#   build-and-push-seeded-image.sh --project=~/workspace/d11 --snapshot=uncompressed
#
#   # Same, explicitly pushed (still required for --push):
#   build-and-push-seeded-image.sh --project=~/workspace/d11 --snapshot=uncompressed \
#     --output-image=ghcr.io/rfay/ddev-db-seed-d11:uncompressed-mariadb_11.8 --push
#
#   # Verify a pushed image really has both platforms (and see the digests):
#   docker buildx imagetools inspect randyfay/dbserver-100k
#
#   # Use the pushed image in a project (triggers a real registry pull):
#   #   echo 'dbimage: randyfay/dbserver-100k:latest' >> .ddev/config.local.yaml
#   #   ddev stop && docker volume rm <project>-mariadb && ddev start
#
# This exact flow (multi-arch build, push to Docker Hub, remove the local
# copy, then a fresh project pull+seed from the published tag) was verified
# end-to-end against randyfay/dbserver-100k: pushed in ~7s, then a clean
# `ddev start` pulled it and seeded a fresh volume in 32s, with correct row
# counts (100,038 nodes / 20,015 users). See notes/devel-generate-scale-findings.md.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE_DIR="${SCRIPT_DIR}/../dockerfiles/db-with-seed"

SEED_FILE=""
BASE_IMAGE=""
OUTPUT_IMAGE=""
PUSH=""
PLATFORMS="linux/amd64,linux/arm64"
BUILDER="ddev-db-seed-builder"
DDEV_IMAGE_TAG=""
PROJECT="."
SNAPSHOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --seed-file=*) SEED_FILE="${1#*=}"; shift ;;
    --seed-file) SEED_FILE="$2"; shift 2 ;;
    --base-image=*) BASE_IMAGE="${1#*=}"; shift ;;
    --base-image) BASE_IMAGE="$2"; shift 2 ;;
    --output-image=*) OUTPUT_IMAGE="${1#*=}"; shift ;;
    --output-image) OUTPUT_IMAGE="$2"; shift 2 ;;
    --platforms=*) PLATFORMS="${1#*=}"; shift ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --builder=*) BUILDER="${1#*=}"; shift ;;
    --builder) BUILDER="$2"; shift 2 ;;
    --ddev-image-tag=*) DDEV_IMAGE_TAG="${1#*=}"; shift ;;
    --ddev-image-tag) DDEV_IMAGE_TAG="$2"; shift 2 ;;
    --project=*) PROJECT="${1#*=}"; shift ;;
    --project) PROJECT="$2"; shift 2 ;;
    --snapshot=*) SNAPSHOT="${1#*=}"; shift ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    -h|--help)
      echo "Usage: $0 --seed-file=<path> --base-image=<image:tag> --output-image=<full-tag> [--push] [--platforms=linux/amd64,linux/arm64] [--builder=<name>] [--ddev-image-tag=<value>]"
      echo "   or: $0 --snapshot=<short-name> [--project=<path>] [--output-image=<full-tag>] [--push] [...]"
      echo "(--opt=value and --opt value are both accepted.)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -n "$SNAPSHOT" ]; then
  if [ -n "$SEED_FILE" ]; then
    echo "ERROR: --snapshot and --seed-file are mutually exclusive -- pick one" >&2
    exit 1
  fi
  for tool in ddev jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: --snapshot requires '$tool' on PATH" >&2; exit 1; }
  done

  # ddev describe/version subcommands only accept a registered project NAME,
  # not an arbitrary path -- so cd into --project and let ddev's own
  # upward directory search (same as any other ddev command) find it,
  # rather than passing --project through as a positional argument.
  case "$PROJECT" in
    "~"|"~/"*) PROJECT="${HOME}${PROJECT#\~}" ;;
  esac
  if ! DESCRIBE_JSON="$(cd "$PROJECT" && ddev describe -j 2>&1)"; then
    echo "ERROR: 'ddev describe' failed for --project=$PROJECT:" >&2
    echo "$DESCRIBE_JSON" >&2
    exit 1
  fi

  PROJECT_NAME="$(jq -r '.raw.name' <<<"$DESCRIBE_JSON")"
  PROJECT_APPROOT="$(jq -r '.raw.approot' <<<"$DESCRIBE_JSON")"
  DB_TYPE="$(jq -r '.raw.database_type' <<<"$DESCRIBE_JSON")"
  DB_VERSION="$(jq -r '.raw.database_version' <<<"$DESCRIBE_JSON")"
  PROJECT_DBIMG="$(jq -r '.raw.dbimg' <<<"$DESCRIBE_JSON")"

  # This whole baked-in-seed technique is mariabackup/xtrabackup-stream based
  # (see ddev/ddev#8704) -- postgres uses pg_basebackup/tar instead and isn't
  # supported by dockerfiles/db-with-seed's Dockerfile.
  if [ "$DB_TYPE" = "postgres" ]; then
    echo "ERROR: --snapshot doesn't support postgres projects (project '$PROJECT_NAME' is $DB_TYPE) -- this seeding technique is mariadb/mysql-only" >&2
    exit 1
  fi

  if [ -z "$BASE_IMAGE" ]; then
    BASE_IMAGE="$PROJECT_DBIMG"
    echo "Using base image from project '$PROJECT_NAME': $BASE_IMAGE"
    # A stock dbimage always looks like ddev/ddev-dbserver-<type>-<version>:<tag>.
    # Anything else is either a hand-picked dbimage: override or -- easy
    # mistake to make -- an image from a PREVIOUS seeded build, in which case
    # building from it again would stack seeds on top of each other.
    case "$BASE_IMAGE" in
      ddev/ddev-dbserver-"${DB_TYPE}"-"${DB_VERSION}":*) : ;;
      *)
        echo "WARNING: '$BASE_IMAGE' doesn't look like a stock ddev-dbserver image for ${DB_TYPE} ${DB_VERSION}." >&2
        echo "  It may be a custom dbimage: override, and/or already have a seed baked in from an earlier build." >&2
        echo "  Pass --base-image explicitly if this isn't the image you want to build from." >&2
        ;;
    esac
  fi

  if [ -z "$SEED_FILE" ]; then
    SNAPSHOT_DIR="${PROJECT_APPROOT}/.ddev/db_snapshots"
    shopt -s nullglob
    candidates=("${SNAPSHOT_DIR}/${SNAPSHOT}-"*)
    shopt -u nullglob
    matches=()
    for candidate in "${candidates[@]}"; do
      case "$candidate" in
        *.zst|*.gz|*.mbstream|*.xbstream) matches+=("$candidate") ;;
      esac
    done
    case "${#matches[@]}" in
      0)
        echo "ERROR: no snapshot named '$SNAPSHOT' found in $SNAPSHOT_DIR" >&2
        echo "Available snapshots for '$PROJECT_NAME':" >&2
        (cd "$PROJECT" && ddev snapshot --list) >&2 || true
        exit 1
        ;;
      1) SEED_FILE="${matches[0]}" ;;
      *)
        echo "ERROR: multiple files match snapshot '$SNAPSHOT' in $SNAPSHOT_DIR:" >&2
        printf '  %s\n' "${matches[@]}" >&2
        exit 1
        ;;
    esac
    echo "Using seed file from snapshot '$SNAPSHOT': $SEED_FILE"
  fi

  if [ -z "$OUTPUT_IMAGE" ]; then
    if [ -n "$PUSH" ]; then
      echo "ERROR: --output-image is required with --push -- there's no registry to safely default to" >&2
      exit 1
    fi
    OUTPUT_IMAGE="${PROJECT_NAME}-db-seed-${SNAPSHOT}:${DB_TYPE}_${DB_VERSION}"
    echo "Defaulting --output-image to local tag: $OUTPUT_IMAGE"
  fi
fi

: "${SEED_FILE:?--seed-file is required}"
: "${BASE_IMAGE:?--base-image is required}"
: "${OUTPUT_IMAGE:?--output-image is required, e.g. ghcr.io/youruser/ddev-db-seed-<project>:<tier>-<dbtype>_<dbversion>}"

# --seed-file supports a leading ~ for $HOME, since the shell only expands
# ~ itself when the flag is unquoted and unglobbed on the command line.
case "$SEED_FILE" in
  "~"|"~/"*) SEED_FILE="${HOME}${SEED_FILE#\~}" ;;
esac

# --base-image must be a full image spec (repo:tag), since the com.ddev.image-tag
# label default below is extracted from its tag portion. Check the final
# path segment for a ':' so a registry host:port (e.g. localhost:5000/foo)
# isn't mistaken for a tag.
case "${BASE_IMAGE##*/}" in
  *:*) : ;;
  *)
    echo "ERROR: --base-image must be a full image spec including a tag, e.g. ddev/ddev-dbserver-mariadb-11.8:20260720_weitzman_zstd_base_db (got: $BASE_IMAGE)" >&2
    exit 1
    ;;
esac

# Default the com.ddev.image-tag label to BASE_IMAGE's own tag (the part
# after the last ':') -- a plain seeded build doesn't change what DDEV
# generation the image belongs to, so the label should say the same
# generation the base image says.
if [ -z "$DDEV_IMAGE_TAG" ]; then
  DDEV_IMAGE_TAG="${BASE_IMAGE##*:}"
fi

if [ ! -f "$SEED_FILE" ]; then
  echo "ERROR: seed file not found: $SEED_FILE" >&2
  exit 1
fi

# ddev-dbserver's docker-entrypoint.sh picks a decompressor purely from the
# seed file's extension (see ddev/ddev#8704), so the file baked into the
# image must keep --seed-file's own extension rather than being renamed.
SEED_EXT="${SEED_FILE##*.}"
case "$SEED_EXT" in
  zst|gz|mbstream|xbstream) : ;;
  *)
    echo "ERROR: --seed-file must end in .zst, .gz (compressed) or .mbstream, .xbstream (uncompressed, ddev/ddev#8704) -- got: $SEED_FILE" >&2
    exit 1
    ;;
esac

# A persistent docker-container builder (not the default docker-driver
# builder, which can't push multi-platform manifest lists) is created once
# and reused -- reused builds get BuildKit's layer cache instead of starting
# cold every time.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "Creating persistent buildx builder '$BUILDER'..."
  docker buildx create --name "$BUILDER" --driver docker-container
fi

# Uncompressed seeds (.mbstream/.xbstream) can be many times larger than a
# compressed one, so a stray leftover copy here is worth avoiding -- clean up
# on any exit, not just success.
cleanup() { rm -f "${DOCKERFILE_DIR}"/base_db.*; }
trap cleanup EXIT

cp "$SEED_FILE" "${DOCKERFILE_DIR}/base_db.${SEED_EXT}"

if [ -n "$PUSH" ]; then
  echo "Building and pushing multi-platform ($PLATFORMS) image: $OUTPUT_IMAGE (com.ddev.image-tag=${DDEV_IMAGE_TAG})"
  docker buildx build --builder "$BUILDER" \
    --platform "$PLATFORMS" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "DDEV_IMAGE_TAG=${DDEV_IMAGE_TAG}" \
    --build-arg "SEED_EXT=${SEED_EXT}" \
    -t "$OUTPUT_IMAGE" \
    --push \
    "$DOCKERFILE_DIR"
  echo "Pushed $OUTPUT_IMAGE for $PLATFORMS"
else
  # --load only works for a single platform (the docker daemon has no
  # concept of a manifest list), so smoke-test with the host's native arch.
  NATIVE_ARCH="linux/$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
  echo "No --push given: building single-arch ($NATIVE_ARCH) and loading locally for a smoke test: $OUTPUT_IMAGE (com.ddev.image-tag=${DDEV_IMAGE_TAG})"
  echo "(Use --push for the real multi-platform manifest list, once you're ready to publish.)"
  docker buildx build --builder "$BUILDER" \
    --platform "$NATIVE_ARCH" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "DDEV_IMAGE_TAG=${DDEV_IMAGE_TAG}" \
    --build-arg "SEED_EXT=${SEED_EXT}" \
    -t "$OUTPUT_IMAGE" \
    --load \
    "$DOCKERFILE_DIR"
  echo "Loaded $OUTPUT_IMAGE locally ($NATIVE_ARCH only) -- set dbimage: $OUTPUT_IMAGE in .ddev/config.local.yaml to try it."
fi
