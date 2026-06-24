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
        echo "Found ${img} locally"
        return 0
    fi
    if [ -n "${DL_CMD}" ]; then
        echo "Downloading ${img} from ${REMOTE_BASE}/..."
        mkdir -p "${PART_DIR}"
        (cd "${PART_DIR}" && ${DL_CMD} "${REMOTE_BASE}/${img}")
        if [ -f "${PART_DIR}/${img}" ]; then
            echo "Downloaded ${img}"
            return 0
        fi
        echo "Failed to download ${img}, skipping"
    fi
    return 1
}

# Collect all images
IMAGES=""
BOOT_IMAGES=""
for img in vendor.img odm.img; do
    download_if_missing "${img}" && IMAGES="${IMAGES} ${img}"
done
for img in boot.img dtbo.img vbmeta.img; do
    download_if_missing "${img}" && BOOT_IMAGES="${BOOT_IMAGES} ${img}"
done

ALL_IMAGES="${IMAGES} ${BOOT_IMAGES}"

if [ -z "${ALL_IMAGES}" ]; then
    echo "No images found, skipping"
    exit 0
fi

# ---- Recovery zip: add images directly at data/ ----
echo "Adding images to recovery zip at data/"
TMP=$(mktemp -d)
clean() { rm -rf "${TMP}"; }
trap clean EXIT
mkdir "${TMP}/data"
for img in ${ALL_IMAGES}; do
    cp "${PART_DIR}/${img}" "${TMP}/data/"
done
(cd "${TMP}" && zip -r9 "${ZIP_PATH}" data/*)
echo "Recovery zip updated with: ${ALL_IMAGES}"

# Replace setup.sh with overlay (flashes boot/dtbo/vbmeta from /data/ directly)
OVERLAY_DIR="${REPO_ROOT}/android-recovery-overlay"
if [ -f "${OVERLAY_DIR}/setup.sh" ]; then
    echo "Replacing setup.sh with overlay version"
    cp "${OVERLAY_DIR}/setup.sh" "${TMP}/setup.sh"
    (cd "${TMP}" && zip -r9 "${ZIP_PATH}" setup.sh)
fi

# ---- Fastboot zip: userdata.img with LVM ----
# Need simg2img/img2simg for sparse conversion
if command -v simg2img >/dev/null 2>&1 && command -v img2simg >/dev/null 2>&1; then
    echo "Creating fastboot zip..."
    FASTBOOT_ZIP="${OUT_DIR}/${ZIP_NAME%.zip}-fastboot.zip"
    cp "${ZIP_PATH}" "${FASTBOOT_ZIP}"

    # Remove partition images from fastboot zip (they go inside userdata.img LVM)
    for img in vendor.img odm.img; do
        zip -d "${FASTBOOT_ZIP}" "data/${img}" 2>/dev/null || true
    done

    # Inject vendor/odm into userdata.img LVM
    WORKDIR=$(mktemp -d)
    TMPCLEAN="${TMPCLEAN} ${WORKDIR}"

    echo "Extracting userdata.img from fastboot zip"
    (cd "${WORKDIR}" && unzip -o "${FASTBOOT_ZIP}" "data/userdata.img")

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
        (cd "${WORKDIR}" && zip -r9 "${FASTBOOT_ZIP}" "data/userdata.img")
    else
        echo "userdata.img not found in zip, skipping LVM injection"
    fi

    rm -rf "${WORKDIR}"
    echo "Fastboot zip created: ${FASTBOOT_ZIP}"
else
    echo "simg2img/img2simg not available, skipping fastboot zip"
fi

echo ""
echo "========================================"
echo "Recovery zip contents:"
echo "========================================"
unzip -l "${ZIP_PATH}" | head -30
echo ""
if [ -f "${FASTBOOT_ZIP}" ]; then
    echo "========================================"
    echo "Fastboot zip contents:"
    echo "========================================"
    unzip -l "${FASTBOOT_ZIP}" | head -30
    echo ""
fi
echo "Done"
