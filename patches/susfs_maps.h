/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-N: sus_map（/proc/<pid>/maps 映射隐藏）。
 */
#ifndef _LINUX_SUSFS_MAPS_H
#define _LINUX_SUSFS_MAPS_H

#include <linux/fs.h>
#include <linux/types.h>

/* true 表示该 inode 的映射需从 maps/smaps 隐藏；uid < 10000 恒为 false */
bool susfs_is_inode_sus_map(const struct inode *inode);

/* 官方 ksu_susfs CMD_SUSFS_ADD_SUS_MAP ABI 设置入口 */
int susfs_map_abi_add(const char *path);

#endif /* _LINUX_SUSFS_MAPS_H */
