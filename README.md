# Volla Phone Quintus (`algiz`) — custom Linux 6.6 kernels

Builds HelloVolla's MediaTek MT6877 kernel (**6.6.89**, Volla OS 16 / Android 16)
from source in GitHub Actions and publishes **three variants side by side in one
release**, each as an AnyKernel3 zip plus (optionally) a repacked `boot.img`.

| Variant | DroidSpaces config | SELinux | Use it when |
|---|---|---|---|
| `droidspaces-enforcing` | yes | **enforcing** (stock) | **Start here.** You want [DroidSpaces](https://github.com/ravindu644/Droidspaces-OSS) and your phone's security model unchanged. |
| `droidspaces-permissive` | yes | permanently permissive | Something inside a container is blocked and `dmesg` shows `avc: denied`. |
| `stock-permissive` | no — stock `gki_defconfig` | permanently permissive | You do not use DroidSpaces and only want a permissive kernel. |

Flash exactly **one** of them. Nothing else about the kernel is changed, and
**no root solution is compiled into any variant** — see [Rooting](#rooting).

---

## What this actually does

### The DroidSpaces variants

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

`stock-permissive` applies neither: it leaves `gki_defconfig` byte-identical and
`task_struct` exactly as shipped.

### The permissive variants

`enforcing_enabled()` in `security/selinux/include/security.h` is the single
predicate every SELinux enforcement decision passes through — in Linux 6.6 there
are exactly five readers (`avc_denied()`, the unrecognized-netlink fallback in
`hooks.c`, and three in `ss/services.c`), plus `selinuxfs.c` which only *reports*
the value. [patches/002.selinux-permanently-permissive.patch](patches/002.selinux-permanently-permissive.patch)
changes that one `static inline` to `return false;`:

```c
 #ifdef CONFIG_SECURITY_SELINUX_DEVELOP
 static inline bool enforcing_enabled(void)
 {
-	return READ_ONCE(selinux_state.enforcing);
+	return false;
 }
```

So the whole LSM logs and allows, without touching a single hook, struct or
exported symbol — **kABI neutral by construction**, and invisible in `.config`.

**This is not `selinux=0`.** `selinuxfs` is still registered and the policy is
still loaded, both of which Android 16's init requires in order to boot at all.
`selinux=0` was considered and rejected: `CONFIG_SECURITY_SELINUX_BOOTPARAM` is
`default n` and absent from the stock defconfig, and with the parameter set
`selinuxfs` is never registered, which would almost certainly bootloop.

`enforcing_set()` is deliberately **not** patched, so `selinux_state.enforcing`
is still written and `/sys/fs/selinux/enforce` stays writable. On a permissive
kernel:

| | |
|---|---|
| `getenforce` | `Permissive`, always, from the first instruction |
| `setenforce 1` | succeeds, and has no effect |
| `/sys/fs/selinux/` | present |
| denials | logged and allowed |

A permissive kernel removes a real security boundary for **every** app on the
device, not just for containers. Prefer `droidspaces-enforcing` unless an
enforcing kernel has actually got in your way.

### Why only the kernel image is rebuilt

Because the layout is preserved in all three variants, the stock vendor modules
keep loading:

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
| [.github/workflows/build-kernel.yml](.github/workflows/build-kernel.yml) | The whole build: a `plan` job computing the variant matrix, a matrixed `build` job, and a `release` job that cuts one release. Run it from the Actions tab. |
| [local_manifests/algiz.xml](local_manifests/algiz.xml) | `repo` local manifest overlaying the five HelloVolla trees onto AOSP `common-android15-6.6`. |
| [scripts/setup-workspace.sh](scripts/setup-workspace.sh) | `repo init` / `repo sync` + a layout sanity check. |
| [scripts/apply-droidspaces-config.sh](scripts/apply-droidspaces-config.sh) | Idempotent, per-symbol `gki_defconfig` editor. Verifies afterwards. DroidSpaces variants only. |
| [scripts/release-notes.sh](scripts/release-notes.sh) | Generates the GitHub release body from the variants that actually built. |
| [patches/](patches/) | The three upstream SYSVIPC kABI patch variants, plus the permissive-SELinux patch. |
| [anykernel3/anykernel.sh](anykernel3/anykernel.sh) | AnyKernel3 config for `algiz` (kernel-image-only flash). `kernel.string` is rewritten per variant at package time. |
| [boot/](boot/README.md) | **Optional, you add this.** Supply your stock `boot.img` to also get repacked, fastboot-flashable images. |

---

## Building

Actions → **Build algiz kernels** → *Run workflow*.

| Input | Default | Meaning |
|---|---|---|
| `variants` | `all` | Build all three, or just one of `droidspaces-enforcing` / `droidspaces-permissive` / `stock-permissive`. |
| `build_scope` | `image` | `image` builds only the GKI-side `Image`/`Image.lz4`/`Image.gz` + in-tree modules (~40–70 min per variant). `dist` runs the full MediaTek build with every vendor module (several hours, and you do not need it). |
| `mode` | `user` | MTK build variant. `userdebug`/`eng` pull in `userdebug.config`/`eng.config`, which set `MTK_PANIC_ON_WARN`, `DEBUG_KMEMLEAK` and ~80 more debug symbols. Do not daily-drive those. |
| `defconfig_overlays` | `mt6877_overlay.config` | `DEFCONFIG_OVERLAYS`, space separated. Pass the literal `none` for an empty list. |
| `boot_img_url` | *(empty)* | Direct download URL of your **stock** `boot.img`. For `algiz` there is one attached to the [`stock-images-algiz`](https://github.com/blue-boy-questions/custom-kernel/releases/tag/stock-images-algiz) release. Alternatively commit it as `boot/boot.img`. |
| `disable_sandbox` | off | Adds `--config=local`. Only if you hit Bazel sandbox errors. |
| `publish_release` | on | Publish one GitHub release with every variant attached. Manual runs only — push-triggered runs never release. |

The three variants build **in parallel**, one runner each, with `fail-fast`
off: a variant that fails does not cancel or block the others, and the release
job still publishes whatever did build (with a warning saying so).

Artifacts are one set per variant (`algiz-kernel-<run>-<variant>`): the
AnyKernel3 zip, `Image`, `Image.lz4`, `Image.gz`, `System.map`, the resolved
`.config`, a small `variant.json` describing the build, and — when you supplied
a stock image — `boot.img`. `vmlinux` and the module set go to a separate,
shorter-retention artifact and are **not** released.

Each variant verifies its own **built** `.config` (not the defconfig) before its
artifacts are uploaded:

- DroidSpaces variants fail if any required DroidSpaces symbol is missing. That
  check is skipped for `stock-permissive`, where several of those symbols are
  legitimately absent.
- Permissive variants fail if `CONFIG_SECURITY_SELINUX_DEVELOP` is not `=y`,
  because the patched branch would then be dead code and the kernel would come
  out silently enforcing. The patch step itself also asserts, at source level,
  that `enforcing_enabled()` now returns `false` **and** that `enforcing_set()`
  still writes `selinux_state.enforcing`.
- Every variant reports the KernelSU-LKM prerequisites (`KPROBES`,
  `KALLSYMS_ALL`, `MODULES`, `MODULE_UNLOAD`, `MODULE_SIG_FORCE`) and confirms
  `MODVERSIONS` / `MODULE_SIG_PROTECT` are still set.

### Releases

A successful **manual** run publishes **one** GitHub release tagged
`v<kernel>-<run number>` containing every variant that built. Assets are
prefixed with the variant they came from — `droidspaces-enforcing-Image`,
`stock-permissive-boot.img`, and so on — except the AnyKernel3 zips, which
already carry the variant in their filename. `SHA256SUMS` covers all of them,
and a follow-up step fails the job if any asset is left in GitHub's `starter`
state (a truncated upload, which never heals). Unlike Actions artifacts, release
assets do not expire and need no login to download. Set `publish_release` to off
to skip it.

Push-triggered runs never publish a release; they only upload Actions artifacts
(30 days for the kernel sets, 7 for `vmlinux` and the modules). The release body
is generated by [scripts/release-notes.sh](scripts/release-notes.sh), which is
given the list of variants that built so it never advertises a missing asset.

The [`stock-images-algiz`](https://github.com/blue-boy-questions/custom-kernel/releases/tag/stock-images-algiz)
release is not a build — it holds the **stock** `algiz` `boot.img`
(`6.6.89-android15-8-gbe8d201b0d27-ab13762941-4k`, no Magisk patch) so its
download URL can be passed as `boot_img_url`, which is what makes the repacked
`boot.img` appear in a build's release. It is also your recovery image if a custom
kernel does not boot.

Two builds of the same commit do **not** produce byte-identical `Image` files, and
that is expected: the `.note.gnu.build-id` differs, and `CONFIG_MODULE_SIG`
generates a fresh "Build time autogenerated kernel key" certificate per build with
its validity dates stamped in (~1.1 kB of difference in total).
`build.config.resolved` *is* byte-identical, so compare that when checking two
builds are equivalent.

### Building locally

```bash
scripts/setup-workspace.sh ~/algiz local_manifests/algiz.xml
cd ~/algiz
# DroidSpaces variants only:
patch -p1 -d kernel-6.6 < /path/to/patches/001.GKI-below-6.12-fix_sysvipc_kabi_6_7_8.patch
/path/to/scripts/apply-droidspaces-config.sh kernel-6.6/arch/arm64/configs/gki_defconfig
sed -i 's|^POST_DEFCONFIG_CMDS="check_defconfig"$|POST_DEFCONFIG_CMDS=""|' kernel-6.6/build.config.gki
# Permissive variants only:
patch -p1 -d kernel-6.6 < /path/to/patches/002.selinux-permanently-permissive.patch
export KERNEL_VERSION=kernel-6.6 DEFCONFIG_OVERLAYS=mt6877_overlay.config KLEAF_GKI_CHECKER=no
tools/bazel build --noenable_bzlmod --experimental_writable_outputs \
  --//build/bazel_mgk_rules:kernel_version=6.6 --nokmi_symbol_list_violations_check \
  //kernel_device_modules-6.6:mgk_64_k66_kernel_aarch64.user
```

Roughly 60 GB of disk and 16 GB of RAM. For a stock-config build, skip the
`apply-droidspaces-config.sh`, `001.*` patch and `check_defconfig` lines — with
`gki_defconfig` unedited, `check_defconfig` passes on its own.

---

## Flashing

1. **Back up your stock `boot.img` first.** If the kernel does not boot, that
   image is how you get your phone back.
2. Set up root if you want it — see [Rooting](#rooting). The order does not
   matter, because root and this kernel live in different partitions.
3. Flash **one** `AK3-algiz-<variant>-*.zip` from a custom recovery, or via the
   Magisk app's *Modules → Install from storage*. The zip prints which variant
   it is while installing.
4. Reboot. For a DroidSpaces variant: open DroidSpaces, enable **Daemon Mode**,
   reboot again.

The AnyKernel3 script runs `split_boot; flash_boot;` — the plain "OG AK" flow. It
replaces **only** the kernel image and leaves your ramdisk exactly as it is, so
an already-Magisk-patched boot image stays patched (`ak3-core.sh` detects Magisk
and re-applies the kernel-side patch on repack). `BLOCK=auto` and
`IS_SLOT_DEVICE=auto` handle the A/B slot suffix.

If you prefer `fastboot`, supply your stock `boot.img` to the workflow and flash
the repacked one for the variant you want:

```bash
fastboot flash boot droidspaces-enforcing-boot.img
```

Each is a lossless `unpack_bootimg --format=mkbootimg` → `mkbootimg` round-trip
with only the kernel payload swapped, then given a fresh AVB hash footer with
algorithm `NONE` — re-signing would need Volla's private AVB key, which nobody
outside Volla has. It therefore requires an unlocked bootloader, which flashing a
custom kernel implies anyway. It will **not** contain a Magisk patch — flash
Magisk again afterwards if you go this route.

To go back to stock:

```bash
fastboot flash boot stock-boot.img
```

---

## Rooting

**No variant contains KernelSU, KernelSU-Next, SukiSU, APatch or any other
in-kernel root implementation.** That is deliberate: keeping root out of the
kernel means a kernel update never breaks root, and a root update never requires
a kernel rebuild.

Root lives in a **different partition** from this kernel, which is why the two are
independent:

| Partition | Contains | Touched by this project |
|---|---|---|
| `boot` | kernel only (`ramdisk_size: 0`) | **yes** — this is what you flash |
| `init_boot` | ramdisk only (`kernel_size: 0`) | **no** — never opened |

### Patching `init_boot.img` with KernelSU

1. Dump your stock `init_boot.img`:

   ```bash
   adb shell su -c "dd if=/dev/block/by-name/init_boot$(getprop ro.boot.slot_suffix) of=/sdcard/init_boot.img"
   ```

   or extract it from the Volla OS 16 factory image / OTA payload. Keep a copy —
   it is your way back.
2. Install the [KernelSU](https://github.com/tiann/KernelSU) manager app, and use
   *Install → Select a file* on that `init_boot.img`. This is KernelSU's **LKM
   mode**: it patches the ramdisk's `init` and loads `kernelsu.ko` at boot. GKI
   mode (which requires the root implementation compiled into the kernel) is
   neither needed nor supported here.
3. Flash the result:

   ```bash
   fastboot flash init_boot init_boot_patched.img
   ```
4. Flash a kernel from a release, and reboot.

LKM mode works on all three variants because `CONFIG_KPROBES`,
`CONFIG_KALLSYMS_ALL`, `CONFIG_MODULES` and `CONFIG_MODULE_UNLOAD` are `=y` and
`CONFIG_MODULE_SIG_FORCE` is off — verified in each variant's
`build.config.resolved` before the release is cut.

**Magisk** and **APatch** work the same way, also on `init_boot`.

**If you are already rooted, do not restore stock `init_boot` before flashing a
kernel from here.** Flashing `boot` leaves your root patch alone; reverting
`init_boot` would only remove root. The AnyKernel3 zip is the same story — it
only runs `split_boot; flash_boot;` and never opens `init_boot`.

Afterwards, in the DroidSpaces app: enable **Daemon Mode** and reboot. Without
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
