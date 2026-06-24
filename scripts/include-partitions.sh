#!/bin/bash
set -e

ZIP_NAME="${1}"
PART_DIR="${2:-android-partitions}"
REMOTE_BASE="${3:-https://media.githubusercontent.com/media/thespider2/droidian-pipa-repo/refs/heads/main/packages}"

if [ -z "${ZIP_NAME}" ]; then
    echo "Usage: $0 <zip-name> [partitions-dir] [remote-base-url]"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/out"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"

if [ ! -f "${ZIP_PATH}" ]; then
    echo "Zip not found at ${ZIP_PATH}, skipping"
    exit 0
fi

[ "${PART_DIR:0:1}" = "/" ] || PART_DIR="${REPO_ROOT}/${PART_DIR}"

DL_CMD=""
if command -v wget >/dev/null 2>&1; then
    DL_CMD="wget -q --show-progress"
elif command -v curl >/dev/null 2>&1; then
    DL_CMD="curl -sSLO"
fi

download_if_missing() {
    local img="$1"
    if [ -f "${PART_DIR}/${img}" ]; then
        echo "  ${img}: found locally"
        return 0
    fi
    if [ -n "${DL_CMD}" ]; then
        echo "  ${img}: downloading from repo..."
        mkdir -p "${PART_DIR}"
        (cd "${PART_DIR}" && ${DL_CMD} "${REMOTE_BASE}/${img}")
        if [ -f "${PART_DIR}/${img}" ]; then
            echo "  ${img}: downloaded"
            return 0
        fi
        echo "  ${img}: failed to download"
    fi
    return 1
}

WORKDIR=$(mktemp -d)
clean() { rm -rf "${WORKDIR}"; }
trap clean EXIT

# Extract rootfs.img from zip using python3 (unzip may not be in container)
echo "Extracting rootfs.img from zip..."
python3 -c "
import zipfile, sys
z = zipfile.ZipFile('${ZIP_PATH}', 'r')
z.extract('data/rootfs.img', '${WORKDIR}')
" || {
    echo "Failed to extract rootfs.img from zip"
    exit 1
}

# Mount rootfs.img and extract boot/dtbo/vbmeta
echo "Extracting boot/dtbo/vbmeta from rootfs.img..."
mkdir -p "${WORKDIR}/r"
mount "${WORKDIR}/data/rootfs.img" "${WORKDIR}/r"

BOOT_IMAGES=""
for img in boot.img dtbo.img vbmeta.img; do
    src="${WORKDIR}/r/boot/${img}"
    if [ -f "${src}" ]; then
        cp "${src}" "${WORKDIR}/${img}"
        BOOT_IMAGES="${BOOT_IMAGES} ${img}"
        echo "  ${img}: extracted from rootfs"
    fi
done
umount "${WORKDIR}/r"

# Download vendor/odm from repo (or use local copies)
echo "Getting vendor/odm images..."
IMAGES=""
for img in vendor.img odm.img; do
    download_if_missing "${img}" && IMAGES="${IMAGES} ${img}" && \
        cp "${PART_DIR}/${img}" "${WORKDIR}/${img}"
done

ALL_IMAGES="${IMAGES} ${BOOT_IMAGES}"

if [ -z "${ALL_IMAGES}" ]; then
    echo "No images found, skipping"
    exit 0
fi

# Add all images to recovery zip at data/
echo "Adding images to recovery zip at data/"
python3 -c "
import zipfile, os
z = zipfile.ZipFile('${ZIP_PATH}', 'a', zipfile.ZIP_DEFLATED)
for img in '${ALL_IMAGES}'.split():
    path = '${WORKDIR}/' + img
    if os.path.exists(path):
        z.write(path, 'data/' + img)
z.close()
"
echo "Recovery zip updated with:${ALL_IMAGES}"

# Replace setup.sh with overlay (flashes boot/dtbo/vbmeta from /data/ directly)
OVERLAY_DIR="${REPO_ROOT}/android-recovery-overlay"
if [ -f "${OVERLAY_DIR}/setup.sh" ]; then
    echo "Replacing setup.sh with overlay version"
    python3 -c "
import zipfile
z = zipfile.ZipFile('${ZIP_PATH}', 'a', zipfile.ZIP_DEFLATED)
z.write('${OVERLAY_DIR}/setup.sh', 'setup.sh')
z.close()
"
fi

# ---- Fastboot zip: userdata.img with LVM ----
if command -v simg2img >/dev/null 2>&1 && command -v img2simg >/dev/null 2>&1; then
    echo "Creating fastboot zip..."
    FASTBOOT_ZIP="${OUT_DIR}/${ZIP_NAME%.zip}-fastboot.zip"
    cp "${ZIP_PATH}" "${FASTBOOT_ZIP}"

    python3 -c "
import zipfile
z = zipfile.ZipFile('${FASTBOOT_ZIP}', 'a', zipfile.ZIP_DEFLATED)
# Remove vendor/odm from fastboot zip (they go inside userdata.img LVM)
namelist = z.namelist()
for name in list(namelist):
    if name in ('data/vendor.img', 'data/odm.img'):
        z.remove(name)
z.close()
"

    echo "Extracting userdata.img from fastboot zip"
    python3 -c "
import zipfile
z = zipfile.ZipFile('${FASTBOOT_ZIP}', 'r')
z.extract('data/userdata.img', '${WORKDIR}')
"

    USERDATA_IMG="${WORKDIR}/data/userdata.img"
    if [ -f "${USERDATA_IMG}" ]; then
        echo "Converting sparse image to raw"
        simg2img "${USERDATA_IMG}" "${WORKDIR}/userdata.raw"

        echo "Setting up loop device"
        DEVICE=$(losetup -f --show "${WORKDIR}/userdata.raw")

        echo "Activating LVM"
        vgchange -ay droidian 2>/dev/null || true
        sleep 3

        ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs 2>/dev/null || echo "")
        if [ -z "${ROOTFS_VOLUME}" ]; then
            echo "LVM volume not found, trying vgscan"
            vgscan --mknodes -v 2>/dev/null || true
            sleep 3
            ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs 2>/dev/null || echo "")
        fi

        ROOTFS_VOLUME=${ROOTFS_VOLUME/\/dev/\/host-dev}
        echo "Mounting rootfs LV at ${ROOTFS_VOLUME}"
        mkdir -p "${WORKDIR}/mnt"
        mount "${ROOTFS_VOLUME}" "${WORKDIR}/mnt"

        echo "Copying vendor/odm to /userdata/ inside LVM"
        mkdir -p "${WORKDIR}/mnt/userdata"
        for img in vendor.img odm.img; do
            if [ -f "${PART_DIR}/${img}" ]; then
                cp "${PART_DIR}/${img}" "${WORKDIR}/mnt/userdata/"
                echo "  added ${img}"
            fi
        done
        sync

        echo "Unmounting"
        umount "${WORKDIR}/mnt"
        vgchange -an droidian 2>/dev/null || true
        losetup -d "${DEVICE}"

        echo "Converting back to sparse image"
        img2simg "${WORKDIR}/userdata.raw" "${USERDATA_IMG}"

        echo "Updating fastboot zip with modified userdata.img"
        python3 -c "
import zipfile
z = zipfile.ZipFile('${FASTBOOT_ZIP}', 'a', zipfile.ZIP_DEFLATED)
z.write('${WORKDIR}/data/userdata.img', 'data/userdata.img')
z.close()
"
    else
        echo "userdata.img not found in zip, skipping LVM injection"
    fi

    echo "Fastboot zip created: ${FASTBOOT_ZIP}"
else
    echo "simg2img/img2simg not available, skipping fastboot zip"
fi

echo ""
echo "========================================"
echo "Recovery zip contents:"
echo "========================================"
python3 -c "
import zipfile
z = zipfile.ZipFile('${ZIP_PATH}', 'r')
for f in z.infolist():
    print(f'{f.compress_size:>10} {f.file_size:>10} {f.filename}')
"
if [ -n "${FASTBOOT_ZIP}" ] && [ -f "${FASTBOOT_ZIP}" ]; then
    echo ""
    echo "========================================"
    echo "Fastboot zip contents:"
    echo "========================================"
    python3 -c "
import zipfile
z = zipfile.ZipFile('${FASTBOOT_ZIP}', 'r')
for f in z.infolist():
    print(f'{f.compress_size:>10} {f.file_size:>10} {f.filename}')
"
fi
echo "Done"
