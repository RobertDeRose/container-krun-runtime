#!/usr/bin/env bash
# Install this package as Apple Container's container-krun-runtime plugin.
# Shipped in the release archive as cli/container-krun-runtime-setup.
#
#   container-krun-runtime-setup [--prefix <install-root>] [--no-network]
#   container-krun-runtime-setup --uninstall [--prefix <install-root>]
#
# Registering the plugin needs no privileges when container's install root is
# writable (Homebrew, mise). Networking needs a root-owned copy of the VMM
# helper and libkrun plus a sudo rule that lets this user run only that copy;
# --no-network skips that part, leaving --network none containers working.
set -euo pipefail
name="container-krun-runtime"
trusted="/Library/PrivilegedHelperTools/com.github.robertderose.$name"
sudoers="/private/etc/sudoers.d/$name-native-vmnet"

usage() { sed -n '5,6s/^#   //p' "${BASH_SOURCE[0]}" >&2; exit 2; }
prefix=""
network=true
uninstall=false
while (($#)); do
  case "$1" in
    --prefix) [[ $# -ge 2 && "$2" == /* ]] || { echo "--prefix needs an absolute install root" >&2; exit 2; }; prefix="${2%/}"; shift 2;;
    --no-network) network=false; shift;;
    --uninstall) uninstall=true; shift;;
    -h|--help) usage;;
    *) echo "unknown argument: $1" >&2; usage;;
  esac
done

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "$name requires an Apple Silicon Mac" >&2; exit 1; }
macos_version="$(sw_vers -productVersion)"
[[ "${macos_version%%.*}" -ge 26 ]] || { echo "$name requires macOS 26 or newer" >&2; exit 1; }
[[ "$(id -u)" -ne 0 ]] || { echo "Run as the user who runs container; setup asks for sudo when it needs it." >&2; exit 1; }
user="$(id -un)"
case "$user" in ''|*[!A-Za-z0-9._-]*) echo "unsupported sudoers user name: $user" >&2; exit 1;; esac

# Homebrew and mise put a symlink to this script on PATH; the package is the
# directory above the real file.
package="$(cd "$(dirname "$(/bin/realpath "${BASH_SOURCE[0]}")")/.." && pwd -P)"
[[ -f "$package/.$name" && -x "$package/bin/$name" && -x "$package/bin/container-krun-vmm-helper" && -f "$package/lib/libkrun.dylib" ]] || {
  echo "setup must run from an extracted $name package; $package is not one" >&2; exit 1;
}

if [[ -z "$prefix" ]]; then
  container="$(command -v container || true)"
  [[ -n "$container" ]] || { echo "container is not on PATH; install it first or pass --prefix" >&2; exit 1; }
  container="$(/bin/realpath "$container")"
  # A mise shim resolves to mise itself; ask mise for the real executable.
  if [[ "$(basename "$container")" != container ]] && command -v mise >/dev/null; then
    container="$(/bin/realpath "$(mise which container)")"
  fi
  # Apple Container's Unix installation layout is <install-root>/bin/container.
  [[ "$(basename "$(dirname "$container")")" == bin ]] || { echo "cannot derive container's install root from $container; pass --prefix" >&2; exit 1; }
  prefix="$(dirname "$(dirname "$container")")"
fi
destination="$prefix/libexec/container-plugins/$name"
parent="$(dirname "$destination")"

# Plugin directories under /usr/local (Apple's installer) are root-owned.
ancestor="$parent"
while [[ ! -e "$ancestor" ]]; do ancestor="$(dirname "$ancestor")"; done
as_owner() { if [[ -w "$ancestor" ]]; then "$@"; else /usr/bin/sudo "$@"; fi; }

if [[ -e "$destination" || -L "$destination" ]]; then
  [[ -f "$destination/.$name" && ! -L "$destination" ]] || {
    echo "Refusing to replace $destination: it is not this plugin's installation" >&2; exit 1;
  }
fi

# Reject symlinks, non-root owners, group/other write access, and ACL grants on
# every existing component of a path that root will trust.
check_privileged_path() {
  local path="$1" allow_missing="${2:-false}" current="" component info uid mode kind
  local IFS=/
  for component in ${path#/}; do
    current="$current/$component"
    if [[ ! -e "$current" && ! -L "$current" ]]; then
      [[ "$allow_missing" == true ]] && return 0
      echo "missing privileged path: $current" >&2; return 1
    fi
    info="$(stat -f '%u %Lp %HT' "$current")"
    uid="${info%% *}"; info="${info#* }"; mode="${info%% *}"; kind="${info#* }"
    if [[ "$uid" != 0 ]] || (( 8#$mode & 8#022 )) || [[ "$kind" == "Symbolic Link" ]]; then
      echo "untrusted privileged path: $current" >&2; return 1
    fi
    [[ "$kind" == Directory || ( "$current" == "$path" && "$kind" == "Regular File" ) ]] || {
      echo "unexpected file type in privileged path: $current" >&2; return 1;
    }
    if /bin/ls -lde "$current" | tail -n +2 | grep -Ev '^[[:space:]]*[0-9]+: .+ deny .+' | grep -q .; then
      echo "ACL grant on privileged path: $current" >&2; return 1
    fi
  done
}

if [[ "$uninstall" == true ]]; then
  [[ -e "$destination" ]] && as_owner rm -rf -- "$destination" && echo "Removed $destination"
  if [[ -e "$sudoers" || -e "$trusted" ]]; then
    /usr/bin/sudo /bin/rm -f "$sudoers"
    /usr/bin/sudo /bin/rm -rf "$trusted"
    echo "Removed $trusted and $sudoers"
  fi
  exit 0
fi

# Register the plugin: a copy of this package, so an upgrade of either tool
# never leaves container running half of one version.
as_owner mkdir -p "$parent"
[[ ! -L "$parent" ]] || { echo "Refusing a symlinked plugin parent directory: $parent" >&2; exit 1; }
temporary="$(as_owner mktemp -d "$parent/.$name-install.XXXXXX")"
backup=""
root_stage=""
cleanup() {
  as_owner rm -rf -- "$temporary"
  if [[ -n "$backup" && -e "$backup" && ! -e "$destination" ]]; then as_owner mv -- "$backup" "$destination"; fi
  if [[ -n "$root_stage" ]]; then /usr/bin/sudo /bin/rm -rf "$root_stage"; fi
}
trap cleanup EXIT
# Only the plugin's own files: not cli/, and not what an installer such as mise
# adds beside them.
as_owner cp -R "$package/.$name" "$package/config.toml" \
  "$package/bin" "$package/lib" "$package/share" "$temporary/"
as_owner find "$temporary" -type d -exec chmod 0755 {} +

if [[ "$network" == true ]]; then
  for path in "$trusted" "$trusted/bin" "$trusted/lib" /private/etc/sudoers.d "$sudoers"; do
    check_privileged_path "$path" true
  done
  for path in "$trusted/bin/container-krun-vmm-helper" "$trusted/lib/libkrun.dylib" "$trusted/lib/libkrun.provenance" "$sudoers"; do
    if [[ -e "$path" || -L "$path" ]]; then
      check_privileged_path "$path"
      [[ -f "$path" ]] || { echo "refusing non-file installation target: $path" >&2; exit 1; }
    fi
  done
  echo "Installing the network helper needs administrator access."
  /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
  /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 "$trusted" "$trusted/bin" "$trusted/lib"
  /usr/bin/sudo /bin/chmod -N "$trusted" "$trusted/bin" "$trusted/lib"
  root_stage="$(/usr/bin/sudo /usr/bin/mktemp -d "$trusted/.install.XXXXXXXX")"
  for item in bin/container-krun-vmm-helper lib/libkrun.dylib lib/libkrun.provenance; do
    file="${item##*/}"
    mode=0644
    [[ "$item" != bin/* ]] || mode=0755
    /usr/bin/sudo /usr/bin/install -o root -g wheel -m "$mode" "$package/$item" "$root_stage/$file"
    /usr/bin/sudo /bin/chmod -N "$root_stage/$file"
    /usr/bin/sudo /bin/mv -f "$root_stage/$file" "$trusted/$item"
  done
  # Only this root-owned executable is authorized, never a user-writable copy.
  printf '%s ALL=(root) NOPASSWD: NOSETENV: %s/bin/container-krun-vmm-helper *\n' "$user" "$trusted" \
    | /usr/bin/sudo /usr/bin/tee "$root_stage/sudoers" >/dev/null
  /usr/bin/sudo /bin/chmod 0440 "$root_stage/sudoers"
  /usr/bin/sudo /usr/sbin/chown root:wheel "$root_stage/sudoers"
  /usr/bin/sudo /bin/chmod -N "$root_stage/sudoers"
  /usr/bin/sudo /usr/sbin/visudo -cf "$root_stage/sudoers" >/dev/null
  /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 /private/etc/sudoers.d
  /usr/bin/sudo /bin/mv -f "$root_stage/sudoers" "$sudoers"
fi

if [[ -e "$destination" ]]; then
  backup="$temporary.previous"
  as_owner mv -- "$destination" "$backup"
fi
as_owner mv -- "$temporary" "$destination"
if [[ -n "$backup" ]]; then as_owner rm -rf -- "$backup"; fi

echo "Installed $destination"
if [[ "$network" == true ]]; then
  echo "Network helper: $trusted (sudo rule for $user in $sudoers)"
else
  echo "Skipped the network helper; only --network none containers will start."
fi
echo "Restart Apple Container to load it: container system stop && container system start"
