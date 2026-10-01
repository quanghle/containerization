# Linux deployment tarball

`scripts/build-dist-linux.sh` builds a self-contained deployment tarball for
the host architecture (x86_64 or aarch64) natively on Linux. The
[`Linux dist`](../.github/workflows/linux-dist.yml) workflow runs it for both
architectures on every push, pull request, and `v*` tag. Tagged builds are
published as GitHub release assets.

## Layout

```
containerization-<arch>-<sha>/
├── bin/
│   ├── cctl               # static musl
│   ├── cloud-hypervisor   # upstream static release
│   └── virtiofsd          # glibc >= 2.35, needs libseccomp2 + libcap-ng0
├── kernel/vmlinux-<arch>  # Kata Containers guest kernel
└── initfs.ext4            # vminitd + vmexec (static musl)
```

## Usage

The host needs `/dev/kvm` (and the `tun` module for networking). Run `cctl`
as root:

```bash
tar -xzf containerization-x86_64-<sha>.tar.gz
cd containerization-x86_64-<sha>
sudo ./bin/cctl run \
    --kernel kernel/vmlinux-x86_64 \
    --initfs initfs.ext4 \
    --ch-binary bin/cloud-hypervisor \
    --virtiofsd-binary bin/virtiofsd \
    -i docker.io/library/alpine:3.22 --id demo \
    /bin/echo hello
```

## Building locally

Prerequisites: the Swift toolchain listed in `.swift-version`, the Static
Linux SDK (`make -C vminitd linux-sdk`), `curl`, `xz`, `e2fsprogs`, and a
virtiofsd binary built with
`scripts/patches/virtiofsd-skip-cap-drop-with-sandbox-none.patch`.

```bash
./scripts/build-dist-linux.sh --virtiofsd /path/to/virtiofsd
```

The script writes the tarball and its `.sha256` file to `bin/`. Downloads are
pinned by SHA-256 and cached in `.local/dist-cache` (override with
`DIST_CACHE_DIR`).
