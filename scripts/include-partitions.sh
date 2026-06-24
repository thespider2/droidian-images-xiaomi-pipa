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

BOOT_DIR="${4:-${PART_DIR}}"

for img in boot.img dtbo.img vbmeta.img; do
    if [ -f "${BOOT_DIR}/${img}" ]; then
        BOOT_IMAGES="${BOOT_IMAGES} ${img}"
        echo "Found ${img} locally"
        continue
    fi

    if [ -n "${DL_CMD}" ]; then
        echo "Downloading ${img} from ${REMOTE_BASE}/..."
        (cd "${PART_DIR}" && ${DL_CMD} "${REMOTE_BASE}/${img}")
        if [ -f "${PART_DIR}/${img}" ]; then
            BOOT_IMAGES="${BOOT_IMAGES} ${img}"
            echo "Downloaded ${img}"
        else
            echo "Failed to download ${img}, skipping"
        fi
    fi
done

ALL_IMAGES="${IMAGES} ${BOOT_IMAGES}"

if [ -z "${ALL_IMAGES}" ]; then
    echo "No images found, skipping"
    exit 0
fi

echo "Adding images to recovery zip at data/"
TMP=$(mktemp -d)
clean() { rm -rf "${TMP}"; }
trap clean EXIT
mkdir "${TMP}/data"
for img in ${ALL_IMAGES}; do
    cp "${PART_DIR}/${img}" "${TMP}/data/"
done
(cd "${TMP}" && zip -r9 "${ZIP_PATH}" data/*)

echo "Images added to recovery zip: ${ALL_IMAGES}"
