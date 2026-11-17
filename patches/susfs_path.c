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
#include <linux/susfs_extra.h>
#include <linux/uaccess.h>
#include <linux/version.h>

/*
 * The entry list grows on demand.  A fixed 64-entry array is far too small in
 * practice: the susfs4ksu module with emulate_vold_app_data adds one path per
 * installed app (/sdcard/Android/data/<pkg>), easily 150+ entries, and every
 * add beyond the cap used to fail silently.
 */
#define SUSFS_PATH_MIN_CAP 64
#define SUSFS_PATH_MAX_CAP 4096
#define SUSFS_PATH_MAX_LEN 256	/* upstream SUSFS_MAX_LEN_PATHNAME */
#define SUSFS_PATH_PROC "susfs_add_sus_path"

struct susfs_path_entry {
	struct inode *inode;
	char path[SUSFS_PATH_MAX_LEN];	/* 仅用于回读展示 */
};

static struct susfs_path_entry *susfs_paths;
static int susfs_path_count;
static int susfs_path_cap;
static DEFINE_MUTEX(susfs_path_mutex);

/* Doubling growth; caller must hold susfs_path_mutex. */
static int susfs_path_grow_locked(void)
{
	struct susfs_path_entry *grown;
	int newcap = susfs_path_cap ? susfs_path_cap * 2 : SUSFS_PATH_MIN_CAP;

	if (newcap > SUSFS_PATH_MAX_CAP)
		newcap = SUSFS_PATH_MAX_CAP;
	if (newcap <= susfs_path_cap)
		return -ENOSPC;

	grown = kvmalloc_array(newcap, sizeof(*grown), GFP_KERNEL);
	if (!grown)
		return -ENOMEM;
	if (susfs_path_count)
		memcpy(grown, susfs_paths,
		       susfs_path_count * sizeof(*grown));
	kvfree(susfs_paths);
	susfs_paths = grown;
	susfs_path_cap = newcap;
	return 0;
}

bool susfs_is_inode_sus_path(struct inode *inode)
{
	int i;
	bool found = false;

	if (!inode || !READ_ONCE(susfs_path_count))
		return false;

	/* SUS_PATH_UID_FILTER: allow-list of uids that may see the real path.
	 * With no filter configured this keeps the legacy "hide for all app
	 * uids" behaviour (see susfs_uid_hidden_for_sus_path()). */
	if (!susfs_uid_hidden_for_sus_path(current_uid().val))
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
	if (susfs_path_count >= susfs_path_cap) {
		ret = susfs_path_grow_locked();
		if (ret) {
			mutex_unlock(&susfs_path_mutex);
			path_put(&p);
			return ret;
		}
	}

	ihold(inode);
	susfs_paths[susfs_path_count].inode = inode;
	strscpy(susfs_paths[susfs_path_count].path, path, SUSFS_PATH_MAX_LEN);
	susfs_path_count++;
	mutex_unlock(&susfs_path_mutex);

	path_put(&p);
	return 0;
}

int susfs_path_abi_add(const char *path)
{
	return susfs_path_add(path);
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
		/* Keep filling the page: the previous "PAGE_SIZE - used <
		 * PATH_MAX" test was always true after the first entry, so the
		 * readback only ever showed one line. */
		if (used >= PAGE_SIZE - 1)
			break;
		n = scnprintf(out + used, PAGE_SIZE - used, "%s\n",
			      susfs_paths[i].path);
		if (n <= 0)
			break;
		used += n;
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
