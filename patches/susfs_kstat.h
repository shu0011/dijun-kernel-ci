/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-4: sus_kstat（伪造指定 inode 的完整 stat 字段）。
 */
#ifndef _LINUX_SUSFS_KSTAT_H
#define _LINUX_SUSFS_KSTAT_H

#include <linux/fs.h>
#include <linux/stat.h>
#include <linux/types.h>

struct susfs_abi_kstat;

/* true 表示该 inode 需要伪造 stat；uid < 10000 恒为 false */
bool susfs_is_inode_sus_kstat(struct inode *inode);

/* 就地覆盖 stat 的 ino/dev/nlink/size/blocks/blksize/atime/mtime/ctime */
void susfs_kstat_override(struct inode *inode, struct kstat *stat);

/* inotify/fanotify 的 fdinfo 用：取该 inode 的伪装 ino/dev。
 * 返回 true 表示命中；uid 判断由调用方负责。 */
bool susfs_kstat_get_spoof(struct inode *inode, u64 *ino, u32 *dev);

/* 官方 ksu_susfs CMD_SUSFS_ADD_SUS_KSTAT / UPDATE / STATICALLY ABI 设置入口。
 * ADD/UPDATE 以当前真实 stat 为快照；STATICALLY 采用载荷里的全部数值字段。 */
int susfs_kstat_abi_add(const char *path, const struct susfs_abi_kstat *info);

#endif /* _LINUX_SUSFS_KSTAT_H */
