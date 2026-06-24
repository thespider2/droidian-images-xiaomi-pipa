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
FASTBOOT_ZIP="${OUT_DIR}/${ZIP_NAME}"
RECOVERY_ZIP="${OUT_DIR}/${ZIP_NAME%.zip}-recovery.zip"

if [ ! -f "${FASTBOOT_ZIP}" ]; then
    echo "Fastboot zip not found at ${FASTBOOT_ZIP}, skipping"
    exit 0
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

# Get vendor/odm images
echo "Getting partition images..."
get_img vendor.img
get_img odm.img

# === RECOVERY ZIP ===
echo ""
echo "=== Building recovery zip ==="

# Extract userdata.img from fastboot zip
python3 -c "
import zipfile
with zipfile.ZipFile('${FASTBOOT_ZIP}', 'r') as z:
    z.extract('data/userdata.img', '${WORKDIR}')
"

# Mount LVM, extract rootfs, and inject vendor/odm
echo "Converting sparse to raw"
simg2img "${WORKDIR}/data/userdata.img" "${WORKDIR}/userdata.raw"

echo "Setting up LVM loop"
DEVICE=$(losetup -f --show "${WORKDIR}/userdata.raw")
vgchange -ay droidian 2>/dev/null || true
sleep 3

ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs 2>/dev/null || echo "")
if [ -z "${ROOTFS_VOLUME}" ]; then
    vgscan --mknodes -v 2>/dev/null || true
    sleep 3
    ROOTFS_VOLUME=$(realpath /dev/mapper/droidian-droidian--rootfs 2>/dev/null || echo "")
fi
ROOTFS_VOLUME=${ROOTFS_VOLUME/\/dev/\/host-dev}

mkdir -p "${WORKDIR}/mnt"
mount "${ROOTFS_VOLUME}" "${WORKDIR}/mnt"

# Inject vendor/odm into LVM for the fastboot zip
echo "Injecting vendor/odm into LVM for fastboot..."
mkdir -p "${WORKDIR}/mnt/userdata"
for img in vendor.img odm.img; do
    [ -f "${WORKDIR}/${img}" ] && cp "${WORKDIR}/${img}" "${WORKDIR}/mnt/userdata/"
done
sync

# Extract rootfs from LVM to create rootfs.img for recovery zip
echo "Creating rootfs.img for recovery zip..."
ROOTFS_SIZE=$(du -sm "${WORKDIR}/mnt" | awk '{print $1}')
dd if=/dev/zero of="${WORKDIR}/rootfs.img" bs=1M count=$((ROOTFS_SIZE + 250))
mkfs.ext4 -O ^metadata_csum -O ^64bit -O ^orphan_file -F "${WORKDIR}/rootfs.img"
mkdir -p "${WORKDIR}/mnt2"
mount -o loop "${WORKDIR}/rootfs.img" "${WORKDIR}/mnt2"
rsync --archive -H -A -X "${WORKDIR}/mnt/" "${WORKDIR}/mnt2/"
sync
umount "${WORKDIR}/mnt2"

# Unmount LVM
umount "${WORKDIR}/mnt"
vgchange -an droidian 2>/dev/null || true
losetup -d "${DEVICE}"

# Re-pack userdata.img for fastboot
img2simg "${WORKDIR}/userdata.raw" "${WORKDIR}/data/userdata.img"

# Remove data/ from fastboot zip, replace with updated userdata.img
python3 -c "
import zipfile
import os

# Remove old data/ entries from fastboot zip
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

# Download boot/dtbo/vbmeta from fastboot zip
python3 -c "
import zipfile
import os
os.makedirs('${WORKDIR}/boot', exist_ok=True)
with zipfile.ZipFile('${FASTBOOT_ZIP}', 'r') as z:
    for f in z.namelist():
        if f.startswith('data/') and f != 'data/userdata.img':
            z.extract(f, '${WORKDIR}/boot')
"

# Build recovery zip from recovery template
TEMPLATE="${REPO_ROOT}/android-recovery-flashing-template"
mkdir -p "${WORKDIR}/recovery/data"
cp "${TEMPLATE}/tools/busybox" "${WORKDIR}/recovery/tools/"
cp "${TEMPLATE}/META-INF/com/google/android/update-binary" "${WORKDIR}/recovery/META-INF/com/google/android/"
cp "${TEMPLATE}/META-INF/com/google/android/updater-script" "${WORKDIR}/recovery/META-INF/com/google/android/"
[ -f "${TEMPLATE}/setup.sh" ] && cp "${TEMPLATE}/setup.sh" "${WORKDIR}/recovery/setup.sh"

# Use overlay setup.sh if present
OVERLAY="${REPO_ROOT}/android-recovery-overlay/setup.sh"
[ -f "${OVERLAY}" ] && cp "${OVERLAY}" "${WORKDIR}/recovery/setup.sh"

# Add rootfs.img and all images to data/
cp "${WORKDIR}/rootfs.img" "${WORKDIR}/recovery/data/"
for img in vendor.img odm.img; do
    [ -f "${WORKDIR}/${img}" ] && cp "${WORKDIR}/${img}" "${WORKDIR}/recovery/data/"
done
for img in boot.img dtbo.img vbmeta.img; do
    [ -f "${WORKDIR}/boot/data/${img}" ] && cp "${WORKDIR}/boot/data/${img}" "${WORKDIR}/recovery/data/"
done

# Zip recovery
echo "Creating recovery zip..."
(cd "${WORKDIR}/recovery" && zip -r9 "${RECOVERY_ZIP}" . -x ".git" "README.md" "*placeholder")

echo ""
echo "========================================"
echo "Fastboot zip: ${FASTBOOT_ZIP}"
echo "========================================"
python3 -c "
import zipfile
with zipfile.ZipFile('${FASTBOOT_ZIP}', 'r') as z:
    for f in z.infolist():
        print(f'{f.compress_size:>10} {f.file_size:>10} {f.filename}')
"
echo ""
echo "========================================"
echo "Recovery zip: ${RECOVERY_ZIP}"
echo "========================================"
python3 -c "
import zipfile
with zipfile.ZipFile('${RECOVERY_ZIP}', 'r') as z:
    for f in z.infolist():
        print(f'{f.compress_size:>10} {f.file_size:>10} {f.filename}')
"
echo "Done"
