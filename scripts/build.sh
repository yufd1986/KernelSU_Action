#!/usr/bin/env bash
# Prepare the defconfig and compile the kernel.

set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/kernelsu.sh
. "$(dirname "${BASH_SOURCE[0]}")/kernelsu.sh"
# shellcheck source=scripts/patches.sh
. "$(dirname "${BASH_SOURCE[0]}")/patches.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
ARCH=${ARCH:-arm64}
OUT="${KERNEL_DIR}/out"

# Export toolchain directories into PATH so Clang's -no-integrated-as can locate GNU as/ld
export PATH="${WORKSPACE}/clang/bin:${WORKSPACE}/gcc-64/bin:${WORKSPACE}/gcc-32/bin:${PATH}"

DEFCONFIG_PATH="${KERNEL_DIR}/arch/${ARCH}/configs/${KERNEL_CONFIG}"

# ------------------------------------------------------------- defconfig ---

prepare_defconfig() {
	group "Preparing defconfig"
	if [ -f "${REPO_ROOT}/configs/${KERNEL_CONFIG}" ]; then
		info "Using custom defconfig from configs/${KERNEL_CONFIG}"
		cp "${REPO_ROOT}/configs/${KERNEL_CONFIG}" "$DEFCONFIG_PATH"
	fi
	[ -f "$DEFCONFIG_PATH" ] \
		|| die "defconfig not found: arch/${ARCH}/configs/${KERNEL_CONFIG}
       Available: $(ls "${KERNEL_DIR}/arch/${ARCH}/configs/" | head -20 | tr '\n' ' ')"

	cp "$DEFCONFIG_PATH" "${WORKSPACE}/defconfig.orig"

	# Disable standalone -Werror in subdirectories without corrupting flags like -Werror-implicit-function-declaration
	find "${KERNEL_DIR}" -type f \( -name "Makefile*" -o -name "Kbuild*" \) -exec sed -i 's/[[:space:]]-Werror[[:space:]]/ /g; s/[[:space:]]-Werror$/ /g' {} + 2>/dev/null || true
	[ -f "${KERNEL_DIR}/mm/Makefile" ] && sed -i 's/-Werror//g' "${KERNEL_DIR}/mm/Makefile"

	# Fix Makefile for modern GCC & Clang: add -fcommon to HOSTCFLAGS, -gdwarf-4, -Wno-unused-but-set-variable, -fno-builtin-stpcpy to KBUILD_CFLAGS
	if [ -f "${KERNEL_DIR}/Makefile" ]; then
		sed -i 's/HOSTCFLAGS   :=/HOSTCFLAGS   := -fcommon /' "${KERNEL_DIR}/Makefile"
		sed -i 's/KBUILD_CFLAGS   :=/KBUILD_CFLAGS   := -gdwarf-4 -Wno-unused-but-set-variable -fno-builtin-stpcpy /' "${KERNEL_DIR}/Makefile"
	fi

	# Fix stpcpy for Clang: add implementation to lib/string.c and declaration to include/linux/string.h if missing
	local string_c="${KERNEL_DIR}/lib/string.c"
	if [ -f "$string_c" ] && ! grep -q "char \*stpcpy(" "$string_c"; then
		cat << 'EOF' >> "$string_c"

#ifndef __HAVE_ARCH_STPCPY
char *stpcpy(char *dest, const char *src)
{
	while ((*dest++ = *src++) != '\0')
		/* nothing */;
	return --dest;
}
EXPORT_SYMBOL(stpcpy);
#endif
EOF
	fi

	local string_h="${KERNEL_DIR}/include/linux/string.h"
	if [ -f "$string_h" ] && ! grep -q "stpcpy(" "$string_h"; then
		sed -i '/extern char \* strcpy/a extern char *stpcpy(char *, const char *);' "$string_h" || true
	fi

	# Fix MTK drvgen build: suppress missing dws for overlay dts and use python
	if [ -f "${KERNEL_DIR}/scripts/drvgen/drvgen.mk" ]; then
		sed -i 's/if \[ -f \$\$dws_path \]/if [ -n "$$base_prj" ] \&\& [ -f $$dws_path ]/' "${KERNEL_DIR}/scripts/drvgen/drvgen.mk"
		sed -i 's/\$(python)/python/g' "${KERNEL_DIR}/scripts/drvgen/drvgen.mk"
	fi

	# Fix dtc yylloc multiple definition under GCC 10+
	if [ -f "${KERNEL_DIR}/scripts/dtc/dtc-lexer.l" ]; then
		sed -i 's/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' "${KERNEL_DIR}/scripts/dtc/dtc-lexer.l"
	fi
	if [ -f "${KERNEL_DIR}/scripts/dtc/dtc-lexer.lex.c_shipped" ]; then
		sed -i 's/^YYLTYPE yylloc;/extern YYLTYPE yylloc;/' "${KERNEL_DIR}/scripts/dtc/dtc-lexer.lex.c_shipped"
	fi

	# Fix VDSO gettimeofday.S macro comma syntax for modern assemblers
	local vdso_gtod="${KERNEL_DIR}/arch/arm64/kernel/vdso/gettimeofday.S"
	if [ -f "$vdso_gtod" ]; then
		sed -i 's/clock_gettime_return, shift=1/clock_gettime_return shift=1/g' "$vdso_gtod"
	fi

	# Add missing J22 panel revision 0C driver
	local panel_dst="${KERNEL_DIR}/drivers/gpu/drm/panel"
	if [ -d "$panel_dst" ] && [ -f "${REPO_ROOT}/patches/panel_j22_43_03_0c_vdo.c" ]; then
		info "Installing J22 0C panel driver"
		cp "${REPO_ROOT}/patches/panel_j22_43_03_0c_vdo.c" "${panel_dst}/"
		if ! grep -q "CONFIG_DRM_PANEL_J22_43_03_0C_VDO" "${panel_dst}/Makefile"; then
			echo 'obj-$(CONFIG_DRM_PANEL_J22_43_03_0C_VDO) += panel_j22_43_03_0c_vdo.o' >> "${panel_dst}/Makefile"
		fi
		if ! grep -q "DRM_PANEL_J22_43_03_0C_VDO" "${panel_dst}/Kconfig"; then
			cat << 'EOF' >> "${panel_dst}/Kconfig"

config DRM_PANEL_J22_43_03_0C_VDO
	tristate "J22 43 03 0C video mode panel"
	depends on OF
	depends on DRM_PANEL
	help
	  Say Y here if you want to enable support for J22 43 03 0C VDO
EOF
		fi
	fi

	# Relax vermagic and symbol CRC checks to ensure all vendor proprietary modules load seamlessly
	local mod_c="${KERNEL_DIR}/kernel/module.c"
	if [ -f "$mod_c" ]; then
		info "Bypassing module vermagic and CRC strict checks"
		python3 -c "
with open('$mod_c', 'r') as f:
    s = f.read()
s = s.replace('!same_magic(modmagic, vermagic, info->index.vers)', '0 /* same_magic bypass */')
t2 = 'static int check_version(const struct load_info *info,\n\t\t\t const char *symname,\n\t\t\t struct module *mod,\n\t\t\t const s32 *crc)\n{'
if t2 in s:
    s = s.replace(t2, t2 + '\n\treturn 1;')
with open('$mod_c', 'w') as f:
    f.write(s)
" || true
	fi

	local kver
	kver=$(kernel_version "$KERNEL_DIR" || echo "0.0")

	if [ "${KSU_VARIANT:-none}" != "none" ]; then
		kconf_enable "$DEFCONFIG_PATH" CONFIG_KSU
		ksu_hook_configs "${KSU_VARIANT}" "${KSU_HOOK_MODE:-auto}" "$DEFCONFIG_PATH" "$kver"

		if is_true "${ENABLE_SUSFS:-false}"; then
			susfs_defconfig "$DEFCONFIG_PATH"
		fi

		if is_true "${ENABLE_KPM:-false}"; then
			# patch_linux resolves symbols at runtime, so kallsyms must be complete.
			kconf_set_many "$DEFCONFIG_PATH" \
				CONFIG_KPM=y CONFIG_KALLSYMS=y CONFIG_KALLSYMS_ALL=y
		fi
	fi

	# Overlayfs backs KernelSU's module mounts and system-partition writes.
	is_true "${ADD_OVERLAYFS_CONFIG:-false}" && kconf_enable "$DEFCONFIG_PATH" CONFIG_OVERLAY_FS

	# Kept as a standalone switch for kernels that need kprobes for their own
	# reasons, independent of the hook mode.
	if is_true "${ADD_KPROBES_CONFIG:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_MODULES=y CONFIG_KPROBES=y CONFIG_HAVE_KPROBES=y CONFIG_KPROBE_EVENTS=y
	elif [ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
		kconf_disable "$DEFCONFIG_PATH" CONFIG_KPROBES
	fi

	if is_true "${DISABLE_LTO:-false}"; then
		kconf_set_many "$DEFCONFIG_PATH" \
			CONFIG_LTO=n CONFIG_LTO_CLANG=n CONFIG_LTO_CLANG_FULL=n \
			CONFIG_LTO_CLANG_THIN=n CONFIG_THINLTO=n CONFIG_LTO_NONE=y
	fi

	is_true "${DISABLE_CC_WERROR:-false}" && kconf_disable "$DEFCONFIG_PATH" CONFIG_CC_WERROR
	kconf_disable "$DEFCONFIG_PATH" CONFIG_DEBUG_INFO

	# Free-form extras: one CONFIG_x=y per line, or space separated.
	if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
		local kv
		# shellcheck disable=SC2086
		for kv in $(printf '%s' "$EXTRA_DEFCONFIG" | tr '\n' ' '); do
			[ -n "$kv" ] || continue
			case "$kv" in
				*=*) kconf_set "$DEFCONFIG_PATH" "${kv%%=*}" "${kv#*=}" ;;
				*)   warn "ignoring malformed EXTRA_DEFCONFIG entry '${kv}' (want CONFIG_X=y)" ;;
			esac
		done
	fi

	# A stable LOCALVERSION keeps artifact names predictable. Without this the
	# tree appends "-dirty" as soon as any patch above touches a tracked file.
	if [ -n "${KERNEL_NAME:-}" ]; then
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION "\"-${KERNEL_NAME}\""
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "\$res"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	else
		kconf_set "$DEFCONFIG_PATH" CONFIG_LOCALVERSION '""'
		if [ -f "${KERNEL_DIR}/scripts/setlocalversion" ]; then
			sed -i 's/echo "\$res"/echo "-g699d347"/; s/-dirty//g' "${KERNEL_DIR}/scripts/setlocalversion"
		fi
	fi

	info "defconfig changes:"
	diff -u "${WORKSPACE}/defconfig.orig" "$DEFCONFIG_PATH" | sed -n '4,$p' | sed 's/^/    /' || true
	endgroup
}

# ----------------------------------------------------------------- build ---

make_args() {
	printf '%s' "O=out ARCH=${ARCH}"
	[ -n "${CUSTOM_CMDS:-}" ] && printf ' %s' "$CUSTOM_CMDS"
	[ -n "${EXTRA_CMDS:-}"  ] && printf ' %s' "$EXTRA_CMDS"
	[ -n "${GCC_64:-}"      ] && printf ' %s' "$GCC_64"
	[ -n "${GCC_32:-}"      ] && printf ' %s' "$GCC_32"
	if is_true "${USE_LLVM:-false}"; then
		printf ' LLVM=1 LLVM_IAS=1'
		[ -n "${GCC_64:-}" ] || printf ' CROSS_COMPILE=aarch64-linux-gnu-'
	fi
}

build_kernel() {
	group "Building kernel"
	export PATH="${CLANG_PATH:-}:${WORKSPACE}/clang/bin:${WORKSPACE}/gcc-64/bin:${WORKSPACE}/gcc-32/bin:${PATH}"
	export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-Github-Action}
	export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-kernelsu-action}

	# DISABLE_LTO is this action's boolean configuration switch, but several
	# Android kernel trees use the same Make variable for compiler flags (for
	# example, "-fno-lto").  Leaving our value in the environment makes a
	# non-LTO build invoke `clang ... false ...`, treating "false" as an input
	# file.  prepare_defconfig() has already consumed the action setting, so let
	# Kbuild own the name from this point on.
	unset DISABLE_LTO

	# Custom manager signature, when the user builds their own manager APK.
	if [ -n "${KSU_EXPECTED_SIZE:-}" ] && [ -n "${KSU_EXPECTED_HASH:-}" ]; then
		export KSU_EXPECTED_SIZE KSU_EXPECTED_HASH
		info "using custom manager signature (size=${KSU_EXPECTED_SIZE})"
	fi

	local cc="clang" args
	args=$(make_args)
	if is_true "${ENABLE_CCACHE:-true}" && command -v ccache >/dev/null; then
		cc="ccache clang"
		export CCACHE_DIR="${CCACHE_DIR:-${WORKSPACE}/.ccache}"
		info "ccache enabled (dir: ${CCACHE_DIR})"
	fi

	export PYTHON=python

	cd "$KERNEL_DIR"
	info "make ${args} ${KERNEL_CONFIG}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC=clang $args "${KERNEL_CONFIG}" \
		|| die "defconfig generation failed"

	info "make ${args} ${KERNEL_IMAGE_NAME:-}"
	# shellcheck disable=SC2086
	make -j"$(nproc --all)" CC="$cc" $args ${KERNEL_IMAGE_NAME:-} \
		|| die "kernel build failed"

	endgroup
}

# --------------------------------------------------------------- verify ---

check_output() {
	group "Checking build output"
	local boot="${OUT}/arch/${ARCH}/boot"
	local image="${boot}/${KERNEL_IMAGE_NAME}"

	[ -f "$image" ] || die "expected kernel image not found: ${image}
       Built files: $(ls "$boot" 2>/dev/null | tr '\n' ' ')
       Check that KERNEL_IMAGE_NAME matches what your kernel produces."

	ok "kernel image: ${KERNEL_IMAGE_NAME} ($(du -h "$image" | cut -f1))"
	export_env CHECK_FILE_IS_OK true

	if is_true "${NEED_DTBO:-false}"; then
		[ -f "${boot}/dtbo.img" ] || die "NEED_DTBO=true but ${boot}/dtbo.img was not produced"
		export_env CHECK_DTBO_IS_OK true
		ok "dtbo.img present"
	fi

	# KPM rewrites the image in place, so it has to happen after the build and
	# before packaging.
	if is_true "${ENABLE_KPM:-false}"; then
		kpm_patch_image "$image"
	fi

	# Record the version string the kernel actually reports.
	if [ -f "${OUT}/include/generated/utsrelease.h" ]; then
		local rel
		rel=$(sed -nE 's/.*UTS_RELEASE[[:space:]]+"([^"]+)".*/\1/p' "${OUT}/include/generated/utsrelease.h")
		export_env KERNEL_RELEASE "$rel"
		ok "kernel release: ${rel}"
		summary "| Kernel release | \`${rel}\` |"
	fi
	endgroup
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		defconfig) prepare_defconfig ;;
		compile)   build_kernel ;;
		check)     check_output ;;
		all)       prepare_defconfig; build_kernel; check_output ;;
		*) die "unknown build step '$1'" ;;
	esac
fi
