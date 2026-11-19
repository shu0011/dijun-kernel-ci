#!/usr/bin/env bash
# 集成 SukiSU + SUSFS 的 SELinux 隐藏。
#
# KSU 部分严格按官方指南来（docs/guide/how-to-integrate.md）：
#   curl -LSs .../kernel/setup.sh | bash -s <branch>
# 官方脚本负责 clone、链到 drivers/kernelsu、改 drivers/Makefile 与 drivers/Kconfig。
# 之前手写这套搬运，在 symlink、obj- 重复、版本串上连踩三个坑，没必要重复。
#
# 分支：
#   main     kprobe/kretprobe + sys_enter tracepoint 运行时注册（built-in 也照注册）
#   builtin  不注册 kprobe，需在内核源码手动调用 hook 入口 —— 想让
#            kprobes/list 彻底干净必须用它，但要改 execveat/faccessat/stat/read
#            等七处，先让系统能起来再切
set -euo pipefail

# 必须转成绝对路径：下面会 cd "$SRC"，之后再拿相对路径拼 "$SRC/drivers/..."
# 就会变成 kernel/kernel/drivers/...，symlink 检查全部落空。
SRC="$(cd "${SRC:-kernel}" && pwd)"
KSU_BRANCH="${KSU_BRANCH:-main}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> A 按官方指南集成 KernelSU（分支 $KSU_BRANCH）"
cd "$SRC"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Nova/SukiSU-Nova/main/kernel/setup.sh" \
    | bash -s "$KSU_BRANCH"

echo "==> B symlink 换成实目录"
# setup.sh 用 ln -s 链过去。打 SUSFS 补丁会污染上游仓库，而且 kbuild 在
# symlink 下解析 $(src) 容易出岔子，换成实拷贝。
if [ -L "$SRC/drivers/kernelsu" ]; then
    target=$(readlink -f "$SRC/drivers/kernelsu")
    rm -f "$SRC/drivers/kernelsu"
    cp -aL "$target" "$SRC/drivers/kernelsu"
    echo "    $target -> drivers/kernelsu"
fi
[ -d "$SRC/drivers/kernelsu" ] || { echo "!! drivers/kernelsu 不存在"; exit 1; }

echo "==> C 注册 CONFIG_KSU_SUSFS"
# 上游没有 SUSFS 开关，补一个。放 drivers/Kconfig 而非 kernelsu 的 Kconfig，
# 让 KSU 目录保持与上游一致，方便日后 diff。
python3 - "$SRC/drivers/Kconfig" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if 'config KSU_SUSFS' in s:
    print("    已存在，跳过")
    sys.exit(0)
block = """
config KSU_SUSFS
	bool "SUSFS (built-in full port)"
	depends on KSU
	default y
	help
	  SUSFS built-in 移植：SELinux 隐藏 + sus_path/mount/kstat/map、
	  spoof uname/cmdline，以及 ksu_susfs 命令字 ABI。

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	bool "Hide ksu/susfs symbols from /proc/kallsyms"
	depends on KSU_SUSFS
	default y
	help
	  Upstream SUSFS 的符号隐藏：在 kernel/kallsyms.c 的 s_show() 里按前缀
	  过滤 ksu_/susfs_ 等符号名。编译期实现，零 kprobe。

config KSU_SUSFS_ENABLE_LOG
	bool "Enable SUSFS kernel logging (static key)"
	depends on KSU_SUSFS
	default y
	help
	  Runtime-switchable SUSFS logging via CMD_SUSFS_ENABLE_LOG.

config KSU_SUSFS_OPEN_REDIRECT
	bool "Enable SUSFS open_redirect"
	depends on KSU_SUSFS
	default y
	help
	  Redirect a target path to a user-defined path on openat.

config KSU_SUSFS_PRIORITY_UID_FILTER
	bool "Enable SUSFS priority UID filter"
	depends on KSU_SUSFS
	default y
	help
	  Hide user-defined uids from get/setpriority and ioprio syscalls.
	  (SUS_PATH_UID_FILTER shares the SUS_PATH gate; it has no own CONFIG.)

"""
i = s.rfind("endmenu")
if i < 0:
    s = s + block
else:
    s = s[:i] + block + s[i:]
open(p, "w").write(s)
print("    KSU_SUSFS 已插入 drivers/Kconfig 的 endmenu 之前")
PYEOF

echo "==> D 合 SUSFS 的 SELinux 补丁"
patch -p1 -d "$SRC" --forward < "$HERE/patches/susfs-selinux.patch"

echo "==> E 加桥接层"
cp "$HERE/patches/susfs_bridge.c" "$SRC/fs/susfs_bridge.c"
grep -q 'susfs_bridge' "$SRC/fs/Makefile" || \
    printf '\nobj-$(CONFIG_KSU_SUSFS) += susfs_bridge.o\n' >> "$SRC/fs/Makefile"

echo "==> F 导出 KSU selinux_hide 的状态符号"
# SUSFS 的 hooks.c 补丁要读：
#   extern bool ksu_selinux_hide_running __read_mostly;
# 这几个在 KSU 里是 static，编译期各文件互不干扰，链接时才报 undefined。
SH="$SRC/drivers/kernelsu/feature/selinux_hide.c"
python3 - "$SH" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
subs = [
    ("static bool ksu_selinux_hide_running __read_mostly = false;",
     "bool ksu_selinux_hide_running __read_mostly = false;"),
    ("static DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);",
     "void initialize_fake_status(void);\nDEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);"),
    ("static struct page *fake_status = NULL;",
     "struct page *fake_status;"),
    ("static void initialize_fake_status()",
     "void initialize_fake_status(void)"),
]
for old, new in subs:
    if old not in s:
        sys.exit("selinux_hide.c 里找不到: " + old)
    s = s.replace(old, new, 1)
open(p, "w").write(s)
print("    已导出 4 个符号")
PYEOF

echo "==> G 固定 KSU 版本串"
# Kbuild 里 KSU_VERSION_FULL 靠 git describe 拼，分支名会是 main。
# 用户要 @shushu，直接写死；sha 和 tag 从 setup.sh 克隆的仓库里读。
KSU_SHA=$(git -C "$SRC/KernelSU" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
# Nova 的 CI 会推一个 manager-ci 标签，它比 v3.0.0 还晚，describe 优先选中它，
# 版本串于是变成 vmanager-ci-<sha>@shushu。只认语义化版本标签。
KSU_TAG=$(git -C "$SRC/KernelSU" tag --list 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -1 | sed 's/^v//' || true)
[ -n "${KSU_TAG:-}" ] || KSU_TAG=3.0.0
sed -i "s|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := v${KSU_TAG}-${KSU_SHA}@shushu|" \
    "$SRC/drivers/kernelsu/Kbuild"
grep -n 'KSU_VERSION_FULL :=' "$SRC/drivers/kernelsu/Kbuild"

echo "==> G-fix 让版本号走上游自动计算（补齐浅克隆历史，不写死）"
# 上游 Kbuild 在构建时自动算版本码，公式随上游版本演进：
#   LOCAL_COUNT := GitHub API 的 commit 页数（GITHUB_COMMITS）或 git rev-list --count main
#   KSU_VERSION := VERSION_BASE + LOCAL_COUNT - VERSION_OFFSET
# 早期 SukiSU-Ultra：40000 + COUNT - 2815（COUNT=4000 → 41185）
# 2026-11-15 改名 Nova 后：30000 + COUNT - 4001（当前 API 实测 COUNT=4001 → 30000）
# 之前写死 41185 违背了上游"自动计算"的设计，且上游改名后已经过时 —— 撤销。
#
# CI 上偶发显示 40000/30000（=VERSION_BASE 回退值）有两个原因，这里都修掉：
#   1) setup.sh 用 --depth=1 浅克隆，git rev-list --count main 只数到 1；
#   2) B 步骤把 drivers/kernelsu 的 symlink 换成实目录后 .git 丢了，
#      Kbuild 里 $(KSU_SRC)/../.git 判断落空 → 走 MDIR → 更拿不到历史。
# 修法：在 B 之后、编译之前把 KernelSU 的完整历史 fetch 下来，并在 drivers/
# 下补一个 .git 指针，让 Kbuild 的 wildcard/../.git 判断与 git rev-list 都命中。
# 这样版本号完全由上游公式自动算出，不钉死、不依赖网络 API 是否限流。
KSU_REPO="$SRC/KernelSU"
if [ -d "$KSU_REPO/.git" ] || [ -f "$KSU_REPO/.git" ]; then
    # 浅克隆补完整历史（已完整时 fetch --unshallow 会报错，忽略即可）
    git -C "$KSU_REPO" fetch --unshallow --tags -q 2>/dev/null || true
    N=$(git -C "$KSU_REPO" rev-list --count main 2>/dev/null || echo 0)
    echo "    KSU main commit count = $N"
    # B 步骤 cp -aL 后 drivers/kernelsu 是实目录，Kbuild 要 $(KSU_SRC)/../.git
    if [ ! -e "$SRC/drivers/.git" ] && [ -e "$KSU_REPO/.git" ]; then
        ln -s "$KSU_REPO/.git" "$SRC/drivers/.git"
        echo "    drivers/.git -> $KSU_REPO/.git"
    fi
fi
# 原样保留上游 Kbuild 的 KSU_VERSION 计算逻辑，不做任何 sed 覆盖
grep -nE 'VERSION_BASE|VERSION_OFFSET|KSU_VERSION[[:space:]]*:=' "$SRC/drivers/kernelsu/Kbuild" | head -8

echo "==> G2 让 KSU 的 selinux_hide 不再运行期改 write_op[]"
# ksu_selinux_hide_enable() 会往 selinuxfs 的 write_op[] 里塞函数指针，
# 而那是个 const 数组（.rodata）。module 模式下 ksu_patch_text 一律 EFAULT(-14)，
# 只能退到 kprobe；built-in 模式下这次写入会落到只读数据上，轻则无效重则写坏
# 相邻字段 —— 打开开关后开机即崩就是这个位置。
# 而 SUSFS 的补丁已经在编译期把 sel_write_context / sel_write_access /
# setprocattr 全部换成了 handle_* 包装，运行期这笔 patch 纯属重复劳动。
python3 - "$SRC/drivers/kernelsu/feature/selinux_hide.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
needle = """    if (!backup_sepolicy) {
        pr_err("no backup sepolicy available, please save feature and reboot to retry!\\n");
        return -EAGAIN;
    }
"""
assert s.count(needle) == 1, "selinux_hide.c 里找不到 backup_sepolicy 检查"
patch = needle + """
#ifdef CONFIG_KSU_SUSFS
    /* SUSFS 在编译期已经接管 sel_write_context / sel_write_access / setprocattr，
       这里不能再去改 const 的 write_op[]，否则 built-in 下写坏只读页 → 开机崩溃。
       只保留 backup sepolicy 与 fake status，running 由 feature_set 置位。 */
    ksu_selinux_hide_keep_backup = true;
    pr_info("selinux_hide: CONFIG_KSU_SUSFS=y, skip runtime hooks (compile-time wrappers)\\n");
    return 0;
#endif
"""
open(p, "w").write(s.replace(needle, patch, 1))
print("    selinux_hide.c: 已插入 CONFIG_KSU_SUSFS 早退分支")
PYEOF

echo "==> G3 fake status 改成按需初始化（不再看 static key）"
# KSU 的 fake_status 初始化有两处时机陷阱：
#   1) second_stage 阶段 policy 可能还没 enforce，initialize_fake_status() 直接跳过；
#   2) 紧接着 handle_post_fs_data() 会把 fake_status_initialize_key 关掉，
#      于是 selinuxfs 里那段「key 开着才初始化」的代码永远不再执行。
# 结果是：开关显示 enabled，但 fake_status 始终是 NULL，隐藏静默失效。
python3 - "$SRC/security/selinux/selinuxfs.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()

old_head = """\tstruct page    *status = selinux_kernel_status_page();

#ifdef CONFIG_KSU_SUSFS
\tif (likely(current_uid().val >= 10000 && ksu_selinux_hide_running)) {"""
new_head = """\tstruct page    *status = selinux_kernel_status_page();

#ifdef CONFIG_KSU_SUSFS
\t/* 按需初始化：不依赖 second_stage 的时机，也不看 static key。
\t   首次打开 status 时 status_page 已经存在，正好是分配 fake 页的时机。 */
\tif (!fake_status)
\t\tinitialize_fake_status();
\tif (likely(current_uid().val >= 10000 && ksu_selinux_hide_running)) {"""
assert s.count(old_head) == 1, "status open 头部没匹配上"
s = s.replace(old_head, new_head, 1)

old_key = """
#ifdef CONFIG_KSU_SUSFS
\tif (static_branch_unlikely(&fake_status_initialize_key)) {
\t\tif (!fake_status)
\t\t\tinitialize_fake_status();
\t}
#endif // #ifdef CONFIG_KSU_SUSFS
"""
assert s.count(old_key) == 1, "static key 初始化块没匹配上"
s = s.replace(old_key, "\n", 1)

open(p, "w").write(s)
print("    selinuxfs.c: fake status 改为按需初始化")
PYEOF

echo "==> G4 编译期接入官方 selinux_hide 的 context/access 实现"
# 官方 ksu_selinux_hide_enable() 的本质是把 write_op[SEL_CONTEXT]/[SEL_ACCESS] 等
# 函数指针在运行期换成 my_write_context / my_write_access（查 backup_sepolicy）。
# built-in 下这些槽位在 .rodata，ksu_patch_text 运行期改写会写坏只读页 → 开机崩；
# G2 早退虽然止住了崩溃，却把官方隐藏一起关掉了，而 SUSFS 编译期包装查的是
# 实时策略（含 ksu_file），所以检测软件照样报。
# 这里在编译期就把这两个包装接到官方实现的同一条策略路径上：
#   - 不改 write_op[] 的指向（仍是 handle_sel_write_*，带 uid/running 判断）
#   - selinuxfs.c 内只替换两处函数调用，改为 KSU 导出的 backup 策略 wrapper
#   - 不新增运行期 hook、不挂 kprobe、不写任何只读数据
SH="$SRC/drivers/kernelsu/feature/selinux_hide.c"
SF="$SRC/security/selinux/selinuxfs.c"
python3 - "$SH" "$SF" <<'PYEOF'
import sys
sh, sf = sys.argv[1], sys.argv[2]

# --- 1) KSU 侧：保住 backup_sepolicy，并暴露官方 app-uid 分支 ---
s = open(sh).read()
old = "static bool ksu_selinux_hide_keep_backup __read_mostly = false;"
assert s.count(old) == 1, "keep_backup 声明没匹配上"
s = s.replace(old, "static bool ksu_selinux_hide_keep_backup __read_mostly = true;", 1)

wrappers = r"""
/* ---- 编译期 SELinux 隐藏入口（CONFIG_KSU_SUSFS=y）------------------------
 * built-in 下 write_op[] 在编译期就指向 handle_sel_write_*，运行期不 patch
 * 任何只读数据，也不挂 kprobe。这里把官方 my_write_context / my_write_access
 * 的 app-uid 分支原样暴露出来，策略源同为 backup_sepolicy（原厂策略）。
 * ------------------------------------------------------------------------ */
int ksu_backup_context_to_sid(const char *scontext, u32 scontext_len, u32 *sid)
{
    if (!backup_sepolicy)
        return -EINVAL;
    return security_context_to_sid_with_policy(backup_sepolicy, scontext,
                                                scontext_len, sid,
                                                SECSID_NULL, GFP_KERNEL,
                                                NULL, NULL);
}

int ksu_backup_sid_to_context(u32 sid, char **scontext, u32 *scontext_len)
{
    if (!backup_sepolicy)
        return -EINVAL;
    return security_sid_to_context_with_policy(backup_sepolicy, sid,
                                                scontext, scontext_len);
}

void ksu_backup_compute_av(u32 ssid, u32 tsid, u16 tclass,
                           struct av_decision *avd)
{
    if (!backup_sepolicy) {
        memset(avd, 0, sizeof(*avd));
        return;
    }
    security_compute_av_user_with_policy(backup_sepolicy, ssid, tsid,
                                          tclass, avd);
}
"""
assert "int ksu_backup_context_to_sid(" not in s, "wrapper 已存在"
s = s.rstrip() + "\n" + wrappers
open(sh, "w").write(s)
print("    selinux_hide.c: 3 个 backup wrapper + keep_backup 初值")

# --- 2) selinuxfs.c：extern 与两处调用换成官方 backup 策略路径 ---
t = open(sf).read()

old_ext = "extern int susfs_security_context_to_sid(const char *scontext, u32 scontext_len, u32 *sid, gfp_t gfp);"
new_ext = """extern int ksu_backup_context_to_sid(const char *scontext, u32 scontext_len, u32 *sid);
extern int ksu_backup_sid_to_context(u32 sid, char **scontext, u32 *scontext_len);
extern void ksu_backup_compute_av(u32 ssid, u32 tsid, u16 tclass, struct av_decision *avd);"""
assert t.count(old_ext) == 1, "selinuxfs.c extern 声明没匹配上"
t = t.replace(old_ext, new_ext, 1)

old_ctx = """\tlength = susfs_security_context_to_sid(buf, size, &sid, GFP_KERNEL);
\tif (length)
\t\tgoto out;

\tlength = security_sid_to_context(sid, &canon, &len);"""
new_ctx = """\t/* 官方 my_write_context 的 app-uid 分支：用原厂备份策略翻译 */
\tlength = ksu_backup_context_to_sid(buf, size, &sid);
\tif (length)
\t\tgoto out;

\tlength = ksu_backup_sid_to_context(sid, &canon, &len);"""
assert t.count(old_ctx) == 1, "context 调用块没匹配上"
t = t.replace(old_ctx, new_ctx, 1)

old_acc = """\tlength = susfs_security_context_str_to_sid(scon, &ssid, GFP_KERNEL);
\tif (length)
\t\tgoto out;

\tlength = susfs_security_context_str_to_sid(tcon, &tsid, GFP_KERNEL);
\tif (length)
\t\tgoto out;

\tsusfs_security_compute_av_user(ssid, tsid, tclass, &avd);"""
new_acc = """\t/* 官方 my_write_access 的 app-uid 分支：用原厂备份策略翻译 */
\tlength = ksu_backup_context_to_sid(scon, strlen(scon), &ssid);
\tif (length)
\t\tgoto out;

\tlength = ksu_backup_context_to_sid(tcon, strlen(tcon), &tsid);
\tif (length)
\t\tgoto out;

\tksu_backup_compute_av(ssid, tsid, tclass, &avd);
\tavd.seqno = 1;"""
assert t.count(old_acc) == 1, "access 调用块没匹配上"
t = t.replace(old_acc, new_acc, 1)

open(sf, "w").write(t)
print("    selinuxfs.c: context/access 已切到 backup_sepolicy 路径")
PYEOF

echo "==> G5 把 setprocattr 接回官方 #3981 侧信道修复"
# Maple 检测项「重要: 策略属性写入特征 / kernelsu_traits_count:1」定位到
# setprocattr（写 /proc/self/attr/current）的侧信道：检测软件写一个 context，
# 比较返回行为判定 live policy 是否被 KSU 改过。
# 上游 2026-11-09 的 c836ea2c（#3981）正是修它：my_setprocattr 先用
# security_context_to_sid_live() 校验，只有遇到 ksu 新增 type（-EAGAIN，stale
# type mark）才 dual parse 查 backup_sepolicy —— 写原厂 context 时行为与真机一致。
# 但 G2 早退跳过了 ksu_lsm_hook(&selinux_setprocattr_hook)，my_setprocattr
# 只是编进内核、从未挂上；app 的写入落到 SUSFS 的 susfs_selinux_setprocattr
# （无 live-parse 修复）→ 侧信道暴露。LKM ko 能过检测，是因为它完整跑了
# enable()（ko 里有 "selinux_setprocattr_hook err ... try kprobe" 与
# "ksu hide kprobe fallback active"），my_setprocattr 真挂上了。
# 和 G4 同一手法：编译期导出 wrapper 指向 my_setprocattr，把 SUSFS 的
# handle_selinux_setprocattr 的 app-uid 分支改调它。不挂 kprobe、不改
# write_op[]、不写只读数据、不新增功能，只是让官方已有实现真正生效。
SH="$SRC/drivers/kernelsu/feature/selinux_hide.c"
HK="$SRC/security/selinux/hooks.c"
python3 - "$SH" "$HK" <<'PYEOF'
import sys
sh, hk = sys.argv[1], sys.argv[2]

# --- 1) selinux_hide.c: 导出 wrapper 指向官方 my_setprocattr ---
s = open(sh).read()
assert "my_setprocattr(" in s, "selinux_hide.c 里找不到 my_setprocattr"
assert "int ksu_backup_setprocattr(" not in s, "ksu_backup_setprocattr 已存在"
g5 = r"""
/* ---- 编译期 setprocattr 入口（CONFIG_KSU_SUSFS=y, G5 / 上游 #3981）---------
 * built-in + G2 早退下 ksu_lsm_hook(selinux_setprocattr_hook) 从未注册，
 * 含 #3981 修复的 my_setprocattr 是死代码。这里编译期导出同一实现给
 * SUSFS 的 handle_selinux_setprocattr 在 app-uid 分支调用，堵住「策略属性
 * 写入」侧信道。两个 goto call_orig 分支（uid<10000 / name!="current"）
 * 因 handle 的前置判断而不会走到，不触碰未注册的 .original。
 * ------------------------------------------------------------------------ */
int ksu_backup_setprocattr(const char *name, void *value, size_t size)
{
    return my_setprocattr(name, value, size);
}
"""
s = s.rstrip() + "\n" + g5
open(sh, "w").write(s)
print("    selinux_hide.c: 导出 ksu_backup_setprocattr -> my_setprocattr")

# --- 2) hooks.c: handle 的 app-uid 分支从 SUSFS 实现改到官方 wrapper ---
t = open(hk).read()
old_decl = "static int handle_selinux_setprocattr(const char *name, void *value, size_t size)"
new_decl = "extern int ksu_backup_setprocattr(const char *name, void *value, size_t size);\n\n" + old_decl
assert t.count(old_decl) == 1, f"handle_selinux_setprocattr 定义没匹配上: {t.count(old_decl)}"
t = t.replace(old_decl, new_decl, 1)

old_call = "return susfs_selinux_setprocattr(name, value, size);"
assert t.count(old_call) == 1, f"setprocattr 调用没匹配上: {t.count(old_call)}"
t = t.replace(old_call, "return ksu_backup_setprocattr(name, value, size);", 1)

# 换成官方 wrapper 后，SUSFS 这两个 static 函数变成死代码；
# 项目开 -Werror,-Wunused-function，必须标记为 maybe_unused 才能编过。
# lsm_setattr 的唯一调用者就是 setprocattr，会被连带架空，两个都要标。
for susfs_def in [
    "static int susfs_selinux_setprocattr(const char *name, void *value, size_t size)",
    "static int susfs_selinux_lsm_setattr(u64 attr, void *value, size_t size)",
]:
    assert t.count(susfs_def) == 1, f"未找到 SUSFS 定义: {susfs_def}"
    t = t.replace(susfs_def, susfs_def.replace("static int", "static __maybe_unused int"), 1)

open(hk, "w").write(t)
print("    hooks.c: setprocattr app-uid 分支切到官方 #3981 修复")
PYEOF

echo "==> G6 把 inode_setxattr 接回官方 #3996 侧信道修复（G2 早退最后一处遗漏）"
# enable() 的第 6 类动作 ksu_lsm_hook(&selinux_inode_setxattr_hook) 被 G2 早退跳过，
# 官方 my_inode_setxattr（上游 5b6262e8 / #3996，11-14）同样只是编进内核、从未挂上。
# 它和 setprocattr 是同类 live-parse 侧信道：app 写文件 security.selinux label 时，
# my_inode_setxattr 先 security_context_to_sid_live() 校验、ksu 新 type 才查 backup，
# 写原厂 context 时行为与真机一致。缺了它，检测软件写文件 label 即可探知 live policy
# 被改。LKM ko 完整跑了 enable() 所以挂上了，故不过检测。
#
# 难点：my_inode_setxattr 用到两个运行期 kallsyms 解析的原函数指针
# （inode_doinit_with_dentry_fn / selinux_inode_setxattr_hook.original），G2 早退把
# selinux_hide_init_setxattr() 也跳过了 → 这俩是 NULL，直接调会崩。
# 解法：编译期导出 wrapper，内部首次调用时 lazy 补跑官方 selinux_hide_init_setxattr()
# 把指针解析好（该函数在 built-in 下 superblock_init 是 no-op stub，安全），再转调官方
# my_inode_setxattr。hooks.c 侧编译期新增 handle + 替换 LSM_HOOK_INIT 挂载点，
# app-uid + security.selinux 走 wrapper，其余走原生 selinux_inode_setxattr。
# 全程零 kprobe、不改 write_op[]、不写只读数据、不新增功能，只是让官方已有实现生效。
SH="$SRC/drivers/kernelsu/feature/selinux_hide.c"
HK="$SRC/security/selinux/hooks.c"
python3 - "$SH" "$HK" <<'PYEOF'
import sys
sh, hk = sys.argv[1], sys.argv[2]

# --- 1) selinux_hide.c: 导出 wrapper（lazy 初始化原函数指针 -> 官方 my_inode_setxattr）---
s = open(sh).read()
assert "int ksu_backup_inode_setxattr(" not in s, "ksu_backup_inode_setxattr 已存在"
assert s.count("static int selinux_hide_init_setxattr()") == 1, "init_setxattr 没匹配上"
g6 = r"""
/* ---- 编译期 inode_setxattr 入口（CONFIG_KSU_SUSFS=y, G6 / 上游 #3996）--------
 * built-in + G2 早退下 ksu_lsm_hook(selinux_inode_setxattr_hook) 从未注册，
 * 含 live-parse 修复的 my_inode_setxattr 是死代码。这里编译期导出同一实现给
 * hooks.c 的 handle_selinux_inode_setxattr 在 app-uid 分支调用，堵住文件 label
 * 写入侧信道。my_inode_setxattr 依赖两个 kallsyms 解析的原函数指针，G2 早退
 * 跳过了 selinux_hide_init_setxattr() 故为 NULL —— 首次进入时 lazy 补跑官方
 * 初始化（built-in 下 superblock_init 是 no-op stub）解析好再转调。
 * ------------------------------------------------------------------------ */
static bool ksu_backup_inode_setxattr_ready __read_mostly = false;
int ksu_backup_inode_setxattr(void *idmap, struct dentry *dentry, const char *name,
                              const void *value, size_t size, int flags)
{
    if (likely(!ksu_backup_inode_setxattr_ready)) {
        if (selinux_hide_init_setxattr())
            return -ENOENT;   /* 原函数指针解析失败：不接管，交回调用方走原生 */
        WRITE_ONCE(ksu_backup_inode_setxattr_ready, true);
    }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    return my_inode_setxattr((struct mnt_idmap *)idmap, dentry, name, value, size, flags);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
    return my_inode_setxattr((struct user_namespace *)idmap, dentry, name, value, size, flags);
#else
    return my_inode_setxattr(dentry, name, value, size, flags);
#endif
}
"""
s = s.rstrip() + "\n" + g6
open(sh, "w").write(s)
print("    selinux_hide.c: 导出 ksu_backup_inode_setxattr -> my_inode_setxattr (lazy init)")

# --- 2) hooks.c: 新增 handle + 替换 inode_setxattr 挂载点 ---
t = open(hk).read()
anchor = "/* ---- G6: inode_setxattr 编译期 handle（CONFIG_KSU_SUSFS）---- */"
assert anchor not in t, "G6 handle 已存在"

# handle 插在 selinux_hooks[] 定义之前（用挂载点所在行做锚）
mount = "\tLSM_HOOK_INIT(inode_setxattr, selinux_inode_setxattr),"
assert t.count(mount) == 1, f"inode_setxattr 挂载点没匹配上: {t.count(mount)}"

handle = r"""/* G6: hooks.c 未直接 include linux/version.h，这里显式补上，
   否则下面的 LINUX_VERSION_CODE/KERNEL_VERSION 在 -Werror,-Wundef 下报未定义 */
#include <linux/version.h>

extern int ksu_backup_inode_setxattr(void *idmap, struct dentry *dentry, const char *name,
                                      const void *value, size_t size, int flags);

/* G6: app-uid 写 security.selinux 时走官方 #3996 live-parse 修复；
   解析失败(-ENOENT)或非 app/非 SELinux xattr 则回落原生。
   签名必须与 LSM_HOOK_INIT(inode_setxattr) 的函数指针类型完全一致。 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
static int handle_selinux_inode_setxattr(struct mnt_idmap *idmap, struct dentry *dentry, const char *name,
                                         const void *value, size_t size, int flags)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
static int handle_selinux_inode_setxattr(struct user_namespace *idmap, struct dentry *dentry, const char *name,
                                         const void *value, size_t size, int flags)
#else
static int handle_selinux_inode_setxattr(struct dentry *dentry, const char *name,
                                         const void *value, size_t size, int flags)
#endif
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    void *vidmap = idmap;
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
    void *vidmap = idmap;
#endif
    if (likely(current_uid().val >= 10000 && ksu_selinux_hide_running &&
               !strcmp(name, XATTR_NAME_SELINUX))) {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
        int rc = ksu_backup_inode_setxattr(vidmap, dentry, name, value, size, flags);
#else
        int rc = ksu_backup_inode_setxattr(NULL, dentry, name, value, size, flags);
#endif
        if (rc != -ENOENT)
            return rc;
    }
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    return selinux_inode_setxattr(idmap, dentry, name, value, size, flags);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 12, 0)
    return selinux_inode_setxattr(idmap, dentry, name, value, size, flags);
#else
    return selinux_inode_setxattr(dentry, name, value, size, flags);
#endif
}

"""
# 插到 static struct security_hook_list selinux_hooks[] 之前
hk_anchor = "static struct security_hook_list selinux_hooks[]"
assert t.count(hk_anchor) == 1, "selinux_hooks[] 定义没匹配上"
t = t.replace(hk_anchor, handle + hk_anchor, 1)

# 替换挂载点
t = t.replace(mount, "\tLSM_HOOK_INIT(inode_setxattr, handle_selinux_inode_setxattr),", 1)
open(hk, "w").write(t)
print("    hooks.c: inode_setxattr 挂载点切到 G6 handle")
PYEOF

if [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
    echo "==> [upstream-align] 官方 SUSFS 移植（vendor + 官方补丁 + 6.18 适配）"
    bash "$HERE/ci/susfs_upstream.sh" "$SRC" "$HERE"
fi

if ! [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
echo "==> I 阶段1：SUSFS spoof_uname（built-in，proc 接口，零运行期改写）"
cp "$HERE/patches/susfs_uname.c" "$SRC/fs/susfs_uname.c"
cp "$HERE/patches/susfs_uname.h" "$SRC/include/linux/susfs_uname.h"
if ! grep -q 'susfs_uname\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_uname.o\n' >> "$SRC/fs/Makefile"
fi
python3 - "$SRC/kernel/sys.c" <<'PYEOF'
import sys

path = sys.argv[1]
s = open(path).read()

inc = "#include <linux/susfs_uname.h>\n"
if inc not in s:
    anchor = "#include <linux/syscalls.h>\n"
    assert anchor in s, "kernel/sys.c: #include <linux/syscalls.h> 没找到"
    s = s.replace(anchor, anchor + inc, 1)

# newuname / uname 两个系统调用都要挂，glibc 的 uname(2) 走的是后者
for fn in ("SYSCALL_DEFINE1(newuname,", "SYSCALL_DEFINE0(uname,"):
    i = s.find(fn)
    if i < 0:
        print("    sys.c: %s 不存在，跳过" % fn)
        continue
    j = s.find("up_read(&uts_sem);", i)
    assert j > 0, "kernel/sys.c: %s 里没找到 up_read(&uts_sem)" % fn
    j += len("up_read(&uts_sem);")
    if "susfs_spoof_uname" in s[j:j + 80]:
        continue
    s = s[:j] + "\n\tsusfs_spoof_uname(&tmp);" + s[j:]

open(path, "w").write(s)
print("    sys.c: newuname/uname 出口已接 susfs_spoof_uname")
PYEOF

echo "==> J 阶段2：/proc/cmdline 与 /proc/version 伪装"
cp "$HERE/patches/susfs_proc.c" "$SRC/fs/susfs_proc.c"
cp "$HERE/patches/susfs_proc.h" "$SRC/include/linux/susfs_proc.h"
if ! grep -q 'susfs_proc\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_proc.o\n' >> "$SRC/fs/Makefile"
fi
python3 - "$SRC" <<'PYEOF'
import os
import re
import sys

SRC = sys.argv[1]


def inject(rel, fn, call):
    p = os.path.join(SRC, rel)
    s = open(p).read()
    if "susfs_proc.h" not in s:
        i = s.find("#include")
        assert i > 0, rel + ": 没找到 include"
        s = s[:i] + "#include <linux/susfs_proc.h>\n" + s[i:]
    pat = re.compile(r"(static int " + fn + r"\(struct seq_file \*m, void \*v\)\s*\{\n)")
    m = pat.search(s)
    if not m:
        print("    %s: %s 没匹配上，跳过" % (rel, fn))
        return
    s = s[:m.end()] + call + s[m.end():]
    open(p, "w").write(s)
    print("    %s: %s 已注入" % (rel, fn))


inject("fs/proc/cmdline.c", "cmdline_proc_show",
       "\tif (susfs_spoof_cmdline_show(m))\n\t\treturn 0;\n")
inject("fs/proc/version.c", "version_proc_show",
       "\tif (susfs_spoof_version_show(m))\n\t\treturn 0;\n")
# 上游把 cmdline 与 bootconfig 当同一件事处理（GKI 开 CONFIG_BOOT_CONFIG，
# /proc/cmdline 的内容由 bootconfig 生成），这里两处都接
inject("fs/proc/bootconfig.c", "boot_config_proc_show",
       "\tif (susfs_spoof_cmdline_show(m))\n\t\treturn 0;\n")
PYEOF


fi

echo "==> K 阶段3：sus_path（inode 匹配）"
# 头文件两种模式都要（K 阶段会往 stat.c/namei.c 注入 susfs_is_inode_sus_path 的 include）
cp "$HERE/patches/susfs_path.h" "$SRC/include/linux/susfs_path.h"
if ! [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
cp "$HERE/patches/susfs_path.c" "$SRC/fs/susfs_path.c"
if ! grep -q 'susfs_path\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_path.o\n' >> "$SRC/fs/Makefile"
fi
fi
python3 - "$SRC" <<'PYEOF'
import os
import re
import sys

SRC = sys.argv[1]


def add_include(path, header):
    s = open(path).read()
    if header not in s:
        i = s.find("#include")
        assert i > 0, path + ": 没找到 include"
        s = s[:i] + "#include <%s>\n" % header + s[i:]
    return s


# 1) fs/stat.c: vfs_getattr 按 inode 判断（覆盖 stat 隐藏路径本身）
p = os.path.join(SRC, "fs/stat.c")
s = add_include(p, "linux/susfs_path.h")
pat = re.compile(r"(int vfs_getattr\(const struct path \*path, struct kstat \*stat,\s*u32 request_mask, unsigned int query_flags\)\s*\{\n)")
m = pat.search(s)
if not m:
    print("    fs/stat.c: vfs_getattr 没匹配上，跳过")
else:
    s = s[:m.end()] + "\tif (susfs_is_inode_sus_path(d_inode(path->dentry)))\n\t\treturn -ENOENT;\n\n" + s[m.end():]
    open(p, "w").write(s)
    print("    fs/stat.c: vfs_getattr 已注入")

# 2) fs/namei.c: link_path_walk 主循环（覆盖 open/exec 子路径）
p = os.path.join(SRC, "fs/namei.c")
s = add_include(p, "linux/susfs_path.h")
anchor = "\t\tidmap = mnt_idmap(nd->path.mnt);\n\t\terr = may_lookup(idmap, nd);\n"
if anchor not in s:
    print("    fs/namei.c: link_path_walk 注入点没匹配上，跳过")
else:
    block = (
        "\t\t{\n"
        "\t\t\tstruct dentry *sus_dentry = nd->path.dentry;\n"
        "\n"
        "\t\t\tif (sus_dentry->d_inode &&\n"
        "\t\t\t    susfs_is_inode_sus_path(sus_dentry->d_inode))\n"
        "\t\t\t\treturn -ENOENT;\n"
        "\t\t}\n"
        "\n"
    )
    s = s.replace(anchor, block + anchor, 1)
    print("    fs/namei.c: link_path_walk 已注入")
open(p, "w").write(s)

# 3) fs/readdir.c: 4 个 filldir 变体全部按 inode 过滤（对齐上游 5 处钩子里的
#    readdir 部分；上游的 dir_emit 路径在 6.18 不存在）
p = os.path.join(SRC, "fs/readdir.c")
s = add_include(p, "linux/susfs_path.h")

# (回调结构体, filler 函数, 对应 syscall 标记)
variants = [
    ("readdir_callback", "fillonedir", "SYSCALL_DEFINE3(old_readdir,"),
    ("getdents_callback", "filldir", "SYSCALL_DEFINE3(getdents,"),
    ("getdents_callback64", "filldir64", "SYSCALL_DEFINE3(getdents64,"),
    ("compat_readdir_callback", "compat_fillonedir",
     "COMPAT_SYSCALL_DEFINE3(old_readdir,"),
    ("compat_getdents_callback", "compat_filldir",
     "COMPAT_SYSCALL_DEFINE3(getdents,"),
]

filter_block = (
    "\tif (buf->sb) {\n"
    "\t\tstruct inode *sus_inode = ilookup(buf->sb, ino);\n"
    "\n"
    "\t\tif (sus_inode) {\n"
    "\t\t\tbool sus_hidden = susfs_is_inode_sus_path(sus_inode);\n"
    "\n"
    "\t\t\tiput(sus_inode);\n"
    "\t\t\tif (sus_hidden)\n"
    "\t\t\t\treturn true;\n"
    "\t\t}\n"
    "\t}\n\n"
)

for cb, fn, sysmark in variants:
    st = s.find("struct %s {" % cb)
    if st < 0:
        print("    fs/readdir.c: %s 不存在（内核未开 CONFIG_COMPAT？），跳过 %s"
              % (cb, fn))
        continue

    # 回调结构体加 sb 字段（幂等）
    j = s.find("{", st) + 1
    if "struct super_block *sb;" not in s[j:j + 80]:
        s = s[:j] + "\n\tstruct super_block *sb;" + s[j:]

    # syscall 里填 sb
    k = s.find(sysmark)
    if k < 0:
        print("    fs/readdir.c: %s 没找到，%s 跳过填充" % (sysmark, fn))
    else:
        it = s.find("error = iterate_dir(fd_file(f), &buf.ctx);", k)
        if it < 0:
            print("    fs/readdir.c: %s 的 iterate_dir 没找到" % fn)
        elif "buf.sb = fd_file(f)->f_inode->i_sb;" not in s[k:it]:
            s = s[:it] + "buf.sb = fd_file(f)->f_inode->i_sb;\n\t" + s[it:]

    # filler 里按 inode 过滤：插在 container_of 声明之后，保证 buf 已声明
    f = s.find("static bool %s(" % fn)
    if f < 0:
        print("    fs/readdir.c: %s 没找到" % fn)
        continue
    anc = "container_of(ctx, struct %s, ctx);" % cb
    a = s.find(anc, f)
    if a < 0:
        print("    fs/readdir.c: %s 的 buf 声明没匹配上" % fn)
        continue
    a = s.find("\n", a + len(anc)) + 1
    if "ilookup(buf->sb, ino)" in s[a:a + 400]:
        print("    fs/readdir.c: %s 已注入过" % fn)
        continue
    s = s[:a] + filter_block + s[a:]
    print("    fs/readdir.c: %s 已注入" % fn)

open(p, "w").write(s)
PYEOF

if ! [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
echo "==> L 阶段4：sus_kstat（伪造 stat 字段）"
cp "$HERE/patches/susfs_kstat.c" "$SRC/fs/susfs_kstat.c"
cp "$HERE/patches/susfs_kstat.h" "$SRC/include/linux/susfs_kstat.h"
if ! grep -q 'susfs_kstat\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_kstat.o\n' >> "$SRC/fs/Makefile"
fi
python3 - "$SRC" <<'PYEOF'
import os
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/stat.c")
s = open(p).read()

if "susfs_kstat.h" not in s:
    i = s.find("#include")
    s = s[:i] + "#include <linux/susfs_kstat.h>\n" + s[i:]

# 改在 vfs_getattr 的出口：先走完正常的 vfs_getattr_nosec（statx 的
# result_mask / mnt_id / attributes 都由它填），再覆盖 sus_kstat 字段。
# 之前插在函数开头直接 return 0，会让 statx 的 result_mask 保持未初始化值。
anchor = "\treturn vfs_getattr_nosec(path, stat, request_mask, query_flags);\n"
if anchor not in s:
    print("    fs/stat.c: vfs_getattr 出口锚点没匹配上，sus_kstat 跳过")
elif "susfs_kstat_override" in s:
    print("    fs/stat.c: sus_kstat 已注入过")
else:
    block = (
        "\tretval = vfs_getattr_nosec(path, stat, request_mask, query_flags);\n"
        "#ifdef CONFIG_KSU_SUSFS\n"
        "\tif (!retval &&\n"
        "\t    susfs_is_inode_sus_kstat(d_backing_inode(path->dentry)))\n"
        "\t\tsusfs_kstat_override(d_backing_inode(path->dentry), stat);\n"
        "#endif\n"
        "\treturn retval;\n"
    )
    s = s.replace(anchor, block, 1)
    print("    fs/stat.c: sus_kstat 已注入（vfs_getattr 出口，保留 statx 掩码）")
open(p, "w").write(s)
PYEOF

echo "==> L1b 阶段4c：sus_kstat 的 inotify/fanotify fdinfo 伪装（对齐上游）"
python3 - "$SRC" <<'PYEOF'
import os
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/notify/fdinfo.c")
s = open(p).read()

if "susfs_kstat.h" not in s:
    i = s.find("#include")
    assert i > 0, "fs/notify/fdinfo.c: 没找到 include"
    s = s[:i] + "#include <linux/susfs_kstat.h>\n" + s[i:]
if "#include <linux/cred.h>" not in s:
    i = s.find("#include")
    assert i > 0, "fs/notify/fdinfo.c: 没找到 include"
    s = s[:i] + "#include <linux/cred.h>\n" + s[i:]

inotify_anchor = ("\tinode = igrab(fsnotify_conn_inode(mark->connector));\n"
                  "\tif (inode) {\n")
inotify_block = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\t\tif (current_uid().val >= 10000) {\n"
    "\t\t\tu64 sus_ino;\n"
    "\t\t\tu32 sus_dev;\n"
    "\n"
    "\t\t\tif (susfs_kstat_get_spoof(inode, &sus_ino, &sus_dev)) {\n"
    "\t\t\t\tseq_printf(m, \"inotify wd:%x ino:%llx sdev:%x mask:%x ignored_mask:0 \",\n"
    "\t\t\t\t\t   inode_mark->wd, sus_ino, sus_dev,\n"
    "\t\t\t\t\t   inotify_mark_user_mask(mark));\n"
    "\t\t\t\tshow_mark_fhandle(m, inode);\n"
    "\t\t\t\tseq_putc(m, '\\n');\n"
    "\t\t\t\tiput(inode);\n"
    "\t\t\t\treturn;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
)
if "susfs_kstat_get_spoof" in s:
    print("    fs/notify/fdinfo.c: 已注入过")
else:
    if inotify_anchor not in s:
        sys.exit("!! fs/notify/fdinfo.c: inotify 锚点没匹配上，终止")
    s = s.replace(inotify_anchor, inotify_anchor + inotify_block, 1)
    print("    fs/notify/fdinfo.c: inotify 已注入")

fanotify_anchor = ("\t\tinode = igrab(fsnotify_conn_inode(mark->connector));\n"
                   "\t\tif (!inode)\n"
                   "\t\t\treturn;\n")
fanotify_block = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\t\tif (current_uid().val >= 10000) {\n"
    "\t\t\tu64 sus_ino;\n"
    "\t\t\tu32 sus_dev;\n"
    "\n"
    "\t\t\tif (susfs_kstat_get_spoof(inode, &sus_ino, &sus_dev)) {\n"
    "\t\t\t\tseq_printf(m, \"fanotify ino:%llx sdev:%x mflags:%x mask:%x ignored_mask:%x \",\n"
    "\t\t\t\t\t   sus_ino, sus_dev, mflags, mark->mask,\n"
    "\t\t\t\t\t   mark->ignore_mask);\n"
    "\t\t\t\tshow_mark_fhandle(m, inode);\n"
    "\t\t\t\tseq_putc(m, '\\n');\n"
    "\t\t\t\tiput(inode);\n"
    "\t\t\t\treturn;\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n"
)
if "fanotify ino:%llx" in s:
    print("    fs/notify/fdinfo.c: fanotify 已注入过")
else:
    if fanotify_anchor not in s:
        sys.exit("!! fs/notify/fdinfo.c: fanotify 锚点没匹配上，终止")
    s = s.replace(fanotify_anchor, fanotify_anchor + fanotify_block, 1)
    print("    fs/notify/fdinfo.c: fanotify 已注入")

open(p, "w").write(s)
PYEOF

echo "==> L2 阶段4b：do_proc_readlink 伪装（/proc/<pid>/fd 的 readlink，对齐上游）"
python3 - "$SRC" <<'PYEOF'
import os
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/proc/base.c")
s = open(p).read()

if "susfs_extra.h" not in s:
    i = s.find("#include")
    assert i > 0, "fs/proc/base.c: 没找到 include"
    s = s[:i] + "#include <linux/susfs_extra.h>\n" + s[i:]

i = s.find("static int do_proc_readlink(")
assert i > 0, "fs/proc/base.c: do_proc_readlink 没找到"
anc = "\tif (!tmp)\n\t\treturn -ENOMEM;\n"
j = s.find(anc, i)
assert j > 0, "fs/proc/base.c: do_proc_readlink 的 tmp 分配锚点没找到"

block = (
    "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
    "\t{\n"
    "\t\tint sus_rl = susfs_open_redirect_readlink(\n"
    "\t\t\td_inode(path->dentry), buffer, buflen);\n"
    "\n"
    "\t\tif (sus_rl >= 0) {\n"
    "\t\t\tkfree(tmp);\n"
    "\t\t\treturn sus_rl;\n"
    "\t\t}\n"
    "\t}\n"
    "#endif\n"
)
if "susfs_open_redirect_readlink" not in s:
    s = s[:j + len(anc)] + block + s[j + len(anc):]
    open(p, "w").write(s)
    print("    fs/proc/base.c: do_proc_readlink 已注入")
else:
    print("    fs/proc/base.c: do_proc_readlink 已注入过")
PYEOF

echo "==> M 阶段5：sus_mount（隐藏挂载点，inode 匹配，改 proc_namespace.c show 函数）"
cp "$HERE/patches/susfs_mount.c" "$SRC/fs/susfs_mount.c"
cp "$HERE/patches/susfs_mount.h" "$SRC/include/linux/susfs_mount.h"
if ! grep -q 'susfs_mount\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_mount.o\n' >> "$SRC/fs/Makefile"
fi
python3 - "$SRC" <<'PYEOF'
import os
import re
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/proc_namespace.c")
s = open(p).read()

if "susfs_mount.h" not in s:
    i = s.find("#include")
    assert i > 0, "proc_namespace.c: 没找到 include"
    s = s[:i] + "#include <linux/susfs_mount.h>\n" + s[i:]
if "#include <linux/cred.h>" not in s:
    # current_uid() 需要 cred.h；proc_namespace.c 自身不一定带
    brid_anchor = "#include <linux/sched/task.h>\n"
    assert brid_anchor in s, "proc_namespace.c: 找不到 sched/task.h 锚点"
    s = s.replace(brid_anchor,
                  brid_anchor + "#include <linux/cred.h>\n", 1)

# 在 3 个 show 函数体第一行插判断，命中就整行跳过（return 0）：
#   1) 显式路径列表（/proc/susfs_add_sus_mount）
#   2) 号段式隐藏：KSU 域进程创建的挂载 mnt_id >= 2000000000，
#      对非 KSU 域进程隐藏（对齐上游 DEFAULT_KSU_MNT_ID 方案）
funcs = ["show_vfsmnt", "show_mountinfo", "show_vfsstat"]
for fn in funcs:
    pat = re.compile(r"(static int " + fn + r"\(struct seq_file \*m, struct vfsmount \*mnt\)\s*\{\n)")
    m = pat.search(s)
    if not m:
        sys.exit("!! proc_namespace.c: %s 锚点没匹配上（6.18 源码变了？），终止以免静默漏功能" % fn)
    if "susfs_mount_is_sus_id" in s[m.end():m.end() + 400]:
        print("    proc_namespace.c: %s 已注入过" % fn)
        continue
    block = (
        "\tif (susfs_is_mnt_sus(mnt))\n"
        "\t\treturn 0;\n"
        "\tif (susfs_mount_is_sus_id(real_mount(mnt)->mnt_id) &&\n"
        "\t    susfs_mount_hide_for_non_su() &&\n"
        "\t    current_uid().val >= 10000)\n"
        "\t\treturn 0;\n\n"
    )
    s = s[:m.end()] + block + s[m.end():]
    print("    proc_namespace.c: %s 已注入" % fn)

open(p, "w").write(s)

# ---- fs/namespace.c：KSU 域进程创建的挂载分配号段内 mnt_id ----
p = os.path.join(SRC, "fs/namespace.c")
s = open(p).read()

if "susfs_mount.h" not in s:
    i = s.find("#include")
    assert i > 0, "namespace.c: 没找到 include"
    s = s[:i] + "#include <linux/susfs_mount.h>\n" + s[i:]
if "DEFAULT_KSU_MNT_ID" not in s:
    # 同上：必须放在 types.h 可达的 include 之后
    # 常量与标记位对齐上游 susfs_def.h
    brid_anchor = "#include <linux/sched/task.h>\n"
    assert brid_anchor in s, "namespace.c: 找不到 sched/task.h 锚点"
    s = s.replace(brid_anchor,
                  brid_anchor
                  + "extern bool susfs_is_current_ksu_domain(void);\n"
                  + "#ifndef DEFAULT_KSU_MNT_ID\n"
                  + "#define DEFAULT_KSU_MNT_ID 2000000000\n"
                  + "#endif\n"
                  + "#ifndef DEFAULT_KSU_MNT_GROUP_ID\n"
                  + "#define DEFAULT_KSU_MNT_GROUP_ID 200000\n"
                  + "#endif\n"
                  + "#ifndef VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT\n"
                  + "#define VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT 0x80000000u\n"
                  + "#endif\n"
                  + "#ifndef CL_COPY_MNT_NS\n"
                  + "#define CL_COPY_MNT_NS BIT(25) /* 对齐上游：copy_mnt_ns() 专用标记 */\n"
                  + "#endif\n", 1)

# 1) mnt_alloc_id：号段 id 用独立计数器，**不登记进 mnt_id_xa**
#    上游 6.12 用的是独立 IDA 范围（不动 mnt_id_ida）；6.18 这里同理，不碰 xa。
#    绝不能在 xa_lock 内做 GFP_KERNEL 分配（曾经的做法）——见下方注释。
alloc_anchor = ("static int mnt_alloc_id(struct mount *mnt)\n"
                "{\n"
                "\tint res;\n"
                "\n"
                "\txa_lock(&mnt_id_xa);\n")
if alloc_anchor not in s:
    sys.exit("!! namespace.c: mnt_alloc_id 锚点没匹配上，终止")
if "susfs_mnt_alloc_id_range" not in s:
    alloc_block = (
        "#ifdef CONFIG_KSU_SUSFS\n"
        "/* 号段挂载的 mnt_id 用独立计数器分配，不登记进 mnt_id_xa（对齐上游：\n"
        " * 上游用独立 IDA 范围，完全不碰 mnt_id_ida）。\n"
        " *\n"
        " * 绝不要在这里调用 __xa_alloc(GFP_KERNEL)：copy_mnt_ns() 是持有\n"
        " * namespace_sem 时走到这儿的，而高号段首次分配需要在 index≈2e9 处\n"
        " * 新建 xarray 节点 → 进入内存回收 → 与 unshare 互锁，全系统应用启动\n"
        " * 卡死在 D 状态（build#107/#109 实测现象：copy_mnt_ns 里 wchan 卡住）。\n"
        " * mnt_free_id() 见到 KSU_UNSHARED 标记即跳过回收，配对正确。 */\n"
        "static int susfs_mnt_alloc_id_range(struct mount *mnt)\n"
        "{\n"
        "\tint id = susfs_mount_next_id();\n"
        "\n"
        "\tif (id < 0)\n"
        "\t\treturn id;\n"
        "\tmnt->mnt_id = id;\n"
        "\tmnt->mnt_id_unique = ++mnt_id_ctr;\n"
        "\tmnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;\n"
        "\treturn 0;\n"
        "}\n"
        "#endif\n"
        "\n"
        "static int mnt_alloc_id(struct mount *mnt)\n"
        "{\n"
        "\tint res;\n"
        "\n"
        "#ifdef CONFIG_KSU_SUSFS\n"
        "\tif (susfs_is_current_ksu_domain())\n"
        "\t\treturn susfs_mnt_alloc_id_range(mnt);\n"
        "#endif\n"
        "\txa_lock(&mnt_id_xa);\n"
    )
    s = s.replace(alloc_anchor, alloc_block, 1)
    print("    namespace.c: mnt_alloc_id 已注入")
else:
    print("    namespace.c: mnt_alloc_id 已注入过")

# 2) mnt_free_id：完全对齐上游
#    只有 unshare 时复用 old->mnt_id 的挂载（打了 KSU_UNSHARED 标记）没登记进
#    xa，才跳过回收；其它号段 id 是 __xa_alloc 正常分配的，照常 xa_erase。
free_anchor = ("static void mnt_free_id(struct mount *mnt)\n"
               "{\n"
               "\txa_erase(&mnt_id_xa, mnt->mnt_id);\n"
               "}\n")
if free_anchor not in s:
    sys.exit("!! namespace.c: mnt_free_id 锚点没匹配上，终止")
if "if (unlikely(mnt->mnt.mnt_flags & VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT))" not in s:
    free_block = (
        "static void mnt_free_id(struct mount *mnt)\n"
        "{\n"
        "#ifdef CONFIG_KSU_SUSFS\n"
        "\tif (unlikely(mnt->mnt.mnt_flags & VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT))\n"
        "\t\treturn;\n"
        "#endif\n"
        "\txa_erase(&mnt_id_xa, mnt->mnt_id);\n"
        "}\n"
    )
    s = s.replace(free_anchor, free_block, 1)
    print("    namespace.c: mnt_free_id 已注入")
else:
    print("    namespace.c: mnt_free_id 已注入过")

# 2b) mnt_alloc_group_id：对齐上游，KSU 域的 peer group id 从号段起分配
group_anchor = "\tint res = ida_alloc_min(&mnt_group_ida, 1, GFP_KERNEL);\n"
if group_anchor not in s:
    sys.exit("!! namespace.c: mnt_alloc_group_id 锚点没匹配上，终止")
if "ida_alloc_min(&mnt_group_ida, DEFAULT_KSU_MNT_GROUP_ID" not in s:
    group_block = (
        "\tint res;\n"
        "\n"
        "#ifdef CONFIG_KSU_SUSFS\n"
        "\tif (susfs_is_current_ksu_domain())\n"
        "\t\tres = ida_alloc_min(&mnt_group_ida, DEFAULT_KSU_MNT_GROUP_ID, GFP_KERNEL);\n"
        "\telse\n"
        "#endif\n"
        "\t\tres = ida_alloc_min(&mnt_group_ida, 1, GFP_KERNEL);\n"
    )
    s = s.replace(group_anchor, group_block, 1)
    print("    namespace.c: mnt_alloc_group_id 已注入")
else:
    print("    namespace.c: mnt_alloc_group_id 已注入过")

# 3) clone_mnt：完全按上游手法
#    - unshare（CL_COPY_MNT_NS）且是 KSU 域：复用 old->mnt_id（对应上游
#      susfs_alloc_unshare_ksu_vfsmnt()），并打 KSU_UNSHARED 标记，
#      mnt_free_id() 见到该标记就不回收（这个 id 没登记进 xa）。
#    - 其它情况克隆号段挂载：新 id 重新分配到号段内（对应上游
#      susfs_alloc_non_unshare_ksu_vfsmnt()）。
#    所有 xa 操作都在 xa_lock 内用 __ 版本，绝不调用会自行加锁的 xa_erase。
clone_head_anchor = ("\tmnt = alloc_vfsmnt(old->mnt_devname);\n"
                     "\tif (!mnt)\n"
                     "\t\treturn ERR_PTR(-ENOMEM);\n")
if clone_head_anchor not in s:
    sys.exit("!! namespace.c: clone_mnt 头部锚点没匹配上，终止")
if "susfs clone mount id" not in s:
    clone_head_block = clone_head_anchor + (
        "#ifdef CONFIG_KSU_SUSFS\n"
        "\t/* susfs clone mount id: 克隆号段挂载时绝不能在 xa_lock 里分配。\n"
        "\t * 先退掉自己在 xa 里的临时 id（只 erase，不分配），再按上游语义：\n"
        "\t *  - CL_COPY_MNT_NS（copy_mnt_ns 建新 namespace）→ 沿用 old->mnt_id；\n"
        "\t *  - 其它（bind mount 等，同一 namespace）→ 取号段新 id，避免同\n"
        "\t *    namespace 内 id 重复。\n"
        "\t * 这些 id 都不在 mnt_id_xa 里，打 KSU_UNSHARED 让 mnt_free_id() 跳过回收。 */\n"
        "\tif (mnt->mnt_id < DEFAULT_KSU_MNT_ID &&\n"
        "\t    old->mnt_id >= DEFAULT_KSU_MNT_ID) {\n"
        "\t\txa_lock(&mnt_id_xa);\n"
        "\t\t__xa_erase(&mnt_id_xa, mnt->mnt_id);\n"
        "\t\txa_unlock(&mnt_id_xa);\n"
        "\t\tif (flag & CL_COPY_MNT_NS) {\n"
        "\t\t\tmnt->mnt_id = old->mnt_id;\n"
        "\t\t} else {\n"
        "\t\t\tint sus_id = susfs_mount_next_id();\n"
        "\n"
        "\t\t\tmnt->mnt_id = sus_id > 0 ? sus_id : old->mnt_id;\n"
        "\t\t}\n"
        "\t\tmnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;\n"
        "\t}\n"
        "#endif\n"
    )
    s = s.replace(clone_head_anchor, clone_head_block, 1)
    print("    namespace.c: clone_mnt 头部已注入")
else:
    print("    namespace.c: clone_mnt 头部已注入过")

# 3b) 在 mnt_flags 复制之后打 KSU_UNSHARED 标记（对齐上游位置）
clone_flag_anchor = "\t\tmnt->mnt_group_id = 0; /* not a peer of original */\n"
if clone_flag_anchor not in s:
    sys.exit("!! namespace.c: clone_mnt mnt_flags 锚点没匹配上，终止")
if "mnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;" not in s:
    s = s.replace(clone_flag_anchor,
                  clone_flag_anchor
                  + "#ifdef CONFIG_KSU_SUSFS\n"
                  + "\tif ((flag & CL_COPY_MNT_NS) && susfs_is_current_ksu_domain())\n"
                  + "\t\tmnt->mnt.mnt_flags |= VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT;\n"
                  + "#endif\n", 1)
    print("    namespace.c: clone_mnt 标记已注入")
else:
    print("    namespace.c: clone_mnt 标记已注入过")

# 3c) copy_mnt_ns：给 copy_tree 加上 CL_COPY_MNT_NS 标记（完全照上游）
copy_ns_anchor = "\tcopy_flags = CL_COPY_UNBINDABLE | CL_EXPIRE;\n"
if copy_ns_anchor not in s:
    sys.exit("!! namespace.c: copy_mnt_ns 锚点没匹配上，终止")
if "copy_flags |= CL_COPY_MNT_NS;" not in s:
    s = s.replace(copy_ns_anchor,
                  copy_ns_anchor
                  + "#ifdef CONFIG_KSU_SUSFS\n"
                  + "\tcopy_flags |= CL_COPY_MNT_NS;\n"
                  + "#endif\n", 1)
    print("    namespace.c: copy_mnt_ns 已注入")
else:
    print("    namespace.c: copy_mnt_ns 已注入过")

# 4) lookup_mnt_in_ns：statmount/listmount 按 unique id 反查挂载时，
#    app 视角下号段挂载当作不存在。
lookup_anchor = ("static struct vfsmount *lookup_mnt_in_ns(u64 id, struct mnt_namespace *ns)\n"
                 "{\n"
                 "\tstruct mount *mnt = mnt_find_id_at(ns, id);\n"
                 "\n"
                 "\tif (!mnt || mnt->mnt_id_unique != id)\n"
                 "\t\treturn NULL;\n"
                 "\n"
                 "\treturn &mnt->mnt;\n"
                 "}\n")
if lookup_anchor not in s:
    sys.exit("!! namespace.c: lookup_mnt_in_ns 锚点没匹配上，终止")
if "susfs_mount_is_sus_id(mnt->mnt_id)" not in s:
    lookup_block = ("static struct vfsmount *lookup_mnt_in_ns(u64 id, struct mnt_namespace *ns)\n"
                    "{\n"
                    "\tstruct mount *mnt = mnt_find_id_at(ns, id);\n"
                    "\n"
                    "\tif (!mnt || mnt->mnt_id_unique != id)\n"
                    "\t\treturn NULL;\n"
                    "#ifdef CONFIG_KSU_SUSFS\n"
                    "\tif (susfs_mount_is_sus_id(mnt->mnt_id) &&\n"
                    "\t    current_uid().val >= 10000)\n"
                    "\t\treturn NULL;\n"
                    "#endif\n"
                    "\n"
                    "\treturn &mnt->mnt;\n"
                    "}\n")
    s = s.replace(lookup_anchor, lookup_block, 1)
    print("    namespace.c: lookup_mnt_in_ns 已注入")
else:
    print("    namespace.c: lookup_mnt_in_ns 已注入过")

# 5) do_listmount：遍历时跳过号段挂载（app 视角）
list_anchor = ("\t\tif (r->mnt_id_unique == mnt_parent_id)\n"
               "\t\t\tcontinue;\n")
if list_anchor not in s:
    sys.exit("!! namespace.c: do_listmount 锚点没匹配上，终止")
if "susfs_mount_is_sus_id(r->mnt_id)" not in s:
    list_block = list_anchor + (
        "#ifdef CONFIG_KSU_SUSFS\n"
        "\t\tif (susfs_mount_is_sus_id(r->mnt_id) &&\n"
        "\t\t    current_uid().val >= 10000)\n"
        "\t\t\tcontinue;\n"
        "#endif\n"
    )
    s = s.replace(list_anchor, list_block, 1)
    print("    namespace.c: do_listmount 已注入")
else:
    print("    namespace.c: do_listmount 已注入过")

open(p, "w").write(s)
PYEOF

echo "==> N 阶段6：sus_map（隐藏 /proc/<pid>/maps 映射，改 task_mmu.c show_map_vma/show_smap）"
cp "$HERE/patches/susfs_maps.c" "$SRC/fs/susfs_maps.c"
cp "$HERE/patches/susfs_maps.h" "$SRC/include/linux/susfs_maps.h"
if ! grep -q 'susfs_maps\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_maps.o\n' >> "$SRC/fs/Makefile"
fi
python3 - "$SRC" <<'PYEOF'
import os
import re
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/proc/task_mmu.c")
s = open(p).read()

if "susfs_maps.h" not in s:
    i = s.find("#include")
    assert i > 0, "task_mmu.c: 没找到 include"
    s = s[:i] + "#include <linux/susfs_maps.h>\n" + s[i:]

# 1) show_map_vma：在 if (vma->vm_file) 块内、dev = 之前插判断。
#    用 file_inode(vma->vm_file)（底层真实 inode），和加入时 d_backing_inode 一致。
#    6.18 这里原本是 const struct inode *inode = file_user_inode(vma->vm_file);
pat = re.compile(
    r"(\tif \(vma->vm_file\) \{\n"
    r"\t\tconst struct inode \*inode = file_user_inode\(vma->vm_file\);\n)"
)
m = pat.search(s)
if not m:
    sys.exit("!! task_mmu.c: show_map_vma 锚点没匹配上（6.18 源码变了？），终止")
else:
    if "susfs_is_inode_sus_map" not in s[m.end():m.end() + 200]:
        # 用 file_inode 而非 m 里那个 inode（后者是 idmapped 视角，和加入时不一致）
        s = s[:m.end()] + (
            "\t\tif (susfs_is_inode_sus_map(file_inode(vma->vm_file)))\n"
            "\t\t\treturn;\n"
        ) + s[m.end():]
        print("    task_mmu.c: show_map_vma 已注入")
    else:
        print("    task_mmu.c: show_map_vma 已注入过")

# 2) show_smap：函数体开头加判断（/proc/<pid>/smaps 单 vma 详情）
pat2 = re.compile(r"(static int show_smap\(struct seq_file \*m, void \*v\)\s*\{\n)")
m2 = pat2.search(s)
if not m2:
    sys.exit("!! task_mmu.c: show_smap 锚点没匹配上（6.18 源码变了？），终止")
else:
    if "susfs_is_inode_sus_map" not in s[m2.end():m2.end() + 200]:
        s = s[:m2.end()] + (
            "\tstruct vm_area_struct *sus_vma = v;\n"
            "\tif (sus_vma->vm_file &&\n"
            "\t    susfs_is_inode_sus_map(file_inode(sus_vma->vm_file)))\n"
            "\t\treturn 0;\n\n"
        ) + s[m2.end():]
        print("    task_mmu.c: show_smap 已注入")
    else:
        print("    task_mmu.c: show_smap 已注入过")

open(p, "w").write(s)
PYEOF

fi

echo "==> O 阶段7：补齐 namei.c sus_path 钩子（覆盖最后一步 open/exec）"
python3 - "$SRC" <<'PYEOF'
import os
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "fs/namei.c")
s = open(p).read()

# fs/namei.c 在 6.18 已 include susfs_path.h（K 阶段的 link_path_walk 注入），
# 这里防御性补一次，避免 K 阶段被跳过时找不到声明。
if "susfs_path.h" not in s:
    i = s.find("#include")
    assert i > 0, "namei.c: 没找到 include"
    s = s[:i] + "#include <linux/susfs_path.h>\n" + s[i:]

count = 0

# 1) lookup_fast RCU 分支：__d_lookup_rcu 之后，命中则 dentry=NULL（RCU 不 dput）
anchor1 = "\t\tdentry = __d_lookup_rcu(parent, &nd->last, &nd->next_seq);\n"
block1 = (
    "\t\tif (dentry && !IS_ERR(dentry) && dentry->d_inode &&\n"
    "\t\t    susfs_is_inode_sus_path(dentry->d_inode))\n"
    "\t\t\tdentry = NULL;  /* RCU: __d_lookup_rcu 未取 dentry 计数，不 dput */\n"
)
if anchor1 in s and "susfs_is_inode_sus_path(dentry->d_inode))\n\t\t\tdentry = NULL;  /* RCU" not in s:
    s = s.replace(anchor1, anchor1 + block1, 1)
    count += 1
    print("    namei.c: lookup_fast RCU 已注入")
else:
    print("    namei.c: lookup_fast RCU 锚点缺失或已注入")

# 2) lookup_fast 非 RCU 分支：__d_lookup 之后，命中则 dput + return NULL
anchor2 = "\t\tdentry = __d_lookup(parent, &nd->last);\n"
block2 = (
    "\t\tif (dentry && !IS_ERR(dentry) && dentry->d_inode &&\n"
    "\t\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\t\tdput(dentry);\n"
    "\t\t\tdentry = NULL;\n"
    "\t\t}\n"
)
if anchor2 in s and block2 not in s:
    s = s.replace(anchor2, anchor2 + block2, 1)
    count += 1
    print("    namei.c: lookup_fast 非 RCU 已注入")
else:
    print("    namei.c: lookup_fast 非 RCU 锚点缺失或已注入")

# 3) __lookup_slow：函数「末尾」那个 return dentry 之前插判断。
#    注意该函数里有两个 `return dentry;`：第一个紧跟 `if (IS_ERR(dentry))`，
#    不能用 find()（会插进错误分支、破坏控制流）。用下一个函数 lookup_slow 作为
#    结束边界，在 [i, k] 区间 rfind 最后一个 return dentry。
i = s.find("static struct dentry *__lookup_slow(const struct qstr *name,")
if i < 0:
    print("    namei.c: __lookup_slow 没找到")
else:
    k = s.find("static struct dentry *lookup_slow(", i)
    assert k > i, "namei.c: 找不到 __lookup_slow 的结束边界 lookup_slow"
    j = s.rfind("\treturn dentry;\n", i, k)
    if j > i:
        block3 = (
            "\tif (dentry && !IS_ERR(dentry) && dentry->d_inode &&\n"
            "\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n"
            "\t\tif (d_in_lookup(dentry))\n"
            "\t\t\td_lookup_done(dentry);\n"
            "\t\tdput(dentry);\n"
            "\t\treturn ERR_PTR(-ENOENT);\n"
            "\t}\n"
        )
        if block3 not in s[max(i, j - 300):j]:
            s = s[:j] + block3 + s[j:]
            count += 1
            print("    namei.c: __lookup_slow 已注入（末尾 return）")
        else:
            print("    namei.c: __lookup_slow 已注入过")
    else:
        print("    namei.c: __lookup_slow 末尾 return 锚点没匹配上")

# 3.5) lookup_dcache：d_lookup 命中但属于 sus_path -> 当作 dcache 未命中，
#      让后续真实 lookup 走 __lookup_slow / lookup_open 的隐藏分支
i = s.find("static struct dentry *lookup_dcache(")
if i < 0:
    print("    namei.c: lookup_dcache 没找到")
else:
    k = s.find("struct dentry *lookup_one_qstr_excl(", i)
    assert k > i, "namei.c: 找不到 lookup_dcache 的结束边界"
    anc = "\tstruct dentry *dentry = d_lookup(dir, name);\n"
    j = s.find(anc, i, k)
    block35 = (
        "\tif (dentry && !IS_ERR(dentry) && dentry->d_inode &&\n"
        "\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n"
        "\t\tdput(dentry);\n"
        "\t\treturn NULL;\n"
        "\t}\n"
    )
    if j > 0 and block35 not in s[i:k]:
        s = s[:j + len(anc)] + block35 + s[j + len(anc):]
        count += 1
        print("    namei.c: lookup_dcache 已注入")
    else:
        print("    namei.c: lookup_dcache 锚点缺失或已注入")

# 3.6) lookup_one_qstr_excl：末尾 return 前隐藏（覆盖 *at / handle 类路径）
i = s.find("struct dentry *lookup_one_qstr_excl(")
if i < 0:
    print("    namei.c: lookup_one_qstr_excl 没找到")
else:
    k = s.find("EXPORT_SYMBOL(lookup_one_qstr_excl);", i)
    assert k > i, "namei.c: 找不到 lookup_one_qstr_excl 的结束边界"
    j = s.rfind("\treturn dentry;\n", i, k)
    block36 = (
        "\tif (d_is_positive(dentry) && dentry->d_inode &&\n"
        "\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n"
        "\t\tdput(dentry);\n"
        "\t\treturn ERR_PTR(-ENOENT);\n"
        "\t}\n"
    )
    if j > i and block36 not in s[i:k]:
        s = s[:j] + block36 + s[j:]
        count += 1
        print("    namei.c: lookup_one_qstr_excl 已注入")
    else:
        print("    namei.c: lookup_one_qstr_excl 锚点缺失或已注入")

# 4) lookup_open：d_lookup(dir, &nd->last) 之后，命中则 dput + ENOENT
anchor4 = "\tdentry = d_lookup(dir, &nd->last);\n"
block4 = (
    "\tif (dentry && !IS_ERR(dentry) && dentry->d_inode &&\n"
    "\t    susfs_is_inode_sus_path(dentry->d_inode)) {\n"
    "\t\tdput(dentry);\n"
    "\t\treturn ERR_PTR(-ENOENT);\n"
    "\t}\n"
)
if anchor4 in s and block4 not in s:
    s = s.replace(anchor4, anchor4 + block4, 1)
    count += 1
    print("    namei.c: lookup_open 已注入")
else:
    print("    namei.c: lookup_open 锚点缺失或已注入")

open(p, "w").write(s)
print("    namei.c: 本次新注入 %d 处" % count)
# 严格校验：4 个注入块必须全部存在于最终文件（覆盖幂等重放场景）。
# 任一缺失说明锚点对不上，明确失败，绝不静默交付缺功能的包。
markers = {
    "lookup_fast RCU":     "dentry = NULL;  /* RCU: __d_lookup_rcu",
    "lookup_fast 非RCU":   "\t\t\tdput(dentry);\n\t\t\tdentry = NULL;\n\t\t}\n",
    "__lookup_slow":       "susfs_is_inode_sus_path(dentry->d_inode)) {\n\t\tif (d_in_lookup(dentry))",
    "lookup_open":         "\t\tdput(dentry);\n\t\treturn ERR_PTR(-ENOENT);\n\t}\n",
    "lookup_dcache":       "\t\tdput(dentry);\n\t\treturn NULL;\n\t}\n",
    "lookup_one_qstr_excl": "d_is_positive(dentry) && dentry->d_inode &&",
}
missing = [name for name, mk in markers.items() if mk not in s]
if missing:
    sys.exit("!! namei.c 注入块缺失: %s（锚点对不上），终止" % ", ".join(missing))
print("    namei.c: %d/%d 注入块校验通过" % (len(markers), len(markers)))
PYEOF

echo "==> P 阶段8：SUSFS reboot-magic 查询 ABI（让管理器/ksu_susfs 识别版本）"
if ! [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
cp "$HERE/patches/susfs_reboot.c" "$SRC/fs/susfs_reboot.c"
cp "$HERE/patches/susfs_reboot.h" "$SRC/include/linux/susfs_reboot.h"
fi
cp "$HERE/patches/susfs_abi.h" "$SRC/include/linux/susfs_abi.h"
if ! [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
if ! grep -q 'susfs_reboot\.o' "$SRC/fs/Makefile"; then
    printf 'obj-$(CONFIG_KSU_SUSFS) += susfs_reboot.o\n' >> "$SRC/fs/Makefile"
fi
fi
python3 - "$SRC" <<'PYEOF'
import os
import sys

SRC = sys.argv[1]
p = os.path.join(SRC, "kernel/reboot.c")
s = open(p).read()

# 1) extern 声明：插在内核已有 "DEFINE_MUTEX(system_transition_mutex);" 之后（6.12/6.18 都有）
anchor = "DEFINE_MUTEX(system_transition_mutex);"
decl = ("\n#ifdef CONFIG_KSU_SUSFS\n"
        "extern int susfs_reboot_handler(int magic1, int magic2, unsigned int cmd,\n"
        "\t\t\t\tvoid __user **arg);\n"
        "#endif\n")
if "susfs_reboot_handler" not in s:
    if anchor not in s:
        sys.exit("!! reboot.c: 找不到 DEFINE_MUTEX(system_transition_mutex)，终止")
    s = s.replace(anchor, anchor + decl, 1)
    print("    reboot.c: extern 声明已注入")
else:
    print("    reboot.c: extern 声明已存在")

# 2) handler 调用：定位 SYSCALL_DEFINE4(reboot 起点，在其函数体内找 'int ret = 0;'
#    插在该行之后。用函数边界 + 严格断言，避免锚点漂移导致静默漏功能。
i = s.find("SYSCALL_DEFINE4(reboot")
if i < 0:
    sys.exit("!! reboot.c: 找不到 SYSCALL_DEFINE4(reboot，终止")
# 函数体起点：从 i 往后找第一个 '{'
b = s.find("{", i)
if b < 0:
    sys.exit("!! reboot.c: 找不到 reboot 函数体起始 '{'，终止")
# 在合理窗口内找 'int ret = 0;'（上游 hunk 锚点）
j = s.find("int ret = 0;", b, b + 400)
if j < 0:
    sys.exit("!! reboot.c: reboot 函数体内找不到 'int ret = 0;'，终止")

call_block = (
    "\n#ifdef CONFIG_KSU_SUSFS\n"
    "\t{\n"
    "\t\tint susfs_ret = susfs_reboot_handler(magic1, magic2, cmd, &arg);\n"
    "\t\tif (!susfs_ret)\n"
    "\t\t\treturn 0;   /* SUSFS query handled */\n"
    "\t}\n"
    "#endif\n"
)
if "susfs_reboot_handler(magic1" in s[j - 200:j + 200] or \
   "susfs_reboot_handler(magic1" in s[j:j + 400]:
    print("    reboot.c: handler 调用已存在")
else:
    # 插在 'int ret = 0;' 这一整行之后
    eol = s.find("\n", j)
    s = s[:eol + 1] + call_block + s[eol + 1:]
    print("    reboot.c: handler 调用已注入（SYSCALL_DEFINE4 reboot）")

open(p, "w").write(s)

# 严格校验：最终文件里两处标记都必须存在
check = open(p).read()
if "extern int susfs_reboot_handler" not in check or \
   "susfs_reboot_handler(magic1, magic2, cmd, &arg)" not in check:
    sys.exit("!! reboot.c: P 阶段注入块校验失败，终止")
print("    reboot.c: P 阶段 2/2 注入块校验通过")
PYEOF

if ! [ "${SUSFS_UPSTREAM:-0}" = "1" ]; then
echo "==> R 阶段：SUSFS extra features（ENABLE_LOG / UID_FILTER / OPEN_REDIRECT）"
cp "$HERE/patches/susfs_extra.c" "$SRC/fs/susfs_extra.c"
cp "$HERE/patches/susfs_extra.h" "$SRC/include/linux/susfs_extra.h"
python3 "$HERE/ci/integrate_extra.py" "$SRC" "$HERE/patches"

echo "==> Q 阶段：SUSFS 符号隐藏（kernel/kallsyms.c s_show，编译期，对齐上游 6.12）"
python3 - "$SRC" <<'PYEOF'
import os, sys
SRC = sys.argv[1]
p = os.path.join(SRC, "kernel/kallsyms.c")
s = open(p).read()

MARK = "SUSFS_HIDE_SYMBOLS"
if MARK in s:
    print("    kallsyms.c: 符号隐藏已注入，跳过")
    sys.exit(0)

# 1) 在 #include "kallsyms_internal.h" 之前插入 helper（仅当开关打开）
inc_anchor = '#include "kallsyms_internal.h"'
if inc_anchor not in s:
    sys.exit("!! kallsyms.c: 找不到 kallsyms_internal.h include，终止")
helper = (
    "#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n"
    "/* SUSFS_HIDE_SYMBOLS: compiled-in prefix filter (zero kprobe), copied\n"
    " * from upstream susfs4ksu 50_add_susfs_in_gki-android16-6.12.patch. */\n"
    "static inline bool susfs_hide_sym_starts_with(const char *str, const char *pfx)\n"
    "{\n"
    "\twhile (*pfx) { if (*str++ != *pfx++) return false; }\n"
    "\treturn true;\n"
    "}\n"
    "#endif\n\n"
)
s = s.replace(inc_anchor, helper + inc_anchor, 1)

# 2) patch s_show 的 else 分支：把裸 seq_printf 换成条件过滤块。
#    锚点用 6.12/6.18 一致的原文（value/iter->type/iter->name）。
orig = (
    "\t} else\n"
    "\t\tseq_printf(m, \"%px %c %s\\n\", value,\n"
    "\t\t\t   iter->type, iter->name);\n"
    "\treturn 0;\n"
)
if orig not in s:
    sys.exit("!! kallsyms.c: s_show else 锚点未命中，终止（拒绝静默漏功能）")
repl = (
    "\t} else\n"
    "#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS\n"
    "\t{\n"
    "\t\tconst char *n = iter->name;\n"
    "\t\tif (susfs_hide_sym_starts_with(n, \"ksu_\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"__ksu_\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"susfs_\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"ksud\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"is_ksu_\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"is_manager_\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"escape_to_\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"setup_selinux\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"track_throne\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"on_post_fs_data\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"try_umount\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"kernelsu\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"__initcall__kmod_kernelsu\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"apply_kernelsu\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"handle_sepolicy\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"getenforce\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"setenforce\") ||\n"
    "\t\t    susfs_hide_sym_starts_with(n, \"is_zygote\"))\n"
    "\t\t\treturn 0;\n"
    "\t\tseq_printf(m, \"%px %c %s\\n\", value,\n"
    "\t\t\t   iter->type, iter->name);\n"
    "\t}\n"
    "#else\n"
    "\t\tseq_printf(m, \"%px %c %s\\n\", value,\n"
    "\t\t\t   iter->type, iter->name);\n"
    "#endif\n"
    "\treturn 0;\n"
)
s = s.replace(orig, repl, 1)
open(p, "w").write(s)

check = open(p).read()
if "susfs_hide_sym_starts_with" not in check or \
   'susfs_hide_sym_starts_with(n, "is_zygote")' not in check:
    sys.exit("!! kallsyms.c: Q 阶段注入块校验失败，终止")
print("    kallsyms.c: 符号隐藏 18 前缀注入完成（编译期 #ifdef）")
PYEOF

fi

echo "==> H 集成完成"
echo "    KSU 分支配置文件: $(ls "$SRC/drivers/kernelsu"/Kbuild "$SRC/drivers/kernelsu"/Makefile 2>/dev/null | tr '\n' ' ')"
echo "    SELinux 补丁命中: $(grep -c 'CONFIG_KSU_SUSFS' "$SRC/security/selinux/status.c" 2>/dev/null || echo 0) 处 status.c"