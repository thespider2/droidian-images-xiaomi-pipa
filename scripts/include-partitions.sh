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
clean() {
    umount "${WORKDIR}/mnt" 2>/dev/null || true
    umount "${WORKDIR}/rfs" 2>/dev/null || true
    vgchange -an droidian 2>/dev/null || true
    losetup -d "${DEVICE}" 2>/dev/null || true
    rm -rf "${WORKDIR}" 2>/dev/null || true
}
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
    EXTRA_NEEDED=$((VENDOR_SIZE + ODM_SIZE + 100*1024*1024))  # +100MB margin

    if [ "${EXTRA_NEEDED}" -le 0 ]; then
        echo "  No partition images to inject, skipping fastboot zip update"
    else
        echo "  Extra space needed: $((EXTRA_NEEDED / 1024 / 1024)) MB"

        # Mount old rootfs and tar it up
        OLD_DEV=$(losetup -f --show "${WORKDIR}/userdata.raw")
        vgchange -ay droidian 2>/dev/null || true
        sleep 3

        # Find LV path
        LV_PATH=""
        for p in /dev/mapper/droidian-droidian--rootfs /dev/droidian/droidian-rootfs; do
            [ -e "${p}" ] && LV_PATH="${p}" && break
        done
        if [ -z "${LV_PATH}" ]; then
            vgscan --mknodes -v 2>/dev/null || true; sleep 3
            for p in /dev/mapper/droidian-droidian--rootfs /dev/droidian/droidian-rootfs; do
                [ -e "${p}" ] && LV_PATH="${p}" && break
            done
        fi

        OLD_SIZE=$(stat -c%s "${WORKDIR}/userdata.raw")
        NEW_SIZE=$((OLD_SIZE + EXTRA_NEEDED))

        if [ -n "${LV_PATH}" ]; then
            ROOTFS_VOLUME=$(realpath "${LV_PATH}" 2>/dev/null || echo "${LV_PATH}")
            MOUNT_PATH="${ROOTFS_VOLUME/\/dev/\/host-dev}"
            [ ! -e "${MOUNT_PATH}" ] && MOUNT_PATH="${LV_PATH/\/dev/\/host-dev}"

            mount "${MOUNT_PATH}" "${WORKDIR}/mnt" 2>/dev/null || mount "${LV_PATH}" "${WORKDIR}/mnt" 2>/dev/null || true
            if mountpoint -q "${WORKDIR}/mnt"; then
                echo "  Backing up rootfs contents"
                tar cf "${WORKDIR}/rootfs.tar" -C "${WORKDIR}/mnt" --one-file-system . 2>/dev/null
                umount "${WORKDIR}/mnt"
            fi
        fi
        # Clean up old VG state before creating new one
        vgchange -an droidian 2>/dev/null || true
        vgremove -f droidian 2>/dev/null || true
        rm -rf /dev/droidian 2>/dev/null || true
        losetup -d "${OLD_DEV}"

        # Build a fresh larger image with same LVM layout
        echo "  Building new image (${NEW_SIZE} bytes)"
        truncate -s "${NEW_SIZE}" "${WORKDIR}/userdata-new.raw"
        NEW_DEV=$(losetup -f --show "${WORKDIR}/userdata-new.raw")
        pvcreate "${NEW_DEV}"
        vgcreate droidian "${NEW_DEV}"
        lvcreate --zero n -L 128M -n droidian-persistent droidian
        lvcreate --zero n -L 32M -n droidian-reserved droidian
        lvcreate --zero n -l 100%FREE -n droidian-rootfs droidian
        vgchange -ay droidian 2>/dev/null || true
        sleep 3

        # Find the new LV path
        LV_PATH=""
        for p in /dev/mapper/droidian-droidian--rootfs /dev/droidian/droidian-rootfs; do
            [ -e "${p}" ] && LV_PATH="${p}" && break
        done
        if [ -z "${LV_PATH}" ]; then
            vgscan --mknodes -v 2>/dev/null || true; sleep 3
            for p in /dev/mapper/droidian-droidian--rootfs /dev/droidian/droidian-rootfs; do
                [ -e "${p}" ] && LV_PATH="${p}" && break
            done
        fi

        if [ -n "${LV_PATH}" ]; then
            ROOTFS_VOLUME=$(realpath "${LV_PATH}" 2>/dev/null || echo "${LV_PATH}")
            MOUNT_PATH="${ROOTFS_VOLUME/\/dev/\/host-dev}"
            [ ! -e "${MOUNT_PATH}" ] && MOUNT_PATH="${LV_PATH/\/dev/\/host-dev}"

            mkfs.ext4 -O ^metadata_csum -O ^64bit -O ^orphan_file "${LV_PATH}" 2>/dev/null || \
                mkfs.ext4 "${LV_PATH}"
            mount "${MOUNT_PATH}" "${WORKDIR}/mnt" 2>/dev/null || mount "${LV_PATH}" "${WORKDIR}/mnt"

            if [ -f "${WORKDIR}/rootfs.tar" ]; then
                echo "  Restoring rootfs contents"
                tar xf "${WORKDIR}/rootfs.tar" -C "${WORKDIR}/mnt"
            fi

            echo "  Adding vendor/odm images to /userdata/"
            mkdir -p "${WORKDIR}/mnt/userdata"
            for img in vendor.img odm.img; do
                [ -f "${WORKDIR}/${img}" ] && cp "${WORKDIR}/${img}" "${WORKDIR}/mnt/userdata/"
            done
            sync

            # Create stamp file (required by Droidian)
            mkdir -p "${WORKDIR}/mnt/var/lib/halium"
            touch "${WORKDIR}/mnt/var/lib/halium/requires-lvm-resize"

            umount "${WORKDIR}/mnt"
        fi

        vgchange -an droidian 2>/dev/null || true
        losetup -d "${NEW_DEV}"
        rm -f "${WORKDIR}/userdata.raw"
        mv "${WORKDIR}/userdata-new.raw" "${WORKDIR}/userdata.raw"
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
