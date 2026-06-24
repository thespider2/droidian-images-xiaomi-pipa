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

echo "Building fastboot zip with partition images"

FASTBOOT_ZIP="${OUT_DIR}/${ZIP_NAME%.zip}-fastboot.zip"
TMPDIR=$(mktemp -d)

for img in ${IMAGES}; do
    cp "${PART_DIR}/${img}" "${TMPDIR}/"
done

cat > "${TMPDIR}/flash-partitions.sh" << 'SCRIPT'
#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Flashing vendor partition..."
fastboot flash vendor "${DIR}/vendor.img" || echo "vendor partition may not exist"

echo "Flashing odm partition..."
fastboot flash odm "${DIR}/odm.img" || echo "odm partition may not exist"

echo "Rebooting..."
fastboot reboot || true
SCRIPT
chmod +x "${TMPDIR}/flash-partitions.sh"

(cd "${TMPDIR}" && zip -r9 "${FASTBOOT_ZIP}" .)
rm -rf "${TMPDIR}"

echo "Fastboot zip created: ${FASTBOOT_ZIP}"
