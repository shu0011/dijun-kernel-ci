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
	bool "SUSFS (SELinux hiding only)"
	depends on KSU
	default y
	help
	  SUSFS 的 SELinux 隐藏：伪造 getenforce 返回值、拦截 /sys/fs/selinux
	  读写路径、过滤 AVC 日志里的 ksu 痕迹。不含 sus_path / sus_mount /
	  open_redirect 这些必须改 VFS 的功能。

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

echo "==> H 集成完成"
echo "    KSU 分支配置文件: $(ls "$SRC/drivers/kernelsu"/Kbuild "$SRC/drivers/kernelsu"/Makefile 2>/dev/null | tr '\n' ' ')"
echo "    SELinux 补丁命中: $(grep -c 'CONFIG_KSU_SUSFS' "$SRC/security/selinux/status.c" 2>/dev/null || echo 0) 处 status.c"

