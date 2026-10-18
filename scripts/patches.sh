#!/usr/bin/env bash
# Kernel source patching: SUSFS, path_umount backport, hide_stuff, manual hooks.
#
# Everything here is idempotent and version-aware. Each step is skipped with a
# clear message when it is unnecessary (feature already present) rather than
# failing, because these trees are frequently already partially patched.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
# Resolved from this file's location, not $PWD -- several helpers below run
# with the working directory changed into the kernel tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

# susfs_branch_for KVER -- map a kernel version onto a susfs4ksu branch.
#
# susfs4ksu is branched per kernel version. The GKI branches are named after
# the Android release they ship with; where a kernel version spans two Android
# releases (5.10 -> android12/android13, 5.15 -> android13/android14) we pick
# the older, which is the one the vast majority of trees are based on.
# Override with SUSFS_BRANCH when that guess is wrong.
susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6)  echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

# susfs_repair_readdir -- put the sus_path readdir guards where they belong.
#
# Idempotent: strips every existing guard and re-inserts one at the top of each
# filldir* body, so a second run changes nothing. Also restores the
# susfs_def.h include, which the same rejected hunk carries.
susfs_repair_readdir() {
	local f="${KERNEL_DIR}/fs/readdir.c"
	[ -f "$f" ] || return 0

	READDIR_C="$f" python3 - <<'PYEOF' || die "failed to repair fs/readdir.c"
import os, re, sys

path = os.environ["READDIR_C"]
src = open(path).read()

GUARD_LINES = [
    "#ifdef CONFIG_KSU_SUSFS_SUS_PATH",
    "\tif (likely(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC) && susfs_sus_ino_for_filldir64(ino)) {",
    "\t\treturn 0;",
    "\t}",
    "#endif",
]

# 1. Drop every copy the patch left behind, plus the blank line it appends.
block = re.compile(
    r"[ \t]*#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
    r"[ \t]*if \(likely\(current->susfs_task_state & TASK_STRUCT_NON_ROOT_USER_APP_PROC\)"
    r" && susfs_sus_ino_for_filldir64\(ino\)\) \{\n"
    r"[ \t]*return 0;\n"
    r"[ \t]*\}\n"
    r"[ \t]*#endif\n"
    r"\n?")
src, removed = block.subn("", src)

# 2. The include block lives in its own hunk; add it if that hunk was dropped.
if "#include <linux/susfs_def.h>" not in src:
    anchor = "#include <linux/uaccess.h>\n"
    if anchor not in src:
        sys.exit("fs/readdir.c: no '#include <linux/uaccess.h>' anchor")
    inc = ("#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
           "#include <linux/susfs_def.h>\n"
           "extern int susfs_sus_ino_for_filldir64(unsigned long ino);\n"
           "#endif\n")
    src = src.replace(anchor, anchor + inc, 1)

# 3. Re-insert at the top of each callback body, anchored on the signature.
#    `ino` is a parameter of all four, so the guard is valid in all four.
lines = src.split("\n")
targets = ["static int filldir(", "static int filldir64(",
           "static int compat_fillonedir(", "static int compat_filldir("]
body_at = {}
for t in targets:
    for j, ln in enumerate(lines):
        if ln.startswith(t):
            k = j
            while k < len(lines) and lines[k].strip() != "{":
                k += 1
            if k < len(lines):
                body_at[t] = k
            break

missing = [t for t in targets if t not in body_at]
if missing:
    sys.exit("fs/readdir.c: could not find body of " + ", ".join(missing))

new, inserted = [], 0
for j, ln in enumerate(lines):
    new.append(ln)
    if j in set(body_at.values()):
        new.extend(GUARD_LINES)
        inserted += 1

open(path, "w").write("\n".join(new))
print("readdir.c: removed %d stale guard(s), inserted %d" % (removed, inserted))
PYEOF

	ok "fs/readdir.c: sus_path guards re-anchored to the filldir* bodies"
}

# susfs_add_include FILE AFTER_LINE -- insert the susfs_def.h include block
# after the given existing include line. Used when the include hunk of the
# SUSFS patch rejects because the tree has an extra include in the way.
susfs_add_include() {
	local f=$1 after=$2
	[ -f "$f" ] || die "no such file: $f"
	grep -q '#include <linux/susfs_def.h>' "$f" && return 0

	python3 - "$f" "$after" <<'PYEOF' || die "failed to add the susfs_def.h include to $f"
import sys

path, after = sys.argv[1], sys.argv[2]
src = open(path).read()
if after not in src:
    sys.exit("anchor not found: %r" % after)
inc = ("#ifdef CONFIG_KSU_SUSFS_SUS_PATH\n"
       "#include <linux/susfs_def.h>\n"
       "#endif\n")
src = src.replace(after + "\n", after + "\n" + inc, 1)
open(path, "w").write(src)
print("added susfs_def.h include to", path)
PYEOF
}

# susfs_filter_patch IN OUT DROP_FDINFO -- drop the sections we patch by hand.
#
# Three places in the 4.14 patch assume a tree that is not this one:
#
#   fs/readdir.c        anchors on `buf->error = verify_dirent_name(...)`;
#                       MIUI has `buf->error = -EINVAL;`. Dropped -- the four
#                       guards and the include are re-inserted by
#                       susfs_repair_readdir(), anchored on the signatures.
#   fs/notify/fdinfo.c  rewrites inotify_fdinfo() around
#                       inotify_mark_user_mask(), absent here. Dropped whole
#                       when the tree lacks it: hunk 1 and 2 must not be
#                       applied on their own, or show_fdinfo() would call the
#                       callbacks with three arguments while they still take
#                       two. The file is self-contained (show_fdinfo is
#                       static), so skipping it is safe -- it only hides
#                       inotify watches on sus_path inodes from
#                       /proc/<pid>/fdinfo, which nothing here relies on.
#   fs/dcache.c         the include hunk is shifted by an extra
#                       `#include <linux/kasan.h>`; only that one hunk is
#                       dropped and susfs_add_include() puts the block in.
susfs_filter_patch() {
	local in=$1 out=$2 drop_fdinfo=${3:-0}

	IN=$in OUT=$out DROP_FDINFO=$drop_fdinfo python3 - <<'PYEOF' \
		|| die "failed to filter $(basename "$in")"
import os, sys

src, dst = os.environ["IN"], os.environ["OUT"]
drop_fdinfo = os.environ.get("DROP_FDINFO") == "1"
lines = open(src, encoding="utf-8", errors="replace").read().split("\n")

sections = []          # (path, header_lines, [hunk_lines, ...])
i, n = 0, len(lines)
while i < n:
    if not lines[i].startswith("diff --git "):
        i += 1
        continue
    path = lines[i].split(" b/")[0][len("diff --git a/"):].strip()
    header, hunks, i = [], [], i
    while i < n and not lines[i].startswith("@@"):
        header.append(lines[i]); i += 1
    cur = None
    while i < n and not lines[i].startswith("diff --git "):
        if lines[i].startswith("@@"):
            if cur:
                hunks.append(cur)
            cur = [lines[i]]
        elif cur is not None:
            cur.append(lines[i])
        else:
            header.append(lines[i])
        i += 1
    if cur:
        hunks.append(cur)
    sections.append((path, header, hunks))

out, dropped = [], []
for path, header, hunks in sections:
    if path == "fs/readdir.c":
        dropped.append(path)
        continue
    if path == "fs/notify/fdinfo.c" and drop_fdinfo:
        dropped.append(path + " (no inotify_mark_user_mask)")
        continue
    kept = hunks
    if path == "fs/dcache.c":
        kept = [h for h in hunks
                if not any(l.startswith("+") and "susfs_def.h" in l for l in h)]
        if len(kept) != len(hunks):
            dropped.append(path + " (include hunk)")
    if not kept:
        continue
    out.extend(header)
    for h in kept:
        out.extend(h)

open(dst, "w").write("\n".join(out))
print("filtered patch: dropped " + "; ".join(dropped))
PYEOF
}

# susfs_assert_no_rejects -- after a strict apply there must be no rejects. Any
# reject means this tree diverges somewhere we have not looked at, and shipping
# a half-patched kernel is worse than failing the build.
susfs_assert_no_rejects() {
	local rej
	rej=$(find "$KERNEL_DIR/fs" "$KERNEL_DIR/include" "$KERNEL_DIR/kernel" \
		-name '*.rej' 2>/dev/null || true)
	if [ -z "$rej" ]; then
		ok "SUSFS kernel patch applied with zero rejects"
		return 0
	fi
	local f
	for f in $rej; do
		warn "reject: ${f}"
		sed -n '1,40p' "$f" >&2
	done
	die "the SUSFS patch left rejects; teach susfs_filter_patch about them"
}

# apply_susfs_kernel_patch PATCH -- strict apply, zero fuzz, no silent repairs.
#
# Deliberately NOT apply_patch(): that falls back to --fuzz=3 when the strict
# apply fails, and a fuzzy match does not fail loudly -- it drops context lines
# and lands the hunk at the next plausible spot. On this MIUI tree that put the
# readdir guard inside SYSCALL_DEFINE3(getdents, ...)'s parameter list (run
# 39108700947) and the fdinfo block inside a seq_printf() call (39109942958).
apply_susfs_kernel_patch() {
	local patch=$1

	( cd "$KERNEL_DIR" && patch -p1 --fuzz=0 --force --forward \
		--no-backup-if-mismatch -i "$patch" ) >/dev/null 2>&1 || true
	susfs_assert_no_rejects
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")
		[ -n "$branch" ] || die "no susfs4ksu branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"
		info "kernel ${kver} -> susfs branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" \
		|| die "susfs4ksu has no branch '${branch}'.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"
	retry 3 git clone -q --depth=1 -b "$branch" "$repo" "$susfs_dir" \
		|| die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"
	[ -d "$kp" ] || die "unexpected susfs4ksu layout: ${kp} missing"

	# 1. Drop in the SUSFS sources. The non-GKI branches carry sus_su.c too.
	info "copying SUSFS sources into the kernel tree"
	cp -v "${kp}/fs/"*.c              "${KERNEL_DIR}/fs/"            2>/dev/null || true
	cp -v "${kp}/include/linux/"*.h   "${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# 2. Patch the kernel itself.
	local kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"
	[ -f "$kernel_patch" ] || {
		# Fall back to whatever 50_* patch the branch actually ships.
		kernel_patch=$(find "$kp" -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -n1)
	}
	[ -n "$kernel_patch" ] && [ -f "$kernel_patch" ] \
		|| die "no 50_add_susfs_in_*.patch found in ${kp}"

	# 2. Patch the kernel itself. The patch is filtered first so that the three
	#    files this tree diverges on are handled by name rather than by fuzz
	#    (see susfs_filter_patch), then applied with zero fuzz and zero
	#    tolerance for rejects.
	local filtered="${WORKSPACE}/susfs_kernel_filtered.patch"
	local drop_fdinfo=0
	grep -q 'inotify_mark_user_mask' "${KERNEL_DIR}/fs/notify/fdinfo.c" 2>/dev/null \
		|| drop_fdinfo=1
	susfs_filter_patch "$kernel_patch" "$filtered" "$drop_fdinfo"
	apply_susfs_kernel_patch "$filtered" \
		|| die "the SUSFS kernel patch did not apply.
       This usually means SUSFS_BRANCH does not match your kernel. Detected
       kernel ${kver}, used branch '${branch}'."

	# The two files that are patched by hand instead of by the patch file.
	susfs_repair_readdir
	susfs_add_include "${KERNEL_DIR}/fs/dcache.c" '#include <linux/list_lru.h>'

	# 3. Patch the KernelSU side -- but only when the variant does not already
	#    ship SUSFS support. SukiSU-Ultra's 'builtin' branch, for instance,
	#    declares CONFIG_KSU_SUSFS itself; applying the patch on top conflicts.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-the selected variant} already bundles SUSFS at ref '${KSU_REF_RESOLVED:-}'; skipping 10_enable_susfs_for_ksu.patch"
	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory ${ksu_dir} not found; skipping the KernelSU-side SUSFS patch"
	elif [ ! -f "$ksu_patch" ]; then
		warn "branch ${branch} ships no KernelSU/10_enable_susfs_for_ksu.patch; skipping"
	else
		( cd "$ksu_dir" && apply_patch "$ksu_patch" 1 ) || {
			warn "the KernelSU-side SUSFS patch did not apply."
			warn "susfs4ksu's non-GKI branches were last updated in early 2025 and still"
			warn "target the old flat KernelSU layout; modern forks have since moved to a"
			warn "modular kernel/ tree. Try a variant/ref whose layout matches, or a fork"
			warn "that bundles SUSFS itself (e.g. KSU_VARIANT=sukisu-ultra KSU_REF=builtin)."
			die "SUSFS integration failed"
		}
	fi

	# Record the SUSFS version for the build summary.
	local sv
	sv=$(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
		"${KERNEL_DIR}/include/linux/susfs.h" 2>/dev/null | head -n1)
	export_env SUSFS_VERSION "${sv:-unknown}"
	export_env SUSFS_BRANCH_RESOLVED "$branch"
	ok "SUSFS ${sv:-?} applied from branch ${branch}"
	summary "| SUSFS | \`${sv:-unknown}\` (branch \`${branch}\`) |"
	endgroup
}

# Does the selected variant+ref already contain SUSFS?
susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--} ref=${KSU_REF_RESOLVED:-}
	[ "$bundled" = "-" ] && return 1
	local r
	for r in $bundled; do
		[ "$r" = "$ref" ] && return 0
	done
	# Fall back to inspecting the tree, which is authoritative.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	[ -d "$ksu_dir" ] && grep -rqs 'CONFIG_KSU_SUSFS\|config KSU_SUSFS' "${ksu_dir}/kernel/Kconfig" 2>/dev/null
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# The SUSFS option set is NOT stable across branches, so it is discovered
	# from the Kconfig that was actually patched in rather than hardcoded.
	#
	# Concretely: the GKI branches ship SUSFS v2.x, which declares SUS_MAP and
	# has dropped the AUTO_ADD_*/SUS_OVERLAYFS/HAS_MAGIC_MOUNT knobs. The
	# non-GKI branches are still on v1.5.5 (last touched early 2025), which is
	# the exact opposite: it has the AUTO_ADD_* family and no SUS_MAP. A
	# hardcoded list is therefore wrong on one side or the other -- and wrong
	# in the silent direction, since an unknown symbol in a defconfig is simply
	# dropped, leaving the feature off with no warning.
	local syms
	syms=$(grep -rhoE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
			"$ksu_dir" "${KERNEL_DIR}/fs/Kconfig" "${KERNEL_DIR}/drivers/kernelsu" 2>/dev/null \
		| awk '{print $2}' | sort -u)

	if [ -z "$syms" ]; then
		die "found no KSU_SUSFS Kconfig symbols to enable.
       The SUSFS sources are in the tree but nothing declares its options, so
       the feature would silently compile out and you would ship a kernel that
       looks patched but hides nothing. Check that the KernelSU-side patch
       applied, or pick a variant that bundles SUSFS."
	fi

	local s enabled=0
	for s in $syms; do
		case "$s" in
			# sus_su is the legacy in-kernel su backend, superseded by the
			# manager; overlayfs hiding conflicts with magic mount. Both are
			# off in the reference builds.
			KSU_SUSFS_SUS_SU | KSU_SUSFS_SUS_OVERLAYFS)
				kconf_disable "$defconfig" "CONFIG_${s}" ;;
			*)
				kconf_enable "$defconfig" "CONFIG_${s}"; enabled=$((enabled + 1)) ;;
		esac
	done
	ok "enabled ${enabled} SUSFS options discovered from Kconfig"
	debug "SUSFS symbols: $(printf '%s ' $syms)"
}

# =============================================================== path_umount

# path_umount() landed upstream in Linux 5.9. KernelSU uses it to unmount its
# own overlays before handing control to an app that is checking for root, so
# on older trees it has to be backported or module unmounting silently no-ops.
#
# The body below is upstream's, unchanged. It is inserted immediately before
# the comment that introduces the umount syscall, which puts it after
# do_umount() -- its only forward dependency -- in every tree from 4.9 to 5.4.
path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"
	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup; return 0
	fi
	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -q '^int path_umount\|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup; return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'
	grep -q "$anchor" "$ns" \
		|| die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)
	# 'can_umount' is a separate helper upstream; guard it in case a partial
	# backport already added it.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

EOF
	fi
	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	# Insert before the line *above* the anchor comment body, i.e. at the '/*'
	# that opens it.
	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)
	# Walk back to the opening '/*' of that comment block.
	local start=$lineno
	while [ "$start" -gt 1 ] && ! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)
	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"
	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" || die "path_umount() insertion failed"
	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"
	endgroup
}

# ============================================================== extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

# Clone the shared patch/tool repo once, on demand.
sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"
	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 "$SUKISU_PATCH_REPO" "$dir" \
			|| die "failed to clone ${SUKISU_PATCH_REPO}"
	fi
	printf '%s' "$dir"
}

# hide_stuff removes the most obvious KernelSU fingerprints from the build.
hide_stuff_apply() {
	group "Applying hide_stuff"
	local dir patch
	dir=$(sukisu_patch_dir)
	patch="${dir}/69_hide_stuff.patch"
	[ -f "$patch" ] || { warn "69_hide_stuff.patch not found in the patch repo; skipping"; endgroup; return 0; }
	( cd "$KERNEL_DIR" && apply_patch "$patch" 1 ) || warn "hide_stuff did not apply cleanly; continuing"
	endgroup
}

# Manual/syscall hook patches for pre-GKI trees, used when the fork expects the
# hooks to already exist in the kernel source rather than hooking via kprobes.
hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none} kver
	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ReSukiSU publishes scope-minimised hook patches keyed by kernel version.
	if [ "$variant" = "resukisu" ]; then
		local dir="${WORKSPACE}/ReSukiSU_Patches"
		[ -d "$dir" ] || retry 3 git clone -q --depth=1 \
			https://github.com/ReSukiSU/ReSukiSU_Patches.git "$dir" || true
		local p="${dir}/scope-minimized/kernel-${kver}.patch"
		if [ -f "$p" ]; then
			( cd "$KERNEL_DIR" && apply_patch "$p" 1 ) && { endgroup; return 0; }
		else
			info "ReSukiSU ships no scope-minimized patch for kernel ${kver}"
		fi
	fi

	# SukiSU's patch repo carries per-version hook patches too.
	if [ "$variant" = "sukisu-ultra" ]; then
		local dir p
		dir=$(sukisu_patch_dir)
		for p in "${dir}/${kver}/"*hook*.patch "${dir}/hooks/syscall_hooks.patch"; do
			[ -f "$p" ] || continue
			if ( cd "$KERNEL_DIR" && apply_patch "$p" 1 ); then endgroup; return 0; fi
		done
	fi

	# Fall back to the in-repo sed script, which is what this action shipped
	# historically and still works for the 4.9-5.4 KernelSU 0.9.x hook API.
	info "falling back to the bundled legacy hook script"
	( cd "$KERNEL_DIR" && bash "${REPO_ROOT}/patches/legacy_ksu_hooks.sh" )
	endgroup
}

# ======================================================================== KPM

# SukiSU-Ultra's Kernel Patch Module support needs a post-link step: the
# patch_linux tool rewrites the built Image and emits oImage.
kpm_patch_image() {
	local image=$1
	group "Applying KPM (patch_linux)"
	local dir tool
	dir=$(sukisu_patch_dir)
	tool="${dir}/kpm/patch_linux"
	[ -f "$tool" ] || die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"
	chmod +x "$tool"
	( cd "$(dirname "$image")" && "$tool" "$(basename "$image")" ) \
		|| die "patch_linux failed"
	local out
	out="$(dirname "$image")/oImage"
	[ -f "$out" ] || die "patch_linux did not produce oImage"
	mv -f "$out" "$image"
	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"
	endgroup
}

# --------------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		susfs)        susfs_apply ;;
		path_umount)  path_umount_apply ;;
		hide_stuff)   hide_stuff_apply ;;
		hooks)        hooks_patch_apply ;;
		kpm)          kpm_patch_image "$2" ;;
		all)
			# Order matters and this is the tested one (4.19 + SukiSU builtin
			# + SUSFS 1.5.5, no rejects):
			#   path_umount and the hook patches both key off textual anchors
			#   in files that SUSFS later rewrites, so they go first.
			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then path_umount_apply; fi

			# Driven by the *resolved* hook mode, not the raw setting, so that
			# KSU_HOOK_MODE=auto on a pre-GKI kernel still gets its hooks
			# patched in rather than only getting the Kconfig symbol set.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
			   [ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
				hooks_patch_apply
			fi

			if is_true "${ENABLE_SUSFS:-false}";      then susfs_apply;      fi
			if is_true "${ENABLE_HIDE_STUFF:-false}"; then hide_stuff_apply; fi
			;;
		*) die "unknown patch step '$1'" ;;
	esac
fi
