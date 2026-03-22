#!/usr/bin/env bash
# Setup drives for NixOS with Yubikey LUKS encryption
# Usage: ./ykluks-setup.sh <device>
set -euo pipefail

DEVICE="${1:-}"
[[ -z "$DEVICE" ]] && { echo "Usage: $0 <device>"; exit 1; }
[[ ! -b "$DEVICE" ]] && { echo "Not a block device: $DEVICE"; exit 1; }

SLOT=1
KEY_LENGTH=64

# TODO: change this to upstream luksroot module if https://github.com/NixOS/nixpkgs/pull/499335 merges
NIXPKGS_URL="https://github.com/nullcopy/nixpkgs/archive/fix/luksroot-salt-rotation.tar.gz"

# Partition names
if [[ "$DEVICE" =~ nvme ]]; then
    EFI_PART="${DEVICE}p1"
    LUKS_PART="${DEVICE}p2"
else
    EFI_PART="${DEVICE}1"
    LUKS_PART="${DEVICE}2"
fi

rbtohex() { od -An -vtx1 | tr -d ' \n'; }
hextorb() { tr '[:lower:]' '[:upper:]' | sed -e 's/\([0-9A-F]\{2\}\)/\\\\\\x\1/gI' | xargs printf; }

# 1. Install dependencies and build pbkdf2-sha512
echo "Installing dependencies..."
nix-env -i yubikey-personalization openssl

echo "Building pbkdf2-sha512..."
PBKDF2=$(nix-build --no-out-link -E '
  let pkgs = import <nixpkgs> {};
  in pkgs.runCommand "pbkdf2-sha512" {
    nativeBuildInputs = [ pkgs.gcc ];
    buildInputs = [ pkgs.openssl ];
  } "cc -O3 -I${pkgs.openssl.dev}/include -L${pkgs.openssl.out}/lib ${pkgs.path}/nixos/modules/system/boot/pbkdf2-sha512.c -o \$out -lcrypto"
')

# 2. Benchmark iterations
echo ""
echo "Benchmarking PBKDF2 speed..."
BENCH_ITERATIONS=100000
BENCH_START=$(date +%s.%N)
echo "test" | "$PBKDF2" $KEY_LENGTH $BENCH_ITERATIONS "00" >/dev/null
BENCH_END=$(date +%s.%N)
BENCH_TIME=$(awk "BEGIN {print $BENCH_END - $BENCH_START}")
ITERS_PER_SEC=$(awk "BEGIN {printf \"%.0f\", $BENCH_ITERATIONS / $BENCH_TIME}")

echo "Your system: ~$(awk "BEGIN {printf \"%.1f\", $ITERS_PER_SEC / 1000000}")M iterations/sec"
echo ""
echo "Unlock time determines security. Longer = more secure but slower boot."
echo "Recommended: 5-10 seconds"
echo ""
echo -n "Target unlock time in seconds [5]: "
read -r TARGET_TIME
TARGET_TIME="${TARGET_TIME:-5}"

ITERATIONS=$(awk "BEGIN {printf \"%.0f\", $ITERS_PER_SEC * $TARGET_TIME}")
echo "Using $ITERATIONS iterations (~${TARGET_TIME}s unlock time)"

# 3. Generate salt and config
echo ""
echo "Generating salt..."
SALT=$(dd if=/dev/random bs=1 count=256 2>/dev/null | rbtohex)

cat > ./yubikey-luks.nix << EOF
# Yubikey LUKS configuration
# EFI: $EFI_PART
# LUKS: $LUKS_PART
{ config, lib, pkgs, ... }:
let
  myNixpkgs = builtins.fetchTarball { url = "$NIXPKGS_URL"; };
in {
  disabledModules = [ "system/boot/luksroot.nix" ];
  imports = [ "\${myNixpkgs}/nixos/modules/system/boot/luksroot.nix" ];
  boot.initrd.kernelModules = [ "vfat" "nls_cp437" "nls_iso8859-1" "usbhid" ];
  boot.initrd.luks.yubikeySupport = true;
  boot.initrd.luks.devices."nixos-enc" = {
    device = "$LUKS_PART";
    preLVM = true;
    yubikey = {
      slot = $SLOT;
      twoFactor = true;
      salt = "$SALT";
      iterations = $ITERATIONS;
      keyLength = $KEY_LENGTH;
      gracePeriod = 30;
    };
  };
}
EOF
echo "Created yubikey-luks.nix"

# 4. Partition drive
echo ""
echo "WARNING: This will DESTROY ALL DATA on $DEVICE"
echo -n "Continue? [y/N]: "
read -r CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 1; }

echo "Partitioning $DEVICE..."
wipefs -af "$DEVICE"
parted -s "$DEVICE" mklabel gpt \
    mkpart efi fat32 0% 256MiB set 1 esp on \
    mkpart luksdata 256MiB 100%
sleep 2
partprobe "$DEVICE" 2>/dev/null || true
mkfs.vfat -F 32 -n uefi "$EFI_PART"

# 5. Configure Yubikey
echo ""
echo "Insert your Yubikey and press Enter..."
read -r

echo "Getting response from your Yubikey. You may need to tap it if blinking..."

# Check if slot already has challenge-response configured
if ykchalresp -$SLOT -x "0000000000000000000000000000000000000000" >/dev/null 2>&1; then
    echo "Yubikey slot $SLOT already has challenge-response configured."
    echo "Reconfigure slot? (WARNING: this will overwrite existing config) [y/N]"
    read -r CONFIGURE_YK
    if [[ "$CONFIGURE_YK" =~ ^[Yy]$ ]]; then
        echo "Tap your Yubikey when it blinks..."
        ykpersonalize -$SLOT -ochal-resp -ochal-hmac -ochal-btn-trig
    fi
else
    echo "Configuring Yubikey slot $SLOT for challenge-response..."
    echo "Tap your Yubikey when it blinks..."
    ykpersonalize -$SLOT -ochal-resp -ochal-hmac -ochal-btn-trig
fi

# 6. Derive key and setup LUKS
echo ""
echo -n "Enter LUKS password: "
read -rs PASSWORD
echo ""
echo -n "Confirm password: "
read -rs PASSWORD2
echo ""
[[ "$PASSWORD" != "$PASSWORD2" ]] && { echo "Passwords don't match"; exit 1; }

echo "Getting Yubikey response (tap when it blinks)..."
CHALLENGE=$(echo -n "$SALT" | openssl dgst -sha512 -binary | rbtohex)
RESPONSE=$(ykchalresp -$SLOT -x "$CHALLENGE")

echo "Deriving key (this will take ~${TARGET_TIME}s)..."
KEY=$(echo -n "$PASSWORD" | "$PBKDF2" $KEY_LENGTH $ITERATIONS "$RESPONSE" | rbtohex)

echo "Formatting LUKS..."
echo -n "$KEY" | hextorb | cryptsetup luksFormat --cipher aes-xts-plain64 --key-size 512 --hash sha512 --key-file=- "$LUKS_PART"

echo "Opening LUKS..."
echo -n "$KEY" | hextorb | cryptsetup luksOpen "$LUKS_PART" nixos-enc --key-file=-

# 7. Setup LVM
echo "Creating LVM..."
pvcreate /dev/mapper/nixos-enc
vgcreate partitions /dev/mapper/nixos-enc
lvcreate -L 2G -n swap partitions
lvcreate -l 100%FREE -n fsroot partitions

# 8. Setup btrfs
echo "Creating btrfs..."
mkswap -L swap /dev/partitions/swap
mkfs.btrfs -L fsroot /dev/partitions/fsroot
mount /dev/partitions/fsroot /mnt
btrfs subvolume create /mnt/root
btrfs subvolume create /mnt/home
umount /mnt

# 9. Mount filesystems
echo "Mounting filesystems..."
mount -o subvol=root /dev/partitions/fsroot /mnt
mkdir -p /mnt/home /mnt/boot
mount -o subvol=home /dev/partitions/fsroot /mnt/home
mount "$EFI_PART" /mnt/boot
swapon /dev/partitions/swap
