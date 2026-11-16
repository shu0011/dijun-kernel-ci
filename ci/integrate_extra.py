#!/usr/bin/env python3
"""
SUSFS "extra features" injection: ENABLE_LOG / SUS_PATH_UID_FILTER /
PRIORITY_UID_FILTER / OPEN_REDIRECT.

Injected VFS/syscall hooks mirror upstream susfs4ksu gki-android16-6.12
(50_add_susfs_in_gki patch), adapted to the 6.18 kernel used by dijun.

Every anchor is asserted; a missing anchor aborts the build instead of
silently dropping a feature.
"""
import os
import sys

SRC = sys.argv[1]
EXTRA = sys.argv[2]  # directory holding susfs_extra.c/.h

errors = []


def add_include(path, header, before=None):
    s = open(path).read()
    if header in s:
        return
    i = s.find(before) if before else s.find("#include")
    assert i > 0, "%s: anchor for include '%s' not found" % (path, before)
    s = s[:i] + "#include <%s>\n" % header + s[i:]
    open(path, "w").write(s)


# ---------------------------------------------------------------- fs/Makefile
mk = os.path.join(SRC, "fs/Makefile")
s = open(mk).read()
if "susfs_extra.o" not in s:
    s += "\nobj-$(CONFIG_KSU_SUSFS) += susfs_extra.o\n"
    open(mk, "w").write(s)
print("    fs/Makefile: susfs_extra.o registered")

# ---------------------------------------------------------------- fs/namei.c
namei = os.path.join(SRC, "fs/namei.c")
s = open(namei).read()
add_include(namei, "linux/susfs_extra.h", before="#include <linux/namei.h>")
s = open(namei).read()

MARK = "SUSFS_OPEN_REDIRECT"
if MARK not in s:
    # (1) path_openat: add locals
    anchor = ("static struct file *path_openat(struct nameidata *nd,\n"
              "\t\t\tconst struct open_flags *op, unsigned flags)\n"
              "{\n")
    assert anchor in s, "namei.c: path_openat signature anchor not found"
    locals_block = (
        "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
        "\tint susfs_old_dfd = nd->dfd;\n"
        "\tbool susfs_root_preset = (nd->state & ND_ROOT_PRESET);\n"
        "\tstruct filename *susfs_fake_name = NULL;\n"
        "\tstruct filename *susfs_old_name = nd->name;\n"
        "#endif\n")
    s = s.replace(anchor, anchor + locals_block, 1)

    # (2) path_openat: after the link_path_walk/open_last_lookups loop
    loop_anchor = ("\t\tconst char *s = path_init(nd, flags);\n"
                   "\t\twhile (!(error = link_path_walk(s, nd)) &&\n"
                   "\t\t       (s = open_last_lookups(nd, file, op)) != NULL)\n"
                   "\t\t\t;\n"
                   "\t\tif (!error)\n"
                   "\t\t\terror = do_open(nd, file, op);\n")
    assert loop_anchor in s, "namei.c: path_openat loop anchor not found"
    redirect_block = (
        "\t\tconst char *s = path_init(nd, flags);\n"
        "\t\twhile (!(error = link_path_walk(s, nd)) &&\n"
        "\t\t       (s = open_last_lookups(nd, file, op)) != NULL)\n"
        "\t\t\t;\n"
        "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
        "\t\tif (!error && !susfs_root_preset && nd->path.dentry &&\n"
        "\t\t    susfs_inode_has_open_redirect(d_inode(nd->path.dentry))) {\n"
        "\t\t\tsusfs_fake_name =\n"
        "\t\t\t\tsusfs_open_redirect_filename(d_inode(nd->path.dentry));\n"
        "\t\t\tif (susfs_fake_name && !IS_ERR(susfs_fake_name)) {\n"
        "\t\t\t\tconst char *new_s = NULL;\n"
        "\t\t\t\tterminate_walk(nd);\n"
        "\t\t\t\trestore_nameidata();\n"
        "\t\t\t\tset_nameidata(nd, susfs_old_dfd, susfs_fake_name, NULL);\n"
        "\t\t\t\tnew_s = path_init(nd, flags);\n"
        "\t\t\t\twhile (!(error = link_path_walk(new_s, nd)) &&\n"
        "\t\t\t\t       (new_s = open_last_lookups(nd, file, op)) != NULL)\n"
        "\t\t\t\t\t;\n"
        "\t\t\t}\n"
        "\t\t}\n"
        "#endif\n"
        "\t\tif (!error)\n"
        "\t\t\terror = do_open(nd, file, op);\n")
    s = s.replace(loop_anchor, redirect_block, 1)

    # (3) path_openat: cleanup after the else-branch (before 'if (likely(!error))')
    cleanup_anchor = ("\t\tterminate_walk(nd);\n"
                      "\t}\n"
                      "\tif (likely(!error)) {\n")
    assert cleanup_anchor in s, "namei.c: path_openat cleanup anchor not found"
    cleanup_block = (
        "\t\tterminate_walk(nd);\n"
        "\t}\n"
        "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
        "\tif (susfs_fake_name && !IS_ERR(susfs_fake_name)) {\n"
        "\t\tnd->name = susfs_old_name;\n"
        "\t\tputname(susfs_fake_name);\n"
        "\t}\n"
        "#endif\n"
        "\tif (likely(!error)) {\n")
    s = s.replace(cleanup_anchor, cleanup_block, 1)

    # (4) vfs_readlink: spoof readlink on redirected inode (before cached-link fast path)
    # Inserted *after* the function's declarations so we never emit a statement
    # before a declaration (-Wdeclaration-after-statement).
    rl_anchor = ("\tstruct inode *inode = d_inode(dentry);\n"
                 "\tDEFINE_DELAYED_CALL(done);\n"
                 "\tconst char *link;\n"
                 "\tint res;\n")
    assert rl_anchor in s, "namei.c: vfs_readlink declarations anchor not found"
    rl_block = rl_anchor + (
        "#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT\n"
        "\t{\n"
        "\t\tint susfs_rl;\n"
        "\t\t/* no local buffer: the helper writes straight to @buffer, so\n"
        "\t\t * vfs_readlink()'s 2 KiB stack frame budget is preserved. */\n"
        "\t\tsusfs_rl = susfs_open_redirect_readlink(inode, buffer, buflen);\n"
        "\t\tif (susfs_rl >= 0)\n"
        "\t\t\treturn susfs_rl;\n"
        "\t}\n"
        "#endif\n")
    s = s.replace(rl_anchor, rl_block, 1)

    s += "\n/* SUSFS_OPEN_REDIRECT injected */\n"
    open(namei, "w").write(s)
    print("    fs/namei.c: open_redirect hooks injected (path_openat + vfs_readlink)")
else:
    print("    fs/namei.c: open_redirect hooks already present")

# ---------------------------------------------------------------- kernel/sys.c
sysc = os.path.join(SRC, "kernel/sys.c")
s = open(sysc).read()
add_include(sysc, "linux/susfs_extra.h", before="#include <linux/syscalls.h>")
s = open(sysc).read()

PRIO_ANCHOR = ("\t\telse if (!uid_eq(uid, cred->uid)) {\n"
               "\t\t\tuser = find_user(uid);\n")
if PRIO_ANCHOR not in s:
    errors.append("kernel/sys.c: PRIO_USER anchor not found")
else:
    n = s.count(PRIO_ANCHOR)
    # setpriority + getpriority both have this anchor (goto out_unlock)
    repl = ("\t\telse if (!uid_eq(uid, cred->uid)) {\n"
            "#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
            "\t\t\tif (cred->uid.val >= 10000 &&\n"
            "\t\t\t    susfs_uid_priority_filtered(uid.val))\n"
            "\t\t\t\tgoto out_unlock;\n"
            "#endif\n"
            "\t\t\tuser = find_user(uid);\n")
    s = s.replace(PRIO_ANCHOR, repl)
    open(sysc, "w").write(s)
    print("    kernel/sys.c: priority filter injected (%d sites)" % n)

# ---------------------------------------------------------------- block/ioprio.c
iop = os.path.join(SRC, "block/ioprio.c")
s = open(iop).read()
add_include(iop, "linux/susfs_extra.h", before="#include <linux/ioprio.h>")
s = open(iop).read()

IO_ANCHOR = "\t\t\telse\n\t\t\t\tuser = find_user(uid);\n"
if IO_ANCHOR not in s:
    errors.append("block/ioprio.c: IOPRIO_WHO_USER anchor not found")
else:
    n = s.count(IO_ANCHOR)
    repl = ("\t\t\telse {\n"
            "#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n"
            "\t\t\t\tif (current_uid().val >= 10000 &&\n"
            "\t\t\t\t    susfs_uid_priority_filtered(uid.val))\n"
            "\t\t\t\t\tbreak;\n"
            "#endif\n"
            "\t\t\t\tuser = find_user(uid);\n"
            "\t\t\t}\n")
    s = s.replace(IO_ANCHOR, repl)
    open(iop, "w").write(s)
    print("    block/ioprio.c: priority filter injected (%d sites)" % n)

if errors:
    for e in errors:
        print("!! " + e, file=sys.stderr)
    sys.exit(1)

print("    integrate_extra.py: all extra-feature hooks injected OK")
