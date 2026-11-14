#!/usr/bin/env bash
set -euo pipefail
umask 022

if (( $# != 2 )); then
    echo "Usage: $0 <u-boot-rockchip.bin> <output-directory>" >&2
    exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
uboot=$(realpath -e -- "$1")
output_dir=$(realpath -m -- "$2")
build_parent=${OPENWRT_BUILD_DIR:-${TMPDIR:-/tmp}}
jobs=${BUILD_JOBS:-$(nproc)}
openwrt_tag=v25.12.6
openwrt_commit=64900e756efa667774214f9c6b17c113222e01f7
device=friendlyarm_nanopi-neo3-plus
image_name=openwrt-${openwrt_tag#v}-rockchip-armv8-${device}-squashfs-sd.img.gz

if [[ $(uname -s) != Linux || $EUID == 0 ]]; then
    echo 'Build OpenWrt as a non-root user on Linux.' >&2
    exit 2
fi
if ! [[ $jobs =~ ^[1-9][0-9]*$ ]]; then
    echo 'BUILD_JOBS must be a positive integer.' >&2
    exit 2
fi
test -s "$uboot"
mkdir -p -- "$build_parent"
build_parent=$(realpath -- "$build_parent")
if [[ $build_parent =~ [[:space:]] ]]; then
    echo 'OpenWrt requires OPENWRT_BUILD_DIR to be a path without spaces.' >&2
    exit 2
fi
work_dir=$(mktemp -d "$build_parent/nanopi-openwrt.XXXXXXXX")
trap 'status=$?; if (( status == 0 )); then rm -rf -- "$work_dir"; else printf "Build directory: %s\n" "$work_dir" >&2; fi' EXIT
source_dir="$work_dir/openwrt"

git -c core.autocrlf=false clone --quiet --depth 1 --single-branch \
    --branch "$openwrt_tag" https://github.com/openwrt/openwrt.git "$source_dir"
cd -- "$source_dir"
if [[ $(git rev-parse HEAD) != "$openwrt_commit" ]]; then
    echo "OpenWrt tag $openwrt_tag does not resolve to $openwrt_commit" >&2
    exit 1
fi

git apply --whitespace=error-all "$repo_dir"/patches/*.patch
install -m 0644 -- "$uboot" .nanopi-neo3-plus-u-boot-rockchip.bin
cp -- "$repo_dir/config/openwrt-25.12.6.config" .config
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
for option in "TARGET_rockchip_armv8_DEVICE_$device" TARGET_ROOTFS_SQUASHFS VERSION_FILENAMES PACKAGE_ethtool; do
    if ! grep -qx "CONFIG_$option=y" .config; then
        echo "Missing required OpenWrt option CONFIG_$option" >&2
        exit 1
    fi
done

make -j"$jobs" download
make -j"$jobs" V=s

image="bin/targets/rockchip/armv8/$image_name"
test -s "$image"
gzip -t -- "$image"

# Check the complete disk image, including the handoff from the U-Boot job.
python3 - "$image" "$uboot" <<'PY'
import gzip
import struct
import sys
from pathlib import Path

sector_size = 512
loader_offset = 64 * sector_size
loader = Path(sys.argv[2]).read_bytes()

with gzip.open(sys.argv[1], "rb") as image:
    mbr = image.read(sector_size)
    if len(mbr) != sector_size or mbr[510:] != b"\x55\xaa":
        raise SystemExit("Missing MBR signature")

    boot_lba, boot_sectors = struct.unpack_from("<II", mbr, 454)
    root_lba, root_sectors = struct.unpack_from("<II", mbr, 470)
    if (
        boot_lba != 65536
        or not boot_sectors
        or root_lba < boot_lba + boot_sectors
        or not root_sectors
        or loader_offset + len(loader) > boot_lba * sector_size
    ):
        raise SystemExit("Invalid OpenWrt SD partition layout")

    image.seek(loader_offset)
    if image.read(len(loader)) != loader:
        raise SystemExit("U-Boot artifact does not match the image at LBA 64")

    image.seek(boot_lba * sector_size + 1024 + 56)
    if image.read(2) != b"\x53\xef":
        raise SystemExit("The boot partition does not contain ext4")

    image.seek(root_lba * sector_size)
    if image.read(4) != b"hsqs":
        raise SystemExit("The root partition does not contain squashfs")
PY

mkdir -p -- "$output_dir"
install -m 0644 -- "$image" "$output_dir/$image_name"
install -m 0644 -- .config "$output_dir/build.config"
uboot_sha256=$(sha256sum -- "$uboot")
(
    cd -- "$output_dir"
    printf '%s\n' "OpenWrt $openwrt_tag $openwrt_commit" \
        "U-Boot SHA-256 ${uboot_sha256%% *}" > build-info.txt
    sha256sum -- "$image_name" build.config build-info.txt > SHA256SUMS
)
