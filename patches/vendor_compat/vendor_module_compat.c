/*
 * Compatibility symbols for prebuilt vendor kernel modules.
 *
 * The stock cannon kernel is built with
 *
 *     CONFIG_CC_STACKPROTECTOR_STRONG=y
 *     CONFIG_LTO_CLANG=y
 *     CONFIG_CFI_CLANG=y
 *
 * and every module shipped in /vendor/lib/modules (wmt_drv.ko, bt_drv.ko,
 * wlan_drv_gen4m.ko, gps_drv.ko, fmradio_drv.ko, fpsgo.ko, sla.ko, met.ko)
 * was linked against exactly that kernel.  Those modules therefore reference
 *
 *     __stack_chk_guard / __stack_chk_fail   (stack protector)
 *     __cfi_slowpath / __cfi_slowpath_diag   (CFI)
 *
 * This action disables LTO (it is memory hungry and frequently breaks 4.14
 * builds), and CFI cannot be enabled without LTO, so the symbols above are
 * missing from the built kernel.  The result is silent and severe:
 *
 *     wmt_drv: Unknown symbol __cfi_slowpath (err 0)
 *     wmt_drv: Unknown symbol __stack_chk_fail (err 0)
 *     wmt_drv: Unknown symbol __stack_chk_guard (err 0)
 *
 * wmt_drv is the base module that bt_drv.ko and wlan_drv_gen4m.ko depend on,
 * so nothing in the connectivity stack loads: /proc/modules is empty, there
 * is no /dev/stpbt, and the Bluetooth HAL crash-loops on
 *
 *     init_uart: Can't open /dev/stpbt (No such file or directory)
 *
 * which in turn aborts com.android.bluetooth with
 * "hci_layer_android.cc(87) Check failed: status == Status::SUCCESS" every
 * few seconds.  Wi-Fi is dead for the same reason.
 *
 * Supplying the symbols here lets the vendor modules load again.  The stack
 * protector half is compiled only when this kernel really has stack
 * protector off, so it never clashes with arch/arm64/kernel/stack-protector.c.
 */
#include <linux/cache.h>
#include <linux/export.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>

#ifndef CONFIG_CC_STACKPROTECTOR
/*
 * Vendor modules load this canary at function entry and verify it on return.
 * Any stable value works: corruption still changes it, which is all the
 * check needs.
 */
unsigned long __stack_chk_guard __read_mostly = 0x4f4b5f4b53550001UL;
EXPORT_SYMBOL(__stack_chk_guard);

void __stack_chk_fail(void)
{
	panic("stack-protector: stack corrupted in a vendor module\n");
}
EXPORT_SYMBOL(__stack_chk_fail);
#endif /* !CONFIG_CC_STACKPROTECTOR */

#ifndef CONFIG_CFI_CLANG
/*
 * Vendor modules were instrumented with -fsanitize=cfi and call this before
 * every indirect call.  With CFI compiled out there is no type hash table to
 * validate against, so accept the call.  The modules themselves are still
 * read-only vendor blobs covered by dm-verity.
 */
void __cfi_slowpath(uint64_t cfi_check, void *ptr)
{
}

void __cfi_slowpath_diag(uint64_t cfi_check, void *ptr, void *diag)
{
}

EXPORT_SYMBOL(__cfi_slowpath);
EXPORT_SYMBOL(__cfi_slowpath_diag);
#endif /* !CONFIG_CFI_CLANG */
