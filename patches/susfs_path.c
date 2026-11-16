// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-3: sus_path（built-in，inode 匹配）
 *
 * 与上游 susfs4ksu 一致：加入路径时解析成 inode 并 igrab()，之后所有判断都是
 * 指针比较（susfs_is_inode_sus_path），因此硬链接 / bind mount / 相对路径
 * 这些绕过路径字符串的手段都无效。
 *
 * 控制接口：/proc/susfs_add_sus_path  0600
 *   写绝对路径 -> 解析并加入（重复写幂等）
 *   写 "clear" -> 清空并 iput
 *   读         -> 每行一个已加入路径（仅用于查看，不参与匹配）
 *
 * 只对 app uid（>= 10000）生效：系统进程若被隐藏，开机阶段会找不到 /data/adb 而崩。
 */
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs_path.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_MAX_PATHS 64
#define SUSFS_PATH_PROC "susfs_add_sus_path"

struct susfs_path_entry {
	struct inode *inode;
	char path[PATH_MAX];	/* 仅用于回读展示 */
};

static struct susfs_path_entry susfs_paths[SUSFS_MAX_PATHS];
static int susfs_path_count;
static DEFINE_MUTEX(susfs_path_mutex);

bool susfs_is_inode_sus_path(struct inode *inode)
{
	int i;
	bool found = false;

	if (!inode || !READ_ONCE(susfs_path_count))
		return false;

	if (likely(current_uid().val < 10000))
		return false;

	mutex_lock(&susfs_path_mutex);
	for (i = 0; i < susfs_path_count; i++) {
		if (susfs_paths[i].inode == inode) {
			found = true;
			break;
		}
	}
	mutex_unlock(&susfs_path_mutex);

	return found;
}

static void susfs_path_clear(void)
{
	int i;

	mutex_lock(&susfs_path_mutex);
	for (i = 0; i < susfs_path_count; i++) {
		if (susfs_paths[i].inode)
			iput(susfs_paths[i].inode);
		susfs_paths[i].inode = NULL;
		susfs_paths[i].path[0] = '\0';
	}
	susfs_path_count = 0;
	mutex_unlock(&susfs_path_mutex);
}

static int susfs_path_add(const char *path)
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

	mutex_lock(&susfs_path_mutex);
	for (i = 0; i < susfs_path_count; i++) {
		if (susfs_paths[i].inode == inode) {
			mutex_unlock(&susfs_path_mutex);
			path_put(&p);
			return 0;	/* 已存在 */
		}
	}
	if (susfs_path_count >= SUSFS_MAX_PATHS) {
		mutex_unlock(&susfs_path_mutex);
		path_put(&p);
		return -ENOSPC;
	}

	ihold(inode);
	susfs_paths[susfs_path_count].inode = inode;
	strscpy(susfs_paths[susfs_path_count].path, path, PATH_MAX);
	susfs_path_count++;
	mutex_unlock(&susfs_path_mutex);

	path_put(&p);
	return 0;
}

static ssize_t susfs_path_write(struct file *file, const char __user *ubuf,
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
		susfs_path_clear();
		kfree(kbuf);
		return count;
	}

	ret = susfs_path_add(kbuf);
	kfree(kbuf);

	return ret ? ret : count;
}

static ssize_t susfs_path_read(struct file *file, char __user *ubuf,
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

	mutex_lock(&susfs_path_mutex);
	for (i = 0; i < susfs_path_count; i++) {
		n = scnprintf(out + used, PAGE_SIZE - used, "%s\n",
			      susfs_paths[i].path);
		if (n <= 0)
			break;
		used += n;
		if (PAGE_SIZE - used < PATH_MAX)
			break;
	}
	mutex_unlock(&susfs_path_mutex);

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
static const struct proc_ops susfs_path_fops = {
	.proc_read  = susfs_path_read,
	.proc_write = susfs_path_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_path_fops = {
	.read  = susfs_path_read,
	.write = susfs_path_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_path_init(void)
{
	if (!proc_create(SUSFS_PATH_PROC, 0600, NULL, &susfs_path_fops))
		return -ENOMEM;

	pr_info("susfs: sus_path ready (/proc/%s)\n", SUSFS_PATH_PROC);
	return 0;
}
device_initcall(susfs_path_init);
