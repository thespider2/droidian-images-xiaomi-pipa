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

IMAGES=""
DL_CMD=""
if command -v wget >/dev/null 2>&1; then
    DL_CMD="wget -q --show-progress"
elif command -v curl >/dev/null 2>&1; then
    DL_CMD="curl -sSLO"
fi

for img in vendor.img odm.img; do
    if [ -f "${PART_DIR}/${img}" ]; then
        IMAGES="${IMAGES} ${img}"
        echo "Found ${img} locally"
        continue
    fi

    if [ -n "${DL_CMD}" ]; then
        echo "Downloading ${img} from ${REMOTE_BASE}/..."
        mkdir -p "${PART_DIR}"
        (cd "${PART_DIR}" && ${DL_CMD} "${REMOTE_BASE}/${img}")
        if [ -f "${PART_DIR}/${img}" ]; then
            IMAGES="${IMAGES} ${img}"
            echo "Downloaded ${img}"
        else
            echo "Failed to download ${img}, skipping"
        fi
    fi
done

if [ -z "${IMAGES}" ]; then
    echo "No partition images found or downloaded, skipping"
    exit 0
fi

if ! command -v simg2img >/dev/null 2>&1 || ! command -v img2simg >/dev/null 2>&1; then
    echo "simg2img/img2simg not available, skipping"
    exit 0
fi

WORKDIR=$(mktemp -d)
clean() { rm -rf "${WORKDIR}"; }
trap clean EXIT

echo "Extracting userdata.img from zip"
(cd "${WORKDIR}" && unzip -o "${ZIP_PATH}" "data/userdata.img")

USERDATA_IMG="${WORKDIR}/data/userdata.img"
if [ ! -f "${USERDATA_IMG}" ]; then
    echo "userdata.img not found in zip, skipping"
    exit 0
fi

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

echo "Copying images to /userdata/"
mkdir -p "${WORKDIR}/mnt/userdata"
for img in ${IMAGES}; do
    cp "${PART_DIR}/${img}" "${WORKDIR}/mnt/userdata/"
    echo "  added ${img}"
done
sync

echo "Unmounting"
umount "${WORKDIR}/mnt"
vgchange -an droidian 2>/dev/null || true
losetup -d "${DEVICE}"

echo "Converting back to sparse image"
img2simg "${WORKDIR}/userdata.raw" "${USERDATA_IMG}"

echo "Updating zip with modified userdata.img"
(cd "${WORKDIR}" && zip -r9 "${ZIP_PATH}" "data/userdata.img")

echo "Adding images to zip at data/"
TMP=$(mktemp -d)
mkdir "${TMP}/data"
for img in ${IMAGES}; do
    cp "${PART_DIR}/${img}" "${TMP}/data/"
done
(cd "${TMP}" && zip -r9 "${ZIP_PATH}" data/*)
rm -rf "${TMP}"

echo "Patching flash_all.sh to copy images to rootfs"
TMP=$(mktemp -d)
(cd "${TMP}" && unzip -o "${ZIP_PATH}" "flash_all.sh" 2>/dev/null || true)
if [ -f "${TMP}/flash_all.sh" ]; then
    cat >> "${TMP}/flash_all.sh" << 'PATCH'

echo ""
echo "I: Copying partition images to /"
for img in vendor.img odm.img; do
    if [ -f "data/${img}" ]; then
        echo "I: Copying ${img}"
        cp "data/${img}" ./
    fi
done
PATCH
    (cd "${TMP}" && zip -r9 "${ZIP_PATH}" flash_all.sh)
    echo "flash_all.sh patched"
fi
rm -rf "${TMP}"

echo "Partition images injected into userdata.img and added to zip successfully"
