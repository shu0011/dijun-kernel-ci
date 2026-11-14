#!/usr/bin/env bash
# 用设备原厂 config 编 arm64 Image，并抽出 vmlinux 里的 .BTF。
# 这一版不加 SUSFS、不加 KernelSU：目的是
#   1) 把 UTS_RELEASE 对齐到设备真值，使产物具备"可刷"的前提；
#   2) 验证 6.18.32 基线 + 设备 config 与设备内核（6.18.21 + 厂商提交）的 ABI 差异。
#
# 版本对齐为什么必须做：
#   内核加载厂商 .ko 时 check_modinfo() 逐字符比较 vermagic 与 UTS_RELEASE。
#   设备 vendor_dlkm / system_dlkm 里那批 .ko 的 vermagic 都是
#   6.18.21-android17-5-g284297031c53-abogki553682993-4k，
#   新 Image 的 uname -r 只要差一个字符，那批模块全部拒载。
#   SUBLEVEL 只进字符串不进 ABI，所以在同一 KMI 分支内改写它是安全的。
set -euo pipefail

SRC="${SRC:-kernel}"
OUT="${OUT:-out}"
CFG="${CFG:-config/dijun_defconfig}"
JOBS="${JOBS:-$(nproc)}"
LLVM_SUFFIX="${LLVM_SUFFIX:--18}"

# 设备真值，来源：OS4.0.4.0 OTA 的 boot.img 里 "Linux version" 字符串
TARGET_RELEASE="${TARGET_RELEASE:-6.18.21-android17-5-g284297031c53-abogki553682993-4k}"
TARGET_SUBLEVEL="${TARGET_SUBLEVEL:-21}"
TARGET_LOCALVERSION="${TARGET_LOCALVERSION:--android17-5-g284297031c53-abogki553682993-4k}"

mkdir -p "$OUT"
export KBUILD_BUILD_USER=ci
export KBUILD_BUILD_HOST=github-actions

echo "==> 1 用设备 config 生成 .config"
cp "$CFG" "$SRC/arch/arm64/configs/dijun_defconfig"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" dijun_defconfig

echo "==> 2 对齐版本字符串 -> $TARGET_RELEASE"
# SUBLEVEL 来自顶 Makefile；LOCALVERSION 从 config 覆盖
sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $TARGET_SUBLEVEL/" "$SRC/Makefile"
"$SRC/scripts/config" --file "$SRC/.config" \
    --set-str LOCALVERSION "$TARGET_LOCALVERSION" \
    --disable LOCALVERSION_AUTO

# 设备 config 里 CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"，
# 这个文件由 kleaf 在 GKI 正式构建时生成，AOSP 源码树里没有。
# 本轮只测 ABI，先关掉裁剪，导出全量符号（对 ABI 测量无影响，对厂商 .ko 是超集）。
if [ ! -e "$SRC/abi_symbollist.raw" ]; then
    echo "    abi_symbollist.raw 不存在，关闭 TRIM_UNUSED_KSYMS"
    "$SRC/scripts/config" --file "$SRC/.config" \
        --disable TRIM_UNUSED_KSYMS \
        --set-str UNUSED_KSYMS_WHITELIST ""
fi

make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" olddefconfig

ACTUAL_RELEASE=$(make -s -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" kernelrelease)
echo "    kernelrelease = $ACTUAL_RELEASE"
if [ "$ACTUAL_RELEASE" != "$TARGET_RELEASE" ]; then
    echo "!! 版本字符串与设备不一致，厂商 .ko 会全部拒载，终止"
    echo "   want: $TARGET_RELEASE"
    echo "   got : $ACTUAL_RELEASE"
    exit 1
fi

grep -E '^CONFIG_LOCALVERSION=|^CONFIG_LOCALVERSION_AUTO=|^CONFIG_DEBUG_INFO_BTF=|^CONFIG_GENDWARFKSYMS=|^CONFIG_CFI=|^CONFIG_MODVERSIONS=' \
    "$SRC/.config" || true

echo "==> 3 编译 Image（$JOBS 并发）"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" -j"$JOBS" Image

echo "==> 4 抽取 .BTF 与产物"
cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
objcopy --dump-section .BTF="$OUT/vmlinux.btf" "$SRC/vmlinux"
cp "$SRC/System.map" "$OUT/System.map"
cp "$SRC/Module.symvers" "$OUT/Module.symvers"
cp "$SRC/.config" "$OUT/config.built"
{
    echo "source_commit=$(git -C "$SRC" rev-parse HEAD)"
    echo "release=$ACTUAL_RELEASE"
    echo "target_release=$TARGET_RELEASE"
    sha256sum "$OUT/Image" | awk '{print "image_sha256="$1}'
    stat -c 'image_bytes=%s' "$OUT/Image"
    stat -c 'btf_bytes=%s' "$OUT/vmlinux.btf"
    echo "exported_symbols=$(awk 'NF>=4' "$OUT/Module.symvers" | wc -l)"
} | tee "$OUT/summary.txt"
