#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# release-notes.sh
#
# Emits the GitHub release body for a build, on stdout.
#
# One run builds several variants and publishes them in a single release, so
# this script is given a JSON array describing the variants that actually
# built (written by the packaging step as artifacts/variant.json, collected by
# the release job). A variant that failed is simply absent from the array; the
# body must never advertise an asset that is not attached.
#
# Kept as a script rather than a heredoc inside the workflow so the text can be
# edited (and shellcheck'd, and previewed locally) without touching the YAML,
# and so the wording stays in one place instead of being duplicated between the
# release body, the job summary and README.md.
#
# Usage: release-notes.sh <kver> <variants.json> <mode> <scope> <run> <run_url>
#
# variants.json: [{"variant","label","droidspaces","permissive","kver",
#                  "zipname","mode","scope"}, ...]
# ---------------------------------------------------------------------------
set -euo pipefail

KVER="${1:?kernel version, e.g. 6.6.89-4k}"
VJSON="${2:?path to the variants JSON array}"
MODE="${3:-user}"
SCOPE="${4:-image}"
RUN="${5:-?}"
RUN_URL="${6:-}"

[ -f "$VJSON" ] || { echo "ERROR: no such file: $VJSON" >&2; exit 1; }
jq -e 'type == "array" and length > 0' "$VJSON" >/dev/null \
  || { echo "ERROR: $VJSON is not a non-empty JSON array" >&2; exit 1; }

# Reading a field for a named variant, or the empty string if that variant is
# not in this release. Used to keep every mention of an asset conditional.
field() { jq -r --arg v "$1" --arg f "$2" \
  'map(select(.variant == $v)) | if length > 0 then .[0][$f] else "" end' "$VJSON"; }
has() { [ -n "$(field "$1" variant)" ]; }

DS_ENF_ZIP="$(field droidspaces-enforcing zipname)"
DS_PRM_ZIP="$(field droidspaces-permissive zipname)"
STOCK_ZIP="$(field stock-permissive zipname)"

N="$(jq -r 'length' "$VJSON")"
ANY_DS="$(jq -r 'map(select(.droidspaces)) | length' "$VJSON")"
ANY_PRM="$(jq -r 'map(select(.permissive)) | length' "$VJSON")"

# Singular/plural throughout: a single-variant dispatch is a supported case
# (the `variants` input can name one), and "kernels ... flash exactly one of
# them" would be nonsense there.
if [ "$N" -gt 1 ]; then NOUN=kernels; else NOUN=kernel; fi

cat <<EOF
Linux **${KVER}** ${NOUN} for the **Volla Phone Quintus** (\`algiz\`, MediaTek
MT6877, Volla OS 16 / Android 16), built from the HelloVolla sources in GitHub
Actions. MTK build variant \`${MODE}\`, scope \`${SCOPE}\`, run #${RUN}.
EOF

if [ "$N" -gt 1 ]; then
  cat <<EOF

${N} kernels in this release. **Flash exactly one of them.**

## Which one do I want?
EOF
else
  cat <<EOF

One kernel in this release.

## What this build is
EOF
fi

cat <<EOF

| Variant | DroidSpaces config | SELinux | Flash this if |
|---|---|---|---|
EOF

has droidspaces-enforcing && cat <<EOF
| \`droidspaces-enforcing\` | yes | enforcing (stock) | **Start here.** You want DroidSpaces with your phone's security model unchanged. |
EOF
has droidspaces-permissive && cat <<EOF
| \`droidspaces-permissive\` | yes | permanently permissive | Something inside a DroidSpaces container is being blocked and \`dmesg\` shows \`avc: denied\`. |
EOF
has stock-permissive && cat <<EOF
| \`stock-permissive\` | no (stock \`gki_defconfig\`) | permanently permissive | You do not use DroidSpaces and only want a permissive kernel. |
EOF

if [ "$ANY_PRM" -gt 0 ]; then
  if has droidspaces-enforcing; then
    cat <<'EOF'

Try `droidspaces-enforcing` first. A permissive kernel disables a real security
boundary for **every** app on the device, not just for containers, so it is
worth reaching for only when an enforcing kernel actually gets in the way.
EOF
  else
    cat <<'EOF'

Note that a permissive kernel disables a real security boundary for **every**
app on the device, not just for containers. Prefer an enforcing build unless
one has actually got in your way.
EOF
  fi

  cat <<'EOF'

### What "permissive" means here

It is **not** `selinux=0`. `selinuxfs` is still mounted and the policy is
still loaded — Android 16's init requires both to boot at all — but the single
predicate every enforcement decision passes through,
`enforcing_enabled()` in `security/selinux/include/security.h`, is patched to
return `false`. So:

- `getenforce` reports **Permissive**, always, from the very first
  instruction — there is no window in which anything is enforced.
- `setenforce 1` still succeeds and `/sys/fs/selinux/enforce` is still
  writable (`enforcing_set()` is deliberately untouched), it just has no
  effect.
- Denials are logged and allowed instead of blocked.

The patch changes one `static inline` in a header: no hook, no struct, no
exported symbol, therefore **kABI neutral by construction**.
EOF
fi

cat <<EOF

## Root: you have to add it yourself

**No kernel here contains a root solution.** No KernelSU, no
KernelSU-Next, no SukiSU, no APatch — by design. Root and kernel are kept
separate so a kernel update never breaks root and vice versa.

Root lives in a **different partition** from this kernel:

| Partition | Contains | Touched by this release |
|---|---|---|
| \`boot\` | kernel only (\`ramdisk_size: 0\`) | **yes** — this is what you flash |
| \`init_boot\` | ramdisk only (\`kernel_size: 0\`) | **no** — never opened |

So, to get root:

1. Dump your stock \`init_boot.img\`:
   \`\`\`
   adb shell su -c "dd if=/dev/block/by-name/init_boot\$(getprop ro.boot.slot_suffix) of=/sdcard/init_boot.img"
   \`\`\`
   or take it from the Volla OS 16 factory image. Keep a copy — it is your way back.
2. Install the **KernelSU** manager app and use *Install → Select a file* to
   patch that \`init_boot.img\` (this is KernelSU's **LKM mode**; GKI mode is not
   needed and not supported here). Magisk works the same way, also on
   \`init_boot\`.
3. \`fastboot flash init_boot init_boot_patched.img\`
4. Flash a kernel from this release (see below) and reboot.

The order does not matter, because the two partitions are independent.
**If you are already rooted, do not restore stock \`init_boot\` before flashing
this kernel** — flashing \`boot\` leaves your root patch alone, and reverting
\`init_boot\` would only remove root.

KernelSU LKM mode works on every kernel here because \`KPROBES\`,
\`KALLSYMS_ALL\`, \`MODULES\` and \`MODULE_UNLOAD\` are \`=y\` and
\`MODULE_SIG_FORCE\` is off, all verified in the attached
\`*-build.config.resolved\` before this release was cut.

## How to flash a kernel

**The AnyKernel3 zip is the recommended path.** Flash it from a custom
recovery, or via the Magisk app → *Modules → Install from storage*:

EOF

has droidspaces-enforcing  && printf -- '- `%s`\n' "$DS_ENF_ZIP"
has droidspaces-permissive && printf -- '- `%s`\n' "$DS_PRM_ZIP"
has stock-permissive       && printf -- '- `%s`\n' "$STOCK_ZIP"

cat <<EOF

It replaces **only the kernel image** and leaves your ramdisk untouched, so an
already-patched boot image stays patched (\`ak3-core.sh\` detects Magisk and
re-applies the kernel-side patch on repack). \`BLOCK=auto\` and
\`IS_SLOT_DEVICE=auto\` handle the A/B slot suffix. Each zip prints which
variant it is while installing.

**Or** flash the matching \`<variant>-boot.img\` with
\`fastboot flash boot <variant>-boot.img\`. Those are attached only when a stock
\`boot.img\` was supplied to the build (\`boot/boot.img\` committed, or the
\`boot_img_url\` input). Each is your stock image with only the kernel payload
swapped, then given a fresh AVB hash footer with algorithm \`NONE\` —
re-signing would need Volla's private AVB key, which nobody outside Volla has.
An unlocked bootloader is required either way, which flashing a custom kernel
already implies.

**Back up your stock \`boot.img\` before flashing.** If a kernel does not boot,
that image is how you get your phone back:

\`\`\`
fastboot flash boot stock-boot.img
\`\`\`
EOF

if [ "$ANY_DS" -gt 0 ]; then
  cat <<'EOF'

## After flashing

1. Reboot, open DroidSpaces, enable **Daemon Mode**, reboot again. Without
   Daemon Mode, DroidSpaces cannot hold the root session it needs and
   containers will not start. (DroidSpaces variants only.)
2. **SuSFS is not supported by DroidSpaces** — use a plain root build.

## Why your stock vendor modules still load

`CONFIG_SYSVIPC` normally adds `sysvsem`/`sysvshm` to `struct task_struct`
and shifts every field after them, which bootloops prebuilt `vendor_dlkm`
modules. The kABI patch parks both members inside the reserved
`ANDROID_KABI_RESERVE(6/7/8)` padding slots instead, and under
`__GENKSYMS__` the macros expand back to the reserve slots — symbol CRCs, and
therefore the KMI, are unchanged. `CONFIG_MODVERSIONS=y` plus
`CONFIG_MODULE_SIG_PROTECT=y` do the rest. That is why only the kernel image
needs rebuilding, and why the default build scope is `image` rather than a
multi-hour MediaTek `dist` build.

The SELinux patch needs no such care: it changes one `static inline` in a
header, so there is nothing for a vendor module to have been compiled against.
EOF

  has stock-permissive && cat <<'EOF'

The `stock-permissive` variant does not apply the SYSVIPC patch at all: it
leaves `task_struct` exactly as shipped, because it makes no config change that
could shift it.
EOF

  cat <<'EOF'

## Config

For the DroidSpaces variants, 17 symbols are enabled and every one is verified
`=y` in that variant's `build.config.resolved` before the release is cut:
SYSVIPC, POSIX_MQUEUE, IPC_NS, PID_NS, DEVTMPFS,
NETFILTER_XT_MATCH_ADDRTYPE, USER_NS, IP_NF_TARGET_REJECT,
IP6_NF_TARGET_REJECT, NETFILTER_XT_TARGET_LOG, NETFILTER_XT_MATCH_RECENT,
IP_SET, IP_SET_HASH_IP, IP_SET_HASH_NET, NETFILTER_XT_SET, TMPFS_POSIX_ACL,
TMPFS_XATTR.

Two deviations from the DroidSpaces documentation, both deliberate:

- `CONFIG_NETFILTER_XT_TARGET_REJECT` **does not exist in Linux 6.6.** The
  real per-family symbols `IP_NF_TARGET_REJECT` / `IP6_NF_TARGET_REJECT` are
  used instead (both already `=y` in the stock defconfig). A config line for a
  nonexistent Kconfig symbol is silently discarded, so the documented spelling
  would have looked applied while UFW's REJECT rules went missing.
- `CONFIG_CGROUP_DEVICE` is **left off**. The docs call it fatal, but only in
  their non-GKI list; the DroidSpaces runtime check never probes it,
  `devices_cgrp_subsys` is cgroup-v1 only (`.legacy_cftypes`), and enabling
  it inserts a `SUBSYS(devices)` entry that shifts every later
  `cgroup_subsys_id` — a kABI break for exactly the modules the patch above
  exists to protect.
EOF
else
  cat <<'EOF'

## Config

No config change at all: this is the stock `gki_defconfig` for `algiz`, so
`task_struct` and every symbol CRC are exactly as shipped and your prebuilt
vendor modules cannot notice the difference. The only change is the one-line
SELinux patch, which lives in a `static inline` in a header and is therefore
kABI neutral too.
EOF
fi

cat <<EOF

\`CONFIG_LOCALVERSION\` is preserved untouched in every variant: it is part of
the release string that stock vendor modules' vermagic is matched against.

## Files

Assets are prefixed with the variant they came from, except the AnyKernel3
zips, which already carry it in the filename.

| File | What it is |
|---|---|
| \`AK3-algiz-<variant>-*.zip\` | AnyKernel3 flashable zip — **flash one of these** |
| \`<variant>-boot.img\` | Repacked fastboot-flashable boot image (only if a stock one was supplied) |
| \`<variant>-Image\` | Raw kernel image, for your own \`boot.img\` repack |
| \`<variant>-Image.lz4\`, \`<variant>-Image.gz\` | Compressed variants |
| \`<variant>-build.config.resolved\` | The full \`.config\` that variant was actually built with |
| \`<variant>-System.map\` | Symbol map, for decoding panics |
| \`SHA256SUMS\` | Checksums for everything above |

Built by [run #${RUN}](${RUN_URL}).
EOF
