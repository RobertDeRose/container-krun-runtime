#!/usr/bin/env bash
# Lay out the installable package under dist/staging from the release build and
# the patched libkrun build. Needs no privileges; the setup command it ships
# installs the package (see scripts/setup.sh).
set -euo pipefail
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "stage on Apple Silicon macOS" >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_dir="$root/.build-deps/libkrun"
build="$root/.build/release"
dylib="$source_dir/target/release/libkrun.1.19.4.dylib"
provenance="$source_dir/target/release/native-vmnet.provenance"
stage="$root/dist/staging/container-krun-runtime"

[[ -x "$build/container-krun-runtime" && -x "$build/container-krun-vmm-helper" ]] || {
  echo "Run mise run release:build first" >&2; exit 1;
}
source_status() {
  git -C "$source_dir" status --porcelain=v1 --untracked-files=all -- . ':(exclude).checkout-*'
}
[[ -f "$provenance" && -z "$(source_status)" ]] || {
  echo "Run mise run libkrun with a committed patch in .build-deps/libkrun first" >&2
  source_status >&2
  exit 1
}
recorded_commit="$(awk -F= '$1=="commit" {print $2}' "$provenance")"
recorded_sha="$(awk -F= '$1=="source_build_sha256" {print $2}' "$provenance")"
[[ "$recorded_commit" == "$(git -C "$source_dir" rev-parse HEAD)" && "$recorded_sha" == "$(shasum -a 256 "$dylib" | awk '{print $1}')" ]] || {
  echo "libkrun checkout/build changed after provenance capture; rebuild first" >&2; exit 1;
}

rm -rf "$stage"
# Explicit modes throughout: setup copies these files as root, so anything left
# to the umask would become unreadable or wrongly writable afterwards.
install -d -m 0755 "$stage" "$stage/bin" "$stage/lib" "$stage/cli" "$stage/share/licenses/libkrun" "$stage/share/licenses/container-krun-runtime"
install -m 0755 "$build/container-krun-runtime" "$stage/bin/container-krun-runtime"
install -m 0755 "$build/container-krun-vmm-helper" "$stage/bin/container-krun-vmm-helper"
install -m 0644 "$dylib" "$stage/lib/libkrun.dylib"
python3 "$root/scripts/macho_trust.py" --normalize "$stage/bin/container-krun-vmm-helper" "$stage/lib/libkrun.dylib"
# The helper dlopens libkrun by absolute path, so its install name is never
# used. An @rpath name is one Homebrew leaves alone (see preserve_rpath in the
# formula) instead of rewriting, and re-signing, the library on install.
install_name_tool -id @rpath/libkrun.dylib "$stage/lib/libkrun.dylib"
python3 "$root/scripts/macho_trust.py" "$stage/lib/libkrun.dylib" >/dev/null
codesign --force --sign - --timestamp=none "$stage/bin/container-krun-runtime"
codesign --force --sign - --timestamp=none "$stage/lib/libkrun.dylib"
codesign --force --sign - --timestamp=none --entitlements "$root/signing/hypervisor.entitlements" "$stage/bin/container-krun-vmm-helper"
codesign --verify --strict "$stage/bin/container-krun-vmm-helper"
codesign --verify --strict "$stage/lib/libkrun.dylib"
install -m 0644 "$provenance" "$stage/lib/libkrun.provenance"
{
  echo "backend=libkrun-vmnet-shared"
  echo "sha256=$(shasum -a 256 "$stage/lib/libkrun.dylib" | awk '{print $1}')"
  echo "helper_sha256=$(shasum -a 256 "$stage/bin/container-krun-vmm-helper" | awk '{print $1}')"
  echo "runtime_sha256=$(shasum -a 256 "$stage/bin/container-krun-runtime" | awk '{print $1}')"
} >>"$stage/lib/libkrun.provenance"
install -m 0644 "$root/plugin/container-krun-runtime/config.toml" "$stage/config.toml"
# Not at the top level: Homebrew moves a top-level LICENSE out of the package.
install -m 0644 "$root/LICENSE" "$stage/share/licenses/container-krun-runtime/LICENSE"
install -m 0644 "$source_dir/LICENSE" "$stage/share/licenses/libkrun/LICENSE"
install -m 0755 "$root/scripts/setup.sh" "$stage/cli/container-krun-runtime-setup"
# Marks a directory as this package, so setup never replaces anything else.
echo "container-krun-runtime package" >"$stage/.container-krun-runtime"
chmod 0644 "$stage/.container-krun-runtime"
printf '%s\n' "$stage"
