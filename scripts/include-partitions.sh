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

# === RECOVERY ZIP: extract boot/dtbo/vbmeta from rootfs, add to data/ ===
if [ -f "${RECOVERY_ZIP}" ]; then
    echo ""
    echo "=== Updating recovery zip ==="
    python3 -c "
import zipfile
with zipfile.ZipFile('${RECOVERY_ZIP}', 'r') as z:
    z.extract('data/rootfs.img', '${WORKDIR}')
"
    # Extract boot/dtbo/vbmeta from rootfs.img
    simg2img "${WORKDIR}/data/rootfs.img" "${WORKDIR}/rootfs.raw" 2>/dev/null || \
        cp "${WORKDIR}/data/rootfs.img" "${WORKDIR}/rootfs.raw"
    RFS_DEV=$(losetup -f --show "${WORKDIR}/rootfs.raw")
    mkdir -p "${WORKDIR}/rfs"
    mount "${RFS_DEV}" "${WORKDIR}/rfs" 2>/dev/null || mount -o ro "${RFS_DEV}" "${WORKDIR}/rfs"
    for img in boot.img dtbo.img vbmeta.img; do
        # Files are versioned: boot.img-4.19.325-xiaomi-pipa
        found=$(ls "${WORKDIR}/rfs/boot/${img}"-* 2>/dev/null | head -1)
        if [ -f "${found}" ]; then
            cp "${found}" "${WORKDIR}/${img}"
            echo "  Extracted ${img} from $(basename ${found})"
        elif [ -f "${WORKDIR}/rfs/boot/${img}" ]; then
            cp "${WORKDIR}/rfs/boot/${img}" "${WORKDIR}/${img}"
            echo "  Extracted ${img}"
        else
            echo "  WARNING: ${img} not found in rootfs/boot/"
        fi
    done
    umount "${WORKDIR}/rfs"
    losetup -d "${RFS_DEV}"
    rm -f "${WORKDIR}/rootfs.raw"

    python3 -c "
import zipfile, os
z = zipfile.ZipFile('${RECOVERY_ZIP}', 'a', zipfile.ZIP_DEFLATED)
for img in ('vendor.img', 'odm.img', 'boot.img', 'dtbo.img', 'vbmeta.img'):
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

    VENDOR_SIZE=$(stat -c%s "${WORKDIR}/vendor.img" 2>/dev/null || echo 0)
    ODM_SIZE=$(stat -c%s "${WORKDIR}/odm.img" 2>/dev/null || echo 0)
    EXTRA_NEEDED=$((VENDOR_SIZE + ODM_SIZE + 50*1024*1024))  # +50MB margin

    if [ "${EXTRA_NEEDED}" -le 0 ]; then
        echo "  No partition images to inject, skipping fastboot zip update"
        rm -f "${WORKDIR}/userdata.raw"
        img2simg "${WORKDIR}/data/userdata.img" "${WORKDIR}/data/userdata.img" 2>/dev/null || true
    else
        echo "  Extra space needed: $((EXTRA_NEEDED / 1024 / 1024)) MB"

        DEVICE=$(losetup -f --show "${WORKDIR}/userdata.raw")
        # Grow the raw image to make room for vendor/odm
        truncate -s "+${EXTRA_NEEDED}" "${WORKDIR}/userdata.raw"
        losetup -c "${DEVICE}" 2>/dev/null || true
        pvresize "${DEVICE}"

        vgchange -ay droidian 2>/dev/null || true
        sleep 3

        # Use the LV logical path for LVM operations, not resolved device
        LV_PATH="/dev/mapper/droidian-droidian--rootfs"
        if [ ! -e "${LV_PATH}" ]; then
            vgscan --mknodes -v 2>/dev/null || true; sleep 3
        fi

        # Also get the /host-dev path for mounting
        ROOTFS_VOLUME=$(realpath "${LV_PATH}" 2>/dev/null || echo "${LV_PATH}")
        HOST_DEV_PATH="${ROOTFS_VOLUME/\/dev/\/host-dev}"

        # Extend LV and filesystem to fit vendor/odm
        if [ "${EXTRA_NEEDED}" -gt 0 ]; then
            lvextend -L "+${EXTRA_NEEDED}" "${LV_PATH}" 2>/dev/null || echo "  WARNING: lvextend failed, continuing"
            resize2fs "${LV_PATH}" 2>/dev/null || echo "  WARNING: resize2fs failed, continuing"
        fi

        mkdir -p "${WORKDIR}/mnt"
        mount "${HOST_DEV_PATH}" "${WORKDIR}/mnt"
        mkdir -p "${WORKDIR}/mnt/userdata"
        for img in vendor.img odm.img; do
            [ -f "${WORKDIR}/${img}" ] && cp "${WORKDIR}/${img}" "${WORKDIR}/mnt/userdata/"
        done
        sync

        umount "${WORKDIR}/mnt"

        # Shrink FS to minimum, then match LV and PV
        if [ -e "${LV_PATH}" ]; then
            e2fsck -fy "${LV_PATH}" 2>/dev/null || true
            resize2fs -M "${LV_PATH}" 2>/dev/null || true
            BLOCK_COUNT=$(dumpe2fs -h "${LV_PATH}" 2>/dev/null | awk '/Block count:/{print $3}')
            BLOCK_SIZE=$(dumpe2fs -h "${LV_PATH}" 2>/dev/null | awk '/Block size:/{print $3}')
            if [ -n "${BLOCK_COUNT}" ] && [ -n "${BLOCK_SIZE}" ]; then
                MIN_LV_BYTES=$((BLOCK_COUNT * BLOCK_SIZE + 50*1024*1024))
                lvreduce -f -L "${MIN_LV_BYTES}B" "${LV_PATH}" 2>/dev/null || true
            fi
        fi

        vgchange -an droidian 2>/dev/null || true

        # Shrink the raw image to minimal size using allocated PE count
        ALLOC_PES=$(pvs --noheadings -o pv_pe_alloc_count "${DEVICE}" 2>/dev/null | tr -d ' ')
        PE_SIZE=$(pvs --noheadings -o pe_size --units b "${DEVICE}" 2>/dev/null | awk '{print $1}' | tr -d ' B')
        if [ -n "${ALLOC_PES}" ] && [ -n "${PE_SIZE}" ] && [ "${ALLOC_PES}" -gt 0 ]; then
            # Add 1 PE of slack and 1 PE for LVM metadata headers
            TARGET_PV_BYTES=$(( (ALLOC_PES + 2) * PE_SIZE ))
            pvresize --setphysicalvolumesize "${TARGET_PV_BYTES}B" "${DEVICE}" 2>/dev/null || true
            truncate -s "${TARGET_PV_BYTES}" "${WORKDIR}/userdata.raw"
        fi

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
