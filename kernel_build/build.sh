#!/bin/bash

set -e

# === Detect root directory ===
if [[ -z "$1" ]]; then
    ROOT_DIR="$(pwd)"
else
    ROOT_DIR="$1"
fi
echo "[+] Building from root: $ROOT_DIR"
cd "$ROOT_DIR"

# === Clone KernelSU if missing ===
if [ ! -d "$ROOT_DIR/KernelSU" ]; then
    echo "[+] Cloning KernelSU..."
    git clone https://github.com/tiann/KernelSU.git -b main
fi

# === Add KernelSU to Makefile if missing ===
if ! grep -q "core-y \+= KernelSU/" "$ROOT_DIR/Makefile"; then
    echo "[+] Adding KernelSU to Makefile..."
    echo "" >> "$ROOT_DIR/Makefile"
    echo "core-y += KernelSU/" >> "$ROOT_DIR/Makefile"
fi



if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "This script requires an x86_64 (64-bit) machine."
  exit 1
fi

# Configs
OUTDIR="$(pwd)/out"
MODULES_OUTDIR="$(pwd)/modules_out"
TMPDIR="$(pwd)/kernel_build/tmp"

IN_PLATFORM="$(pwd)/kernel_build/vboot_platform"
IN_DLKM="$(pwd)/kernel_build/vboot_dlkm"
IN_DTB="$OUTDIR/arch/arm64/boot/dts/mediatek/mt6789.dtb"

PLATFORM_RAMDISK_DIR="$TMPDIR/ramdisk_platform"
PREBUILT_RAMDISK="$(pwd)/kernel_build/boot/ramdisk"
MODULES_DIR="$PLATFORM_RAMDISK_DIR/lib/modules"

MKBOOTIMG="$(pwd)/kernel_build/mkbootimg/mkbootimg.py"
MKDTBOIMG="$(pwd)/kernel_build/dtb/mkdtboimg.py"

OUT_KERNELZIP="$(pwd)/kernel_build/Kernel-$(date '+%Y%m%d-%H%M')_gta9.zip"
OUT_KERNELTAR="$(pwd)/kernel_build/Kernel-$(date '+%Y%m%d-%H%M')_gta9.tar"
OUT_KERNEL="$OUTDIR/arch/arm64/boot/Image.gz"
OUT_BOOTIMG="$(pwd)/kernel_build/zip/boot.img"
OUT_VENDORBOOTIMG="$(pwd)/kernel_build/zip/vendor_boot.img"
OUT_DTBIMAGE="$TMPDIR/dtb.img"

# Kernel-side
BUILD_ARGS="LOCALVERSION=-Kernel KBUILD_BUILD_USER=$(whoami)"

kfinish() {
    rm -rf "$TMPDIR"
    rm -rf "$MODULES_OUTDIR"
}

kfinish

DIR="$(readlink -f .)"
PARENT_DIR="$(readlink -f ${DIR}/..)"

export CROSS_COMPILE="$PARENT_DIR/clang-r547379/bin/aarch64-linux-gnu-"
export CC="$PARENT_DIR/clang-r547379/bin/clang"

export PLATFORM_VERSION=12
export ANDROID_MAJOR_VERSION=s
export PATH="$PARENT_DIR/build-tools/path/linux-x86:$PARENT_DIR/clang-r547379/bin:$PATH"
export TARGET_SOC=mt8781
export LLVM=1 LLVM_IAS=1
export ARCH=arm64

if [ ! -d "$PARENT_DIR/clang-r547379" ]; then
    mkdir -p "$PARENT_DIR/clang-r547379"
    wget -P "$PARENT_DIR" "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master/clang-r547379.tar.gz"
    tar -xzf "$PARENT_DIR/clang-r547379.tar.gz" -C "$PARENT_DIR/clang-r547379"
fi

if [ ! -d "$PARENT_DIR/build-tools" ]; then
    git clone https://android.googlesource.com/platform/prebuilts/build-tools "$PARENT_DIR/build-tools" --depth=1
fi

# Calculate safe job count
TOTAL_MEM_MB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_SWAP_MB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
TOTAL_VMEM_MB=$((TOTAL_MEM_MB + TOTAL_SWAP_MB))
SAFE_JOBS=$((TOTAL_VMEM_MB / 1228))
CPU_CORES=$(nproc --all)
if [ $SAFE_JOBS -gt $CPU_CORES ]; then
    SAFE_JOBS=$CPU_CORES
fi
if [ $SAFE_JOBS -lt 4 ]; then
    SAFE_JOBS=4
fi
echo "[+] Using -j$SAFE_JOBS (RAM+swap aware)"

echo "Starting compilation..."
rm -f log.txt
make -j$(nproc --all) -C $(pwd) O=out $BUILD_ARGS gta9_defconfig 2>&1 | tee log.txt

# Enable KernelSU configs
scripts/config --file out/.config \
    --enable CONFIG_KPROBES \
    --enable CONFIG_HAVE_KPROBES \
    --enable CONFIG_KALLSYMS \
    --enable CONFIG_KALLSYMS_ALL \
    --enable CONFIG_BPF \
    --enable CONFIG_BPF_SYSCALL \
    --enable CONFIG_KPROBES_ON_FTRACE \
    --enable CONFIG_KSU

# Apply the new config
make -j$(nproc --all) -C $(pwd) O=out olddefconfig

# Now build everything
make -j$(nproc --all) -C $(pwd) O=out $BUILD_ARGS dtbs 2>&1 | tee -a log.txt
make -j$(nproc --all) -C $(pwd) O=out $BUILD_ARGS 2>&1 | tee -a log.txt
make -j$(nproc --all) -C $(pwd) O=out INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" INSTALL_MOD_PATH="$MODULES_OUTDIR" modules_install 2>&1 | tee -a log.txt

rm -rf "$TMPDIR"
rm -f "$OUT_BOOTIMG"
rm -f "$OUT_VENDORBOOTIMG"
mkdir "$TMPDIR"
mkdir "$PLATFORM_RAMDISK_DIR"
mkdir -p "$MODULES_DIR/0.0"

cp -rf "$IN_PLATFORM"/* "$PLATFORM_RAMDISK_DIR/"

if ! find "$MODULES_OUTDIR/lib/modules" -mindepth 1 -type d | read; then
    echo "Unknown error!"
    exit 1
fi

# Check for duplicate modules in modules.load
if [ -f "$IN_DLKM/modules.load" ]; then
    dupes=$(sort "$IN_DLKM/modules.load" | uniq -d | xargs)
    if [ -n "$dupes" ]; then
        echo -e "\nERROR: Duplicate module entries found in modules.load: $dupes\n"
        exit 1
    fi
fi

# Warn for modules present but not in modules.load
if [ -d "$MODULES_OUTDIR/lib/modules" ] && [ -f "$IN_DLKM/modules.load" ]; then
    all_built=$(find "$MODULES_OUTDIR/lib/modules" -type f -name "*.ko" -exec basename {} \; | sort)
    all_load=$(sort "$IN_DLKM/modules.load")
    not_in_load=$(comm -23 <(echo "$all_built") <(echo "$all_load") | xargs)
    if [ -n "$not_in_load" ]; then
        echo -e "\nWARNING: The following modules exist but are NOT in modules.load: $not_in_load\n"
    fi
fi

# Copy all modules
MODULE_SRC_DIR=$(find "$MODULES_OUTDIR/lib/modules" -mindepth 1 -maxdepth 1 -type d)
find "$MODULE_SRC_DIR" -name "*.ko" -type f -exec cp -t "$MODULES_DIR/0.0/" {} +

missing_modules=""

for module in $(cat "$IN_DLKM/modules.load"); do
    i=$(find "$MODULES_OUTDIR/lib/modules" -name $module);
    if [[ ! -f "$i" ]]; then
        missing_modules="$missing_modules $module"
    fi
done

if [[ "$missing_modules" != "" ]]; then
    echo "ERROR: the following modules were not found: $missing_modules"
	  exit 1
fi

depmod 0.0 -b "$PLATFORM_RAMDISK_DIR"
sed -i 's/\([^ ]\+\)/\/lib\/modules\/\1/g' "$MODULES_DIR/0.0/modules.dep"
cd "$MODULES_DIR/0.0"
for i in $(find . -name "modules.*" -type f); do
    if [[ $(basename "$i") != "modules.dep" ]] && [[ $(basename "$i") != "modules.softdep" ]] && [[ $(basename "$i") != "modules.alias" ]]; then
        rm -f "$i"
    fi
done
cd "$DIR"

cp -f "$IN_DLKM/modules.load" "$MODULES_DIR/0.0/modules.load"
mv "$MODULES_DIR/0.0"/* "$MODULES_DIR/"
rm -rf "$MODULES_DIR/0.0"

echo "Building dtb image..."
python3 "$MKDTBOIMG" create "$OUT_DTBIMAGE" --custom0=0x00000000 --custom1=0x00000000 --version=0 --page_size=2048 "$IN_DTB" || exit 1

echo "Building boot image..."

$MKBOOTIMG --header_version 4 \
    --kernel "$OUT_KERNEL" \
    --output "$OUT_BOOTIMG" \
    --ramdisk "$PREBUILT_RAMDISK" \
    --os_version 15.0.0 \
    --os_patch_level 2025-01 || exit 1

echo "Done!"
echo "Building vendor_boot image..."

cd "$PLATFORM_RAMDISK_DIR"
find . | cpio --quiet -o -H newc -R root:root | lz4 -9cl > ../ramdisk_platform.lz4
cd ..
touch bootconfig

$MKBOOTIMG --header_version 4 \
    --vendor_boot "$OUT_VENDORBOOTIMG" \
    --vendor_bootconfig "$(pwd)/bootconfig" \
    --dtb "$OUT_DTBIMAGE" \
    --vendor_ramdisk "$(pwd)/ramdisk_platform.lz4" \
    --vendor_cmdline "bootopt=64S3,32N2,64N2 loop.max_part=7" \
    --board SRPWF07A004 \
    --os_version 15.0.0 \
    --os_patch_level 2025-01 || exit 1

cd "$DIR"

echo "Done!"

echo "Building zip..."
cd "$(pwd)/kernel_build/zip"
rm -f "$OUT_KERNELZIP"
brotli --quality=6 -c boot.img > boot.br
brotli --quality=6 -c vendor_boot.img > vendor_boot.br
zip -r0 -q "$OUT_KERNELZIP" META-INF boot.br vendor_boot.br
rm -f boot.br vendor_boot.br
cd "$DIR"
echo "Done! Output: $OUT_KERNELZIP"

echo "Building tar..."
cd "$(pwd)/kernel_build"
rm -f "$OUT_KERNELTAR"
lz4 -c -6 -B6 --content-size "$OUT_BOOTIMG" > boot.img.lz4
lz4 -c -6 -B6 --content-size "$OUT_VENDORBOOTIMG" > vendor_boot.img.lz4
tar -cf "$OUT_KERNELTAR" boot.img.lz4 vendor_boot.img.lz4
cd "$DIR"
rm -f boot.img.lz4 vendor_boot.img.lz4
echo "Done! Output: $OUT_KERNELTAR"

echo "Cleaning..."
rm -f "${OUT_VENDORBOOTIMG}" "${OUT_BOOTIMG}"
kfinish
