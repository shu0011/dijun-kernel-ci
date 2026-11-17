// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS ←→ 6.18 内核的最小桥接层。
 *
 * 只服务 security/selinux/ 下的 SELinux 隐藏补丁，不含 sus_path / sus_mount /
 * open_redirect 那些必须改 VFS 的功能。
 *
 * 补丁里这些符号是 extern，真正的实现在 6.12 的 fs/susfs.c 与 KernelSU 的
 * feature/selinux_hide.c 里。这里给出 6.18 + SukiSU(built-in) 下的等价实现：
 *   - 能工作的：getenforce 伪造（status.c）、selinuxfs 读写拦截、SID 转换
 *   - 暂为空壳：sus_av 规则表（没有 sus_path 就不需要改写 avd）、sus_type 判断
 *   - AVC 日志过滤：static key 默认关闭，打开需要配套的 av 规则表
 */
#include <linux/types.h>
#include <linux/kernel.h>
#include <linux/gfp.h>
#include <linux/init.h>
#include <linux/jump_label.h>
#include <linux/susfs_extra.h>	/* susfs_set_avc_log_spoofing 原型 */

/* KernelSU built-in 后与内核同镜像，直接声明即可 */
#if IS_ENABLED(CONFIG_KSU)
extern bool is_ksu_domain(void);
#else
static inline bool is_ksu_domain(void)
{
	return false;
}
#endif

/* SELinux 内部接口（security/selinux/include/security.h） */
extern int security_context_to_sid(const char *scontext, u32 scontext_len,
				   u32 *sid, gfp_t gfp);

/* 补丁里这些是 extern，定义在本文件；先声明再定义，避免
 * -Wmissing-prototypes 把它们当"没有原型的全局函数"报错。 */
bool susfs_is_current_ksu_domain(void);
bool susfs_is_sus_type_rcu(u32 sid);
void susfs_spoof_avd_allowed_rcu(u32 s_type, u32 t_type, u32 c_type,
				 u32 *avd_allowed);

/* ---- 补丁引用的全局量 ---- */
u32 susfs_ksu_sid __read_mostly;
u32 susfs_priv_app_sid __read_mostly;

DEFINE_STATIC_KEY_FALSE(susfs_is_avc_log_spoofing_enabled);

bool susfs_is_current_ksu_domain(void)
{
	return is_ksu_domain();
}

/*
 * AVC 日志伪装的唯一开关。真正的过滤在 patches/susfs-selinux.patch 的
 * security/selinux/avc.c 里（tsid == ksu_sid 时把上下文改写成 priv_app）。
 * 之前只定义了 static key、没人打开它，导致 CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING
 * 回 err=0 但功能完全不生效。
 */
void susfs_set_avc_log_spoofing(bool enabled)
{
	if (enabled)
		static_branch_enable(&susfs_is_avc_log_spoofing_enabled);
	else
		static_branch_disable(&susfs_is_avc_log_spoofing_enabled);

	pr_info("susfs: avc_log_spoofing %s\n", enabled ? "enabled" : "disabled");
}

/* 没有 sus_path 表，任何 sid 都不算"要伪造的类型" */
bool susfs_is_sus_type_rcu(u32 sid)
{
	(void)sid;
	return false;
}

/* 没有 sus_av 规则表，avd 不需要改写 */
void susfs_spoof_avd_allowed_rcu(u32 s_type, u32 t_type, u32 c_type,
				 u32 *avd_allowed)
{
	(void)s_type;
	(void)t_type;
	(void)c_type;
	(void)avd_allowed;
}

static int __init susfs_bridge_init(void)
{
	static const char ksu_ctx[] = "u:r:ksu:s0";
	static const char priv_app_ctx[] = "u:r:priv_app:s0";
	int err;

	err = security_context_to_sid(ksu_ctx, sizeof(ksu_ctx) - 1,
				      &susfs_ksu_sid, GFP_KERNEL);
	if (err)
		susfs_ksu_sid = 0;

	err = security_context_to_sid(priv_app_ctx, sizeof(priv_app_ctx) - 1,
				      &susfs_priv_app_sid, GFP_KERNEL);
	if (err)
		susfs_priv_app_sid = 0;

	pr_info("susfs: bridge ready (ksu_sid=%u priv_app_sid=%u)\n",
		susfs_ksu_sid, susfs_priv_app_sid);
	return 0;
}
late_initcall(susfs_bridge_init);
