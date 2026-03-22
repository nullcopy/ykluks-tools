# NixOS Yubikey LUKS Setup
Tools for setting up and managing a LUKS partition with Yubikey 2FA.

The current version of these tools is tailored to be run on a NixOS
installation media, or on a running NixOS system; However, the actual LUKS
configuration itself could be applied to any Linux distribution with a bit of
tweaking.

## Setup
1. Boot NixOS installer
2. Clone this repo
3. Run: `./scripts/ykluks-setup.sh <device>`
4. Run: `nixos-generate-config --root /mnt`
5. Run: `cp yubikey-luks.nix /mnt/etc/nixos/`
6. Edit `/mnt/etc/nixos/configuration.nix`, add `./yubikey-luks.nix` to imports
7. Edit `/mnt/etc/nixos/configuration.nix` to set up your NixOS system for install.
8. Run: `nixos-install`
9. Reboot

## Add Another Yubikey
Once booted into NixOS, clone this repo and run the `ykluks-addkey.sh` script
as root:
```
sudo ./scripts/ykluks-addkey.sh
```
