# Droidian rootfs installer script
# https://droidian.org

OUTFD=/proc/self/fd/$1;
VENDOR_DEVICE_PROP=`grep ro.product.vendor.device /vendor/build.prop | cut -d "=" -f 2 | awk '{print tolower($0)}'`;

# ui_print <text>
ui_print() { echo -e "ui_print $1\nui_print" > $OUTFD; }

## rootfs install
mv /data/droidian/data/* /data/;

mkdir /r;

# mount droidian rootfs
mount /data/rootfs.img /r;

# function to get the partitions where to flash imgs to.
get_partitions() {
	if [ -f '/proc/bootconfig' ]; then
		current_slot=$(grep -oE 'androidboot\.slot_suffix[[:space:]]*=[[:space:]]*"_[ab]"' /proc/bootconfig | sed -E 's/[[:space:]]*=[[:space:]]*"/=/' | tr -d '"')
	fi

	if [ -z "$current_slot" ]; then
		current_slot=$(grep -o 'androidboot\.slot_suffix=_[a-b]' /proc/cmdline)
	fi
	case "${current_slot}" in
		"androidboot.slot_suffix=_a")
			target_boot_partition="boot_a"
			target_dtbo_partition="dtbo_a"
			target_vbmeta_partition="vbmeta_a"
			;;
		"androidboot.slot_suffix=_b")
			target_boot_partition="boot_b"
			target_dtbo_partition="dtbo_b"
			target_vbmeta_partition="vbmeta_b"
			;;
		"")
			# No A/B
			target_boot_partition="boot"
			target_dtbo_partition="dtbo"
			target_vbmeta_partition="vbmeta"
			;;
		*)
			error "Unknown error while searching for a partition, exiting"
			;;
	esac
}

# If we should flash the kernel, do it
BOOT_IMG=""
for candidate in /data/boot.img /r/boot/boot.img; do
    if [ -f "${candidate}" ]; then
        BOOT_IMG="${candidate}"
        break
    fi
done
if [ -n "${BOOT_IMG}" ]; then
    ui_print "Kernel found at ${BOOT_IMG}, flashing"
    get_partitions
    partition=$(find /dev/block/by-name -name "$target_boot_partition" | head -n 1)
    if [ -n "${partition}" ]; then
        ui_print "Found boot partition for current slot ${partition}"
        dd if="${BOOT_IMG}" of="${partition}" || error "Unable to flash kernel"
        ui_print "Kernel flashed"
    fi
fi

# If we should flash the dtbo, do it
DTBO_IMG=""
for candidate in /data/dtbo.img /r/boot/dtbo.img; do
    if [ -f "${candidate}" ]; then
        DTBO_IMG="${candidate}"
        break
    fi
done
if [ -n "${DTBO_IMG}" ]; then
    ui_print "DTBO found at ${DTBO_IMG}, flashing"
    get_partitions
    partition=$(find /dev/block/by-name -name "$target_dtbo_partition" | head -n 1)
    if [ -n "${partition}" ]; then
        ui_print "Found DTBO partition for current slot ${partition}"
        dd if="${DTBO_IMG}" of="${partition}" || error "Unable to flash DTBO"
        ui_print "DTBO flashed"
    fi
fi

# If we should flash the vbmeta, do it
VBMETA_IMG=""
for candidate in /data/vbmeta.img /r/boot/vbmeta.img; do
    if [ -f "${candidate}" ]; then
        VBMETA_IMG="${candidate}"
        break
    fi
done
if [ -n "${VBMETA_IMG}" ]; then
    ui_print "VBMETA found at ${VBMETA_IMG}, flashing"
    partition=$(find /dev/block/by-name -name "$target_vbmeta_partition" | head -n 1)
    if [ -n "${partition}" ]; then
        ui_print "Found VBMETA partition ${partition}"
        dd if="${VBMETA_IMG}" of="${partition}" || error "Unable to flash VBMETA"
        ui_print "VBMETA flashed"
    fi
fi

if [ -f /r/.full_resize ]; then
    umount /r;

    # resize rootfs
    # first get the remaining space on the partition
    AVAILABLE_SPACE=$(df /data | awk '/dev\/block\/.+/ {print $4}')
    PRETTY_SIZE=$(df -h /data | awk '/dev\/block\/.+/ {print $4}')

    # then remove 100MB (102400KB) from the size
    # later on in case of kernel updates this storage might come in handy.
    # about the same amount is preserved for LVM images in the droidian--persistent and droidian--reserved partitions.
    IMG_SIZE=$((AVAILABLE_SPACE - 102400))
    ui_print "Resizing rootfs to $PRETTY_SIZE";
    e2fsck -fy /data/rootfs.img
    resize2fs /data/rootfs.img "$IMG_SIZE"K
else
    umount /r;

    ui_print "Resizing rootfs to 8GB";
    e2fsck -fy /data/rootfs.img
    resize2fs -f /data/rootfs.img 8G
fi

# halium initramfs workaround,
# create symlink to android-rootfs inside /data
if [ ! -e /data/android-rootfs.img ]; then
	ln -s /halium-system/var/lib/lxc/android/android-rootfs.img /data/android-rootfs.img || true
fi
## end install
