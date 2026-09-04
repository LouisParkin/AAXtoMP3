#!/usr/bin/env bash
#
# Build the release archives attached to a GitHub release.
#
# Upstream built its v1.3 archives by hand on a Mac, which is why the tar.gz
# unpacks to AAXtoMP3/ but the zip unpacks to release/. Building them from a
# script means the artifacts do not depend on whose machine produced them, and
# CI and a local run yield identical bytes.
#
# Two variants are produced:
#   slim - the converter and nothing else, mirroring upstream's v1.3 bundle
#   full - also the documentation and the OpenAudible toolchain
#
# Usage: build-archives.sh --version 2.0.0 [--source DIR] [--out DIR]

set -euo pipefail

version=
source_dir=
out_dir=dist

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version ) version="$2"; shift 2 ;;
    --source  ) source_dir="$2"; shift 2 ;;
    --out     ) out_dir="$2"; shift 2 ;;
    -h | --help ) sed -n '2,15p' "$0"; exit 0 ;;
    * ) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$version" ] || { echo "--version is required (e.g. 2.0.0)" >&2; exit 1; }
version="${version#v}"

if [ -z "$source_dir" ]; then
  source_dir="$(git rev-parse --show-toplevel)"
fi
source_dir="$(cd "$source_dir" && pwd)"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# Both archive formats unpack to the same directory name.
stem="AAXtoMP3-v${version}"

# Reproducibility: pin every timestamp to the source commit rather than "now".
if epoch="$(git -C "$source_dir" log -1 --format=%ct 2>/dev/null)" && [ -n "$epoch" ]; then
  : "${SOURCE_DATE_EPOCH:=$epoch}"
else
  : "${SOURCE_DATE_EPOCH:=$(date +%s)}"
fi
export SOURCE_DATE_EPOCH

slim_paths=(AAXtoMP3 interactiveAAXtoMP3 README.md LICENSE)
full_paths=("${slim_paths[@]}" docs openaudible)

stage_and_pack() {
  local variant="$1"; shift
  local -a paths=("$@")
  local work stage name
  work="$(mktemp -d)"
  stage="${work}/${stem}"
  mkdir -p "$stage"

  local p
  for p in "${paths[@]}"; do
    [ -e "${source_dir}/${p}" ] || { echo "missing from source tree: $p" >&2; exit 1; }
    cp -R "${source_dir}/${p}" "${stage}/"
  done

  # Scripts must stay executable; everything else must not be.
  find "$stage" -type f -exec chmod 0644 {} +
  chmod 0755 "${stage}/AAXtoMP3" "${stage}/interactiveAAXtoMP3"
  if [ -d "${stage}/openaudible" ]; then
    find "${stage}/openaudible" -maxdepth 1 -type f ! -name '*.md' -exec chmod 0755 {} +
  fi
  find "$stage" -type d -exec chmod 0755 {} +

  # Uniform timestamps so repeated builds are byte-identical.
  find "$stage" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +

  name="${stem}-${variant}"

  # gzip -n omits the embedded mtime, which would otherwise differ per run.
  tar --sort=name --owner=0 --group=0 --numeric-owner \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      -C "$work" -cf - "$stem" | gzip -9 -n > "${out_dir}/${name}.tar.gz"

  # -X drops uid/gid and platform extras; zip stores DOS local time, so pin TZ.
  ( cd "$work" && TZ=UTC zip -q -r -X -9 "${out_dir}/${name}.zip" "$stem" )

  rm -rf "$work"
  echo "  built ${name}.tar.gz and ${name}.zip"
}

echo "Building ${stem} archives from ${source_dir}"
stage_and_pack slim "${slim_paths[@]}"
stage_and_pack full "${full_paths[@]}"

( cd "$out_dir" && sha256sum "${stem}"-*.tar.gz "${stem}"-*.zip > SHA256SUMS )

echo
echo "Artifacts in ${out_dir}:"
( cd "$out_dir" && ls -l "${stem}"-* SHA256SUMS | sed 's/^/  /' )
