#!/bin/bash

# This script runs INSIDE the buildah container via "buildah run".
# It downloads only the packages listed in /packages.list and their dependencies.
# Requires internet access.

set -Eeuo pipefail

ARCH="${ARCH:-x86_64}"
CENTOS_VERSION="${CENTOS_VERSION:-9}"
EPEL_VERSION="${EPEL_VERSION:-${CENTOS_VERSION}}"
UPSTREAM_CENTOS="${UPSTREAM_CENTOS:-https://mirror.stream.centos.org}"
UPSTREAM_EPEL="${UPSTREAM_EPEL:-https://dl.fedoraproject.org/pub/epel}"

BASEOS_URL="${UPSTREAM_CENTOS}/${CENTOS_VERSION}-stream/BaseOS/${ARCH}/os/"
APPSTREAM_URL="${UPSTREAM_CENTOS}/${CENTOS_VERSION}-stream/AppStream/${ARCH}/os/"
RT_URL="${UPSTREAM_CENTOS}/${CENTOS_VERSION}-stream/RT/${ARCH}/os/"
EPEL_URL="${UPSTREAM_EPEL}/${EPEL_VERSION}/Everything/${ARCH}/"

PACKAGES_DIR="/var/www/packages"
mkdir -p "${PACKAGES_DIR}"

# Extract the package list (skip comments, blank lines, and exclusions)
mapfile -t PACKAGES < <(grep -v '^[[:space:]]*[#-]' /packages.list | grep -v '^[[:space:]]*$')

# Build exclusion flags (--exclude=pkg) for dnf
EXCLUDE_FLAGS=()
while IFS= read -r pkg; do
  [[ -n "$pkg" ]] && EXCLUDE_FLAGS+=("--exclude=${pkg}")
done < <(grep '^[[:space:]]*-' /packages.list | sed 's/^[[:space:]]*-[[:space:]]*//')


# coreutils-single is the lightweight variant installed in CentOS Stream 9
# container images. It conflicts with coreutils (full version) which we need
# in the ISO. Remove it before downloading packages.
echo "==> Removing container-specific packages incompatible with the target ISO..."
dnf remove -y coreutils-single 2>/dev/null || true

echo "==> Downloading ${#PACKAGES[@]} packages + dependencies..."
echo "==> Exclusions: ${EXCLUDE_FLAGS[*]:-none}"

# "dnf download --resolve" downloads packages and all their dependencies
# regardless of what is installed in the container.
# The "up-*" repo names avoid conflicts with the container's system repos.
# dnf download \
#   --resolve \
#   --releasever="${CENTOS_VERSION}" \
#   --repofrompath="up-baseos,${BASEOS_URL}" \
#   --repofrompath="up-appstream,${APPSTREAM_URL}" \
#   --repofrompath="up-rt,${RT_URL}" \
#   --repofrompath="up-epel,${EPEL_URL}" \
#   --repo=up-baseos --repo=up-appstream --repo=up-rt --repo=up-epel \
#   --destdir="${PACKAGES_DIR}" \
#   --nogpgcheck \
#   --allowerasing \
#   "${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"}" \
#   "${PACKAGES[@]}" 2>&1 | tee /logs/dnf-download.log

INSTALL_ROOT="/tmp/install-root"
mkdir -p "${INSTALL_ROOT}"

dnf download \
  --resolve \
  --installroot="${INSTALL_ROOT}" \
  --releasever="${CENTOS_VERSION}" \
  --repofrompath="up-baseos,${BASEOS_URL}" \
  --repofrompath="up-appstream,${APPSTREAM_URL}" \
  --repofrompath="up-rt,${RT_URL}" \
  --repofrompath="up-epel,${EPEL_URL}" \
  --repo=up-baseos --repo=up-appstream --repo=up-rt --repo=up-epel \
  --destdir="${PACKAGES_DIR}" \
  --nogpgcheck \
  --setopt=*.gpgcheck=0 \
  "${EXCLUDE_FLAGS[@]+"${EXCLUDE_FLAGS[@]}"}" \
  "${PACKAGES[@]}" 2>&1 | tee /logs/dnf-download.log

# Report any dependency resolution errors
if grep -i "error\|cannot\|nothing provides" /logs/dnf-download.log; then
  echo "==> WARNING: some dependencies could not be resolved"
  cat /logs/dnf-download.log | grep -i "error\|cannot\|nothing provides"
fi

echo "==> Generating repository metadata..."
createrepo_c "${PACKAGES_DIR}"

echo "==> Cleaning dnf cache..."
dnf clean all

RPM_COUNT=$(find "${PACKAGES_DIR}" -name "*.rpm" | wc -l)
TOTAL_SIZE=$(du -sh "${PACKAGES_DIR}" | cut -f1)
echo "==> Sync complete: ${RPM_COUNT} packages, ${TOTAL_SIZE} total."
