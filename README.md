<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/assets/logo-dark.svg">
    <img src="site/assets/logo-light.svg" alt="container-krun-runtime" width="120">
  </picture>
</p>

# container-krun-runtime

`container-krun-runtime` is an experimental Apple Container runtime plugin that boots the normal Apple Container Linux guest stack with [libkrun](https://github.com/libkrun/libkrun) and Hypervisor.framework instead of Virtualization.framework.

The project exists to validate and productize one specific advantage demonstrated by the preceding feasibility experiment: Apple's stock Container kernel negotiates `VIRTIO_BALLOON_F_REPORTING` with libkrun, allowing guest-released pages to become reclaimable by macOS while the VM remains running.

No changes to `apple/container` or `apple/containerization` are required. The plugin uses Apple Container's public `runtime` plugin contract.

Product page: <https://robertderose.github.io/container-krun-runtime/>

## Current scope

What the runtime supports:

| Capability | Current |
| --- | --- |
| Boot Apple kernel + vminitd with libkrun | yes |
| Run initial container process | yes |
| `container exec` | yes |
| stdin/stdout/stderr | yes, fixed predeclared vsock pool |
| terminal resize | yes |
| signal / stop / wait | yes |
| container statistics | yes |
| automatic free-page reporting | yes, provided by libkrun + Apple kernel |
| Networking | yes, managed default `allocationOnly` network plus explicit compatible attachments |
| Published TCP/UDP ports | yes, through Apple `SocketForwarder` on the first attachment |
| Apple named/anonymous volumes | yes, libkrun virtio-blk |
| Host bind/virtiofs mounts | yes, libkrun virtio-fs with read-write/read-only support |
| Published Unix sockets | yes, fixed libkrun vsock mappings + vminitd relay |
| Arbitrary runtime `dial(port)` | yes, dynamic host-to-guest libkrun vsock |
| `copyIn` / `copyOut` | yes, dedicated predeclared vsock pool |
| Disk snapshot / export | yes, live rootfs export |
| Persistent `container logs` | yes, init stdout/stderr plus VM boot log |
| Filesystem trim / `container clean` | yes, writable rootfs and block-backed mounts |
| Rosetta | no, intentionally deferred; use Apple's official runtime for x86_64 emulation |
| Nested virtualization | no |
| SSH agent forwarding | yes, reverse fixed-vsock relay from host `SSH_AUTH_SOCK` |
| `--init` | yes, guest vminitd mounted as the minimal container init |

Remaining unsupported features fail with `ContainerizationError(.unsupported)` rather than silently degrading. Rosetta is intentionally deferred; users requiring x86_64 emulation should use Apple's official runtime.

Host bind mounts use libkrun's native virtio-fs backend. Each share is attached as an independent virtio-fs device, mounted at a VM-global staging path, and bind-mounted into the requested container destination. Read-only shares are enforced both by the libkrun device and the container bind mount. libkrun's macOS passthrough backend is not, by itself, a hard confinement boundary against a malicious guest kernel; host shares therefore assume the stock Apple Container guest kernel and vminitd are trusted. Do not expose host directories to an untrusted custom guest kernel when host-filesystem isolation is a security requirement.

The native path preserves Apple's `allocationOnly` attachment allocator and the
managed default-network resolution. It creates its own vmnet network in libkrun;
Apple's `reserved` serialization is not consumed. `--network none` remains
unprivileged. Native failures never fall back to external `vmnet-helper`.

## Requirements

- An Apple Silicon Mac running macOS 26 or newer.
- Apple Container 1.5.0 or newer, with `container` on your `PATH`.
- Administrator approval, once per install, for networking: a root-owned copy of the VMM helper
  and libkrun, and a sudo rule that lets your user run only that copy. Containers started with
  `--network none` need neither. See [the privilege boundary](docs/native-vmnet.md#privilege-boundary).

## Install

Install the package with Homebrew or mise, then run `container-krun-runtime-setup`. Setup copies the
runtime into the plugin directory of the `container` on your `PATH` and installs the network helper,
asking for sudo for that part only. Pass `--no-network` to skip the helper.

### Homebrew

```bash
brew install RobertDeRose/tap/container-krun-runtime
container-krun-runtime-setup
container system stop && container system start
```

### mise

```bash
mise use -g packslip:github.com/RobertDeRose/container-krun-runtime
container-krun-runtime-setup
container system stop && container system start
```

mise verifies the release's [packslip](https://packslip.dev) signature against this repository before
installing it. By default mise skips releases younger than 24 hours; name a version, such as
`packslip:github.com/RobertDeRose/container-krun-runtime@0.9.0`, to install a newer one.

To run setup automatically whenever mise installs a new version, give the tool a `postinstall` step.
It prompts for sudo during `mise install` or `mise upgrade`:

```toml
# ~/.config/mise/config.toml
[tools."packslip:github.com/RobertDeRose/container-krun-runtime"]
version = "latest"
postinstall = '"$MISE_TOOL_INSTALL_PATH/cli/container-krun-runtime-setup"'
```

### Upgrade and uninstall

Setup installs a copy, so after upgrading either `container-krun-runtime` or `container`, run
`container-krun-runtime-setup` again and restart Apple Container. To remove the plugin, the network
helper, and the sudo rule:

```bash
container-krun-runtime-setup --uninstall
```

### From source

Building needs Xcode with Swift 6.2+, mise 2026.9.3+, and Homebrew `llvm`, `lld`, and `xz`.
`mise run native:install` fetches the libkrun fork at the commit pinned in `mise.toml`, builds it and the
runtime, stages the same package a release ships, and runs its setup:

```bash
brew install llvm lld xz
mise install
scripts/fetch_libkrun.sh
mise run native:install
```

The build, release, and test tasks use `--force-resolved-versions` to enforce the committed `Package.resolved`,
including transitive dependency versions. Use the same flag with direct `swift build` or `swift test` commands.
For an intentional dependency change, resolve or update dependencies separately, review and commit
`Package.resolved`, then rerun validation. Do not delete the lockfile to clear build warnings.

`mise run native:install` (also available as `mise run install`) derives the Apple Container installation root
from the resolved `container` executable. mise pins Rust 1.98.1 for the libkrun build. Override the installation
root when necessary:

```bash
INSTALL_ROOT=/path/to/container/install/root mise run install
```

### Installed layout

```text
<install-root>/libexec/container-plugins/container-krun-runtime/
├── config.toml
├── bin/
│   ├── container-krun-runtime
│   └── container-krun-vmm-helper
├── lib/
│   ├── libkrun.dylib
│   └── libkrun.provenance
└── share/licenses/libkrun/LICENSE
```

The VMM helper is ad-hoc signed with the `com.apple.security.hypervisor` entitlement. The runtime plugin does not
need that entitlement because libkrun is isolated in the helper process. Networked VMs load the fixed root-owned
copy under `/Library/PrivilegedHelperTools/com.github.robertderose.container-krun-runtime`. Networkless VMs use the
packaged copy. `LIBKRUN_DYLIB` is rejected for native setup unless it names the protected copy.

## Use

Start with the runtime selected explicitly and networking disabled:

```bash
container run --rm \
  --runtime container-krun-runtime \
  --network none \
  alpine:3.20 echo hello-from-libkrun
```

Run a workload under the minimal init process for signal forwarding and zombie reaping:

```bash
container run --rm \
  --runtime container-krun-runtime \
  --network none \
  --init \
  alpine:3.20 sh -c 'echo pid=$$; sleep 1'
```

Networking works without any setup. When Apple Container requests its built-in `default` network,
`container-krun-runtime` uses it directly when it is already a compatible `allocationOnly` network. On macOS 26,
where Apple's built-in default uses the incompatible `reserved` variant, the runtime creates and uses a managed `krun`
network instead. The managed network is a `container-network-vmnet` NAT network with `variant=allocationOnly`; subnet
selection chooses the first unused `/24` from `192.168.200.0/24` through `192.168.254.0/24`.

```bash
container run --rm \
  --runtime container-krun-runtime \
  alpine:3.20 ping -c 1 1.1.1.1
```

Explicit networks are still honored. They must already exist and use `container-network-vmnet`, NAT mode, and
`variant=allocationOnly`; incompatible networks fail before allocation with an actionable error. Additional
compatible networks become `eth1`, `eth2`, ... while `eth0` remains primary:

```bash
container network create \
  --subnet 192.168.220.0/24 \
  --option variant=allocationOnly \
  krun-secondary

container run --rm \
  --runtime container-krun-runtime \
  --network krun \
  --network krun-secondary \
  alpine:3.20 ip route
```

TCP and UDP ports can be published through the same Apple `SocketForwarder` implementation used by the stock runtime:

```bash
container run --rm \
  --runtime container-krun-runtime \
  --publish 127.0.0.1:8080:80/tcp \
  nginx:alpine
```

Unix sockets can be published without a network attachment:

```bash
container run --rm \
  --runtime container-krun-runtime \
  --network none \
  --publish-socket /tmp/service.sock:/run/service.sock \
  your-image
```

SSH agent forwarding uses the launching process's `SSH_AUTH_SOCK`, matching Apple's runtime behavior:

```bash
container run --rm \
  --runtime container-krun-runtime \
  --network none \
  --ssh \
  your-image ssh-add -l
```

Choose a different private subnet if `192.168.200.0/24` overlaps an existing Apple Container network.

Apple named and anonymous volumes are attached as libkrun virtio-blk devices while Apple Container remains authoritative for volume creation, ownership, and deletion:

```bash
container volume create app-data
container run --rm \
  --runtime container-krun-runtime \
  --network none \
  -v app-data:/data \
  alpine:3.20 sh -c 'echo persisted >/data/value.txt'
```

Host directory mounts remain unsupported pending a safe macOS confinement boundary for virtio-fs.

Once feature parity is sufficient, a separately installed user plugin named `container-runtime-linux` can shadow Apple's bundled runtime. v0.2 deliberately does not install itself that way.

## Design constraints

The runtime is one plugin process per Apple Container sandbox. It starts one child `container-krun-vmm-helper` process that owns libkrun and the Hypervisor.framework entitlement.

libkrun's vsock mappings are configured before VM start. The runtime currently reserves:

- guest port `1024` for the host-to-guest vminitd control channel;
- 96 guest-to-host ports beginning at `0x10000000` for process stdio;
- 8 guest-to-host ports immediately after the stdio range for copy transfers;
- one fixed mapping per configured published Unix socket or active SSH-agent relay, beginning after the copy range.

The stdio pool supports 32 simultaneously connected processes when all three stdio streams are present. Ports are returned to the pool when a process is cleaned up.

Apple's network plugin remains authoritative for attachment allocation/IPAM. A request for Apple Container's built-in `default` network uses that resource directly when it is compatible; on macOS 26 the incompatible `reserved` default is resolved to the runtime-managed `krun` `allocationOnly` network, which is created through Apple Container's public network API when missing. Explicit network names are preserved and must be compatible (`container-network-vmnet`, NAT, `variant=allocationOnly`). The Apple-assigned address and MTU are configured on `eth0`, `eth1`, ... in request order. `eth0` remains authoritative for the default route, fallback DNS, hostname identity, and published TCP/UDP forwarding.

See [docs/design.md](docs/design.md) for the lifecycle and rationale.

## Website

`site/` holds the project's product page: static HTML with no build step. The `Pages` workflow publishes it to
GitHub Pages on pushes to `main` that change `site/`. Preview it locally with `mise run site`, which serves it at
`http://localhost:8000`; set `PORT` to use another port.

## Releases

Every push to `main` runs the `Release` workflow, which runs `scripts/release.sh`.
[Cocogitto](https://docs.cocogitto.io/) derives the next version from the Conventional Commits since the last tag
(configured in `cog.toml`): `fix`, `perf`, and `revert` release a patch, `feat` a minor, and a breaking change a
major. The workflow builds the package on macOS, pushes the tag, publishes the GitHub release with the archive and
its checksum, updates the formula in `RobertDeRose/homebrew-tap`, and signs the release with packslip for mise.
`mise run release:preview` shows the version and notes the next release would publish, changing nothing.
