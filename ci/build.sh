#!/usr/bin/env bash
# 用设备原厂 config 编 arm64 Image，并抽出 vmlinux 里的 .BTF。
# 这一版不加 SUSFS、不加 KernelSU：唯一目的是验证"6.18.32 基线 + 设备 config"
# 与设备内核（6.18.21 + 厂商提交）的 ABI 差异有多大。
set -euo pipefail

SRC="${SRC:-kernel}"
OUT="${OUT:-out}"
CFG="${CFG:-config/dijun_defconfig}"
JOBS="${JOBS:-$(nproc)}"
LLVM_SUFFIX="${LLVM_SUFFIX:--18}"

mkdir -p "$OUT"
export KBUILD_BUILD_USER=ci
export KBUILD_BUILD_HOST=github-actions

echo "==> 1 用设备 config 生成 .config"
cp "$CFG" "$SRC/arch/arm64/configs/dijun_defconfig"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" dijun_defconfig
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" olddefconfig

grep -E '^CONFIG_LOCALVERSION=|^CONFIG_DEBUG_INFO_BTF=|^CONFIG_GENDWARFKSYMS=|^CONFIG_CFI=' \
    "$SRC/.config" || true

echo "==> 2 编译 Image（$JOBS 并发）"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" -j"$JOBS" Image

echo "==> 3 抽取 .BTF 与产物"
cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"
objcopy --dump-section .BTF="$OUT/vmlinux.btf" "$SRC/vmlinux"
cp "$SRC/System.map" "$OUT/System.map"
cp "$SRC/.config" "$OUT/config.built"
{
    echo "source_commit=$(git -C "$SRC" rev-parse HEAD)"
    echo "release=$(cat "$SRC/include/config/kernel.release")"
    sha256sum "$OUT/Image" | awk '{print "image_sha256="$1}'
    stat -c 'image_bytes=%s' "$OUT/Image"
    stat -c 'btf_bytes=%s' "$OUT/vmlinux.btf"
} | tee "$OUT/summary.txt"
