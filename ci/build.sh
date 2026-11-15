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

# LLVM=1 要求 PATH 里有不带后缀的 clang/ld.lld/llvm-objcopy；
# 只有 ubuntu 的 clang-18 时要用 LLVM=-18 走带后缀的工具链。
# AOSP 预编译 clang 自带这些名字，用 LLVM=1 才能让 POR_EL0 之类的
# 编译器能力探测通过（决定 CONFIG_ARM64_POE 等 config）。
# AOSP 预编译 clang 由 workflow 拉到 $AOSP_CLANG，优先用它：
# 设备内核就是 r584948c 编的，同版本编译器才能算出同样的 DWARF → 同样的符号 CRC。
if [ -n "${AOSP_CLANG:-}" ] && [ -x "$AOSP_CLANG/bin/clang" ]; then
    export PATH="$AOSP_CLANG/bin:$PATH"
fi

LLVM_VAL="${LLVM_VAL:-}"
if [ -z "$LLVM_VAL" ]; then
    if clang --version 2>/dev/null | grep -q "Android"; then
        LLVM_VAL=1
    else
        LLVM_VAL="$LLVM_SUFFIX"
    fi
fi
echo "==> 0 工具链 LLVM=$LLVM_VAL（$(clang --version 2>/dev/null | head -1)）"

# 设备真值，来源：OS4.0.4.0 OTA 的 boot.img 里 "Linux version" 字符串
TARGET_RELEASE="${TARGET_RELEASE:-6.18.21-android17-5-g284297031c53-abogki553682993-4k}"
TARGET_SUBLEVEL="${TARGET_SUBLEVEL:-21}"
TARGET_LOCALVERSION="${TARGET_LOCALVERSION:--android17-5-g284297031c53-abogki553682993-4k}"

mkdir -p "$OUT"
# 构建者信息伪装成官方 kleaf 构建，与设备内核的 "Linux version …" 行一致：
#   官方: 6.18.21-android17-5-g284297031c53-abogki553682993-4k (kleaf@build-host)
#         (Android (15323222, …, based on r584948c) clang version 22.0.1 …)
#         #1 SMP PREEMPT Mon Aug 31 02:13:04 UTC 2026
# user/host/timestamp 三个变量决定前两段和末尾日期；编译器那段由 AOSP
# clang r584948c 自己输出，换对工具链就一致。
BUILD_USER="${BUILD_USER:-kleaf}"
BUILD_HOST="${BUILD_HOST:-build-host}"
BUILD_TIMESTAMP="${BUILD_TIMESTAMP:-Mon Aug 31 02:13:04 UTC 2026}"
export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"
export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"
export KBUILD_BUILD_VERSION=1
echo "==> 构建者信息: ${BUILD_USER}@${BUILD_HOST}  ${BUILD_TIMESTAMP}"

# GKI 的 KMI 跨 sub-level 稳定，靠的就是 gendwarfksyms 的 --stable：
# scripts/Makefile.build:198  $(if $(KBUILD_GENDWARFKSYMS_STABLE), --stable)
# kleaf（AOSP 官方构建，设备内核和作者都用它）默认传这个标志，裸 make 不会。
# 不开的话 CRC 会绑定实现细节（函数体、内联、编译顺序等），跨版本一变就不同，
# 厂商 .ko 全部拒载。开了之后只按稳定类型信息算，才和设备的 __versions 对得上。
export KBUILD_GENDWARFKSYMS_STABLE=1
# setlocalversion 已被替换成固定输出，不再需要靠 LOCALVERSION 环境变量压制 -g<sha>-dirty；
# 保留反而会干扰 Makefile 里 LOCALVERSION = $(CONFIG_LOCALVERSION) 的取值

echo "==> 1 用设备 config 生成 .config"
cp "$CFG" "$SRC/arch/arm64/configs/dijun_defconfig"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_VAL" dijun_defconfig

echo "==> 2 对齐版本字符串 -> $TARGET_RELEASE"
# SUBLEVEL 来自顶 Makefile；值以 '-' 开头，不能用 scripts/config（会被 getopt 当选项）
sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $TARGET_SUBLEVEL/" "$SRC/Makefile"

# 版本串拆成两段拼，和设备一致：
#   UTS_RELEASE = 6.18.21 + (setlocalversion 输出) + CONFIG_LOCALVERSION
#   设备 = 6.18.21 + "-android17-5-g284297031c53-abogki553682993" + "-4k"
# 之前图省事把整串塞进 CONFIG_LOCALVERSION 并关掉 LOCALVERSION_AUTO，
# 结果 CONFIG_MODULE_SCMVERSION（depends on LOCALVERSION_AUTO）被连带关掉，
# struct module 少了 scmversion[64]，布局差 64 字节，module_layout 的 CRC
# 跟着变 —— 厂商 .ko 全部 "disagrees about version of symbol module_layout"。
# 现在保持 LOCALVERSION_AUTO=y、LOCALVERSION 只放 -4k，改 setlocalversion 伪造前半段。
sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"-4k\"|" "$SRC/.config"
sed -i "s|^# CONFIG_LOCALVERSION_AUTO is not set|CONFIG_LOCALVERSION_AUTO=y|" "$SRC/.config"
sed -i "s|^CONFIG_LOCALVERSION_AUTO=.*|CONFIG_LOCALVERSION_AUTO=y|" "$SRC/.config"

# 关键：Makefile 里
#   ifeq ($(origin KERNELRELEASE),file)
#   filechk_kernel.release = $(srctree)/scripts/setlocalversion $(srctree)
#   else
#   filechk_kernel.release = echo $(KERNELRELEASE)
# 第一次生成 kernel.release 后它就存在了，之后 KERNELRELEASE 的来源变成 file，
# 内核**完全用这个脚本的输出**做 UTS_RELEASE，不再拼 KERNELVERSION 和
# CONFIG_LOCALVERSION。所以这里必须给完整串。
cat > "$SRC/scripts/setlocalversion" <<SLV
#!/bin/sh
echo "6.18.${TARGET_SUBLEVEL}-android17-5-g284297031c53-abogki553682993-4k"
exit 0
SLV
chmod +x "$SRC/scripts/setlocalversion"

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

# 打开 KernelSU(built-in) 与 SUSFS 的 SELinux 隐藏。
# Kconfig 定义由 ci/integrate.sh 注入，所以这一步必须排在它之后。
enable_cfg() {
    local k="$1" f="$2"
    [ -e "$f" ] || return 0
    if grep -q "^# CONFIG_${k} is not set" "$f"; then
        sed -i "s|^# CONFIG_${k} is not set|CONFIG_${k}=y|" "$f"
    elif grep -q "^CONFIG_${k}=" "$f"; then
        sed -i "s|^CONFIG_${k}=.*|CONFIG_${k}=y|" "$f"
    else
        echo "CONFIG_${k}=y" >> "$f"
    fi
}
disable_cfg() {
    local k="$1" f="$2"
    [ -e "$f" ] || return 0
    if grep -q "^CONFIG_${k}=" "$f"; then
        sed -i "s|^CONFIG_${k}=.*|# CONFIG_${k} is not set|" "$f"
    fi
}

for k in KSU KSU_SUSFS MODULE_SCMVERSION; do
    enable_cfg "$k" "$SRC/.config"
done

# MODVERSIONS 必须保持 y。
# 关掉它不只是"跳过 CRC 校验"，还会让 kernel/module/Makefile 里的
#   obj-$(CONFIG_MODVERSIONS) += version.o
# 不编译 —— 而 version.o 正是 module_layout 符号的定义所在。没有它，
# 每个 .ko 加载都在 simplify_symbols 阶段失败，报 Exec format error：
#   init: Failed to insmod '.../securelib.ko': Exec format error
grep -E 'MODVERSIONS' "$SRC/.config" || true
grep -E '^CONFIG_(KSU|KSU_SUSFS)=' "$SRC/.config" || echo "    !! KSU 没打开"

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

make -C "$SRC" ARCH=arm64 LLVM="$LLVM_VAL" olddefconfig

# olddefconfig 不一定刷新 auto.conf，而 setlocalversion 与 modpost 认的都是 auto.conf。
# 注意 auto.conf 是 make 语法，字符串值不带引号（.config 才带）。
if [ -e "$SRC/include/config/auto.conf" ]; then
    # auto.conf 会被内核 Makefile include，优先级高于 .config —— 这里必须用
    # 和 .config 相同的新写法，否则前面改的又被覆盖回去。
    sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=-4k|" \
        "$SRC/include/config/auto.conf"
    sed -i "s|^# CONFIG_LOCALVERSION_AUTO is not set|CONFIG_LOCALVERSION_AUTO=y|" \
        "$SRC/include/config/auto.conf"
    sed -i "s|^CONFIG_LOCALVERSION_AUTO=.*|CONFIG_LOCALVERSION_AUTO=y|" \
        "$SRC/include/config/auto.conf"
    drop_kleaf_file_dep "$SRC/include/config/auto.conf"
    for k in KSU KSU_SUSFS MODULE_SCMVERSION; do
        enable_cfg "$k" "$SRC/include/config/auto.conf"
    done

fi
rm -f "$SRC/include/config/kernel.release" "$SRC/include/generated/utsrelease.h"

echo "    auto.conf: $(grep -c . "$SRC/include/config/auto.conf" 2>/dev/null || echo 0) 行"
grep -E '^CONFIG_(LOCALVERSION|TRIM_UNUSED_KSYMS|MODULE_SIG_PROTECT)' \
    "$SRC/include/config/auto.conf" 2>/dev/null || true

ACTUAL_RELEASE=$(make -s -C "$SRC" ARCH=arm64 LLVM="$LLVM_VAL" kernelrelease)
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

echo "==> 4 伪造编译器版本串"
# uname -a 里 "(...) clang version ..." 那一段由 scripts/mkcompile_h 写进
# include/generated/compile.h 的 LINUX_COMPILER，内容是 "${CC_VERSION}, ${LD_VERSION}"。
# AOSP 的 clang 预编译包在 googlesource 上拿不到（+archive 一直 400），
# 与其为了一个字符串去下 1.5 GB，不如直接让 mkcompile_h 输出官方那串。
FAKE_CC="${FAKE_CC:-Android (15323222, +pgo, +bolt, +lto, +mlgo, based on r584948c) clang version 22.0.1 (https://android.googlesource.com/toolchain/llvm-project 2d65e4108033380e6fe8e08b1f1826cd2bfb0c99)}"
FAKE_LD="${FAKE_LD:-LLD 22.0.1 (/mnt/disks/build-disk/src/googleplex-android/llvm-r584948-release/out/llvm-project/llvm 2d65e4108033380e6fe8e08b1f1826cd2bfb0c99)}"
python3 - "$SRC/scripts/mkcompile_h" "$FAKE_CC" "$FAKE_LD" <<'PY'
import re, sys
path, cc, ld = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
pat = re.compile(r'#define LINUX_COMPILER\s+"\$\{CC_VERSION\}, \$\{LD_VERSION\}"')
if not pat.search(src):
    sys.exit("mkcompile_h 里找不到 LINUX_COMPILER 模板，内核结构可能变了")
src = pat.sub(lambda m: '#define LINUX_COMPILER\t\t"%s, %s"' % (cc, ld), src, count=1)
open(path, "w").write(src)
print("    mkcompile_h 已改为输出官方编译器串")
PY

echo "==> 5 编译 Image（$JOBS 并发）"
make -C "$SRC" ARCH=arm64 LLVM="$LLVM_VAL" -j"$JOBS" Image

echo "==> 6 抽取 .BTF 与产物"
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
# make Image 只产出 vmlinux.symvers，Module.symvers 要 make modules 才有
for f in Module.symvers vmlinux.symvers; do
    if [ -f "$SRC/$f" ]; then cp "$SRC/$f" "$OUT/$f"; fi
done
cp "$SRC/.config" "$OUT/config.built"

# 从 Image 里回读真实版本串（内核 Image 未压缩，字符串是明文）
IMG_RELEASE=$(grep -a -o -m1 'Linux version [^ ]*' "$OUT/Image" | awk '{print $3}')
echo "    Image 内 Linux version = $IMG_RELEASE"
if [ "$IMG_RELEASE" != "$TARGET_RELEASE" ]; then
    echo "!! 编出来的 Image 版本串与目标不一致"
    exit 1
fi

# 构建者信息、编译器串、时间戳都要和官方一致，否则 uname -a 一眼能看出来
for probe in "(${BUILD_USER}@${BUILD_HOST})" "$BUILD_TIMESTAMP" \
             "based on r584948c" "clang version 22.0.1" "LLD 22.0.1"; do
    if ! grep -aq -- "$probe" "$OUT/Image"; then
        echo "!! Image 里找不到 '$probe'，伪装没生效"
        grep -a -o -m1 'Linux version .\{0,200\}' "$OUT/Image" || true
        exit 1
    fi
done
echo "    版本行伪装已与官方对齐"

{
    echo "source_commit=$(git -C "$SRC" rev-parse HEAD)"
    echo "release=$ACTUAL_RELEASE"
    echo "target_release=$TARGET_RELEASE"
    echo "image_uts_release=$IMG_RELEASE"
    sha256sum "$OUT/Image" | awk '{print "image_sha256="$1}'
    stat -c 'image_bytes=%s' "$OUT/Image"
    stat -c 'btf_bytes=%s' "$OUT/vmlinux.btf"
    SYMVERS=""
    for f in "$OUT/Module.symvers" "$OUT/vmlinux.symvers"; do
        if [ -f "$f" ]; then SYMVERS="$f"; break; fi
    done
    if [ -n "$SYMVERS" ]; then
        echo "exported_symbols=$(awk 'NF>=4' "$SYMVERS" | wc -l)"
    else
        # 两个都没有时不报错：pipefail 下 `ls 不存在的文件` 会让整块以 2 退出
        echo "exported_symbols=unavailable"
    fi
} | tee "$OUT/summary.txt"
