// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS stage-4: sus_kstat（built-in，全字段伪装）
 *
 * 控制接口：
 *   /proc/susfs_add_sus_kstat  0600
 *     写 "<绝对路径> <size> [mode(八进制)]" -> 以当前 stat 为底，覆盖 size（可选 mode）
 *     写 "clear"                            -> 清空并 iput
 *     读                                    -> 每行 "<path> <size> <mode>"
 *
 * 官方命令字 ABI（CMD_SUSFS_ADD_SUS_KSTAT / UPDATE_SUS_KSTAT /
 * ADD_SUS_KSTAT_STATICALLY）走 susfs_kstat_abi_add()：
 *   - ADD / UPDATE：以路径当前的真实 stat 为快照（generic_fillattr）
 *   - STATICALLY ：直接采用 userspace 传来的 ino/dev/nlink/size/atime/mtime/
 *                  ctime/blocks/blksize（CLI 会把 "default" 字段先填成真实值）
 *
 * 与 sus_path 共用同一套 inode 匹配思路：加入时 kern_path() 拿 inode 并 ihold()，
 * 之后按指针比较。只对 app uid（>= 10000）生效。
 *
 * 伪装方式：vfs_getattr() 里先 generic_fillattr() 填基础字段，再用本表覆盖
 * ino / dev / nlink / size / blocks / blksize / atime / mtime / ctime。
 * 对齐上游 susfs4ksu 的 sus_kstat 字段集合（上游同样不覆盖 rdev/uid/gid）。
 */
#include <linux/cred.h>
#include <linux/dcache.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/mutex.h>
#include <linux/mnt_idmapping.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/proc_fs.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/stat.h>
#include <linux/string.h>
#include <linux/susfs_abi.h>
#include <linux/susfs_kstat.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#define SUSFS_MAX_KSTAT 64
#define SUSFS_KSTAT_PATH_MAX SUSFS_ABI_MAX_LEN_PATHNAME
#define SUSFS_KSTAT_PROC "susfs_add_sus_kstat"

struct susfs_kstat_entry {
	struct inode *inode;
	char path[SUSFS_KSTAT_PATH_MAX];	/* 仅用于回读展示 */
	struct kstat kst;			/* 完整伪装值 */
	bool mode_valid;			/* false 时保持真实 mode */
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
		struct susfs_kstat_entry *e = &susfs_kstats[i];

		if (e->inode != inode)
			continue;

		stat->ino = e->kst.ino;
		stat->dev = e->kst.dev;
		stat->nlink = e->kst.nlink;
		stat->size = e->kst.size;
		stat->blocks = e->kst.blocks;
		stat->blksize = e->kst.blksize;
		stat->atime = e->kst.atime;
		stat->mtime = e->kst.mtime;
		stat->ctime = e->kst.ctime;
		if (e->mode_valid)
			stat->mode = e->kst.mode;
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

/* caller holds susfs_kstat_mutex */
static int susfs_kstat_store_locked(struct inode *inode, const char *path,
				    const struct kstat *kst, bool mode_valid)
{
	int i;

	for (i = 0; i < susfs_kstat_count; i++) {
		if (susfs_kstats[i].inode == inode) {
			susfs_kstats[i].kst = *kst;
			susfs_kstats[i].mode_valid = mode_valid;
			strscpy(susfs_kstats[i].path, path,
				SUSFS_KSTAT_PATH_MAX);
			return 0;
		}
	}
	if (susfs_kstat_count >= SUSFS_MAX_KSTAT)
		return -ENOSPC;

	ihold(inode);
	susfs_kstats[susfs_kstat_count].inode = inode;
	susfs_kstats[susfs_kstat_count].kst = *kst;
	susfs_kstats[susfs_kstat_count].mode_valid = mode_valid;
	strscpy(susfs_kstats[susfs_kstat_count].path, path, SUSFS_KSTAT_PATH_MAX);
	susfs_kstat_count++;
	return 0;
}

/*
 * 官方 ABI 入口。
 * info->is_statically == true 时采用 payload 里的数值字段；
 * 否则以路径当前真实 stat 为快照（ADD / UPDATE 语义）。
 */
int susfs_kstat_abi_add(const char *path, const struct susfs_abi_kstat *info)
{
	struct path p;
	struct inode *inode;
	struct kstat kst = {};
	int ret;

	ret = kern_path(path, 0, &p);
	if (ret)
		return ret;

	inode = d_backing_inode(p.dentry);
	if (!inode) {
		path_put(&p);
		return -ENOENT;
	}

	generic_fillattr(mnt_idmap(p.mnt), STATX_BASIC_STATS, inode, &kst);

	if (info && info->is_statically) {
		kst.ino = (u64)info->spoofed_ino;
		kst.dev = (dev_t)info->spoofed_dev;
		kst.nlink = info->spoofed_nlink;
		kst.size = (loff_t)info->spoofed_size;
		kst.atime.tv_sec = info->spoofed_atime_tv_sec;
		kst.atime.tv_nsec = info->spoofed_atime_tv_nsec;
		kst.mtime.tv_sec = info->spoofed_mtime_tv_sec;
		kst.mtime.tv_nsec = info->spoofed_mtime_tv_nsec;
		kst.ctime.tv_sec = info->spoofed_ctime_tv_sec;
		kst.ctime.tv_nsec = info->spoofed_ctime_tv_nsec;
		kst.blocks = (u64)info->spoofed_blocks;
		kst.blksize = (u32)info->spoofed_blksize;
	}

	mutex_lock(&susfs_kstat_mutex);
	ret = susfs_kstat_store_locked(inode, path, &kst, false);
	mutex_unlock(&susfs_kstat_mutex);

	path_put(&p);
	return ret;
}

/* /proc 接口：<path> <size> [mode] —— 以真实 stat 为底只覆盖 size（可选 mode） */
static int susfs_kstat_add_simple(const char *path, u64 size, unsigned int mode)
{
	struct path p;
	struct inode *inode;
	struct kstat kst = {};
	int ret;

	ret = kern_path(path, 0, &p);
	if (ret)
		return ret;

	inode = d_backing_inode(p.dentry);
	if (!inode) {
		path_put(&p);
		return -ENOENT;
	}

	generic_fillattr(mnt_idmap(p.mnt), STATX_BASIC_STATS, inode, &kst);
	kst.size = (loff_t)size;
	kst.blocks = (size + 511) >> 9;
	if (mode)
		kst.mode = (umode_t)mode;

	mutex_lock(&susfs_kstat_mutex);
	ret = susfs_kstat_store_locked(inode, path, &kst, mode != 0);
	mutex_unlock(&susfs_kstat_mutex);

	path_put(&p);
	return ret;
}

static ssize_t susfs_kstat_write(struct file *file, const char __user *ubuf,
				 size_t count, loff_t *ppos)
{
	char *kbuf, *sep;
	char path[SUSFS_KSTAT_PATH_MAX];
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
	if (strlen(kbuf) >= SUSFS_KSTAT_PATH_MAX) {
		kfree(kbuf);
		return -ENAMETOOLONG;
	}
	strscpy(path, kbuf, sizeof(path));

	if (sscanf(sep + 1, "%llu %lo", &size, &mode) < 1) {
		kfree(kbuf);
		return -EINVAL;
	}

	ret = susfs_kstat_add_simple(path, size, (unsigned int)mode);
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
		n = scnprintf(out + used, PAGE_SIZE - used, "%s %lld %o\n",
			      susfs_kstats[i].path,
			      (long long)susfs_kstats[i].kst.size,
			      susfs_kstats[i].mode_valid ?
				      (unsigned int)susfs_kstats[i].kst.mode : 0);
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
