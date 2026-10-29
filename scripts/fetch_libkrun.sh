#!/usr/bin/env bash
# Populate .build-deps/libkrun with the libkrun fork at the commit mise.toml
# pins. An existing checkout is left alone unless it is clean and elsewhere.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_dir="$root/.build-deps/libkrun"
repository="${LIBKRUN_REPOSITORY:-https://github.com/RobertDeRose/libkrun.git}"
commit="$(sed -n 's/^LIBKRUN_BASE_COMMIT = "\([0-9a-f]\{40\}\)"$/\1/p' "$root/mise.toml")"
[[ -n "$commit" ]] || { echo "LIBKRUN_BASE_COMMIT is missing from mise.toml" >&2; exit 1; }

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init -q
  git -C "$source_dir" remote add origin "$repository"
fi
[[ "$(git -C "$source_dir" rev-parse -q --verify HEAD || true)" == "$commit" ]] && { echo "$source_dir is at $commit"; exit 0; }
[[ -z "$(git -C "$source_dir" status --porcelain=v1 --untracked-files=no)" ]] || {
  echo "Refusing to move $source_dir: it has uncommitted changes" >&2; exit 1;
}
git -C "$source_dir" fetch -q --depth 1 origin "$commit"
git -C "$source_dir" checkout -q --detach "$commit"
echo "$source_dir is at $commit"
