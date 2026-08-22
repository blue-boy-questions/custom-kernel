#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# apply-droidspaces-config.sh
#
# Applies the DroidSpaces "GKI-Exclusive Configuration" to a gki_defconfig,
# following the workflow rules from Droidspaces-OSS
# Documentation/guides/Kernel-Configuration.md:
#
#   * Do NOT append the list as a block.
#   * Search for each option individually.
#   * "# CONFIG_NAME is not set"  ->  "CONFIG_NAME=y"
#   * "CONFIG_NAME=y" already     ->  leave alone
#   * option absent               ->  add at the end
#
# Nothing beyond the documented list is touched: the list is exactly the set
# that is kABI-safe when combined with the SYSVIPC padding patch.
#
# Idempotent: running it twice produces the same file.
#
# Usage: scripts/apply-droidspaces-config.sh <path/to/gki_defconfig>
# ---------------------------------------------------------------------------
set -euo pipefail

DEFCONFIG="${1:?usage: apply-droidspaces-config.sh <path/to/gki_defconfig>}"
[ -f "$DEFCONFIG" ] || { echo "ERROR: no such file: $DEFCONFIG" >&2; exit 1; }

# The DroidSpaces GKI-exclusive list, verbatim and in documented order.
DS_SYMBOLS=(
  # IPC
  SYSVIPC
  POSIX_MQUEUE
  # Namespaces
  IPC_NS
  PID_NS
  # HW access support
  DEVTMPFS
  # Networking (enhanced NAT support)
  NETFILTER_XT_MATCH_ADDRTYPE
  # Fix for docker "unsafe procfs" error
  USER_NS
  # UFW support.
  #
  # The DroidSpaces docs spell the REJECT target NETFILTER_XT_TARGET_REJECT.
  # That symbol does not exist in Linux 6.6 (nor in mainline): net/netfilter
  # has 26 NETFILTER_XT_TARGET_* symbols and REJECT is not among them, and
  # net/netfilter/xt_REJECT.c does not exist either. The real symbols are the
  # per-family ones, IP_NF_TARGET_REJECT (net/ipv4/netfilter/Kconfig) and
  # IP6_NF_TARGET_REJECT (net/ipv6/netfilter/Kconfig), both of which are
  # already =y in the stock algiz gki_defconfig. Writing the documented
  # spelling would be silently discarded by merge_config.sh/olddefconfig
  # (no such Kconfig symbol) and would leave UFW's REJECT rules unavailable
  # while looking like it had been applied.
  IP_NF_TARGET_REJECT
  IP6_NF_TARGET_REJECT
  NETFILTER_XT_TARGET_LOG
  NETFILTER_XT_MATCH_RECENT
  # Fail2ban support
  IP_SET
  IP_SET_HASH_IP
  IP_SET_HASH_NET
  NETFILTER_XT_SET
  # xattr / POSIX ACL on tmpfs (NixOS support)
  TMPFS_POSIX_ACL
  TMPFS_XATTR
)

# Options DroidSpaces treats as fatal-if-missing. Not written by this script
# unless they are also in DS_SYMBOLS; only verified afterwards.
DS_REQUIRED=(PID_NS NAMESPACES UTS_NS IPC_NS DEVTMPFS)

# CGROUP_DEVICE is called "Fatal. Containers cannot start." by the DroidSpaces
# documentation, but it is deliberately NOT enabled here, and not treated as
# required:
#
#   * It appears only in the doc's non-GKI list, not the GKI-exclusive list.
#   * DroidSpaces' own runtime probe (Droidspaces-OSS check.c) never looks for
#     it. Its cgroup probes are /proc/filesystems:cgroup2 and
#     check_ns(CLONE_NEWCGROUP), both flagged OPT.
#   * devices_cgrp_subsys in security/device_cgroup.c defines only
#     .legacy_cftypes, i.e. it is cgroup-v1 only. Android 16 boots pure
#     cgroup v2 for the container-relevant hierarchies, so the controller
#     would not even be mounted.
#   * It is a kABI hazard: include/linux/cgroup_subsys.h gates SUBSYS(devices)
#     on CONFIG_CGROUP_DEVICE, between MEMCG and CGROUP_FREEZER. Enabling it
#     inserts a cgroup_subsys_id enum value and shifts every subsequent ID,
#     which prebuilt vendor modules were compiled against. That is exactly the
#     class of breakage the SYSVIPC padding patch exists to avoid.
#
# It is reported for information only.
DS_INFORMATIONAL=(CGROUP_DEVICE)

cp -f "$DEFCONFIG" "${DEFCONFIG}.droidspaces.bak"

flipped=0; appended=0; kept=0
appended_list=()

for sym in "${DS_SYMBOLS[@]}"; do
  key="CONFIG_${sym}"
  if grep -qx -- "${key}=y" "$DEFCONFIG"; then
    printf '  keep    %s=y\n' "$key"
    kept=$((kept + 1))
  elif grep -qx -- "# ${key} is not set" "$DEFCONFIG"; then
    # In-place flip; keeps the symbol in its original position in the file.
    sed -i "s|^# ${key} is not set\$|${key}=y|" "$DEFCONFIG"
    printf '  flip    # %s is not set  ->  %s=y\n' "$key" "$key"
    flipped=$((flipped + 1))
  elif grep -qE "^${key}=" "$DEFCONFIG"; then
    # Present with a non-y value (e.g. =m or a string). Rewrite to =y.
    old="$(grep -E "^${key}=" "$DEFCONFIG" | head -1)"
    sed -i "s|^${key}=.*\$|${key}=y|" "$DEFCONFIG"
    printf '  set     %s  ->  %s=y\n' "$old" "$key"
    flipped=$((flipped + 1))
  else
    appended_list+=("$key")
  fi
done

if [ "${#appended_list[@]}" -gt 0 ]; then
  # Rule: "If an option does not exist, add it at the end."
  [ -n "$(tail -c 1 "$DEFCONFIG")" ] && printf '\n' >> "$DEFCONFIG"
  printf '\n# --- DroidSpaces (GKI-exclusive, kABI-safe) ---\n' >> "$DEFCONFIG"
  for key in "${appended_list[@]}"; do
    printf '%s=y\n' "$key" >> "$DEFCONFIG"
    printf '  append  %s=y\n' "$key"
    appended=$((appended + 1))
  done
fi

echo "==> DroidSpaces config applied: ${kept} kept, ${flipped} flipped, ${appended} appended"

# --- Verification -----------------------------------------------------------
echo "==> Verifying every DroidSpaces symbol is now =y"
bad=0
for sym in "${DS_SYMBOLS[@]}"; do
  grep -qx -- "CONFIG_${sym}=y" "$DEFCONFIG" || { echo "  FAIL CONFIG_${sym}"; bad=1; }
done

echo "==> Checking DroidSpaces fatal-if-missing options"
for sym in "${DS_REQUIRED[@]}"; do
  if grep -qx -- "CONFIG_${sym}=y" "$DEFCONFIG"; then
    echo "  ok        CONFIG_${sym}=y (explicit)"
  elif grep -qE "^(# )?CONFIG_${sym}\b" "$DEFCONFIG"; then
    echo "  FAIL      CONFIG_${sym} present but not =y"
    bad=1
  else
    # Absent from defconfig. For UTS_NS this is expected on GKI: it is not
    # listed but comes from Kconfig defaults (UTS_NS is "default y" in 6.6).
    # Report so the .config check can confirm it later.
    echo "  defer     CONFIG_${sym} not in defconfig (verify in built .config)"
  fi
done

echo "==> Informational (documented as fatal, deliberately not enabled - see above)"
for sym in "${DS_INFORMATIONAL[@]}"; do
  if grep -qx -- "CONFIG_${sym}=y" "$DEFCONFIG"; then
    echo "  note      CONFIG_${sym}=y (came from the vendor config, not from us)"
  else
    echo "  note      CONFIG_${sym} not enabled (cgroup-v1 only, unprobed, kABI hazard)"
  fi
done

# LOCALVERSION must survive untouched: it is part of the release string that
# stock vendor modules' vermagic is matched against.
if grep -q '^CONFIG_LOCALVERSION=' "$DEFCONFIG"; then
  echo "==> $(grep '^CONFIG_LOCALVERSION=' "$DEFCONFIG") (preserved)"
fi

if ! diff -q "${DEFCONFIG}.droidspaces.bak" "$DEFCONFIG" >/dev/null; then
  echo "==> Diff against original:"
  diff -u "${DEFCONFIG}.droidspaces.bak" "$DEFCONFIG" || true
else
  echo "==> No change (already applied)"
fi

[ "$bad" -eq 0 ] || { echo "ERROR: DroidSpaces config verification failed" >&2; exit 1; }
