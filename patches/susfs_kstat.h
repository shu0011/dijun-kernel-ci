/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-4: sus_kstat（伪造指定 inode 的 stat 字段）。
 */
#ifndef _LINUX_SUSFS_KSTAT_H
#define _LINUX_SUSFS_KSTAT_H

#include <linux/fs.h>
#include <linux/stat.h>
#include <linux/types.h>

/* true 表示该 inode 需要伪造 stat；uid < 10000 恒为 false */
bool susfs_is_inode_sus_kstat(struct inode *inode);

/* 就地覆盖 stat 的 size / blocks（可选 mode） */
void susfs_kstat_override(struct inode *inode, struct kstat *stat);

#endif /* _LINUX_SUSFS_KSTAT_H */
