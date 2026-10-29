#!/usr/bin/env bash
# Archive the staged package for a release, with a checksum file beside it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
stage="$root/dist/staging/container-krun-runtime"
[[ -x "$stage/bin/container-krun-runtime" ]] || { echo "Run scripts/stage.sh first" >&2; exit 1; }
version="${VERSION:-$("$stage/bin/container-krun-runtime" --version)}"
case "$version" in ''|*[!a-zA-Z0-9._-]*) echo "invalid package version: $version" >&2; exit 2;; esac
# darwin and aarch64 are packslip's spellings, so it infers the platform.
archive="$root/dist/container-krun-runtime-${version}-darwin-aarch64.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$root/dist/staging" container-krun-runtime
# Checksum against the bare file name, so shasum -c works beside the download.
(cd "$root/dist" && shasum -a 256 "$(basename "$archive")" >"$archive.sha256")
printf '%s\n' "$archive"
