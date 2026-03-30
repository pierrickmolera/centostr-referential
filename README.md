# Selective RPM Mirror and Air-Gap Installation ISO for CentOS Stream 9

Builds a minimal RPM mirror (~1-2 GB) containing only the packages listed in
`packages.list` and their dependencies, then generates a self-contained
(air-gap) installation ISO for CentOS Stream 9 with a real-time kernel.

## Overview

```
packages.list          build.sh               output/
(source of truth) --> [sync + ISO build] --> install-centos-stream-9-YYYY-MM-DD.iso
```

Three-stage pipeline:

1. **Sync** — `sync.sh` runs inside a buildah container and downloads via
   `dnf download --resolve --installroot` only the listed packages and their
   dependencies from the upstream repos (BaseOS, AppStream, RT, EPEL).
2. **Commit** — The result is committed as an OCI image
   (`localhost/mirrors/centos-stream-9:YYYY-MM-DD`).
3. **ISO** — `create-iso.sh` starts a pod (local nginx mirror + ISO builder),
   extracts the official boot ISO, injects the packages and kickstart, and
   produces the final ISO.

---

## Prerequisites

```sh
sudo dnf install -y podman buildah
```

The official CentOS Stream 9 boot ISO must be present at the project root:

```sh
curl -L -o boot.iso \
  https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/iso/CentOS-Stream-9-latest-x86_64-boot.iso
```

> This file (~800 MB) is only required for ISO creation.
> It contains the Anaconda installer environment and is not modified.

---

## Step 1 — Define the package list

Edit `packages.list` to add or remove packages.

**Syntax:**
```
# comment (line ignored)
pkg-name        # include this package and its dependencies
-pkg-name       # exclude this package (useful to force a variant, e.g. -kernel)
```

**Example:**
```
# Real-time kernel instead of the standard kernel
-kernel
-kernel-core
kernel-rt
kernel-rt-core
```

> `packages.list` is the single source of truth. Any change requires
> re-running `build.sh` to regenerate the mirror and the ISO.

---

## Step 2 — Build the mirror

```sh
./build.sh
```

This script:

1. Builds the base image (`Containerfile.base`) if it does not exist yet —
   CentOS Stream 9 + nginx + createrepo_c + dnf-plugins-core.
2. Creates (or resumes) a buildah working container from that image.
3. Resolves the `coreutils-single` / `coreutils` conflict inside the container
   before downloading packages.
4. Mounts `packages.list` and `sync.sh` read-only into the container and runs
   `sync.sh` inside via `buildah run`.
5. `sync.sh` downloads all packages via `dnf download --resolve --installroot`
   from the upstream repos and generates repo metadata with `createrepo_c`.
6. Commits the result as image `localhost/mirrors/centos-stream-9:YYYY-MM-DD`
   (~2.7 GB) and removes the working container.

**Available environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `UPSTREAM_CENTOS` | `https://mirror.stream.centos.org` | Upstream CentOS mirror |
| `UPSTREAM_EPEL` | `https://dl.fedoraproject.org/pub/epel` | Upstream EPEL mirror |
| `ARCH` | `x86_64` | Target architecture |

---

## Step 3 — Generate the installation ISO

```sh
CREATE_ISO=1 ./build.sh
```

This script (via `create-iso.sh` then `create-iso-inner.sh`):

1. Builds the ISO builder image (`Containerfile.iso`) if it does not exist yet.
2. Starts a pod with two containers:
   - **mirror**: serves the packages via nginx on port 8080
   - **builder**: runs `create-iso-inner.sh`
3. Fetches all packages from the local mirror via `dnf reposync`.
4. Generates a minimal `comps.xml` required by Anaconda.
5. Generates the embedded repo metadata with `createrepo_c`.
6. Extracts the official boot ISO with `xorriso`.
7. Copies the packages into the ISO tree under `/Packages`.
8. Writes a complete `.treeinfo` declaring the `BaseOS` variant with the
   `/Packages` directory.
9. Copies the kickstart and patches the bootloaders:
   - BIOS (`isolinux.cfg`): adds `inst.ks=hd:LABEL=...` and `inst.repo=hd:LABEL=...`
   - UEFI (`grub.cfg`, `grubx64.cfg`): same kernel parameters
10. Updates `.discinfo` with a custom description.
11. Rebuilds the final ISO with `xorriso` (dual BIOS/UEFI boot).
12. Verifies the ISO label and computes an MD5 checksum.

**Output:** `./output/install-centos-stream-9-YYYY-MM-DD.iso` (~2.8 GB)

**Environment variable:**

| Variable | Default | Description |
|----------|---------|-------------|
| `BOOT_ISO` | `./boot.iso` | Path to the official boot ISO |

---

## Step 4 — Test the ISO in a VM

```sh
virt-install \
  --name test-centos9-rt \
  --memory 4096 \
  --vcpus 2 \
  --disk path=/var/lib/libvirt/images/test-centos9.qcow2,format=qcow2,bus=virtio,size=50 \
  --cdrom ./output/install-centos-stream-9-$(date -I).iso \
  --network network=default \
  --os-variant rhel9-unknown \
  --boot uefi
```

The installation is fully automated via the embedded kickstart.
The VM shuts down automatically at the end of the installation (`poweroff`).

**Cleanup after test:**
```sh
virsh destroy test-centos9-rt
virsh undefine test-centos9-rt --nvram
rm -f /var/lib/libvirt/images/test-centos9.qcow2
```

---

## File structure

```
.
├── build.sh                # Main script (mirror + optional ISO)
├── packages.list           # Source of truth: packages to include
├── sync.sh                 # Package downloader (runs inside the buildah container)
├── Containerfile.base      # Base image: CentOS Stream 9 + nginx + tools
├── Containerfile.iso       # ISO builder image: xorriso + dnf + createrepo_c
├── nginx.conf              # nginx configuration for serving packages
├── kickstart.cfg           # Installation kickstart (air-gap, hd: repo)
├── create-iso.sh           # ISO creation orchestration (podman pod)
├── create-iso-inner.sh     # ISO construction (runs inside the builder container)
├── boot.iso                # Official CentOS Stream 9 boot ISO (to be provided)
└── output/                 # Generated ISOs
    ├── install-centos-stream-9-YYYY-MM-DD.iso
    └── install-centos-stream-9-YYYY-MM-DD.iso.md5
```

---

## Kickstart customization

`kickstart.cfg` configures the automated installation:

- **Partitioning**: `vda` disk, single XFS root partition
- **Network**: DHCP on `enp1s0`, hostname `localhost.localdomain`
- **Account**: `admin` user in the `wheel` group, passwordless sudo
- **SSH**: key-based authentication only (password disabled)
- **SELinux**: enforcing
- **Post-install**: all repos disabled (air-gap mode)

Adapt `rootpw`, `user`, `sshkey`, `network`, and `ignoredisk` to the target
environment before running `CREATE_ISO=1 ./build.sh`.

---

## Numbers

| Element | Size |
|---------|------|
| RPM mirror (OCI image) | ~2.7 GB |
| Installation ISO | ~2.8 GB |
| Included packages | ~594 |
| Build time (fast network) | ~5-10 min |

