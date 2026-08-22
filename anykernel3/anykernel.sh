### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Volla Phone Quintus (algiz) - DroidSpaces-enabled kernel

### AnyKernel setup
# global properties
properties() { '
kernel.string=Volla Quintus (algiz) DroidSpaces kernel
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=algiz
device.name2=Quintus
device.name3=volla_quintus
device.name4=mt6877
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
# BLOCK=auto detects the boot partition by name; IS_SLOT_DEVICE=auto appends the
# active slot suffix on A/B devices (Quintus ships Android 16 / A-B).
BLOCK=auto;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
# split_boot keeps the stock ramdisk untouched ("OG AK" mode): this kernel only
# replaces the Image, and magiskboot re-applies an existing Magisk patch on
# repack, so root survives the flash.
split_boot;
flash_boot;
## end boot install
