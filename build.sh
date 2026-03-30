#!/bin/bash

set -Eeuo pipefail

# CentOS Stream version to mirror.
declare CENTOS_VERSION="9"
declare EPEL_VERSION="${EPEL_VERSION:-${CENTOS_VERSION}}"
declare ARCH="${ARCH:-x86_64}"

# Upstream mirrors (overridable via environment variables)
declare UPSTREAM_CENTOS="${UPSTREAM_CENTOS:-https://mirror.stream.centos.org}"
declare UPSTREAM_EPEL="${UPSTREAM_EPEL:-https://dl.fedoraproject.org/pub/epel}"

declare IMAGE_BASE="localhost/mirrors/centos-stream-${CENTOS_VERSION}"
declare IMAGE_TAG="$(date -I)"

##
## Step 1: build the base image if it does not exist yet.
##
if ! podman image inspect "${IMAGE_BASE}:base" &>/dev/null; then
  echo "Building base image..."
  podman build \
    --file Containerfile.base \
    -t "${IMAGE_BASE}:base" \
    --security-opt label=disable \
    .
fi

##
## Step 2: build the mirror image with the selected packages.
##
if ! podman image inspect "${IMAGE_BASE}:latest" &>/dev/null; then
  podman tag "${IMAGE_BASE}:base" "${IMAGE_BASE}:latest"
fi

BUILDAH_CONTAINER_NAME="buildah-sync-centos-${CENTOS_VERSION}"
if buildah inspect "${BUILDAH_CONTAINER_NAME}" &>/dev/null; then
  echo "Resuming existing buildah container: ${BUILDAH_CONTAINER_NAME}"
else
  echo "Creating buildah container from ${IMAGE_BASE}:latest..."
  buildah from --name="${BUILDAH_CONTAINER_NAME}" "${IMAGE_BASE}:latest"
fi

# Prepare the container by resolving package conflicts
echo "==> Preparing container (resolving conflicts)..."
buildah run "${BUILDAH_CONTAINER_NAME}" -- bash -c '
    if rpm -q coreutils-single &>/dev/null; then
        dnf swap -y coreutils-single coreutils --allowerasing || 
        dnf remove -y coreutils-single
    fi
'


# Run sync.sh INSIDE the container.
# packages.list and sync.sh are mounted read-only for the duration of the run.
# Downloaded packages persist in the container's writable layer.
echo "Starting package download..."
# Absolute path required by buildah run --volume
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
export CENTOS_VERSION EPEL_VERSION ARCH UPSTREAM_CENTOS UPSTREAM_EPEL
mkdir -p "${SCRIPT_DIR}/logs"

buildah run \
  --network=host \
  --env CENTOS_VERSION \
  --env EPEL_VERSION \
  --env ARCH \
  --env UPSTREAM_CENTOS \
  --env UPSTREAM_EPEL \
  --volume "${SCRIPT_DIR}/packages.list:/packages.list:ro,z" \
  --volume "${SCRIPT_DIR}/sync.sh:/sync.sh:ro,z" \
  --volume "${SCRIPT_DIR}/logs:/logs:z" \
  "${BUILDAH_CONTAINER_NAME}" \
  -- bash /sync.sh

# Commit the final image
echo "Creating final image ${IMAGE_BASE}:${IMAGE_TAG}..."
BUILDAH_TMPDIR="${HOME}/.local/share/buildah-tmp"
mkdir -p "${BUILDAH_TMPDIR}"
export TMPDIR="${BUILDAH_TMPDIR}"
buildah commit --quiet "${BUILDAH_CONTAINER_NAME}" "${IMAGE_BASE}:${IMAGE_TAG}"
buildah tag "${IMAGE_BASE}:${IMAGE_TAG}" "${IMAGE_BASE}:latest"
buildah rm "${BUILDAH_CONTAINER_NAME}"

echo "Build complete. Image: ${IMAGE_BASE}:${IMAGE_TAG}"

##
## Step 3 (optional): create the bootable ISO.
## Enable with: CREATE_ISO=1 ./build.sh
##
if [ "${CREATE_ISO:-0}" = "1" ]; then
  export IMAGE_BASE CENTOS_VERSION
  "${BASH_SOURCE[0]%/*}/create-iso.sh"
fi
