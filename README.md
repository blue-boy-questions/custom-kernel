# Volla Phone Quintus (`algiz`) — DroidSpaces-ready Linux 6.6 kernel

Builds HelloVolla's MediaTek MT6877 kernel (**6.6.89**, Volla OS 16 / Android 16)
from source in GitHub Actions, patched so that
[DroidSpaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) works, and
packages the result as an AnyKernel3 zip plus (optionally) a repacked `boot.img`.

Nothing else is changed. **No root solution is compiled into this kernel** — see
[Rooting](#rooting) below.

---

## What this actually does

DroidSpaces needs Linux namespaces and IPC features that Android's GKI
`gki_defconfig` ships disabled. Two changes are required, and only two:

1. **The config fragment.** 17 symbols are enabled in
   `kernel-6.6/arch/arm64/configs/gki_defconfig`
   ([scripts/apply-droidspaces-config.sh](scripts/apply-droidspaces-config.sh)) —
   SYSVIPC, POSIX message queues, IPC/PID namespaces, devtmpfs, user
   namespaces, the netfilter matches and targets UFW and fail2ban need, and
   tmpfs xattr/POSIX-ACL support.

2. **The kABI patch.** Turning on `CONFIG_SYSVIPC` normally adds
   `sysvsem`/`sysvshm` to `struct task_struct`, which shifts every field after
   them. Your stock `vendor_dlkm` modules were compiled against the *unshifted*
   layout, so the phone would bootloop. The patch
   ([patches/](patches/), from DroidSpaces upstream) instead parks both members
   inside the reserved `ANDROID_KABI_RESERVE(6/7/8)` padding slots:

   ```c
   #ifdef CONFIG_SYSVIPC
       ANDROID_KABI_USE(6, struct sysv_sem sysvsem);
       _ANDROID_KABI_REPLACE(ANDROID_KABI_RESERVE(7); ANDROID_KABI_RESERVE(8),
                             struct sysv_shm sysvshm);
   #else
       ANDROID_KABI_RESERVE(6);
       ANDROID_KABI_RESERVE(7);
       ANDROID_KABI_RESERVE(8);
   #endif
   ```

   Under `__GENKSYMS__` the macros expand back to the original reserve slots, so
   symbol CRCs — and therefore the KMI — are unchanged.

Because the layout is preserved, only the **kernel image** has to be rebuilt.
The stock vendor modules keep loading:

- `CONFIG_MODVERSIONS=y` → `same_magic()` in `kernel/module/version.c` skips the
  leading release-string token of vermagic when CRCs are present, so the module's
  `6.6.89-…` string does not have to match byte for byte.
- `CONFIG_MODULE_SIG_PROTECT=y` → `signing.c` hard-defines `sig_enforce` to
  `false`, so modules signed with MediaTek's key (or unsigned) are not rejected.

That is why the workflow's default build scope is `image`, not a full
multi-hour MediaTek `dist` build.

---

## Repository layout

| Path | Purpose |
|---|---|
| [.github/workflows/build-kernel.yml](.github/workflows/build-kernel.yml) | The whole build. Run it from the Actions tab. |
| [local_manifests/algiz.xml](local_manifests/algiz.xml) | `repo` local manifest overlaying the five HelloVolla trees onto AOSP `common-android15-6.6`. |
| [scripts/setup-workspace.sh](scripts/setup-workspace.sh) | `repo init` / `repo sync` + a layout sanity check. |
| [scripts/apply-droidspaces-config.sh](scripts/apply-droidspaces-config.sh) | Idempotent, per-symbol `gki_defconfig` editor. Verifies afterwards. |
| [patches/](patches/) | The three upstream SYSVIPC kABI patch variants. |
| [anykernel3/anykernel.sh](anykernel3/anykernel.sh) | AnyKernel3 config for `algiz` (kernel-image-only flash). |
| [boot/](boot/README.md) | **Optional, you add this.** Drop your stock `boot.img` here to also get a repacked, fastboot-flashable image. |

---

## Building

Actions → **Build algiz DroidSpaces kernel** → *Run workflow*.

| Input | Default | Meaning |
|---|---|---|
| `build_scope` | `image` | `image` builds only the GKI-side `Image`/`Image.lz4`/`Image.gz` + in-tree modules (~40–70 min). `dist` runs the full MediaTek build with every vendor module (several hours, and you do not need it). |
| `mode` | `user` | MTK build variant. `userdebug`/`eng` pull in `userdebug.config`/`eng.config`, which set `MTK_PANIC_ON_WARN`, `DEBUG_KMEMLEAK` and ~80 more debug symbols. Do not daily-drive those. |
| `defconfig_overlays` | `mt6877_overlay.config` | `DEFCONFIG_OVERLAYS`, space separated. Pass the literal `none` for an empty list. |
| `boot_img_url` | *(empty)* | Direct download URL of your **stock** `boot.img`. Alternatively commit it as `boot/boot.img`. |
| `disable_sandbox` | off | Adds `--config=local`. Only if you hit Bazel sandbox errors. |

Artifacts: the AnyKernel3 zip, `Image`, `Image.lz4`, `Image.gz`, `System.map`,
the resolved `.config` and — when you supplied a stock image — `boot.img`.
`vmlinux` and the module set are uploaded as a separate, shorter-retention
artifact.

Every run ends with a verification step that reads the **built** `.config` (not
the defconfig) and fails if any required DroidSpaces option is missing. It also
prints the recommended-but-optional ones, and confirms `MODVERSIONS` /
`MODULE_SIG_PROTECT` are still set.

### Building locally

```bash
scripts/setup-workspace.sh ~/algiz local_manifests/algiz.xml
cd ~/algiz
patch -p1 -d kernel-6.6 < /path/to/patches/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch
/path/to/scripts/apply-droidspaces-config.sh kernel-6.6/arch/arm64/configs/gki_defconfig
sed -i 's|^POST_DEFCONFIG_CMDS="check_defconfig"$|POST_DEFCONFIG_CMDS=""|' kernel-6.6/build.config.gki
export KERNEL_VERSION=kernel-6.6 DEFCONFIG_OVERLAYS=mt6877_overlay.config KLEAF_GKI_CHECKER=no
tools/bazel build --noenable_bzlmod --experimental_writable_outputs \
  --//build/bazel_mgk_rules:kernel_version=6.6 --nokmi_symbol_list_violations_check \
  //kernel_device_modules-6.6:mgk_64_k66_kernel_aarch64.user
```

Roughly 60 GB of disk and 16 GB of RAM.

---

## Flashing

1. **Back up your stock `boot.img` first.** If the kernel does not boot, that
   image is how you get your phone back.
2. Root the phone with Magisk or APatch **before** flashing this kernel (see
   below).
3. Flash `AK3-algiz-droidspaces-*.zip` from a custom recovery, or via the Magisk
   app's *Modules → Install from storage*.
4. Reboot, open DroidSpaces, enable **Daemon Mode**, reboot again.

The AnyKernel3 script runs `split_boot; flash_boot;` — the plain "OG AK" flow. It
replaces **only** the kernel image and leaves your ramdisk exactly as it is, so
an already-Magisk-patched boot image stays patched (`ak3-core.sh` detects Magisk
and re-applies the kernel-side patch on repack). `BLOCK=auto` and
`IS_SLOT_DEVICE=auto` handle the A/B slot suffix.

If you prefer `fastboot`, supply your stock `boot.img` to the workflow and flash
the repacked one:

```bash
fastboot flash boot boot.img
```

That variant is a lossless `unpack_bootimg --format=mkbootimg` →
`mkbootimg` round-trip with only the kernel payload swapped, and the AVB hash
footer re-added at the original partition size. It will **not** contain a Magisk
patch — flash Magisk again afterwards if you go this route.

---

## Rooting

This kernel deliberately contains **no** KernelSU, KernelSU-Next, SukiSU or any
other in-kernel root implementation. Root it from userspace instead:

- **Magisk** or **APatch** — patch your stock boot image as usual, flash it, then
  flash the AnyKernel3 zip on top.
- Then in the DroidSpaces app: enable **Daemon Mode** and reboot. Without
  Daemon Mode, DroidSpaces cannot hold the root session it needs and containers
  will fail to start.

**SuSFS is not supported by DroidSpaces.** If you are running a SuSFS-patched
root solution, DroidSpaces is expected to misbehave; use a plain build.

---

## Notes and caveats

- **Two symbols in the DroidSpaces documentation are wrong for this kernel, and
  the build corrects them.**
  - `CONFIG_NETFILTER_XT_TARGET_REJECT` **does not exist in Linux 6.6.**
    `net/netfilter/Kconfig` defines 26 `NETFILTER_XT_TARGET_*` symbols and
    REJECT is not one of them; there is no `net/netfilter/xt_REJECT.c` either.
    The real symbols are the per-family `IP_NF_TARGET_REJECT`
    (`net/ipv4/netfilter/Kconfig:183`) and `IP6_NF_TARGET_REJECT`
    (`net/ipv6/netfilter/Kconfig:196`), and both are **already `=y`** in the
    stock `algiz` `gki_defconfig`. Those are what the scripts write and verify.
    Writing the documented spelling would be silently dropped by
    `merge_config.sh`/`olddefconfig` — a `CONFIG_X=y` line for a nonexistent
    Kconfig symbol vanishes without a warning — so UFW's REJECT rules would be
    missing while the config looked applied.
  - `CONFIG_CGROUP_DEVICE` is **deliberately left off**, and demoted from fatal
    to informational. The docs call it "Fatal. Containers cannot start.", but
    only in their *non-GKI* list. DroidSpaces' own runtime probe never looks for
    it — its cgroup checks are `/proc/filesystems:cgroup2` and
    `check_ns(CLONE_NEWCGROUP)`, both marked `OPT`. `devices_cgrp_subsys` in
    `security/device_cgroup.c` defines only `.legacy_cftypes`, i.e. cgroup **v1
    only**, which Android 16 does not use for the container hierarchies. And
    enabling it is a kABI break: `include/linux/cgroup_subsys.h` gates
    `SUBSYS(devices)` on it, between `MEMCG` and `CGROUP_FREEZER`, so turning it
    on inserts a `cgroup_subsys_id` enum value and shifts every later ID — the
    exact class of breakage the SYSVIPC padding patch exists to prevent. The
    verify step reports its state and never fails on it.

- **`patches/001.GKI-below-6.12-fix_sysvipc_kabi_1_2_3.patch` does not apply to
  this tree** — its second hunk fails at line 1508 of `include/linux/sched.h` on
  6.6.89. `_6_7_8` is the variant this kernel uses (slots 6/7/8 are the free
  ones here); `_3_4_5` is a working fallback. `patch` is invoked with default
  fuzz on purpose: hunk 1 lands at offset −2 and hunk 2 at offset +8.
- **The two upstream trees are out of sync, and the workflow fixes it.**
  `kernel_device_modules-6.6` @ `volla-16.0` still passes
  `dtb_files = ["mt6899.dtb"]` to `define_mgk()` — a different SoC — but
  `build/bazel_mgk_rules` @ `volla-16.0-algiz` removed DTB handling entirely:
  its `define_mgk()` signature ends at `symbol_list`, with no `dtb`/`dtstree`
  code left to consume the argument. Bazel fails analysis with
  `define_mgk() got unexpected keyword argument: dtb_files` and never declares
  `mgk_64_k66_kernel_aarch64.<mode>`. A dedicated step diffs the call site
  against the signature and drops any kwarg the signature does not accept. The
  `ansuz` branches still carry `dtb_files = None` in the signature, which
  confirms `BUILD.bazel` is the stale side. The step no-ops once HelloVolla
  fixes it, and refuses to guess at any stale kwarg other than `dtb_files`.
- **`check_defconfig` is disabled** for the GKI-side build. For `MODE=user`,
  `define_mgk()` remaps the build variant to `ack`, which makes
  `_mgk_build_config_impl` skip its `POST_DEFCONFIG_CMDS=""` line, so
  `build.config.gki`'s `check_defconfig` would survive and reject the added
  symbols (`make savedefconfig` re-sorts them into Kconfig order). The workflow
  blanks it, exactly as MediaTek already does for every other variant.
- **`KLEAF_GKI_CHECKER=no`** — `scripts/gki_checker.py` wants a prebuilt AOSP
  `vmlinux-userdebug` under `../vendor/aosp_gki/`, which is not in the manifest.
- **`--//build/bazel_mgk_rules:kernel_version=6.6`** is mandatory: the flag
  defaults to `6.1`, and every `select()` in `mgk.bzl` keys off it.
- **`KERNEL_VERSION` and `DEFCONFIG_OVERLAYS` must be exported before Bazel
  starts**, because `key_value_repo()` reads them during WORKSPACE evaluation.
  An empty `KERNEL_VERSION` breaks `common_kernel_package = "@//"+KERNEL_VERSION`.
- **`repo init --no-use-superproject`** — the AOSP manifest declares a
  `<superproject>`, which does not compose with the `<remove-project>` entries in
  the local manifest.
- `local_manifests/algiz.xml` drops two linkfiles present upstream
  (`build_test.sh`, `config.sh`); both sources are 404 on `volla-16.0-algiz` and
  Kleaf does not use them.
- `CONFIG_LOCALVERSION="-4k"` is preserved untouched — it is part of the release
  string vendor modules are matched against.

## Sources

- `HelloVolla/android_kernel_manifest` @ `volla-16.0-algiz`
- `HelloVolla/android_kernel_build_kernel` @ `volla-16.0-algiz`
- `HelloVolla/android_kernel_build_bazel_mgk_rules` @ `volla-16.0-algiz`
- `HelloVolla/android_kernel_volla_mt6877` @ `volla-16.0` (kernel 6.6.89)
- `HelloVolla/android_kernel_device_modules_volla_mt6877` @ `volla-16.0`
- `HelloVolla/android_kernel_modules_volla_mt6877` @ `volla-16.0`
- [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) — config list and kABI patches
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) — packaging

Kernel sources are GPL-2.0. The patches are DroidSpaces upstream, AnyKernel3 is
its own project; everything in this repo is glue.
