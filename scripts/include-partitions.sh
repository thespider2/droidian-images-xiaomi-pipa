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

# Find the rootfs from the debos build directory
ROOTFS_PATH=$(find ${REPO_ROOT} -maxdepth 2 -mindepth 2 -type d -name '.debos-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | awk '{ print $2 }')/root
if [ -z "${ROOTFS_PATH}" ] || [ ! -d "${ROOTFS_PATH}" ]; then
    echo "Rootfs path not found, trying .."
    ROOTFS_PATH=$(find .. -maxdepth 2 -mindepth 2 -type d -name '.debos-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | awk '{ print $2 }')/root
fi
if [ ! -d "${ROOTFS_PATH}" ]; then
    echo "Rootfs path not found, falling back to LVM extraction"
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

# Get boot/dtbo/vbmeta from fastboot zip (extracted by genimage.sh from rootfs/boot)
python3 -c "
import zipfile, os
os.makedirs('${WORKDIR}/boot', exist_ok=True)
with zipfile.ZipFile('${FASTBOOT_ZIP}', 'r') as z:
    for f in z.namelist():
        if f.startswith('data/') and f != 'data/userdata.img':
            z.extract(f, '${WORKDIR}/boot')
"

# === RECOVERY ZIP ===
echo ""
echo "=== Building recovery zip ==="

# Create rootfs.img from debos rootfs, or extract from LVM as fallback
if [ -d "${ROOTFS_PATH}" ]; then
    echo "Creating rootfs.img from debos rootfs..."
    ROOTFS_SIZE=$(du -sm "${ROOTFS_PATH}" | awk '{print $1}')
    dd if=/dev/zero of="${WORKDIR}/rootfs.img" bs=1M count=$((ROOTFS_SIZE + 250))
    mkfs.ext4 -O ^metadata_csum -O ^64bit -O ^orphan_file -F "${WORKDIR}/rootfs.img"
    mkdir -p "${WORKDIR}/mnt"
    mount -o loop "${WORKDIR}/rootfs.img" "${WORKDIR}/mnt"
    rsync --archive -H -A -X "${ROOTFS_PATH}/" "${WORKDIR}/mnt/"
    sync
    umount "${WORKDIR}/mnt"
else
    echo "Extracting rootfs from LVM userdata.img..."
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
    mkdir -p "${WORKDIR}/lvm"
    mount "${ROOTFS_VOLUME}" "${WORKDIR}/lvm"
    ROOTFS_SIZE=$(du -sm "${WORKDIR}/lvm" | awk '{print $1}')
    dd if=/dev/zero of="${WORKDIR}/rootfs.img" bs=1M count=$((ROOTFS_SIZE + 250))
    mkfs.ext4 -O ^metadata_csum -O ^64bit -O ^orphan_file -F "${WORKDIR}/rootfs.img"
    mkdir -p "${WORKDIR}/mnt"
    mount -o loop "${WORKDIR}/rootfs.img" "${WORKDIR}/mnt"
    rsync --archive -H -A -X "${WORKDIR}/lvm/" "${WORKDIR}/mnt/"
    sync
    umount "${WORKDIR}/mnt"
    umount "${WORKDIR}/lvm"
    vgchange -an droidian 2>/dev/null || true
    losetup -d "${DEVICE}"
fi

# Build recovery zip from recovery template
TEMPLATE="${REPO_ROOT}/android-recovery-flashing-template"
mkdir -p "${WORKDIR}/recovery/data"
cp "${TEMPLATE}/tools/busybox" "${WORKDIR}/recovery/tools/"
mkdir -p "${WORKDIR}/recovery/META-INF/com/google/android"
cp "${TEMPLATE}/META-INF/com/google/android/update-binary" "${WORKDIR}/recovery/META-INF/com/google/android/"
cp "${TEMPLATE}/META-INF/com/google/android/updater-script" "${WORKDIR}/recovery/META-INF/com/google/android/"
cp "${TEMPLATE}/setup.sh" "${WORKDIR}/recovery/setup.sh"

# Use overlay setup.sh if present (flashes boot/dtbo/vbmeta from /data/ directly)
OVERLAY="${REPO_ROOT}/android-recovery-overlay/setup.sh"
[ -f "${OVERLAY}" ] && cp "${OVERLAY}" "${WORKDIR}/recovery/setup.sh"

# Add all images to data/
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

# === FASTBOOT ZIP: inject vendor/odm into LVM ===
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
mkdir -p "${WORKDIR}/mnt2"
mount "${ROOTFS_VOLUME}" "${WORKDIR}/mnt2"

mkdir -p "${WORKDIR}/mnt2/userdata"
for img in vendor.img odm.img; do
    [ -f "${WORKDIR}/${img}" ] && cp "${WORKDIR}/${img}" "${WORKDIR}/mnt2/userdata/"
done
sync
umount "${WORKDIR}/mnt2"
vgchange -an droidian 2>/dev/null || true
losetup -d "${DEVICE}"
img2simg "${WORKDIR}/userdata.raw" "${WORKDIR}/data/userdata.img"

# Replace userdata.img in fastboot zip
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
