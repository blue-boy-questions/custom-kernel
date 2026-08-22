# Optional: your stock boot.img

Drop your **stock** (unmodified) `boot.img` here as `boot/boot.img` if you want
the workflow to emit a fastboot-flashable, repacked `boot.img` in addition to the
AnyKernel3 zip.

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
