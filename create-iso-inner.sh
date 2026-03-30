#!/bin/bash

# This script runs INSIDE the ISO builder container.
# It is invoked by create-iso.sh via podman run.
#
# Expected environment variables: CENTOS_VERSION, EPEL_VERSION, ARCH
# Expected volumes:
#   /boot.iso       → official CentOS Stream boot ISO (read-only)
#   /kickstart.cfg  → installation kickstart file
#   /output         → output directory

set -Eeuo pipefail

PACKAGES_URL="http://localhost:8080/packages/"
ISO_LABEL="CentOS-Stream-9-BaseOS-x86_64"

WORK_DIR="/tmp/iso-work"
PACKAGES_DIR="${WORK_DIR}/packages"
ISO_TREE="${WORK_DIR}/iso-tree"

##
## Step 1: Fetch all packages from the local mirror.
##
echo "==> Fetching packages from the local mirror..."
mkdir -p "${PACKAGES_DIR}"

dnf reposync \
  --repofrompath="mirror,${PACKAGES_URL}" \
  --repo=mirror \
  --destdir="${WORK_DIR}/reposync" \
  --download-metadata \
  --norepopath \
  --setopt="mirror.gpgcheck=0"

find "${WORK_DIR}/reposync" -name "*.rpm" -exec mv {} "${PACKAGES_DIR}/" \;

##
## Step 2: Generate a minimal comps.xml required by Anaconda.
##
echo "==> Generating comps.xml..."
cat > "${PACKAGES_DIR}/comps.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE comps PUBLIC "-//Red Hat, Inc.//DTD Comps info//EN" "comps.dtd">
<comps>
  <group>
    <id>core</id>
    <name>Core</name>
    <default>true</default>
    <uservisible>true</uservisible>
    <packagelist>
    </packagelist>
  </group>
</comps>
EOF

##
## Step 3: Generate the embedded repository metadata.
##
echo "==> Generating embedded repository metadata..."
createrepo_c --groupfile "${PACKAGES_DIR}/comps.xml" "${PACKAGES_DIR}"

##
## Step 4: Extract the contents of the official boot ISO.
##
echo "==> Extracting boot ISO..."
mkdir -p "${ISO_TREE}"
xorriso -osirrox on -indev /boot.iso -extract / "${ISO_TREE}" 2>/dev/null
chmod -R u+w "${ISO_TREE}"

##
## Step 5: Inject the packages into the ISO tree.
##
echo "==> Injecting packages into the ISO tree..."
cp -r "${PACKAGES_DIR}" "${ISO_TREE}/Packages"

##
## Step 6: Write a complete .treeinfo file.
##
echo "==> Writing .treeinfo..."
cat > "${ISO_TREE}/.treeinfo" << EOF
[general]
name = CentOS Stream
version = ${CENTOS_VERSION}
arch = ${ARCH}
family = CentOS Stream
variant = BaseOS
packagedir = Packages

[stage2]
mainimage = images/install.img

[variant-BaseOS]
id = BaseOS
name = BaseOS
packages = Packages
repository = Packages
type = variant
uid = BaseOS
EOF

##
## Step 7: Copy the kickstart and patch the bootloader configs.
##
echo "==> Injecting kickstart..."
cp /kickstart.cfg "${ISO_TREE}/ks.cfg"

# isolinux.cfg for BIOS boot
if [ -f "${ISO_TREE}/isolinux/isolinux.cfg" ]; then
    echo "==> Patching isolinux.cfg for BIOS boot..."
    cp "${ISO_TREE}/isolinux/isolinux.cfg" "${ISO_TREE}/isolinux/isolinux.cfg.orig"
    sed -i "s|append initrd=initrd\.img|append initrd=initrd.img inst.ks=hd:LABEL=${ISO_LABEL}:/ks.cfg inst.repo=hd:LABEL=${ISO_LABEL}:/|g" \
        "${ISO_TREE}/isolinux/isolinux.cfg"
    sed -i 's/timeout [0-9]*/timeout 30/' "${ISO_TREE}/isolinux/isolinux.cfg"
fi

# grub.cfg for UEFI boot
if [ -f "${ISO_TREE}/EFI/BOOT/grub.cfg" ]; then
    echo "==> Patching grub.cfg for UEFI boot..."
    cp "${ISO_TREE}/EFI/BOOT/grub.cfg" "${ISO_TREE}/EFI/BOOT/grub.cfg.orig"
    sed -i "s|linuxefi /images/pxeboot/vmlinuz|linuxefi /images/pxeboot/vmlinuz inst.ks=hd:LABEL=${ISO_LABEL}:/ks.cfg inst.repo=hd:LABEL=${ISO_LABEL}:/ |g" \
        "${ISO_TREE}/EFI/BOOT/grub.cfg"
    # Remove any stale inst.ks=cdrom parameters
    sed -i 's|inst\.ks=cdrom:[^ ]*||g' "${ISO_TREE}/EFI/BOOT/grub.cfg"
    sed -i 's/set timeout=[0-9]*/set timeout=3/' "${ISO_TREE}/EFI/BOOT/grub.cfg"
fi

# grubx64.cfg if present
if [ -f "${ISO_TREE}/EFI/BOOT/grubx64.cfg" ]; then
    echo "==> Patching grubx64.cfg..."
    cp "${ISO_TREE}/EFI/BOOT/grubx64.cfg" "${ISO_TREE}/EFI/BOOT/grubx64.cfg.orig"
    sed -i "s|linux /images/pxeboot/vmlinuz|linux /images/pxeboot/vmlinuz inst.ks=hd:LABEL=${ISO_LABEL}:/ks.cfg inst.repo=hd:LABEL=${ISO_LABEL}:/ |g" \
        "${ISO_TREE}/EFI/BOOT/grubx64.cfg"
    sed -i 's|inst\.ks=cdrom:[^ ]*||g' "${ISO_TREE}/EFI/BOOT/grubx64.cfg"
fi

##
## Step 8: Update .discinfo
##
echo "==> Updating .discinfo..."
if [ -f "${ISO_TREE}/.discinfo" ]; then
    head -n1 "${ISO_TREE}/.discinfo" > "${ISO_TREE}/.discinfo.new"
    echo "CentOS Stream ${CENTOS_VERSION} Custom Install" >> "${ISO_TREE}/.discinfo.new"
    echo "x86_64" >> "${ISO_TREE}/.discinfo.new"
    mv "${ISO_TREE}/.discinfo.new" "${ISO_TREE}/.discinfo"
fi

##
## Step 9: Rebuild the final ISO with xorriso.
##
echo "==> Rebuilding final ISO..."
ISO_SIZE=$(du -sm "${ISO_TREE}" | cut -f1)
echo "==> Estimated ISO size: ${ISO_SIZE}MB"

xorriso -as mkisofs \
  -o /output/install.iso \
  -R -J -T --joliet-long \
  -V "${ISO_LABEL}" \
  -A "CentOS Stream ${CENTOS_VERSION} Custom Installation" \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --efi-boot images/efiboot.img \
  -eltorito-alt-boot \
  -no-emul-boot \
  "${ISO_TREE}"

##
## Step 10: Verify and summarize.
##
echo "==> Verifying the created ISO..."
if [ -f /output/install.iso ]; then
    ISO_FINAL_SIZE=$(ls -lh /output/install.iso | awk '{print $5}')
    echo "==> ISO created successfully: install.iso (${ISO_FINAL_SIZE})"
    echo "==> Computing MD5 checksum..."
    cd /output
    md5sum install.iso > install.iso.md5
    echo "==> Checksum saved to install.iso.md5"

    # Verify the ISO label
    ACTUAL_LABEL=$(xorriso -indev /output/install.iso 2>&1 | grep "Volume id" | awk '{print $NF}' | tr -d "'")
    if [ "${ACTUAL_LABEL}" = "${ISO_LABEL}" ]; then
        echo "==> Label verified: ${ACTUAL_LABEL} ✓"
    else
        echo "==> WARNING: expected label '${ISO_LABEL}', got '${ACTUAL_LABEL}'"
    fi
else
    echo "==> ERROR: ISO was not created correctly"
    exit 1
fi

echo "==> ISO creation completed successfully."