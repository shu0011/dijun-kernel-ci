// SPDX-License-Identifier: GPL-2.0
/*
 * SUSFS extra features — built-in, zero-kprobe implementation.
 *
 * Covers the four upstream features that were previously missing from this
 * port: ENABLE_LOG, SUS_PATH_UID_FILTER, PRIORITY_UID_FILTER and
 * OPEN_REDIRECT.  State lives in static kernel memory; ABI payload structs
 * are defined in <linux/susfs_abi.h> and are byte-identical to upstream's
 * ksu_susfs userspace tool (gki-android16-6.12).
 *
 * No LKM, no kprobe, no kthread.  The VFS/syscall effect is produced by tiny
 * hooks injected by ci/integrate.sh that call the consumers below.
 */
#include <linux/susfs_extra.h>
#include <linux/susfs_abi.h>

#include <linux/bitmap.h>
#include <linux/bitops.h>
#include <linux/cred.h>
#include <linux/err.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/gfp.h>
#include <linux/jump_label.h>
#include <linux/kstrtox.h>
#include <linux/list.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/namei.h>	/* kern_path() */
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/vmalloc.h>

/* Provided by susfs_bridge.c (built-in SukiSU).  Declared before first use. */
extern bool susfs_is_current_ksu_domain(void);

/* ======================================================================= */
/* ENABLE_LOG                                                              */
/* ======================================================================= */
/* Default OFF: a stock build should not spam dmesg.  The upstream static
 * key is DEFINE_STATIC_KEY_TRUE; we invert to FALSE so that disabled is the
 * quiet default and toggling simply enables/disables this branch. */
DEFINE_STATIC_KEY_FALSE(susfs_log_key);

bool susfs_log_enabled(void)
{
	return static_branch_unlikely(&susfs_log_key);
}

int susfs_extra_enable_log(bool enabled)
{
	if (enabled)
		static_branch_enable(&susfs_log_key);
	else
		static_branch_disable(&susfs_log_key);
	pr_info("susfs: %s logging to kernel\n", enabled ? "enable" : "disable");
	return 0;
}

#define susfs_log(fmt, ...)                                                  \
	do {                                                                 \
		if (susfs_log_enabled())                                     \
			pr_info("susfs: [%u][%d] " fmt, current_uid().val,  \
				current->pid, ##__VA_ARGS__);               \
	} while (0)

/* ======================================================================= */
/* UID FILTERS (SUS_PATH allow-list, PRIORITY deny-list)                    */
/* ======================================================================= */
#define SUSFS_UID_MIN 10000
#define SUSFS_UID_MAX 19999
#define SUSFS_UID_NUM (SUSFS_UID_MAX - SUSFS_UID_MIN + 1)
#define SUSFS_UID_WORDS BITS_TO_LONGS(SUSFS_UID_NUM)

struct susfs_uid_bitmap {
	unsigned long bits[SUSFS_UID_WORDS];
};

/* Two independent bitmaps.  sus_path is an allow-list (empty == allow all,
 * matching upstream's "no filter configured" behaviour); priority is a
 * deny-list (empty == hide nothing). */
static struct susfs_uid_bitmap sus_path_allow;
static struct susfs_uid_bitmap priority_deny;
static DEFINE_MUTEX(sus_path_filter_mutex);
static DEFINE_MUTEX(priority_filter_mutex);
static bool sus_path_filter_active;
static bool priority_filter_active;

bool susfs_uid_hidden_for_sus_path(uid_t uid)
{
	bool allowed;

	/* System/root uids are never hidden (keeps boot stability). */
	if (uid < 10000)
		return false;
	/* No filter configured: legacy behaviour — hide for every app uid. */
	if (!READ_ONCE(sus_path_filter_active))
		return true;
	/* Upstream: uids >= 90000 are always allowed to see sus paths. */
	if (uid >= 90000)
		return false;
	if (uid < SUSFS_UID_MIN || uid > SUSFS_UID_MAX)
		return true;

	mutex_lock(&sus_path_filter_mutex);
	allowed = test_bit(uid - SUSFS_UID_MIN, sus_path_allow.bits);
	mutex_unlock(&sus_path_filter_mutex);
	/* allow-list member sees the real path (not hidden); others hidden. */
	return !allowed;
}

bool susfs_uid_priority_filtered(uid_t uid)
{
	bool filtered;

	if (!READ_ONCE(priority_filter_active))
		return false;
	if (uid < SUSFS_UID_MIN || uid > SUSFS_UID_MAX)
		return false;

	mutex_lock(&priority_filter_mutex);
	filtered = test_bit(uid - SUSFS_UID_MIN, priority_deny.bits);
	mutex_unlock(&priority_filter_mutex);
	return filtered;
}

/*
 * Resolve package names to app uids via /data/system/packages.list.
 *
 * The read deliberately uses the *caller's* credentials.  This ABI is
 * root-only (see susfs_reboot_handler), and the caller (ksu_susfs launched
 * from a su shell) runs in the KernelSU domain, which is allowed to read
 * packages_list_file.  Overriding with init_cred would switch the SELinux
 * context to u:r:kernel:s0, which is *denied* read on that file.
 *
 * Format: <package> <uid> <gid> [flags...].  We take uid % 100000 like
 * upstream so a 100000-offset uid still lands in [10000,19999].
 */
#define PACKAGES_LIST "/data/system/packages.list"
#define SUSFS_PKG_LINE_MAX 512

/* Read the whole file once; callers scan it for every requested package. */
static int susfs_read_packages_list(char **out)
{
	struct file *fp;
	loff_t pos = 0;
	char *buf;
	size_t size;
	ssize_t n;

	fp = filp_open(PACKAGES_LIST, O_RDONLY | O_LARGEFILE, 0);
	if (IS_ERR(fp))
		return PTR_ERR(fp);

	size = i_size_read(file_inode(fp));
	if (size == 0 || size > (4 * 1024 * 1024)) {
		filp_close(fp, NULL);
		return -EFBIG;
	}

	buf = vmalloc(size + 1);
	if (!buf) {
		filp_close(fp, NULL);
		return -ENOMEM;
	}

	n = kernel_read(fp, buf, size, &pos);
	filp_close(fp, NULL);
	if (n != (ssize_t)size) {
		vfree(buf);
		return n < 0 ? (int)n : -EIO;
	}
	buf[size] = '\0';
	*out = buf;
	return 0;
}

/* Find @name in an already-loaded packages.list image. */
static int susfs_lookup_uid_in_list(const char *list, const char *name,
				    uid_t *out_uid)
{
	const char *line = list;

	while (line && *line) {
		char tmp[SUSFS_PKG_LINE_MAX];
		char *cursor = tmp, *pkg, *uid_str;
		unsigned long val;
		size_t len = 0;

		while (line[len] && line[len] != '\n' &&
		       len < sizeof(tmp) - 1)
			len++;
		memcpy(tmp, line, len);
		tmp[len] = '\0';

		line = strchr(line, '\n');
		if (line)
			line++;

		pkg = strsep(&cursor, " \t");
		uid_str = strsep(&cursor, " \t");
		if (!pkg || !*pkg || !uid_str || !*uid_str)
			continue;
		if (strcmp(pkg, name))
			continue;
		if (kstrtoul(uid_str, 10, &val))
			return -EINVAL;
		*out_uid = (uid_t)(val % 100000);
		return 0;
	}
	return -ENOENT;
}

/*
 * Parse a comma-separated package list into the bitmap.
 * Returns 0 when at least one entry resolved (skipped entries are tolerated),
 * the read error when packages.list is unreadable, or -ENOENT when nothing at
 * all resolved — so userspace sees a failure instead of a silently empty
 * filter.
 */
static int susfs_parse_app_list(char *apps, struct susfs_uid_bitmap *map)
{
	char *token, *save = apps;
	char *list;
	int resolved = 0, tokens = 0;
	int ret;

	ret = susfs_read_packages_list(&list);
	if (ret)
		return ret;

	while ((token = strsep(&save, ",")) != NULL) {
		uid_t uid;

		token = strim(token);
		if (!*token)
			continue;
		tokens++;
		if (susfs_lookup_uid_in_list(list, token, &uid))
			continue;
		if (uid < SUSFS_UID_MIN || uid > SUSFS_UID_MAX)
			continue;
		set_bit(uid - SUSFS_UID_MIN, map->bits);
		resolved++;
		susfs_log("resolved app '%s' -> uid %u\n", token, uid);
	}
	vfree(list);

	if (tokens && !resolved)
		return -ENOENT;
	return 0;
}

static int susfs_set_uid_filter(const char __user *app_strings,
				struct susfs_uid_bitmap *map,
				struct mutex *lock,
				bool *active,
				const char *tag)
{
	/* 65540-byte payload — must be heap/vmalloc, never on the kernel stack. */
	struct susfs_abi_uid_filter *info;
	struct susfs_uid_bitmap *newmap;
	int ret = 0;

	info = kvzalloc(sizeof(*info), GFP_KERNEL);
	if (!info)
		return -ENOMEM;
	if (copy_from_user(info, (const void __user *)app_strings, sizeof(*info))) {
		kvfree(info);
		return -EFAULT;
	}
	if (!memchr(info->app_strings, '\0', sizeof(info->app_strings))) {
		kvfree(info);
		return -EINVAL;
	}

	/* strsep() modifies the buffer; parse directly from the kvzalloc copy. */
	newmap = kzalloc(sizeof(*newmap), GFP_KERNEL);
	if (!newmap) {
		kvfree(info);
		return -ENOMEM;
	}
	ret = susfs_parse_app_list(info->app_strings, newmap);
	kvfree(info);
	if (ret) {
		/* Unreadable packages.list or nothing resolved: do not silently
		 * install an empty filter — leave the previous state untouched. */
		kfree(newmap);
		return ret;
	}

	mutex_lock(lock);
	memcpy(map->bits, newmap->bits, sizeof(map->bits));
	WRITE_ONCE(*active, true);
	mutex_unlock(lock);
	kfree(newmap);

	susfs_log("%s filter updated\n", tag);
	return ret;
}

int susfs_extra_set_sus_path_uid_filter(const char __user *app_strings)
{
	return susfs_set_uid_filter(app_strings, &sus_path_allow,
				    &sus_path_filter_mutex,
				    &sus_path_filter_active, "sus_path");
}

int susfs_extra_set_priority_uid_filter(const char __user *app_strings)
{
	return susfs_set_uid_filter(app_strings, &priority_deny,
				    &priority_filter_mutex,
				    &priority_filter_active, "priority");
}

/* ======================================================================= */
/* OPEN_REDIRECT                                                           */
/* ======================================================================= */
/*
 * A target inode is mapped to a redirected pathname.  On open, the VFS hook
 * calls susfs_open_redirect_filename(target_inode); when the current process
 * matches the rule's uid_scheme, a getname_kernel() copy of the redirected
 * path is returned and the caller restarts the lookup with it.
 *
 * We keep it deliberately simple: a mutex-protected singly linked list and a
 * per-inode flag bit on i_mapping->flags.  Rule counts are tiny (a handful),
 * so a linear scan is fine and avoids RCU/SRCU complexity in this built-in
 * port.  Uses bit 36 (AS_FLAGS_OPEN_REDIRECT) exactly like upstream 6.12.
 */
#define AS_FLAGS_OPEN_REDIRECT 36

struct susfs_redirect_entry {
	struct hlist_node node;
	struct inode *target_inode;
	struct inode *redirect_inode;
	char *target_path;
	char *redirect_path;
	int uid_scheme;
	struct list_head list;
};

static LIST_HEAD(susfs_redirect_list);
static DEFINE_MUTEX(susfs_redirect_mutex);

static bool susfs_uid_scheme_match(int scheme)
{
	uid_t uid = current_uid().val;

	switch (scheme) {
	case 0: /* non-app processes (uid < 10000) */
		return uid < 10000;
	case 1: /* root but not in ksu domain */
		return uid == 0 && !susfs_is_current_ksu_domain();
	case 2: /* non-su processes */
		return !susfs_is_current_ksu_domain();
	case 3: /* app processes (uid >= 10000) */
		return uid >= 10000;
	case 4: /* any non-root process */
		return uid != 0;
	default:
		return false;
	}
}

bool susfs_inode_has_open_redirect(struct inode *inode)
{
	return inode && inode->i_mapping &&
	       test_bit(AS_FLAGS_OPEN_REDIRECT, &inode->i_mapping->flags);
}

struct filename *susfs_open_redirect_filename(struct inode *inode)
{
	struct susfs_redirect_entry *e;
	struct filename *ret = NULL;

	if (!susfs_inode_has_open_redirect(inode))
		return NULL;

	mutex_lock(&susfs_redirect_mutex);
	list_for_each_entry(e, &susfs_redirect_list, list) {
		if (e->target_inode == inode && susfs_uid_scheme_match(e->uid_scheme)) {
			ret = getname_kernel(e->redirect_path);
			break;
		}
	}
	mutex_unlock(&susfs_redirect_mutex);
	return ret;
}

/*
 * Called from vfs_readlink() before the cached-link fast path.
 *
 * Direction matches upstream susfs_open_redirect_spoof_vfs_readlink(): when the
 * *target* inode is readlinked, report the redirected pathname, so the real
 * location of the hidden target is never exposed.  Writes straight into the
 * caller's user buffer via readlink_copy(), which keeps the hook free of any
 * stack buffer (a PATH_MAX local inside vfs_readlink() trips
 * -Wframe-larger-than=2048).
 * Returns >= 0 (bytes copied) when handled, -ENOENT when there is no rule.
 */
int susfs_open_redirect_readlink(struct inode *inode, char __user *buffer,
				 int buflen)
{
	struct susfs_redirect_entry *e;
	int ret = -ENOENT;

	if (!inode || !susfs_inode_has_open_redirect(inode))
		return -ENOENT;

	mutex_lock(&susfs_redirect_mutex);
	list_for_each_entry(e, &susfs_redirect_list, list) {
		if (e->target_inode == inode &&
		    susfs_uid_scheme_match(e->uid_scheme)) {
			ret = readlink_copy(buffer, buflen, e->redirect_path,
					    strlen(e->redirect_path));
			break;
		}
	}
	mutex_unlock(&susfs_redirect_mutex);
	return ret;
}

int susfs_extra_add_open_redirect(const void __user *payload)
{
	struct susfs_abi_open_redirect info = {0};
	struct susfs_redirect_entry *e, *tmp, *pos;
	struct path target = {}, redirect = {};
	int ret;

	if (copy_from_user(&info, payload, sizeof(info)))
		return -EFAULT;
	if (!info.target_pathname[0] || !info.redirected_pathname[0] ||
	    info.uid_scheme < 0 || info.uid_scheme > 4)
		return -EINVAL;

	ret = kern_path(info.redirected_pathname, 0, &redirect);
	if (ret)
		return ret;
	ret = kern_path(info.target_pathname, 0, &target);
	if (ret) {
		path_put(&redirect);
		return ret;
	}

	e = kzalloc(sizeof(*e), GFP_KERNEL);
	if (!e) {
		ret = -ENOMEM;
		goto out;
	}
	e->target_path = kstrdup(info.target_pathname, GFP_KERNEL);
	e->redirect_path = kstrdup(info.redirected_pathname, GFP_KERNEL);
	if (!e->target_path || !e->redirect_path) {
		kfree(e->target_path);
		kfree(e->redirect_path);
		kfree(e);
		ret = -ENOMEM;
		goto out;
	}
	/* Pin the inodes: path_put() below drops the dentry/path references, so
	 * we must hold our own inode references for the lifetime of the rule
	 * (rules are permanent — there is no delete command upstream either). */
	e->target_inode = d_backing_inode(target.dentry);
	e->redirect_inode = d_backing_inode(redirect.dentry);
	if (e->target_inode)
		e->target_inode = igrab(e->target_inode);
	if (e->redirect_inode)
		e->redirect_inode = igrab(e->redirect_inode);
	e->uid_scheme = info.uid_scheme;
	INIT_HLIST_NODE(&e->node);
	INIT_LIST_HEAD(&e->list);

	/* Replace any existing rule for the same target inode. */
	mutex_lock(&susfs_redirect_mutex);
	list_for_each_entry_safe(tmp, pos, &susfs_redirect_list, list) {
		if (tmp->target_inode == e->target_inode) {
			list_del(&tmp->list);
			if (tmp->target_inode)
				iput(tmp->target_inode);
			if (tmp->redirect_inode)
				iput(tmp->redirect_inode);
			kfree(tmp->target_path);
			kfree(tmp->redirect_path);
			kfree(tmp);
		}
	}
	list_add(&e->list, &susfs_redirect_list);
	mutex_unlock(&susfs_redirect_mutex);

	/* Mark both inodes so the VFS hooks can fast-path the check. */
	if (e->target_inode && e->target_inode->i_mapping)
		set_bit(AS_FLAGS_OPEN_REDIRECT, &e->target_inode->i_mapping->flags);
	if (e->redirect_inode && e->redirect_inode->i_mapping)
		set_bit(AS_FLAGS_OPEN_REDIRECT, &e->redirect_inode->i_mapping->flags);

	ret = 0;
out:
	path_put(&target);
	path_put(&redirect);
	return ret;
}
