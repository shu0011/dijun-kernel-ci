#!/usr/bin/env bash
# 用设备原厂 config 编 arm64 Image，并把 vmlinux 里的 .BTF 抽出来。
# 这版不加 SUSFS：先把"树 + config"能不能复现设备 ABI 这件事验清楚。
set -euo pipefail

SRC="${SRC:-kernel}"
OUT="${OUT:-out}"
CFG="${CFG:-config/dijun_defconfig}"
JOBS="${JOBS:-$(nproc)}"
LLVM_SUFFIX="${LLVM_SUFFIX:--18}"
RELEASE_LOCAL="${RELEASE_LOCAL:--android17-5-g284297031c53-abogki553682993-4k}"

mkdir -p "$OUT"
export KBUILD_BUILD_USER=ci
export KBUILD_BUILD_HOST=github-actions

echo "==> 1 用设备 config 生成 .config"
cp "$CFG" "$SRC/arch/arm64/configs/dijun_defconfig"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" dijun_defconfig

echo "==> 2 固定 localversion（要和设备 vermagic 对齐），保留 BTF 生成"
"$SRC/scripts/config" --file "$SRC/.config" \
    --set-str LOCALVERSION "$RELEASE_LOCAL" \
    --disable LOCALVERSION_AUTO
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" olddefconfig
grep -E '^CONFIG_LOCALVERSION=|^CONFIG_LOCALVERSION_AUTO|^CONFIG_DEBUG_INFO_BTF=|^CONFIG_GENDWARFKSYMS=' \
    "$SRC/.config" || true

echo "==> 3 编译 Image（$JOBS 并发）"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" -j"$JOBS" Image

echo "==> 4 抽取 .BTF 与产物"
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
