/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-3: sus_path（inode 级匹配，与上游 susfs4ksu 一致）。
 */
#ifndef _LINUX_SUSFS_PATH_H
#define _LINUX_SUSFS_PATH_H

#include <linux/fs.h>
#include <linux/types.h>

/* true 表示该 inode 属于被隐藏的路径；uid < 10000 恒为 false */
bool susfs_is_inode_sus_path(struct inode *inode);

/* 官方 ksu_susfs CMD_SUSFS_ADD_SUS_PATH ABI 的设置入口（root-only caller）。
 * 返回 0 成功，负 errno 失败。语义与 /proc/susfs_add_sus_path 写入一致。 */
int susfs_path_abi_add(const char *path);

/* 官方 CMD_SUSFS_ADD_SUS_PATH_LOOP：路径可稍后出现/被重建，登记后由定时
 * 任务周期性重试解析并入普通 sus_path 表。路径暂时不存在也返回 0。 */
int susfs_path_abi_add_loop(const char *path);

#endif /* _LINUX_SUSFS_PATH_H */
