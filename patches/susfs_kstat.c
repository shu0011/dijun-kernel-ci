// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-4: sus_kstat（built-in）
 *
 * 控制接口：/proc/susfs_add_sus_kstat  0600
 *   写 "<绝对路径> <size> [mode]"  -> 加入伪装（mode 为八进制，可省略）
 *   写 "clear"                     -> 清空并 iput
 *   读                             -> 每行 "<path> <size> <mode>"
 *
 * 与 sus_path 共用同一套 inode 匹配思路：加入时 kern_path() 拿 inode 并 ihold()，
 * 之后按指针比较。只对 app uid（>= 10000）生效。
 *
 * 伪造方式：不调用文件系统自身的 getattr，而是 generic_fillattr() 填基础字段后
 * 覆盖 size / blocks /（可选）mode。文件系统专有的扩展字段（如 f2fs 的压缩标志）
 * 不参与，检测软件看的是 size/ino/mode 这些常规项。
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
#include <linux/stat.h>
#include <linux/string.h>
#include <linux/susfs_kstat.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_MAX_KSTAT 64
#define SUSFS_KSTAT_PROC "susfs_add_sus_kstat"

struct susfs_kstat_entry {
	struct inode *inode;
	u64 size;
	unsigned int mode;	/* 0 表示不改 mode */
	char path[PATH_MAX];
};

static struct susfs_kstat_entry susfs_kstats[SUSFS_MAX_KSTAT];
static int susfs_kstat_count;
static DEFINE_MUTEX(susfs_kstat_mutex);

bool susfs_is_inode_sus_kstat(struct inode *inode)
{
	int i;
	bool found = false;

	if (!inode || !READ_ONCE(susfs_kstat_count))
		return false;

	if (likely(current_uid().val < 10000))
		return false;

	mutex_lock(&susfs_kstat_mutex);
	for (i = 0; i < susfs_kstat_count; i++) {
		if (susfs_kstats[i].inode == inode) {
			found = true;
			break;
		}
	}
	mutex_unlock(&susfs_kstat_mutex);

	return found;
}

void susfs_kstat_override(struct inode *inode, struct kstat *stat)
{
	int i;

	if (!inode || !stat)
		return;

	mutex_lock(&susfs_kstat_mutex);
	for (i = 0; i < susfs_kstat_count; i++) {
		if (susfs_kstats[i].inode != inode)
			continue;
		stat->size = susfs_kstats[i].size;
		stat->blocks = (susfs_kstats[i].size + 511) >> 9;
		if (susfs_kstats[i].mode)
			stat->mode = susfs_kstats[i].mode;
		break;
	}
	mutex_unlock(&susfs_kstat_mutex);
}

static void susfs_kstat_clear(void)
{
	int i;

	mutex_lock(&susfs_kstat_mutex);
	for (i = 0; i < susfs_kstat_count; i++) {
		if (susfs_kstats[i].inode)
			iput(susfs_kstats[i].inode);
		susfs_kstats[i].inode = NULL;
		susfs_kstats[i].path[0] = '\0';
	}
	susfs_kstat_count = 0;
	mutex_unlock(&susfs_kstat_mutex);
}

static int susfs_kstat_add(const char *path, u64 size, unsigned int mode)
{
	struct path p;
	struct inode *inode;
	int i, ret;

	ret = kern_path(path, 0, &p);
	if (ret)
		return ret;

	inode = d_backing_inode(p.dentry);
	if (!inode) {
		path_put(&p);
		return -ENOENT;
	}

	mutex_lock(&susfs_kstat_mutex);
	for (i = 0; i < susfs_kstat_count; i++) {
		if (susfs_kstats[i].inode == inode) {
			susfs_kstats[i].size = size;
			susfs_kstats[i].mode = mode;
			mutex_unlock(&susfs_kstat_mutex);
			path_put(&p);
			return 0;
		}
	}
	if (susfs_kstat_count >= SUSFS_MAX_KSTAT) {
		mutex_unlock(&susfs_kstat_mutex);
		path_put(&p);
		return -ENOSPC;
	}

	ihold(inode);
	susfs_kstats[susfs_kstat_count].inode = inode;
	susfs_kstats[susfs_kstat_count].size = size;
	susfs_kstats[susfs_kstat_count].mode = mode;
	strscpy(susfs_kstats[susfs_kstat_count].path, path, PATH_MAX);
	susfs_kstat_count++;
	mutex_unlock(&susfs_kstat_mutex);

	path_put(&p);
	return 0;
}

int susfs_kstat_abi_add(const char *path, u64 size, unsigned int mode)
{
	return susfs_kstat_add(path, size, mode);
}

static ssize_t susfs_kstat_write(struct file *file, const char __user *ubuf,
				 size_t count, loff_t *ppos)
{
	char *kbuf, *sep, *mode_str;
	u64 size = 0;
	unsigned long mode = 0;
	size_t len;
	int ret;

	if (!count || count > PATH_MAX + 64)
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
		susfs_kstat_clear();
		kfree(kbuf);
		return count;
	}

	/* "<path> <size> [mode]" */
	sep = strchr(kbuf, ' ');
	if (!sep) {
		kfree(kbuf);
		return -EINVAL;
	}
	*sep = '\0';
	if (strlen(kbuf) >= PATH_MAX) {
		kfree(kbuf);
		return -ENAMETOOLONG;
	}
	/* kbuf 已在堆上，*sep='\0' 后其前半段即 path，直接复用，避免栈上 PATH_MAX 缓冲 */

	if (sscanf(sep + 1, "%llu %lo", &size, &mode) < 1) {
		kfree(kbuf);
		return -EINVAL;
	}
	mode_str = strchr(sep + 1, ' ');
	(void)mode_str;

	ret = susfs_kstat_add(kbuf, size, (unsigned int)mode);
	kfree(kbuf);

	return ret ? ret : count;
}

static ssize_t susfs_kstat_read(struct file *file, char __user *ubuf,
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

	mutex_lock(&susfs_kstat_mutex);
	for (i = 0; i < susfs_kstat_count; i++) {
		if (used >= PAGE_SIZE - 1)
			break;
		n = scnprintf(out + used, PAGE_SIZE - used, "%s %llu %o\n",
			      susfs_kstats[i].path,
			      (unsigned long long)susfs_kstats[i].size,
			      susfs_kstats[i].mode);
		if (n <= 0)
			break;
		used += n;
	}
	mutex_unlock(&susfs_kstat_mutex);

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
static const struct proc_ops susfs_kstat_fops = {
	.proc_read  = susfs_kstat_read,
	.proc_write = susfs_kstat_write,
	.proc_lseek = noop_llseek,
};
#else
static const struct file_operations susfs_kstat_fops = {
	.read  = susfs_kstat_read,
	.write = susfs_kstat_write,
	.llseek = noop_llseek,
};
#endif

static int __init susfs_kstat_init(void)
{
	if (!proc_create(SUSFS_KSTAT_PROC, 0600, NULL, &susfs_kstat_fops))
		return -ENOMEM;

	pr_info("susfs: sus_kstat ready (/proc/%s)\n", SUSFS_KSTAT_PROC);
	return 0;
}
device_initcall(susfs_kstat_init);
