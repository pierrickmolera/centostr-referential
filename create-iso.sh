#!/bin/bash

set -Eeuo pipefail

declare CENTOS_VERSION="${CENTOS_VERSION:-9}"
declare EPEL_VERSION="${EPEL_VERSION:-${CENTOS_VERSION}}"
declare ARCH="${ARCH:-x86_64}"
declare IMAGE_BASE="${IMAGE_BASE:-localhost/mirrors/centos-stream-${CENTOS_VERSION}}"
declare ISO_IMAGE="${IMAGE_BASE}:iso-builder"
declare ISO_OUTPUT="${ISO_OUTPUT:-${BASH_SOURCE[0]%/*}/output}"
declare ISO_NAME="install-centos-stream-${CENTOS_VERSION}-$(date -I).iso"
# Path to the official CentOS Stream boot ISO (installer only, ~800 MB).
# Download once from: https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/iso/
declare BOOT_ISO="${BOOT_ISO:-${BASH_SOURCE[0]%/*}/boot.iso}"

declare BOOT_ISO_URL="https://mirror.stream.centos.org/${CENTOS_VERSION}-stream/BaseOS/${ARCH}/iso/CentOS-Stream-${CENTOS_VERSION}-latest-${ARCH}-boot.iso"

_download_boot_iso() {
  echo "Downloading boot ISO from ${BOOT_ISO_URL}..."
  curl -L --progress-bar -o "${BOOT_ISO}" "${BOOT_ISO_URL}"
  echo "Boot ISO saved to: ${BOOT_ISO}"
}

if [ ! -f "${BOOT_ISO}" ]; then
  echo "Boot ISO not found at: ${BOOT_ISO}"
  read -r -p "Download it now? (~800 MB) [y/N] " _reply
  if [[ "${_reply}" =~ ^[Yy]$ ]]; then
    _download_boot_iso
  else
    echo "Aborted. Provide the boot ISO at '${BOOT_ISO}' or set BOOT_ISO=<path>." >&2
    exit 1
  fi
else
  read -r -p "Boot ISO already exists at '${BOOT_ISO}'. Replace it? [y/N] " _reply
  if [[ "${_reply}" =~ ^[Yy]$ ]]; then
    _download_boot_iso
  fi
fi

##
## Build the ISO builder image if it does not exist yet.
##
if ! podman image inspect "${ISO_IMAGE}" &>/dev/null; then
  echo "Building ISO builder image..."
  podman build \
    --file "${BASH_SOURCE[0]%/*}/Containerfile.iso" \
    --security-opt label=disable \
    --tag "${ISO_IMAGE}" \
    "${BASH_SOURCE[0]%/*}"
fi

##
## Create a pod so that the mirror server and the ISO builder share the same
## network namespace. This allows the builder to reach the local mirror via
## http://localhost:8080 without any port mapping on the host.
##
POD_NAME="iso-build-$(date +%s)"
podman pod create --name "${POD_NAME}"

function cleanup {
  echo "Cleaning up build pod..."
  podman pod rm -f "${POD_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

echo "Starting local mirror server..."
podman run -d \
  --pod "${POD_NAME}" \
  --name "${POD_NAME}-mirror" \
  "${IMAGE_BASE}:latest"

# Give nginx a moment to start serving
sleep 3

mkdir -p "${ISO_OUTPUT}"

##
## Run the inner script inside the ISO builder container.
## The container joins the pod's network (localhost:8080 = mirror server),
## and is privileged so lorax can create device nodes and chroots.
##
echo "Starting ISO build process..."
podman run --rm \
  --pod "${POD_NAME}" \
  --privileged \
  --security-opt label=disable \
  -v "${ISO_OUTPUT}:/output:z" \
  -v "${BOOT_ISO}:/boot.iso:ro,z" \
  -v "${BASH_SOURCE[0]%/*}/kickstart.cfg:/kickstart.cfg:ro,z" \
  -v "${BASH_SOURCE[0]%/*}/create-iso-inner.sh:/create-iso-inner.sh:ro,z" \
  -e "CENTOS_VERSION=${CENTOS_VERSION}" \
  -e "EPEL_VERSION=${EPEL_VERSION}" \
  -e "ARCH=${ARCH}" \
  "${ISO_IMAGE}" \
  bash /create-iso-inner.sh

mv "${ISO_OUTPUT}/install.iso" "${ISO_OUTPUT}/${ISO_NAME}"
echo "ISO available at: ${ISO_OUTPUT}/${ISO_NAME}"
