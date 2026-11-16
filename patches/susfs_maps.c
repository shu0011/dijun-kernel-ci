// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-N: sus_map（built-in，inode 匹配）
 *
 * 隐藏 /proc/<pid>/maps、/proc/<pid>/smaps 里指定的文件映射行（典型用途：
 * 隐藏注入的 .so）。复用 sus_path 的 inode 指针匹配架构：加入时 kern_path
 * 解析路径、取底层 inode 并 ihold()；show_map_vma 里对映射文件的 inode 比对。
 *
 * 与上游 susfs4ksu 的差异：上游在 inode->i_mapping->flags 打 AS_FLAGS_SUS_MAP
 * 位（LKM 不能改 struct inode 才这么做），本实现用 inode 指针数组，不依赖
 * 具体 bit 号，零运行期改写。
 *
 * 控制接口：/proc/susfs_add_sus_map  0600
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
#include <linux/mutex.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/susfs_maps.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_MAX_MAPS 128
#define SUSFS_MAPS_PROC "susfs_add_sus_map"

struct susfs_maps_entry {
	struct inode *inode;
	char path[PATH_MAX];	/* 仅用于回读展示 */
};

static struct susfs_maps_entry susfs_maps[SUSFS_MAX_MAPS];
static int susfs_maps_count;
static DEFINE_MUTEX(susfs_maps_mutex);

bool susfs_is_inode_sus_map(const struct inode *inode)
{
	int i;
	bool found = false;

	if (!inode || !READ_ONCE(susfs_maps_count))
		return false;
	if (likely(current_uid().val < 10000))
		return false;

	mutex_lock(&susfs_maps_mutex);
	for (i = 0; i < susfs_maps_count; i++) {
		if (susfs_maps[i].inode == inode) {
			found = true;
			break;
		}
	}
	mutex_unlock(&susfs_maps_mutex);

	return found;
}

static void susfs_maps_clear(void)
{
	int i;

	mutex_lock(&susfs_maps_mutex);
	for (i = 0; i < susfs_maps_count; i++) {
		if (susfs_maps[i].inode)
			iput(susfs_maps[i].inode);
		susfs_maps[i].inode = NULL;
		susfs_maps[i].path[0] = '\0';
	}
	susfs_maps_count = 0;
	mutex_unlock(&susfs_maps_mutex);
}

static int susfs_maps_add(const char *path)
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

	mutex_lock(&susfs_maps_mutex);
	for (i = 0; i < susfs_maps_count; i++) {
		if (susfs_maps[i].inode == inode) {
			mutex_unlock(&susfs_maps_mutex);
			path_put(&p);
			return 0;	/* 已存在 */
		}
	}
	if (susfs_maps_count >= SUSFS_MAX_MAPS) {
		mutex_unlock(&susfs_maps_mutex);
		path_put(&p);
		return -ENOSPC;
	}

	ihold(inode);
	susfs_maps[susfs_maps_count].inode = inode;
	strscpy(susfs_maps[susfs_maps_count].path, path, PATH_MAX);
	susfs_maps_count++;
	mutex_unlock(&susfs_maps_mutex);

	path_put(&p);
	return 0;
}

static ssize_t susfs_maps_write(struct file *file, const char __user *ubuf,
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
		susfs_maps_clear();
		kfree(kbuf);
		return count;
	}

	ret = susfs_maps_add(kbuf);
	kfree(kbuf);

	return ret ? ret : count;
}

static ssize_t susfs_maps_read(struct file *file, char __user *ubuf,
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

	mutex_lock(&susfs_maps_mutex);
	for (i = 0; i < susfs_maps_count; i++) {
		n = scnprintf(out + used, PAGE_SIZE - used, "%s\n",
			      susfs_maps[i].path);
		if (n <= 0)
			break;
		used += n;
		if (PAGE_SIZE - used < PATH_MAX)
			break;
	}
	mutex_unlock(&susfs_maps_mutex);

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
static const struct proc_ops susfs_maps_fops = {
	.proc_read  = susfs_maps_read,
	.proc_write = susfs_maps_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_maps_fops = {
	.read  = susfs_maps_read,
	.write = susfs_maps_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_maps_init(void)
{
	if (!proc_create(SUSFS_MAPS_PROC, 0600, NULL, &susfs_maps_fops))
		return -ENOMEM;

	pr_info("susfs: sus_map ready (/proc/%s)\n", SUSFS_MAPS_PROC);
	return 0;
}
device_initcall(susfs_maps_init);
