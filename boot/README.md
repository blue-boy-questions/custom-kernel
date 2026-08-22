# Optional: your stock boot.img

**For `algiz`, this is already done — you do not need to put anything here.** The
stock image is attached to the
[`stock-images-algiz`](https://github.com/blue-boy-questions/custom-kernel/releases/tag/stock-images-algiz)
release; pass that asset's download URL as the workflow's `boot_img_url` input and
the run will emit a repacked, fastboot-flashable `boot.img` alongside the
AnyKernel3 zip:

```
https://github.com/blue-boy-questions/custom-kernel/releases/download/stock-images-algiz/boot.img
```

sha256 `227e34c2798893a0743da64b4ed44413b9cfda6501087596af99b781625d2720`, 41943040
bytes, kernel `6.6.89-android15-8-gbe8d201b0d27-ab13762941-4k`, no Magisk patch.

Keeping it as a release asset rather than a committed file keeps 40 MB of vendor
binary out of the git history, where it could not be removed without a rewrite.

---

Drop your **stock** (unmodified) `boot.img` here as `boot/boot.img` instead if you
prefer it to be automatic for every run, including push-triggered ones.

How to get it:

- Extract it from the Volla OS 16 factory image / OTA payload for `algiz`, or
- dump it from the device:

```bash
adb shell su -c "dd if=/dev/block/by-name/boot\$(getprop ro.boot.slot_suffix) of=/sdcard/boot.img"
```

then `adb pull /sdcard/boot.img`.

Keep a copy somewhere safe — it is your recovery path if the custom kernel does
not boot.

Alternatively, don't commit anything here and pass the `boot_img_url` input when
running the workflow. A committed `boot/boot.img` takes precedence over the URL.

Note that a repacked `boot.img` contains **no** Magisk patch; re-patch it with
Magisk afterwards, or just flash the AnyKernel3 zip instead (that path preserves
an existing Magisk patch).

**KernelSU in LKM mode is unaffected either way.** Its patch is in the
`init_boot` partition (ramdisk only, `kernel_size: 0`), not `boot` (kernel only,
`ramdisk_size: 0`) — so you do not restore stock `init_boot` before flashing a
new `boot.img`, and doing so would only remove your root.

The repacked image is given a fresh AVB hash footer with algorithm `NONE`,
because re-signing needs Volla's private AVB key. It therefore only boots with
an unlocked bootloader, which flashing a custom kernel requires anyway.
