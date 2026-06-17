#!/bin/bash
set -e

PRODUCT="xiaomi_pipa"
ARCH="arm64"
EDITION="phosh"
VARIANT="phone"
APILEVEL="33"
DROIDIAN_VERSION="next"

IMAGES_DIR="${PWD}/images"
mkdir -p "${IMAGES_DIR}"

echo "I: Pulling rootfs-builder image..."
docker pull "quay.io/droidian/rootfs-builder:${DROIDIAN_VERSION}-amd64"

echo "I: Building rootfs for ${PRODUCT}..."
docker run --privileged \
    -v "${IMAGES_DIR}:/buildd/out" \
    -v /dev:/host-dev \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    -v "${PWD}:/buildd/sources" \
    --security-opt seccomp:unconfined \
    --cgroupns host \
    "quay.io/droidian/rootfs-builder:${DROIDIAN_VERSION}-amd64" \
    /bin/sh -c "cd /buildd/sources; \
        DROIDIAN_VERSION=\"${DROIDIAN_VERSION}\" \
        ./generate_device_recipe.py ${PRODUCT} ${ARCH} ${EDITION} ${VARIANT} ${APILEVEL} && \
        debos --disable-fakemachine generated/droidian.yaml"

echo "I: Rootfs image built at ${IMAGES_DIR}/"
ls -lh "${IMAGES_DIR}/"
