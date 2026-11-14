#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${1:-"$repo_dir/out/uboot"}
build_parent=${UBOOT_BUILD_DIR:-${TMPDIR:-/tmp}}
cross_compile=${CROSS_COMPILE:-aarch64-linux-gnu-}
jobs=${BUILD_JOBS:-$(nproc)}

uboot_version=v2026.07
uboot_commit=ece349ade2973e220f524ce59e59711cc919263f
# Use the RK3528 blobs pinned by OpenWrt 25.12.
rkbin_commit=74213af1e952c4683d2e35952507133b61394862
ddr_blob=rk3528_ddr_1056MHz_v1.11.bin
bl31_blob=rk3528_bl31_v1.20.elf
board_dts=rk3528-nanopi-neo3-plus

if (( $# > 1 )) || ! [[ $jobs =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: BUILD_JOBS=<positive integer> $0 [output-directory]" >&2
    exit 2
fi

mkdir -p -- "$build_parent"
build_parent=$(cd -- "$build_parent" && pwd)
work_dir=$(mktemp -d "$build_parent/nanopi-uboot.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
source_dir="$work_dir/u-boot"

git -c core.autocrlf=false clone --quiet --depth=1 --branch "$uboot_version" \
    https://github.com/u-boot/u-boot.git "$source_dir"
if [[ $(git -C "$source_dir" rev-parse HEAD) != "$uboot_commit" ]]; then
    echo "U-Boot tag $uboot_version does not resolve to $uboot_commit" >&2
    exit 1
fi

rkbin_url="https://raw.githubusercontent.com/rockchip-linux/rkbin/$rkbin_commit/bin/rk35"
for blob in "$ddr_blob" "$bl31_blob"; do
    curl --fail --silent --show-error --location --retry 3 \
        "$rkbin_url/$blob" --output "$work_dir/$blob"
done
# These are the Git blob IDs recorded in the pinned rkbin tree.
if [[ $(git hash-object --no-filters "$work_dir/$ddr_blob") != 2b703a389df1e7ccee38da714fd491cba0516011 ||
      $(git hash-object --no-filters "$work_dir/$bl31_blob") != f642b7baf293413eb7af47ee9c76867435f75e87 ]]; then
    echo 'RK3528 firmware does not match the pinned rkbin tree' >&2
    exit 1
fi

install -m 0644 "$repo_dir/uboot/$board_dts.dts" \
    "$source_dir/dts/upstream/src/arm64/rockchip/$board_dts.dts"
install -m 0644 "$repo_dir/uboot/$board_dts-u-boot.dtsi" \
    "$source_dir/arch/arm/dts/$board_dts-u-boot.dtsi"

export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git -C "$source_dir" show -s --format=%ct "$uboot_commit")
export LC_ALL=C TZ=UTC
make_args=("CROSS_COMPILE=$cross_compile" "ROCKCHIP_TPL=$work_dir/$ddr_blob" "BL31=$work_dir/$bl31_blob")
make -C "$source_dir" "${make_args[@]}" nanopi-zero2-rk3528_defconfig
"$source_dir/scripts/config" --file "$source_dir/.config" \
    --set-str DEFAULT_DEVICE_TREE "rockchip/$board_dts" \
    --set-str DEFAULT_FDT_FILE "rockchip/$board_dts.dtb" \
    --set-str OF_LIST "rockchip/$board_dts" \
    --set-str SPL_OF_LIST "rockchip/$board_dts" \
    --enable BOOTSTD_FULL --enable BOOTSTD_DEFAULTS --enable BOOTMETH_SCRIPT \
    --enable LEGACY_IMAGE_FORMAT \
    --enable USE_BOOTCOMMAND --set-str BOOTCOMMAND 'bootflow scan -lb' \
    --enable DOS_PARTITION --enable CMD_PART --enable CMD_FS_GENERIC \
    --enable CMD_EXT4 --enable CMD_FAT --enable CMD_BOOTM --enable FIT --enable LZMA \
    --enable MISC_INIT_R --enable ROCKCHIP_OTP --enable SHA256 \
    --enable ENV_IS_NOWHERE --disable CMD_SAVEENV --disable TOOLS_MKEFICAPSULE
make -C "$source_dir" "${make_args[@]}" olddefconfig

for option in BOOTSTD_FULL BOOTMETH_SCRIPT LEGACY_IMAGE_FORMAT USE_BOOTCOMMAND \
    DOS_PARTITION CMD_PART CMD_FS_GENERIC CMD_EXT4 CMD_FAT CMD_BOOTM FIT LZMA \
    CMD_BOOTFLOW_FULL ENV_VARS_UBOOT_CONFIG MISC_INIT_R ROCKCHIP_OTP HASH SHA256 ENV_IS_NOWHERE; do
    if ! grep -qx "CONFIG_$option=y" "$source_dir/.config"; then
        echo "Missing required U-Boot option CONFIG_$option" >&2
        exit 1
    fi
done
for option in DEFAULT_DEVICE_TREE OF_LIST SPL_OF_LIST; do
    if ! grep -Fxq "CONFIG_$option=\"rockchip/$board_dts\"" "$source_dir/.config"; then
        echo "U-Boot option CONFIG_$option must use the NEO3 Plus device tree" >&2
        exit 1
    fi
done
if grep -Eq '^CONFIG_(ENV_IS_IN_[A-Z0-9_]+|CMD_SAVEENV)=y$' "$source_dir/.config"; then
    echo 'U-Boot boot configuration must remain in memory' >&2
    exit 1
fi
grep -qx 'CONFIG_BOOTCOMMAND="bootflow scan -lb"' "$source_dir/.config"
grep -qx 'CONFIG_SYS_MMCSD_RAW_MODE_U_BOOT_SECTOR=0x4000' "$source_dir/.config"
make -C "$source_dir" "${make_args[@]}" -j"$jobs"

dtb="$source_dir/dts/upstream/src/arm64/rockchip/$board_dts.dtb"
test "$(fdtget "$dtb" / model)" = 'FriendlyElec NanoPi NEO3 Plus'
test "$(fdtget "$dtb" /aliases ethernet0)" = '/soc/ethernet@ffbe0000'

# The two images must land at LBAs 64 and 0x4000 when the combined file is
# placed at LBA 64. OpenWrt's first partition starts at 32 MiB.
python3 - "$source_dir" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
image = (source / "u-boot-rockchip.bin").read_bytes()
idb = (source / "idbloader.img").read_bytes()
fit = (source / "u-boot.itb").read_bytes()
fit_offset = (0x4000 - 64) * 512
fit_end = fit_offset + len(fit)

if not idb.startswith(b"RKNS") or not image.startswith(idb):
    raise SystemExit("RK3528 BootROM header is missing or incorrectly positioned")
if not fit.startswith(bytes.fromhex("d00dfeed")) or image[fit_offset:fit_end] != fit:
    raise SystemExit("U-Boot FIT is missing or does not start at the expected sector")
if len(image) + 64 * 512 > 32 * 1024 * 1024:
    raise SystemExit("U-Boot image extends into the first OpenWrt partition")
PY
"$source_dir/tools/dumpimage" -l "$source_dir/u-boot.itb"

mkdir -p -- "$output_dir"
install -m 0644 "$source_dir/u-boot-rockchip.bin" "$output_dir/u-boot-rockchip.bin"
(
    cd -- "$output_dir"
    printf '%s\n' "U-Boot $uboot_version $uboot_commit" \
        "rkbin $rkbin_commit" "DDR $ddr_blob" "BL31 $bl31_blob" \
        "SOURCE_DATE_EPOCH $SOURCE_DATE_EPOCH" > build-info.txt
    sha256sum u-boot-rockchip.bin > SHA256SUMS
)
