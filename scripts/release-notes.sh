#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# release-notes.sh
#
# Emits the GitHub release body for a build, on stdout.
#
# Kept as a script rather than a heredoc inside the workflow so the text can be
# edited (and shellcheck'd, and previewed locally) without touching the YAML,
# and so the wording stays in one place instead of being duplicated between the
# release body, the job summary and README.md.
#
# Usage: release-notes.sh <kver> <zipname> <mode> <scope> <run_number> <run_url>
# ---------------------------------------------------------------------------
set -euo pipefail

KVER="${1:?kernel version, e.g. 6.6.89-4k}"
ZIPNAME="${2:?AnyKernel3 zip filename}"
MODE="${3:-user}"
SCOPE="${4:-image}"
RUN="${5:-?}"
RUN_URL="${6:-}"

cat <<EOF
DroidSpaces-ready Linux **${KVER}** kernel for the **Volla Phone Quintus**
(\`algiz\`, MediaTek MT6877, Volla OS 16 / Android 16), built from the
HelloVolla sources in GitHub Actions.

Build variant \`${MODE}\`, scope \`${SCOPE}\`, run #${RUN}.

## What to flash

**\`${ZIPNAME}\`** — this is the file you want. Flash it from a custom recovery,
or via the Magisk app → *Modules → Install from storage*.

It replaces **only the kernel image** and leaves your ramdisk untouched, so an
already-Magisk-patched boot image stays patched (\`ak3-core.sh\` detects Magisk
and re-applies the kernel-side patch on repack). \`BLOCK=auto\` and
\`IS_SLOT_DEVICE=auto\` handle the A/B slot suffix.

**Back up your stock \`boot.img\` before flashing.** If this kernel does not
boot, that image is how you get your phone back.

## After flashing

1. Root with **Magisk** or **APatch** — this kernel contains **no** in-kernel
   root (no KernelSU / KernelSU-Next / SukiSU) by design.
2. Reboot, open DroidSpaces, enable **Daemon Mode**, reboot again. Without
   Daemon Mode, DroidSpaces cannot hold the root session it needs and
   containers will not start.
3. **SuSFS is not supported by DroidSpaces** — use a plain root build.

## Why your stock vendor modules still load

\`CONFIG_SYSVIPC\` normally adds \`sysvsem\`/\`sysvshm\` to \`struct task_struct\`
and shifts every field after them, which bootloops prebuilt \`vendor_dlkm\`
modules. The kABI patch parks both members inside the reserved
\`ANDROID_KABI_RESERVE(6/7/8)\` padding slots instead, and under
\`__GENKSYMS__\` the macros expand back to the reserve slots — symbol CRCs, and
therefore the KMI, are unchanged. \`CONFIG_MODVERSIONS=y\` plus
\`CONFIG_MODULE_SIG_PROTECT=y\` do the rest. That is why only the kernel image
needs rebuilding, and why the default build scope is \`image\` rather than a
multi-hour MediaTek \`dist\` build.

## Config

17 DroidSpaces symbols are enabled; every one is verified \`=y\` in the attached
\`build.config.resolved\` before the release is cut: SYSVIPC, POSIX_MQUEUE,
IPC_NS, PID_NS, DEVTMPFS, NETFILTER_XT_MATCH_ADDRTYPE, USER_NS,
IP_NF_TARGET_REJECT, IP6_NF_TARGET_REJECT, NETFILTER_XT_TARGET_LOG,
NETFILTER_XT_MATCH_RECENT, IP_SET, IP_SET_HASH_IP, IP_SET_HASH_NET,
NETFILTER_XT_SET, TMPFS_POSIX_ACL, TMPFS_XATTR.

Two deviations from the DroidSpaces documentation, both deliberate:

- \`CONFIG_NETFILTER_XT_TARGET_REJECT\` **does not exist in Linux 6.6.** The
  real per-family symbols \`IP_NF_TARGET_REJECT\` / \`IP6_NF_TARGET_REJECT\` are
  used instead (both already \`=y\` in the stock defconfig). A config line for a
  nonexistent Kconfig symbol is silently discarded, so the documented spelling
  would have looked applied while UFW's REJECT rules went missing.
- \`CONFIG_CGROUP_DEVICE\` is **left off**. The docs call it fatal, but only in
  their non-GKI list; the DroidSpaces runtime check never probes it,
  \`devices_cgrp_subsys\` is cgroup-v1 only (\`.legacy_cftypes\`), and enabling
  it inserts a \`SUBSYS(devices)\` entry that shifts every later
  \`cgroup_subsys_id\` — a kABI break for exactly the modules the patch above
  exists to protect.

\`CONFIG_LOCALVERSION\` is preserved untouched: it is part of the release string
that stock vendor modules' vermagic is matched against.

## Files

| File | What it is |
|---|---|
| \`${ZIPNAME}\` | AnyKernel3 flashable zip — **flash this** |
| \`Image\` | Raw kernel image, for your own \`boot.img\` repack |
| \`Image.lz4\`, \`Image.gz\` | Compressed variants |
| \`build.config.resolved\` | The full \`.config\` this kernel was actually built with |
| \`System.map\` | Symbol map, for decoding panics |
| \`SHA256SUMS\` | Checksums for everything above |

A \`boot.img\` is attached only when a stock one was supplied to the build —
commit \`boot/boot.img\` or pass the \`boot_img_url\` input. Note a repacked
image contains no Magisk patch.

Built by [run #${RUN}](${RUN_URL}).
EOF
