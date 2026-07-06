#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

read_target() {
  local target_id=$1

  awk -F '\t' -v id="$target_id" '
    $0 !~ /^#/ && $1 == id {
      print $1 "\t" $2 "\t" $3 "\t" $4
      found = 1
    }
    END { if (!found) exit 1 }
  ' "$ROOT/distros.tsv"
}

container_engine() {
  if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    printf '%s\n' "$CONTAINER_ENGINE"
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    printf 'docker\n'
    return
  fi

  if command -v podman >/dev/null 2>&1; then
    printf 'podman\n'
    return
  fi

  die "Docker or Podman is required"
}

prepare_source() {
  local package_name=$1
  local pkg_dir="/repo/packages/$package_name"
  local meta="$pkg_dir/package.env"

  [[ -f "$meta" ]] || die "missing package.env for $package_name"

  # shellcheck disable=SC1090
  source "$meta"

  : "${PACKAGE_NAME:?PACKAGE_NAME is required}"
  : "${UPSTREAM_VERSION:?UPSTREAM_VERSION is required}"
  : "${SOURCE_URL:=}"
  : "${SOURCE_STRIP_DIR:=}"

  local work_dir="/repo/work/${TARGET_ID:-native}/$package_name"
  local src_parent="$work_dir"
  local src_dir="$src_parent/${PACKAGE_NAME}-${UPSTREAM_VERSION}"

  rm -rf "$work_dir"
  mkdir -p "$src_parent"

  if [[ "$PACKAGE_NAME" == "rtb2" && -n "${RTB2_SOURCE_DIR:-}" ]]; then
    mkdir -p "$src_dir"
    cp -a "$RTB2_SOURCE_DIR"/. "$src_dir"/
  elif [[ "$PACKAGE_NAME" == "rtb2" && -f "$pkg_dir/rtb2-1.0.0.tar.gz" ]]; then
    tar -xzf "$pkg_dir/rtb2-1.0.0.tar.gz" -C "$src_parent"
    if [[ ! -d "$src_dir" ]]; then
      local first_dir
      first_dir=$(find "$src_parent" -mindepth 1 -maxdepth 1 -type d | head -n 1)
      mv "$first_dir" "$src_dir"
    fi
  elif [[ -n "$SOURCE_URL" ]]; then
    local archive="$work_dir/source.tar.gz"
    curl -L --fail --retry 3 -o "$archive" "$SOURCE_URL"
    tar -xf "$archive" -C "$src_parent"
    if [[ -n "$SOURCE_STRIP_DIR" && -d "$src_parent/$SOURCE_STRIP_DIR" ]]; then
      mv "$src_parent/$SOURCE_STRIP_DIR" "$src_dir"
    elif [[ ! -d "$src_dir" ]]; then
      local first_dir
      first_dir=$(find "$src_parent" -mindepth 1 -maxdepth 1 -type d | head -n 1)
      mv "$first_dir" "$src_dir"
    fi
  else
    die "no source configured for $package_name"
  fi

  cp -a "$pkg_dir/debian" "$src_dir/"

  if [[ -d "$pkg_dir/files" ]]; then
    cp -a "$pkg_dir/files"/. "$src_dir"/
  fi

  find "$src_dir/debian" -type f -name rules -exec chmod 0755 {} +
  printf '%s\n' "$src_dir"
}

build_inside_container() {
  local package_name=$1

  apt-get update
  apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    debhelper \
    devscripts \
    dpkg-dev \
    equivs \
    fakeroot \
    file \
    git \
    gnupg \
    make \
    patch \
    tar \
    xz-utils

  local src_dir
  src_dir=$(prepare_source "$package_name")

  mk-build-deps \
    --install \
    --remove \
    --tool 'apt-get -y --no-install-recommends' \
    "$src_dir/debian/control"

  cd "$src_dir"
  dpkg-buildpackage -us -uc -b

  local out_dir="/repo/out/${TARGET_ID}/${package_name}"
  mkdir -p "$out_dir"
  find "/repo/work/${TARGET_ID}/${package_name}" \
    -maxdepth 1 \
    -type f \
    \( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) \
    -exec cp -v {} "$out_dir"/ \;
}

if [[ "${MDSPACE_DEB_BUILD_IN_CONTAINER:-0}" == "1" ]]; then
  build_inside_container "${1:?package name is required}"
  exit 0
fi

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "Usage: $0 <target-id> <package-name> [output-dir]" >&2
  echo "Example: $0 ubuntu-24.04 genesis output" >&2
  exit 1
fi

TARGET_ID=$1
PACKAGE_NAME=$2
OUTPUT_DIR=${3:-output}

target=$(read_target "$TARGET_ID") || die "unknown target: $TARGET_ID"
IFS=$'\t' read -r TARGET_ID TARGET_FAMILY TARGET_VERSION TARGET_IMAGE <<< "$target"

[[ -d "$ROOT/packages/$PACKAGE_NAME" ]] || die "unknown package: $PACKAGE_NAME"

mkdir -p "$ROOT/out/$TARGET_ID/$PACKAGE_NAME"

engine=$(container_engine)

"$engine" run --rm \
  -e "MDSPACE_DEB_BUILD_IN_CONTAINER=1" \
  -e "TARGET_ID=$TARGET_ID" \
  -e "TARGET_FAMILY=$TARGET_FAMILY" \
  -e "TARGET_VERSION=$TARGET_VERSION" \
  -e "TARGET_IMAGE=$TARGET_IMAGE" \
  -e "DEBIAN_FRONTEND=noninteractive" \
  -v "$ROOT:/repo" \
  -w /repo \
  "$TARGET_IMAGE" \
  /repo/build.sh "$PACKAGE_NAME"

mkdir -p "$OUTPUT_DIR"
find "$ROOT/out/$TARGET_ID/$PACKAGE_NAME" \
  -maxdepth 1 \
  -type f \
  \( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) \
  -exec cp -v {} "$OUTPUT_DIR"/ \;
