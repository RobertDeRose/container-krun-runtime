#!/usr/bin/env bash
# Install a source build the same way a release installs: stage the package,
# then run its setup command. Run as the login user; setup requests sudo only
# for the network helper.
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(id -u)" -ne 0 ]] || {
  echo "Run as the unprivileged Apple Container user on macOS; installation requests sudo." >&2; exit 1;
}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
install_root="${INSTALL_ROOT:-$(python3 "$root/scripts/install_root.py")}"
[[ -n "$install_root" ]] || { echo "Set INSTALL_ROOT to the installed Apple Container prefix" >&2; exit 1; }
stage="$("$root/scripts/stage.sh" | tail -n 1)"
"$stage/cli/container-krun-runtime-setup" --prefix "$install_root"
