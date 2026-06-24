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

# Derive both zip names
FASTBOOT_ZIP="${OUT_DIR}/${ZIP_NAME}"
RECOVERY_ZIP="${OUT_DIR}/${ZIP_NAME/_recovery/}-recovery.zip"
if echo "${ZIP_NAME}" | grep -q "_recovery"; then
    # Called from recovery build — fastboot zip has no _recovery
    FASTBOOT_ZIP="${OUT_DIR}/${ZIP_NAME/_recovery/}"
    RECOVERY_ZIP="${OUT_DIR}/${ZIP_NAME}"
fi

[ "${PART_DIR:0:1}" = "/" ] || PART_DIR="${REPO_ROOT}/${PART_DIR}"

DL_CMD=""
if command -v wget >/dev/null 2>&1; then
    DL_CMD="wget -q --show-progress"
elif command -v curl >/dev/null 2>&1; then
    DL_CMD="curl -sSLO"
fi

get_img() {
    local img="$1"
    if [ -f "${PART_DIR}/${img}" ]; then
        echo "  ${img}: using local copy"
        cp "${PART_DIR}/${img}" "${WORKDIR}/${img}"
        return 0
    fi
    if [ -n "${DL_CMD}" ]; then
        echo "  ${img}: downloading..."
        (cd "${PART_DIR}" && ${DL_CMD} "${REMOTE_BASE}/${img}")
        if [ -f "${PART_DIR}/${img}" ]; then
            cp "${PART_DIR}/${img}" "${WORKDIR}/${img}"
            echo "  ${img}: downloaded"
            return 0
        fi
    fi
    return 1
}

WORKDIR=$(mktemp -d)
clean() { rm -rf "${WORKDIR}"; }
trap clean EXIT

# Get vendor/odm
echo "Getting partition images..."
get_img vendor.img
get_img odm.img

# === RECOVERY ZIP: add vendor/odm to data/ ===
if [ -f "${RECOVERY_ZIP}" ]; then
    echo ""
    echo "=== Updating recovery zip ==="
    python3 -c "
import zipfile, os
z = zipfile.ZipFile('${RECOVERY_ZIP}', 'a', zipfile.ZIP_DEFLATED)
for img in ('vendor.img', 'odm.img'):
    p = '${WORKDIR}/' + img
    if os.path.exists(p):
        z.write(p, 'data/' + img)
z.close()
"
    echo "Recovery zip updated"
fi

# === FASTBOOT ZIP: inject vendor/odm into LVM ===
if [ -f "${FASTBOOT_ZIP}" ]; then
    echo ""
    echo "=== Updating fastboot zip ==="
    python3 -c "
import zipfile
with zipfile.ZipFile('${FASTBOOT_ZIP}', 'r') as z:
    z.extract('data/userdata.img', '${WORKDIR}')
"
    simg2img "${WORKDIR}/data/userdata.img" "${WORKDIR}/userdata.raw"
    DEVICE=$(losetup -f --show "${WORKDIR}/userdata.raw")
    vgchange -ay droidian 2>/dev/null || true
    sleep 3

    ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs 2>/dev/null || echo "")
    if [ -z "${ROOTFS_VOLUME}" ]; then
        vgscan --mknodes -v 2>/dev/null || true; sleep 3
        ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs 2>/dev/null || echo "")
    fi
    ROOTFS_VOLUME=${ROOTFS_VOLUME/\/dev/\/host-dev}

    mkdir -p "${WORKDIR}/mnt"
    mount "${ROOTFS_VOLUME}" "${WORKDIR}/mnt"
    mkdir -p "${WORKDIR}/mnt/userdata"
    for img in vendor.img odm.img; do
        [ -f "${WORKDIR}/${img}" ] && cp "${WORKDIR}/${img}" "${WORKDIR}/mnt/userdata/"
    done
    sync
    umount "${WORKDIR}/mnt"
    vgchange -an droidian 2>/dev/null || true
    losetup -d "${DEVICE}"
    img2simg "${WORKDIR}/userdata.raw" "${WORKDIR}/data/userdata.img"

    python3 -c "
import zipfile, os
z = zipfile.ZipFile('${FASTBOOT_ZIP}', 'r')
keep = [f for f in z.namelist() if not f.startswith('data/')]
z.close()
os.remove('${FASTBOOT_ZIP}')
z = zipfile.ZipFile('${FASTBOOT_ZIP}', 'w', zipfile.ZIP_DEFLATED)
for fname in keep:
    z.write(os.path.join(os.path.dirname('${FASTBOOT_ZIP}'), fname), fname)
z.write('${WORKDIR}/data/userdata.img', 'data/userdata.img')
z.close()
"
    echo "Fastboot zip updated"
fi

echo ""
for zip in "${RECOVERY_ZIP}" "${FASTBOOT_ZIP}"; do
    [ ! -f "${zip}" ] && continue
    echo "========================================"
    echo "$(basename ${zip})"
    echo "========================================"
    python3 -c "
import zipfile
with zipfile.ZipFile('${zip}', 'r') as z:
    for f in z.infolist():
        print(f'{f.compress_size:>10} {f.file_size:>10} {f.filename}')
"
done
echo "Done"
