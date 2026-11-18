// SPDX-License-Identifier: GPL-2.0
/*
 * upstream-align 分支：SUSFS 的 rebake ABI 分发 + 少量 SukiSU 胶水
 *
 * 功能实体**全部**来自 patches/upstream/fs/susfs.c（官方 v2.4.0），本文件只补
 * SukiSU-Nova 上缺的三样东西：
 *   1) reboot magic → CMD_SUSFS_* 的分发（对照官方 KernelSU/supercall/dispatch.c）
 *   2) susfs_is_current_ksu_domain()
 *   3) 官方 susfs_def.h 里三个 TIF 闸门的等价实现
 *   4) susfs_init() 的调用点（官方由 KernelSU 调）
 *
 * ksu_cred / setup_selinux 直接用 SukiSU 已导出的实现，不重复造。
 */
#include <linux/cred.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/susfs.h>
#include <linux/susfs_abi.h>
#include <linux/uidgid.h>

/* SukiSU 已提供（kernel/core/init.c / kernel/selinux/selinux.c） */
extern struct cred *ksu_cred;
extern bool is_ksu_domain(void);
/* kernel/policy/allowlist.c：该 uid 是否在"要 umount 模块"的名单里
 * （已经排除了管理器自身与已授权 su 的应用）*/
extern bool ksu_uid_should_umount(uid_t uid);

/* 6.18 -Werror,-Wmissing-prototypes：本文件的全局函数需要定义侧原型。
 * 前两个官方头文件可能已声明（兼容重复声明无害），reboot_handler 是本地新增、
 * 无任何头文件声明，必须在这里给出原型。 */
bool susfs_is_current_ksu_domain(void);
bool susfs_ksu_proc_umounted(void);
int susfs_reboot_handler(int magic1, int magic2, unsigned int cmd,
			 void __user **arg);

bool susfs_is_current_ksu_domain(void)
{
	return is_ksu_domain();
}

/*
 * 官方 susfs_def.h 用 TIF_PROC_UMOUNTED / TIF_PROC_NO_SU 三个线程标志做闸门，
 * 这些标志由 KernelSU-Next 在 exec 时打上，SukiSU-Nova 没有。
 * 这里改成直接问 KSU：语义一致（"这个 app 进程会不会被 umount 模块"），
 * 且同样是进程粒度（fork 后 uid 已确定）。
 */
bool susfs_ksu_proc_umounted(void)
{
	uid_t uid = current_uid().val % 100000;

	if (uid < 10000)
		return false;
	if (susfs_is_current_ksu_domain())
		return false;
	/* 官方 TIF_PROC_UMOUNTED 对 isolated 进程（app zygote 90000-98999、
	 * classic isolated 99000-99999）无条件打标；这里补上同样的语义，
	 * 否则 Play Integrity / Authenticator 这类在 isolated 进程里做检测的
	 * 应用会看到 mountinfo 被过滤、而 fdinfo/__lookup_mnt 仍走未 umount 分支。 */
	if (uid >= 90000 && uid <= 99999)
		return true;
	return ksu_uid_should_umount(uid);
}

/* CMD_SUSFS_* → 官方实现。命令字取值与 ksu_susfs 工具一致（见 susfs_abi.h）。 */
int susfs_reboot_handler(int magic1, int magic2, unsigned int cmd,
			 void __user **arg)
{
	if (magic1 != (int)SUSFS_ABI_MAGIC1)
		return -EINVAL;
	if (magic2 != (int)SUSFS_ABI_MAGIC2 || current_uid().val != 0)
		return -EINVAL;

	switch (cmd) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	case SUSFS_ABI_CMD_ADD_SUS_PATH:
		susfs_add_sus_path(arg);
		return 0;
	case SUSFS_ABI_CMD_ADD_SUS_PATH_LOOP:
		susfs_add_sus_path_loop(arg);
		return 0;
	case SUSFS_ABI_CMD_SET_SUS_PATH_UID:
		susfs_set_sus_path_uid_filter(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	case SUSFS_ABI_CMD_HIDE_MNTS_NON_SU:
		susfs_set_hide_sus_mnts_for_non_su_procs(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	case SUSFS_ABI_CMD_ADD_SUS_KSTAT:
	case SUSFS_ABI_CMD_ADD_SUS_KSTAT_ST:
		susfs_add_sus_kstat(arg);
		return 0;
	case SUSFS_ABI_CMD_UPDATE_SUS_KSTAT:
		susfs_update_sus_kstat(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	case SUSFS_ABI_CMD_SET_UNAME:
		susfs_set_uname(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	case SUSFS_ABI_CMD_ENABLE_LOG:
		susfs_enable_log(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	case SUSFS_ABI_CMD_SET_CMDLINE:
		susfs_set_cmdline_or_bootconfig(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	case SUSFS_ABI_CMD_ADD_OPEN_REDIRECT:
		susfs_add_open_redirect(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	case SUSFS_ABI_CMD_ADD_SUS_MAP:
		susfs_add_sus_map(arg);
		return 0;
#endif
#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER
	case SUSFS_ABI_CMD_SET_PRIORITY_UID:
		susfs_set_priority_uid_filter(arg);
		return 0;
#endif
	case SUSFS_ABI_CMD_ENABLE_AVC_SPOOF:
		susfs_set_avc_log_spoofing(arg);
		return 0;
	case SUSFS_ABI_CMD_SHOW_FEATURES:
		susfs_get_enabled_features(arg);
		return 0;
	case SUSFS_ABI_CMD_SHOW_VARIANT:
		susfs_show_variant(arg);
		return 0;
	case SUSFS_ABI_CMD_SHOW_VERSION:
		susfs_show_version(arg);
		return 0;
	default:
		return -EINVAL;
	}
}

static int __init susfs_upstream_init(void)
{
	might_sleep();
	susfs_init();
	pr_info("susfs: upstream v2.4.0 initialised (KSU glue by dijun)\n");
	return 0;
}
late_initcall(susfs_upstream_init);
