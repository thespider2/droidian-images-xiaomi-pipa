#!/bin/bash
set -e

ZIP_NAME="${1}"
PART_DIR="${2:-android-partitions}"
REMOTE_BASE="${3:-https://media.githubusercontent.com/media/thespider2/droidian-pipa-repo/refs/heads/main/packages}"

if [ -z "${ZIP_NAME}" ]; then
    echo "Usage: $0 <zip-name> [partitions-dir] [remote-base-url]"
    exit 1
fi

# Determine repo root (this script lives at scripts/include-partitions.sh)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP_PATH="${REPO_ROOT}/rootfs-templates/out/${ZIP_NAME}"
WORK_DIR="${REPO_ROOT}/rootfs-templates/${ZIP_NAME}.work"

# Check if the zip exists
if [ ! -f "${ZIP_PATH}" ]; then
    echo "Zip not found at ${ZIP_PATH}, skipping partition inclusion"
    exit 0
fi

# Resolve partition dir
[ "${PART_DIR:0:1}" = "/" ] || PART_DIR="${REPO_ROOT}/${PART_DIR}"

# Find or download images
IMAGES=""
DL_CMD=""
if command -v wget >/dev/null 2>&1; then
    DL_CMD="wget -q --show-progress"
elif command -v curl >/dev/null 2>&1; then
    DL_CMD="curl -sSLO"
fi

for img in vendor.img odm.img product.img; do
    # Try local first
    if [ -f "${PART_DIR}/${img}" ]; then
        IMAGES="${IMAGES} ${img}"
        echo "Found ${img} locally"
        continue
    fi

    # Download from remote if we have a download tool
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

echo "Including partition images:${IMAGES}"

# Try to add to work directory first (if it exists and has target/data)
TARGET_DIR="${WORK_DIR}/target/data"
if [ -d "${TARGET_DIR}" ]; then
    for img in ${IMAGES}; do
        cp "${PART_DIR}/${img}" "${TARGET_DIR}/"
    done
    (cd "${WORK_DIR}/target" && zip -r9 "${ZIP_PATH}" ${IMAGES})
    echo "Images added to zip via work directory"
else
    # Fallback: add directly to zip
    TMPDIR=$(mktemp -d)
    mkdir -p "${TMPDIR}/data"
    for img in ${IMAGES}; do
        cp "${PART_DIR}/${img}" "${TMPDIR}/data/"
    done
    (cd "${TMPDIR}" && zip -r9 "${ZIP_PATH}" data/*)
    rm -rf "${TMPDIR}"
    echo "Images added to zip directly"
fi
