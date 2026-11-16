/* SPDX-License-Identifier: GPL-2.0 */
/*
 * SUSFS stage-1: spoof_uname.
 *
 * 参考实现是 LKM 版（inforcqb/susfs4ksu-lkm，分支 main@f95ae4c）的
 * spoof_uname 一层；这里是 built-in 版本，零运行期代码改写：
 * 只在 kernel/sys.c 的 newuname/uname 出口处调用一次。
 */
#ifndef _LINUX_SUSFS_UNAME_H
#define _LINUX_SUSFS_UNAME_H

#include <linux/types.h>
#include <linux/utsname.h>

/* 若未启用伪装则原样返回，调用方可无条件调用 */
void susfs_spoof_uname(struct new_utsname *u);
bool susfs_is_uname_spoofed(void);

/* 官方 ksu_susfs CMD_SUSFS_SET_UNAME ABI 设置入口。
 * release/version 为空串时表示不改该字段；两者皆空则关闭伪装。 */
void susfs_uname_abi_set(const char *release, const char *version);

#endif /* _LINUX_SUSFS_UNAME_H */
