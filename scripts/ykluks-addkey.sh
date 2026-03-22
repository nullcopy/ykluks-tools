#!/usr/bin/env bash
# Add another Yubikey to existing LUKS device
# Usage: sudo ./addkey.sh
set -euo pipefail

CONFIG="/etc/nixos/yubikey-luks.nix"
[[ ! -f "$CONFIG" ]] && { echo "Config not found: $CONFIG"; exit 1; }

KEY_LENGTH=64

# Parse config
SALT=$(grep -oP 'salt = "\K[^"]+' "$CONFIG")
LUKS_PART=$(grep -oP 'device = "\K[^"]+' "$CONFIG")
ITERATIONS=$(grep -oP 'iterations = \K[0-9]+' "$CONFIG")
SLOT=$(grep -oP 'slot = \K[0-9]+' "$CONFIG")
[[ -z "$SALT" ]] && { echo "Salt not found in config"; exit 1; }
[[ -z "$LUKS_PART" ]] && { echo "LUKS device not found in config"; exit 1; }
[[ -z "$ITERATIONS" ]] && { echo "Iterations not found in config"; exit 1; }
[[ -z "$SLOT" ]] && { echo "Slot not found in config"; exit 1; }

# Install dependencies
echo "Installing dependencies..."
nix-env -i yubikey-personalization openssl

# Build pbkdf2-sha512 via nix
echo "Building pbkdf2-sha512..."
PBKDF2=$(nix-build --no-out-link -E '
  let pkgs = import <nixpkgs> {};
  in pkgs.runCommand "pbkdf2-sha512" {
    nativeBuildInputs = [ pkgs.gcc ];
    buildInputs = [ pkgs.openssl ];
  } "cc -O3 -I${pkgs.openssl.dev}/include -L${pkgs.openssl.out}/lib ${pkgs.path}/nixos/modules/system/boot/pbkdf2-sha512.c -o \$out -lcrypto"
')

rbtohex() { od -An -vtx1 | tr -d ' \n'; }
hextorb() { tr '[:lower:]' '[:upper:]' | sed -e 's/\([0-9A-F]\{2\}\)/\\\\\\x\1/gI' | xargs printf; }

derive_key() {
    local password="$1"
    local challenge response
    challenge=$(echo -n "$SALT" | openssl dgst -sha512 -binary | rbtohex)
    echo "Getting response from your Yubikey. You may need to tap it if blinking..." >&2
    response=$(ykchalresp -$SLOT -x "$challenge")
    echo -n "$password" | "$PBKDF2" $KEY_LENGTH $ITERATIONS "$response" | rbtohex
}

echo "Add Yubikey to LUKS"
echo "Device: $LUKS_PART"
echo "Slot: $SLOT"
echo ""

# Step 1: Authenticate with existing Yubikey
echo "Step 1: Authenticate with your EXISTING Yubikey"
echo "Insert your existing Yubikey and press Enter..."
read -r
echo -n "Enter current LUKS password: "
read -rs OLD_PASSWORD
echo ""
OLD_KEY=$(derive_key "$OLD_PASSWORD")

# Step 2: Setup new Yubikey
echo ""
echo "Step 2: Remove old Yubikey, insert NEW Yubikey"
read -rp "Press Enter when ready..."

echo ""
echo "Your config expects slot $SLOT to be configured for challenge-response."
echo ""
echo "Options:"
echo "  [1] Configure slot $SLOT for challenge-response (overwrites existing config)"
echo "  [2] Use existing slot $SLOT configuration (if already set up)"
echo ""
echo -n "Choose [1/2]: "
read -r SLOT_CHOICE
if [[ "$SLOT_CHOICE" == "1" ]]; then
    echo "Tap your Yubikey when it blinks..."
    ykpersonalize -$SLOT -ochal-resp -ochal-hmac -ochal-btn-trig
elif [[ "$SLOT_CHOICE" != "2" ]]; then
    echo "Invalid choice. Aborting."
    exit 1
fi

# Step 3: Set password for new Yubikey
echo ""
echo "Step 3: Set password for NEW Yubikey"
echo -n "Enter new LUKS password: "
read -rs NEW_PASSWORD
echo ""
echo -n "Confirm password: "
read -rs NEW_PASSWORD2
echo ""
[[ "$NEW_PASSWORD" != "$NEW_PASSWORD2" ]] && { echo "Passwords don't match"; exit 1; }

NEW_KEY=$(derive_key "$NEW_PASSWORD")

# Step 4: Add new key to LUKS
echo ""
echo "Adding new key to LUKS..."
echo -n "$OLD_KEY" | hextorb | cryptsetup luksAddKey "$LUKS_PART" --key-file=- <(echo -n "$NEW_KEY" | hextorb)

echo ""
echo "Done. Your Yubikey can now be used to unlock the disk."
