/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-3: sus_path（inode 级匹配，与上游 susfs4ksu 一致）。
 */
#ifndef _LINUX_SUSFS_PATH_H
#define _LINUX_SUSFS_PATH_H

#include <linux/fs.h>
#include <linux/types.h>

struct dentry;

/* true 表示该 inode 属于被隐藏的路径；uid < 10000 恒为 false */
bool susfs_is_inode_sus_path(struct inode *inode);

/* Plan A：按 dentry 名字链判定 '.../Android/(data|media)/<pkg>'。
 * Android FUSE 给这些目录的 i_ino 是 0，per-inode flag 永远看不到，
 * 因此 app data 目录必须用名字判定，不能用 inode 身份。 */
bool susfs_is_vold_hidden_dentry(const struct dentry *dentry);

/* true 表示 dentry 就是 '.../Android/(data|media)' 目录本身（readdir 用） */
bool susfs_is_vold_root_dir(const struct dentry *dentry);

/* readdir：按名字判断该 dirent 是否要隐藏（name 不保证 NUL 结尾） */
bool susfs_should_hide_vold_name(const char *name, int namlen);

/* namei/stat 钩子的统一入口：普通 sus_path 或 app data 名字规则命中即隐藏 */
static inline bool susfs_is_hidden_dentry(const struct dentry *dentry)
{
	struct inode *inode;

	if (!dentry)
		return false;
	inode = d_inode(dentry);
	if (inode && susfs_is_inode_sus_path(inode))
		return true;
	return susfs_is_vold_hidden_dentry(dentry);
}

/* 官方 ksu_susfs CMD_SUSFS_ADD_SUS_PATH ABI 的设置入口（root-only caller）。
 * 返回 0 成功，负 errno 失败。语义与 /proc/susfs_add_sus_path 写入一致。 */
int susfs_path_abi_add(const char *path);

/* 官方 CMD_SUSFS_ADD_SUS_PATH_LOOP：路径可稍后出现/被重建，登记后由定时
 * 任务周期性重试解析并入普通 sus_path 表。路径暂时不存在也返回 0。 */
int susfs_path_abi_add_loop(const char *path);

#endif /* _LINUX_SUSFS_PATH_H */
