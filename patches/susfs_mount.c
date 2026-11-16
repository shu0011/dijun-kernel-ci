// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-M: sus_mount（built-in，inode 匹配）
 *
 * 隐藏 /proc/mounts、/proc/self/mountinfo、/proc/mountstats 里指定的挂载项。
 * 复用 sus_path 的 inode 指针匹配架构：加入时 kern_path 解析挂载点、取底层
 * inode 并 ihold()；show 函数里对 mnt->mnt_root 的 inode 做指针比较。
 *
 * 与上游 susfs4ksu 的差异：上游按 mnt_id >= 2000000000 号段整体隐藏（要改
 * fs/namespace.c 的 mount ID 分配），本实现用显式 inode 列表，不碰 mount 核心，
 * 零运行期改写，风险更低且更可控。
 *
 * 控制接口：/proc/susfs_add_sus_mount  0600
 *   写绝对路径 -> 解析并加入（重复写幂等）
 *   写 "clear"  -> 清空并 iput
 *   读          -> 每行一个已加入路径
 *
 * 只对 app uid（>= 10000）生效。
 */
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/mount.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs_mount.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_MAX_MOUNTS 64
#define SUSFS_MOUNT_PROC "susfs_add_sus_mount"

struct susfs_mount_entry {
	struct inode *inode;
	char path[PATH_MAX];	/* 仅用于回读展示 */
};

static struct susfs_mount_entry susfs_mounts[SUSFS_MAX_MOUNTS];
static int susfs_mount_count;
static DEFINE_MUTEX(susfs_mount_mutex);

bool susfs_is_mnt_sus(const struct vfsmount *mnt)
{
	int i;
	bool found = false;

	if (!mnt || !mnt->mnt_root)
		return false;
	if (!READ_ONCE(susfs_mount_count))
		return false;
	if (likely(current_uid().val < 10000))
		return false;

	mutex_lock(&susfs_mount_mutex);
	for (i = 0; i < susfs_mount_count; i++) {
		if (susfs_mounts[i].inode == d_backing_inode(mnt->mnt_root)) {
			found = true;
			break;
		}
	}
	mutex_unlock(&susfs_mount_mutex);

	return found;
}

static void susfs_mount_clear(void)
{
	int i;

	mutex_lock(&susfs_mount_mutex);
	for (i = 0; i < susfs_mount_count; i++) {
		if (susfs_mounts[i].inode)
			iput(susfs_mounts[i].inode);
		susfs_mounts[i].inode = NULL;
		susfs_mounts[i].path[0] = '\0';
	}
	susfs_mount_count = 0;
	mutex_unlock(&susfs_mount_mutex);
}

static int susfs_mount_add(const char *path)
{
	struct path p;
	struct inode *inode;
	int i, ret;

	if (path[0] != '/')
		return -EINVAL;

	ret = kern_path(path, 0, &p);
	if (ret)
		return ret;

	inode = d_backing_inode(p.dentry);
	if (!inode) {
		path_put(&p);
		return -ENOENT;
	}

	mutex_lock(&susfs_mount_mutex);
	for (i = 0; i < susfs_mount_count; i++) {
		if (susfs_mounts[i].inode == inode) {
			mutex_unlock(&susfs_mount_mutex);
			path_put(&p);
			return 0;	/* 已存在 */
		}
	}
	if (susfs_mount_count >= SUSFS_MAX_MOUNTS) {
		mutex_unlock(&susfs_mount_mutex);
		path_put(&p);
		return -ENOSPC;
	}

	ihold(inode);
	susfs_mounts[susfs_mount_count].inode = inode;
	strscpy(susfs_mounts[susfs_mount_count].path, path, PATH_MAX);
	susfs_mount_count++;
	mutex_unlock(&susfs_mount_mutex);

	path_put(&p);
	return 0;
}

int susfs_mount_abi_add(const char *path)
{
	return susfs_mount_add(path);
}

/* CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS:
 * 官方按 mnt_id >= 2000000000 号段整体隐藏（依赖改 fs/namespace.c 的 mount ID
 * 分配）；本项目用显式路径列表（/proc/susfs_add_sus_mount）实现等价效果，
 * 没有号段开关。此 setter 仅吸收命令、返回成功，避免官方脚本因 unsupported
 * 报错；实际隐藏由路径列表负责。 */
void susfs_mount_abi_set_enabled(bool enabled)
{
	/* no-op: path-list based implementation has no global id-range toggle */
	(void)enabled;
}

static ssize_t susfs_mount_write(struct file *file, const char __user *ubuf,
				 size_t count, loff_t *ppos)
{
	char *kbuf;
	size_t len;
	int ret;

	if (!count || count > PATH_MAX)
		return -EINVAL;

	kbuf = memdup_user_nul(ubuf, count);
	if (IS_ERR(kbuf))
		return PTR_ERR(kbuf);

	len = strnlen(kbuf, count);
	while (len && (kbuf[len - 1] == '\n' || kbuf[len - 1] == '\r' ||
		       kbuf[len - 1] == ' ' || kbuf[len - 1] == '\t'))
		kbuf[--len] = '\0';

	if (!len) {
		kfree(kbuf);
		return -EINVAL;
	}

	if (!strcmp(kbuf, "clear")) {
		susfs_mount_clear();
		kfree(kbuf);
		return count;
	}

	ret = susfs_mount_add(kbuf);
	kfree(kbuf);

	return ret ? ret : count;
}

static ssize_t susfs_mount_read(struct file *file, char __user *ubuf,
				size_t count, loff_t *ppos)
{
	char *out;
	size_t used = 0;
	int i, n;

	if (*ppos)
		return 0;

	out = kmalloc(PAGE_SIZE, GFP_KERNEL);
	if (!out)
		return -ENOMEM;

	mutex_lock(&susfs_mount_mutex);
	for (i = 0; i < susfs_mount_count; i++) {
		n = scnprintf(out + used, PAGE_SIZE - used, "%s\n",
			      susfs_mounts[i].path);
		if (n <= 0)
			break;
		used += n;
		if (PAGE_SIZE - used < PATH_MAX)
			break;
	}
	mutex_unlock(&susfs_mount_mutex);

	if (used > count)
		used = count;
	if (copy_to_user(ubuf, out, used)) {
		kfree(out);
		return -EFAULT;
	}

	kfree(out);
	*ppos += used;
	return used;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops susfs_mount_fops = {
	.proc_read  = susfs_mount_read,
	.proc_write = susfs_mount_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_mount_fops = {
	.read  = susfs_mount_read,
	.write = susfs_mount_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_mount_init(void)
{
	if (!proc_create(SUSFS_MOUNT_PROC, 0600, NULL, &susfs_mount_fops))
		return -ENOMEM;

	pr_info("susfs: sus_mount ready (/proc/%s)\n", SUSFS_MOUNT_PROC);
	return 0;
}
device_initcall(susfs_mount_init);
