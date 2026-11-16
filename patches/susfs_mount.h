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

#endif /* _LINUX_SUSFS_MOUNT_H */
