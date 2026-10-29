# container-krun-runtime benchmarks

Network benchmarks and profilers for [container-krun-runtime](https://github.com/RobertDeRose/container-krun-runtime).
This orphan branch holds only these tools; it shares no files with the runtime, so it never needs merging or
rebasing onto `main`. The tools drive the `container` CLI against whatever runtime is installed, released builds
and Apple's own runtime included, and compare them in paired runs.

## Use

Check the branch out beside a runtime checkout:

```bash
git worktree add ../container-krun-runtime-bench bench
cd ../container-krun-runtime-bench
mise tasks
```

Run a task with `mise run`, for example the sustained TCP throughput benchmark behind the product page's network
numbers:

```bash
mise run benchmark:network-streams
```

Judge results by the paired krun/Apple ratio, not absolute throughput: host load moves absolute numbers between
runs, and paired ordering shares it between the two runtimes.

## Tasks

| Task | Measures | Needs a patched runtime |
| --- | --- | --- |
| `benchmark:network-streams` | sustained TCP throughput at P1/P4/P8, Apple vs krun | no |
| `benchmark:network-network-scaling` | two VMs on one vmnet network vs two networks | no |
| `benchmark:network-worker-scaling` | one P8 VM vs two concurrent P4 VMs | no |
| `profile:network-guest-cpu-compare` | guest CPU, softirq, IRQ, and virtio queues, Apple vs krun | no |
| `profile:network-streams` | host-side `sample`/`top` profile of a krun P8 run (asks for sudo) | no |
| `profile:network-guest-cpu` | guest CPU plus the helper's TX datapath statistics | `patches/tx-datapath-stats` |
| `benchmark:network-cpu-scaling` | throughput with 2 vs 8 guest vCPUs | `patches/vmnet-helper-comparison` |
| `benchmark:vmnet-backends` | native vmnet vs the external vmnet-helper backend | `patches/vmnet-helper-comparison` |
| `validate:vmnet-batching` | libkrun vmnet batching with paired bulk evidence | runs from a runtime checkout |

`scripts/vmnet_tx_bench` is a host-only C benchmark of `vmnet_write` cost per call; run it with
`scripts/vmnet_tx_bench/run.sh`.

`validate:vmnet-batching` drives the runtime repository's own checks and installer (`mise run check`,
`mise run native:install`), so run `scripts/validate_vmnet_batching.sh` from the root of a runtime checkout.

`scripts/install_root.py`, `scripts/native_vmnet_validation.py`, and `scripts/macho_trust.py` are copies of the
runtime repository's helpers that the profilers import.

## Runtime patches

Three runtime changes support the tools above but are not part of the shipped runtime. They live here as
`git format-patch` series against the runtime's source; apply one to a scratch runtime checkout and install that
build with `mise run native:install`:

```bash
git -C ../container-krun-runtime-scratch am --3way patches/vmnet-helper-comparison/*.patch
```

| Series | Adds | Applies to current `main` |
| --- | --- | --- |
| `tx-datapath-stats` | TX datapath statistics the VMM helper prints on `SIGUSR1`, reset on `SIGUSR2` | no; port by hand |
| `vmnet-helper-comparison` | a control mode that runs the guest over the external vmnet-helper instead of native vmnet | yes |
| `guest-sysctl-labels` | per-container guest sysctls from `com.github.robertderose.container-krun-runtime.sysctl.<name>` labels, such as choosing Reno over BBR | yes |

## Tests

```bash
python3 -m unittest discover -s scripts/tests
```
