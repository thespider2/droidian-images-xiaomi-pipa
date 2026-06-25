Droidian for Xiaomi Pad 6 (pipa)
=================================

This repository builds Droidian flashable images for the **Xiaomi Pad 6 (pipa)**.

Two image types are produced:

* **Fastboot-flashable image** — recommended. Contains `userdata.img` with LVM
  and `vendor.img`/`odm.img` pre-loaded inside `/userdata/`.
* **Recovery-flashable zipfile** — for recovery (TWRP) flashing. Contains the
  rootfs as `rootfs.img` plus `vendor.img`/`odm.img` alongside it.

# Downloads

Nightly builds are available on the
[releases page](https://github.com/thespider2/droidian-images-xiaomi-pipa/releases/tag/nightly).

# Installation (fastboot)

## Prerequisites

* A PC with `fastboot` installed
* Unlocked bootloader on the Xiaomi Pad 6

## Steps

1. Download the latest fastboot zip from the
   [nightly release](https://github.com/thespider2/droidian-images-xiaomi-pipa/releases/tag/nightly).
   Look for `droidian-UNOFFICIAL-phosh-phone-xiaomi_pipa-api33-arm64-next_*.zip`.
2. Extract it:
   ```
   unzip droidian-UNOFFICIAL-*.zip
   cd droidian-UNOFFICIAL-*
   ```
3. Reboot the device to fastboot mode (Volume Down + Power).
4. Run the flash script:
   ```
   sudo ./flash_all.sh
   ```
5. The device reboots automatically. Default passcode: `1234`.

# Installation (recovery)

1. Download the recovery zip (contains `_recovery` in the name).
2. Boot TWRP or another Android recovery.
3. From recovery, enter ADB sideload mode:
   ```
   adb sideload droidian-UNOFFICIAL-*_recovery.zip
   ```
4. Reboot. The device boots to Droidian.

# Droidian Installer

This device is supported by the
[Droidian Installer](https://github.com/droidian-releng/droidian-installer).

To install using the local config:

```
droidian-installer -f installer-configs/v2/devices/pipa.yml
```

The installer configs are also published to GitHub Pages at
`https://thespider2.github.io/droidian-images-xiaomi-pipa/`.

The fastboot zip is available at the stable URL:
`https://github.com/thespider2/droidian-images-xiaomi-pipa/releases/download/nightly/image-fastboot-pipa.zip`

# Building locally

```
DROIDIAN_VERSION=next ./generate_device_recipe.py xiaomi_pipa arm64 phosh phone 33 && \
  debos --disable-fakemachine generated/droidian.yaml
```

# Repository structure

| Path | Description |
|------|-------------|
| `community_devices.yml` | Device definitions for fastboot + recovery builds |
| `generate_device_recipe.py` | Generates the debos recipe from device config |
| `scripts/include-partitions.sh` | Injects `vendor.img`/`odm.img` into both zip types |
| `installer-configs/v2/devices/pipa.yml` | Droidian Installer device config |
| `installer-configs/v2/devices/pipa.json` | JSON variant for direct serving |
| `.github/workflows/release.yml` | CI: builds and publishes nightly images |
