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
#
# 版本串由 scripts/setlocalversion 拼出来，它读的是
#   ${KERNELVERSION} + ${file_localversion} + ${config_localversion} + ${LOCALVERSION} + ${scm_version}
# 其中 config_localversion 取自 include/config/auto.conf（不是 .config！），
# LOCALVERSION 未设置时会追加 -g<sha>-dirty。两头都要管住。
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
# 显式设为空串（"已设置"状态），setlocalversion 才不会追加 -g<sha>-dirty
export LOCALVERSION=""

echo "==> 1 用设备 config 生成 .config"
cp "$CFG" "$SRC/arch/arm64/configs/dijun_defconfig"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" dijun_defconfig

echo "==> 2 对齐版本字符串 -> $TARGET_RELEASE"
# SUBLEVEL 来自顶 Makefile；值以 '-' 开头，不能用 scripts/config（会被 getopt 当选项）
sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $TARGET_SUBLEVEL/" "$SRC/Makefile"
sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$TARGET_LOCALVERSION\"|" "$SRC/.config"
sed -i "s|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|" "$SRC/.config"

# 设备 config 里有两个指向 kleaf 生成物的条目，AOSP 源码树里没有：
#   CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"
#   CONFIG_MODULE_SIG_PROTECT_LIST="protected_module_names_list"
# 不处理就会在 modpost 阶段报 "No rule to make target X, needed by vmlinux.symvers"。
# 本轮只测 ABI：关掉 KSYMS 裁剪（导出全量，对厂商 .ko 是超集）、关掉受保护模块名单。
# 两个文件（.config 与 auto.conf）都要改：make 读 auto.conf，olddefconfig 读 .config。
drop_kleaf_file_dep() {
    local f="$1"
    [ -e "$f" ] || return 0
    if [ ! -e "$SRC/abi_symbollist.raw" ]; then
        sed -i "s|^CONFIG_TRIM_UNUSED_KSYMS=.*|# CONFIG_TRIM_UNUSED_KSYMS is not set|" "$f"
        sed -i "s|^CONFIG_UNUSED_KSYMS_WHITELIST=.*|CONFIG_UNUSED_KSYMS_WHITELIST=\"\"|" "$f"
    fi
    if [ ! -e "$SRC/protected_module_names_list" ]; then
        sed -i "s|^CONFIG_MODULE_SIG_PROTECT=.*|# CONFIG_MODULE_SIG_PROTECT is not set|" "$f"
        sed -i "s|^CONFIG_MODULE_SIG_PROTECT_LIST=.*|CONFIG_MODULE_SIG_PROTECT_LIST=\"\"|" "$f"
    fi
}

echo "    处理 kleaf 专属文件依赖"
drop_kleaf_file_dep "$SRC/.config"

# 顺手把 config 里所有「指向源码树内某个不存在文件」的字符串项列出来。
# 这类条目都是 kleaf 构建时才有的生成物，缺一个就可能在编译末尾报
# "No rule to make target"，早暴露总比等半小时好。
echo "    扫描 config 指向的外部文件"
{ grep -oE '^CONFIG_[A-Z0-9_]+="[^"/]*"' "$SRC/.config" || true; } | while IFS='=' read -r k v; do
    f=$(printf '%s' "$v" | tr -d '"')
    case "$k" in CONFIG_LOCALVERSION) continue;; esac
    [ -z "$f" ] && continue
    [ -e "$SRC/$f" ] || echo "    ?? $k -> $f 不存在"
done

make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" olddefconfig

# olddefconfig 不一定刷新 auto.conf，而 setlocalversion 与 modpost 认的都是 auto.conf。
# 注意 auto.conf 是 make 语法，字符串值不带引号（.config 才带）。
if [ -e "$SRC/include/config/auto.conf" ]; then
    sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=$TARGET_LOCALVERSION|" \
        "$SRC/include/config/auto.conf"
    sed -i "s|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|" \
        "$SRC/include/config/auto.conf"
    drop_kleaf_file_dep "$SRC/include/config/auto.conf"
fi
rm -f "$SRC/include/config/kernel.release" "$SRC/include/generated/utsrelease.h"

echo "    auto.conf: $(grep -c . "$SRC/include/config/auto.conf" 2>/dev/null || echo 0) 行"
grep -E '^CONFIG_(LOCALVERSION|TRIM_UNUSED_KSYMS|MODULE_SIG_PROTECT)' \
    "$SRC/include/config/auto.conf" 2>/dev/null || true

ACTUAL_RELEASE=$(make -s -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" kernelrelease)
echo "    kernelrelease = $ACTUAL_RELEASE"
if [ "$ACTUAL_RELEASE" != "$TARGET_RELEASE" ]; then
    echo "!! 版本字符串与设备不一致，厂商 .ko 会全部拒载，终止"
    echo "   want: $TARGET_RELEASE"
    echo "   got : $ACTUAL_RELEASE"
    exit 1
fi

grep -E '^CONFIG_(LOCALVERSION|DEBUG_INFO_BTF|GENDWARFKSYMS|CFI|MODVERSIONS|TRIM_UNUSED_KSYMS)=' \
    "$SRC/.config" || true

echo "==> 3 处理 pahole 的 per-CPU 变量上限"
# pahole 1.22~1.26 的 btf_encoder 对 per-CPU 变量有 4096 条硬上限，超了就返回 -1
# 并且不再写 .BTF 段，resolve_btfids 随即报
#   FAILED: load BTF from vmlinux.unstripped: Invalid argument
# 这台机器的 distro config 编出来的 percpu 变量超过 4096，必挂。
# 我们只需要 STRUCT/UNION 的 sizeof 与成员偏移，VAR/DATASEC 完全用不上，
# 所以直接关掉 percpu 变量编码。（上游 2024-02 的修法是改成动态分配，1.27+ 才有。）
PAHOLE_V=$(pahole --version 2>/dev/null | sed -nE 's/^v([0-9]+)\.([0-9]+).*/\1\2/p')
echo "    pahole $(pahole --version 2>/dev/null || echo '(缺失)') -> 解析为 ${PAHOLE_V:-?}"
if [ -n "${PAHOLE_V:-}" ] && [ "$PAHOLE_V" -lt 126 ]; then
    sed -i 's|^pahole-flags-y :=$|pahole-flags-y := --skip_encoding_btf_vars|' \
        "$SRC/scripts/Makefile.btf"
    echo "    旧式 flags：加 --skip_encoding_btf_vars"
else
    sed -i 's|--btf_features=encode_force,var,float|--btf_features=encode_force,float|' \
        "$SRC/scripts/Makefile.btf"
    echo "    btf_features 白名单：去掉 var"
fi
grep -nE 'btf_features=[a-z]|pahole-flags-y :=' "$SRC/scripts/Makefile.btf" | head -4

echo "==> 4 编译 Image（$JOBS 并发）"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_SUFFIX" -j"$JOBS" Image

echo "==> 5 抽取 .BTF 与产物"
cp "$SRC/arch/arm64/boot/Image" "$OUT/Image"

# vmlinux 是 aarch64 ELF，宿主的 x86 objcopy 认不出来
# （objcopy: Unable to recognise the format of the input file）。用 llvm-objcopy。
OBJCOPY_BIN=""
for c in llvm-objcopy llvm-objcopy-18 llvm-objcopy-19 aarch64-linux-gnu-objcopy; do
    if command -v "$c" >/dev/null 2>&1; then OBJCOPY_BIN="$c"; break; fi
done
if [ -z "$OBJCOPY_BIN" ]; then
    echo "!! 找不到能处理 arm64 ELF 的 objcopy（需要 llvm-objcopy 或 aarch64-linux-gnu-objcopy）"
    exit 1
fi
echo "    用 $OBJCOPY_BIN 抽 .BTF"
"$OBJCOPY_BIN" --dump-section .BTF="$OUT/vmlinux.btf" "$SRC/vmlinux"
cp "$SRC/System.map" "$OUT/System.map"
cp "$SRC/Module.symvers" "$OUT/Module.symvers"
cp "$SRC/.config" "$OUT/config.built"

# 从 Image 里回读真实版本串（内核 Image 未压缩，字符串是明文）
IMG_RELEASE=$(grep -a -o -m1 'Linux version [^ ]*' "$OUT/Image" | awk '{print $3}')
echo "    Image 内 Linux version = $IMG_RELEASE"
if [ "$IMG_RELEASE" != "$TARGET_RELEASE" ]; then
    echo "!! 编出来的 Image 版本串与目标不一致"
    exit 1
fi

{
    echo "source_commit=$(git -C "$SRC" rev-parse HEAD)"
    echo "release=$ACTUAL_RELEASE"
    echo "target_release=$TARGET_RELEASE"
    echo "image_uts_release=$IMG_RELEASE"
    sha256sum "$OUT/Image" | awk '{print "image_sha256="$1}'
    stat -c 'image_bytes=%s' "$OUT/Image"
    stat -c 'btf_bytes=%s' "$OUT/vmlinux.btf"
    echo "exported_symbols=$(awk 'NF>=4' "$OUT/Module.symvers" | wc -l)"
} | tee "$OUT/summary.txt"
