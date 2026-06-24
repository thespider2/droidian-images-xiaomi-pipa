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
ZIP_PATH="${REPO_ROOT}/out/${ZIP_NAME}"

if [ ! -f "${ZIP_PATH}" ]; then
    echo "Zip not found at ${ZIP_PATH}, skipping partition inclusion"
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

for img in vendor.img odm.img product.img; do
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

echo "Including partition images:${IMAGES}"

TMPDIR=$(mktemp -d)
mkdir -p "${TMPDIR}/data"
for img in ${IMAGES}; do
    cp "${PART_DIR}/${img}" "${TMPDIR}/data/"
done
(cd "${TMPDIR}" && zip -r9 "${ZIP_PATH}" data/*)
rm -rf "${TMPDIR}"
echo "Images added to zip successfully"
