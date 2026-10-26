# Making a `boot.img` and a flashable zip, and flashing them

Volla Phone Quintus (`algiz`, MT6877, Volla OS 16). Every build of this repo
produces **two** things per variant:

| File | What it is | Flash with | Keeps your Magisk/KernelSU root? |
|---|---|---|---|
| `AK3-algiz-<variant>-*.zip` | AnyKernel3 zip. Replaces **only the kernel image** inside your existing `boot` partition. | Custom recovery, or the Magisk / KernelSU manager (*Modules -> Install from storage*) | **Yes** (ramdisk untouched) |
| `<variant>-boot.img` | Your **stock** `boot.img` with only the kernel payload swapped. | `fastboot flash boot ...` | Root lives in `init_boot`, so it is unaffected, but the image itself has no Magisk patch |

Flash **one** variant. Not both the zip and the img, and not two variants.

Before anything else: **back up your stock `boot.img`**. It is the way back if
a kernel does not boot. A copy is also attached to the
[`stock-images-algiz`](https://github.com/blue-boy-questions/custom-kernel/releases/tag/stock-images-algiz)
release (sha256 `227e34c2798893a0743da64b4ed44413b9cfda6501087596af99b781625d2720`).

---

## 1. Easiest way: let GitHub Actions make them

1. Actions -> **Build algiz kernels** -> *Run workflow*.
2. Pick `variants` (for containers + USB gadget: `droidspaces-usbarsenal-enforcing`).
3. Leave `boot_img_url` **empty**. The workflow then downloads the stock image from
   the `stock-images-algiz` release, checks its sha256, and repacks one
   `<variant>-boot.img` per variant. (Paste your own URL to use a different stock
   image, or commit `boot/boot.img`; a committed file wins over the URL.)
4. DroidSpaces extras are three separate checkboxes: `ds_macvlan` (on by
   default, low risk), `ds_cpu_limit` (off) and `ds_pids_limit` (off). Add them
   **one at a time**: flash, boot, then enable the next. The zip name shows what
   it contains (`-macvlan`, `-cpu`, `-pids`). The first build that bootloops
   tells you which option the phone does not accept.

   Shortcut: choose `variants` = `bisect-droidspaces-usbarsenal-enforcing`.
   One run builds `-t1` (MACVLAN), `-t2` (MACVLAN + process limit) and `-t3`
   (MACVLAN + CPU limit) and publishes them as a pre-release tagged
   `v<kernel>-extras-test-<run>`. Flash t1, t2, t3 in that order.
5. When the run finishes, open the **Releases** page. Each variant has
   `AK3-algiz-<variant>-...zip` and `<variant>-boot.img`, plus `SHA256SUMS`.
   Download and verify:

   ```bash
   sha256sum -c SHA256SUMS --ignore-missing
   ```

Push-triggered runs (changes under `patches/`, `scripts/`, `anykernel3/`,
`boot/`, `local_manifests/` or the workflow) behave the same and also publish a
release.

---

## 2. Flashing the AnyKernel3 zip (recommended)

1. Copy the zip to the phone.
2. Flash it with **one** of:
   - a custom recovery (*Install -> select the zip*), or
   - the Magisk app / KernelSU manager: *Modules -> Install from storage*.
3. The installer prints the variant name. Reboot.
4. DroidSpaces variants: open DroidSpaces, enable **Daemon Mode**, reboot again.

What the zip does (`anykernel3/anykernel.sh`): targets
`/dev/block/by-name/boot` (the slot suffix is added automatically, so it never
picks `init_boot`), runs `split_boot; flash_boot;`, and leaves the ramdisk
alone. It refuses to run on a device that is not `algiz` / `Quintus` /
`volla_quintus` / `mt6877`.

---

## 3. Flashing the `boot.img` with fastboot

Needs an **unlocked bootloader** (the repacked image carries an AVB hash footer
with algorithm `NONE`, because nobody outside Volla has the signing key).

```bash
adb reboot bootloader
fastboot flash boot droidspaces-usbarsenal-enforcing-boot.img
fastboot reboot
```

Back to stock at any time:

```bash
fastboot flash boot stock-boot.img
```

A repacked `boot.img` has **no Magisk patch**. If you use Magisk on the `boot`
partition, patch the image again, or use the zip instead. KernelSU in LKM mode
and Magisk-on-`init_boot` are unaffected, because they live in `init_boot`.

---

## 4. Making the files yourself (no GitHub Actions)

You need the synced workspace from `scripts/setup-workspace.sh` and a finished
build. The paths below are the ones the workflow uses.

### 4a. The kernel image

After the Bazel build, the files are in `out/dist/`, or under
`bazel-bin/kernel_device_modules-6.6/mgk_64_k66_kernel_aarch64.user/`
(the workflow's *Collect kernel artifacts* step searches both, then the Bazel
execroot). You want `Image` (and `Image.gz` if you want to follow the workflow
exactly):

```bash
SRC=$(dirname "$(find -L out/dist bazel-bin/kernel_device_modules-6.6 -maxdepth 4 -type f -name Image | head -1)")
mkdir -p ~/kimg && cp "$SRC"/Image "$SRC"/Image.gz ~/kimg/ 2>/dev/null; ls -l ~/kimg
```

### 4b. Repack `boot.img`

This mirrors the workflow step line for line.

```bash
cd ~/algiz                       # your synced workspace
PY=python3
STOCK=/path/to/stock-boot.img    # must start with the ANDROID! magic
KIMG=~/kimg/Image.gz             # the workflow prefers Image.gz, else Image

head -c 8 "$STOCK"; echo         # expect: ANDROID!

work=/tmp/bootrepack; rm -rf "$work"; mkdir -p "$work/unpacked"
$PY tools/mkbootimg/unpack_bootimg.py --boot_img "$STOCK" \
    --out "$work/unpacked" --format=mkbootimg -0 > "$work/args0"
mapfile -d '' ARGS < "$work/args0"

# swap ONLY the kernel payload; every other argument stays as unpacked
cp "$KIMG" "$work/kernel-payload"
for i in "${!ARGS[@]}"; do
  if [ "${ARGS[$i]}" = "--kernel" ]; then ARGS[$((i+1))]="$work/kernel-payload"; break; fi
done

$PY tools/mkbootimg/mkbootimg.py "${ARGS[@]}" --output "$work/boot-new.img"

# fresh AVB hash footer, same partition size as stock, algorithm NONE (unsigned)
AVB=prebuilts/kernel-build-tools/linux-x86/bin/avbtool
PSIZE=$(stat -c %s "$STOCK")
$AVB add_hash_footer --image "$work/boot-new.img" --partition_name boot --partition_size "$PSIZE"
ls -l "$work/boot-new.img"       # must be <= $PSIZE
```

Notes:

- `-0` makes `unpack_bootimg` emit NUL-separated arguments, so values with
  spaces (the kernel cmdline) survive intact; that is why `mapfile -d ''` is used.
- `avbtool add_hash_footer ... --calc_max_image_size` tells you the largest
  payload that fits. The workflow fails the build if the repacked image would
  not fit the partition.
- Check the result before flashing:
  `python3 tools/mkbootimg/unpack_bootimg.py --boot_img "$work/boot-new.img" --format=info`
  should show the same header version, OS version/patch level and cmdline as
  the stock image.

### 4c. Build the AnyKernel3 zip

```bash
git clone --depth=1 https://github.com/osm0sis/AnyKernel3 ak3
cd ak3
rm -rf .git .github README.md ramdisk patch modules
mkdir ramdisk patch modules && touch ramdisk/.gitkeep patch/.gitkeep modules/.gitkeep

cp /path/to/custom-kernel/anykernel3/anykernel.sh anykernel.sh
sed -i 's|^kernel\.string=.*|kernel.string=Volla Quintus (algiz) my build|' anykernel.sh
cp /path/to/Image Image               # plain Image, not Image.gz

zip -r9 ../AK3-algiz-mybuild.zip . -x '.git*'
```

The zip must contain `anykernel.sh`, `Image` and the AnyKernel3 `tools/`, `META-INF/`
directories. Do not add a ramdisk: the point is to keep yours.

---

## 5. After flashing: check it worked

In a root shell (or `adb shell` + `su`):

```bash
uname -r                       # 6.6.89-android15-8-...-4k
getenforce                     # Enforcing, or Permissive on *-permissive variants
```

- **DroidSpaces:** open the app -> *Requirements* -> *Check*. With
  the matching extra on you should now see `[✓]` for Macvlan, CPU limit and/or
  Process limit.
- **USB-Arsenal:** `usb-arsenal check`. `HID poll interval (f_hid)` should be
  `[+]`. If it is still `[-]`, open the build log's
  *Add the f_hid configurable poll-interval patch* step: it says whether the
  patch was found in the USB-Arsenal tree, backported from mainline, or skipped
  because it did not fit. Everything else works without it; only
  `usb-arsenal hid --interval` needs it.

### If CPU limit still says unsupported

`CONFIG_CFS_BANDWIDTH=y` only gives the kernel `cpu.max`. The DroidSpaces check
also needs the `cpu` controller to be available in the cgroup hierarchy the
container uses. If the line still fails after flashing, tap **Copy Logs** in
the Requirements Check and look at the second half of that line (it is cut off
on screen).

### If the phone bootloops

1. Hold power + volume down to reach fastboot, then
   `fastboot flash boot stock-boot.img`.
2. Rebuild with `ds_cpu_limit` and `ds_pids_limit` **off** (`CGROUP_PIDS` grows
   the cgroup layout and `CFS_BANDWIDTH` changes scheduler structs that vendor
   modules were built against), then enable them one by one and compare the
   *kABI check vs stock* table between runs.
3. Also note that the workflow clones the *latest* AnyKernel3, so the bundled
   `magiskboot`/`magiskpolicy` can differ between two builds even with the same
   kernel config. If a build with identical options starts looping, compare the
   `tools/` folders of the two zips.
