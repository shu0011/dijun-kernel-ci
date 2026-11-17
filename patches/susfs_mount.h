/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-M: sus_mount（挂载点隐藏）。
 */
#ifndef _LINUX_SUSFS_MOUNT_H
#define _LINUX_SUSFS_MOUNT_H

#include <linux/mount.h>
#include <linux/types.h>

/* true 表示该挂载项需从 /proc/mounts 等隐藏；uid < 10000 恒为 false */
bool susfs_is_mnt_sus(const struct vfsmount *mnt);

/* 官方 ksu_susfs ABI 设置入口 */
int susfs_mount_abi_add(const char *path);
void susfs_mount_abi_set_enabled(bool enabled);

/* ---- 号段式隐藏（对齐上游 DEFAULT_KSU_MNT_ID 方案）----
 * KSU 域进程创建的挂载会拿到 SUSFS_KSU_MNT_ID_BASE 起始的 mnt_id；
 * /proc/{mounts,mountinfo,mountstats} 对非 KSU 域进程隐藏这些号段。 */
#define SUSFS_KSU_MNT_ID_BASE 2000000000
#define SUSFS_KSU_MNT_ID_MAX  1000000	/* 号段容量，防止溢出 int */

/* 分配一个号段内的 mnt_id；返回 <= 0 表示号段用尽，调用方退回普通分配 */
int susfs_mount_next_id(void);
bool susfs_mount_is_sus_id(int mnt_id);
/* hide_sus_mnts_for_non_su_procs 开关（默认开，ABI 可关） */
bool susfs_mount_hide_for_non_su(void);

#endif /* _LINUX_SUSFS_MOUNT_H */
