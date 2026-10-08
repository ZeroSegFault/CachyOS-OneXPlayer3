#!/usr/bin/env bash
# Secure Boot with this device's own keys (sbctl): only systemd-boot and the
# signed UKI from 12-uki-boot start, so the TPM (15-tpm-unlock) unlocks the
# disk only for them.
#
# Without it, anyone holding the device can boot other media or replace
# boot files on the unencrypted ESP, and the TPM still releases the disk key.
# The factory Platform Key is "DO NOT TRUST - AMI Test PK" (PKfail), so the
# firmware's own keys are no alternative.
#
# Signed: systemd-boot (registered with sbctl; its pacman hook re-signs it on
# systemd updates) and the UKIs (signed as mkinitcpio builds them, by
# files/etc/initcpio/post/sbctl). Never a bare kernel: a signed vmlinuz would
# boot with any command line and initramfs.
#
# Keys are enrolled only while the firmware is in Setup Mode, which takes the
# person at the device once; the summary says what to do in the BIOS.
# Microsoft's keys are enrolled next to ours (-m) so revocation (dbx) updates
# and Microsoft-signed option ROMs keep working; whatever they sign measures
# a different PCR 7 and cannot unlock the disk.
# Research: docs/research/2026-10-08-secure-boot-uki.md.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3
pkg_install sbctl jq

# 1. Keys, created only once the firmware can take them. This firmware
#    refuses a loader signed with a key it does not know ("Invalid signature
#    detected", red screen) even while Secure Boot is inactive, yet starts
#    unsigned ones. So nothing is signed before Setup Mode, and the run in
#    Setup Mode creates the keys, signs everything and enrols the keys.
bios="systemctl reboot --firmware-setup, then Security → Secure Boot"
setup_steps="One BIOS visit for Secure Boot: $bios. Set Secure Boot Mode to Custom. In its advanced key menu set Factory Key Provision to Disabled first, then choose 'Reset To Setup Mode' (if the page still shows System Mode: User, use 'Delete all Secure Boot Variables'). Set Secure Boot to Enabled. Save and exit, type the disk passphrase, then rerun install.sh."
if ! sudo test -d "$SBCTL_DIR/keys"; then
  if ! setup_mode_on; then
    need_action "$setup_steps"
    exit 0
  fi
  log "creating Secure Boot keys in $SBCTL_DIR"
  as_root sbctl create-keys
  mark_changed "created Secure Boot keys"
fi
# Never sign bare kernels: mask sbctl's kernel-install plugin (nothing runs
# kernel-install here, but keep it that way) and replace its mkinitcpio post
# hook with one that signs only UKIs. Installed only once keys exist, so a
# declined Secure Boot leaves nothing behind.
plugin=/etc/kernel/install.d/91-sbctl.install
if [[ "$(readlink "$plugin" 2>/dev/null)" != /dev/null ]]; then
  as_root install -d /etc/kernel/install.d
  as_root ln -sfn /dev/null "$plugin"
  mark_changed "masked sbctl's kernel-install plugin"
fi
install_file "$FILES_DIR/etc/initcpio/post/sbctl" /etc/initcpio/post/sbctl 0755 || true

if [[ $DRY_RUN == 1 ]] && ! sudo test -d "$SBCTL_DIR/keys"; then
  log "[dry-run] would sign systemd-boot and the UKIs with the new keys"
  exit 0
fi

# 2. systemd-boot: sbctl keeps a signed copy beside the package file, and
#    bootctl installs the .signed copy in preference to the plain one.
sdboot=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
loader_info() { sudo grep -ao 'LoaderInfo: systemd-boot [^ ]*' "$1" 2>/dev/null | head -n 1 || true; }
registered="$(sudo sbctl list-files --json | jq --arg f "$sdboot" \
  '[.[] | select(.file == $f and .output_file == $f + ".signed")] | length')"
if (( registered == 0 )) || [[ "$(loader_info "$sdboot")" != "$(loader_info "$sdboot.signed")" ]]; then
  # sbctl 0.18 neither registers nor refreshes an output that is already
  # signed (sbctl #482, #488), so start from no output.
  log "signing systemd-boot"
  as_root rm -f "$sdboot.signed"
  as_root sbctl sign -s -o "$sdboot.signed" "$sdboot"
  mark_changed "signed systemd-boot"
fi
# Nothing else belongs in sbctl's database (sign-all re-signs all of it).
while IFS= read -r f; do
  log "removing $f from sbctl's database"
  as_root sbctl remove-file "$f"
  mark_changed "unregistered $f from sbctl"
done < <(sudo sbctl list-files --json | jq -r --arg f "$sdboot" '.[] | select(.file != $f) | .file')

# 3. The ESP holds the signed build. bootctl update skips an equal version,
#    install always copies.
esp_loaders=(/boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI)
stale=0
for f in "${esp_loaders[@]}"; do
  sudo cmp -s "$sdboot.signed" "$f" || stale=1
done
if (( stale )); then
  log "installing the signed systemd-boot on the ESP"
  as_root bootctl install --graceful
  mark_changed "installed signed systemd-boot on the ESP"
fi

# 4. Every file the firmware may start is signed with our db key: the
#    loaders, bootctl's fallback copy of the previous loader, and each
#    preset's UKI. Nothing found on the ESP is signed as it is, since the ESP
#    is unencrypted: an unsigned UKI is rebuilt from the root filesystem (the
#    mkinitcpio hook signs it), an unsigned fallback loader is removed
#    (bootctl rotates the signed one into place on its next update), and any
#    other unsigned file is left unsigned, so it cannot boot.
expected_ukis() {
  local p
  for p in /etc/mkinitcpio.d/*.preset; do
    [[ -e $p ]] || continue
    grep -q '^default_uki=' "$p" && printf '/boot/EFI/Linux/%s.efi\n' "$(basename "$p" .preset)"
  done
  return 0
}
boot_files() {
  printf '%s\n' "${esp_loaders[@]}"
  sudo find /boot/EFI/systemd -maxdepth 1 -name 'systemd-boot-fallback*.efi'
  expected_ukis
}
unsigned() {
  local v f
  v="$(sudo sbctl verify --json 2>/dev/null || echo '[]')"
  while IFS= read -r f; do
    jq -e --arg f "$f" 'any(.[]; .file_name == $f and .is_signed == 1)' <<<"$v" >/dev/null || printf '%s\n' "$f"
  done < <(boot_files)
}
rebuild=0
while IFS= read -r f; do
  case $f in
    */systemd-boot-fallback*)
      log "removing unsigned $f"
      as_root rm -f -- "$f"
      mark_changed "removed unsigned $f" ;;
    /boot/EFI/Linux/*) rebuild=1 ;;
  esac
done < <(unsigned)
if (( rebuild )); then
  log "rebuilding the UKIs so the mkinitcpio hook signs them"
  as_root mkinitcpio -P
  mark_changed "rebuilt and signed the UKIs"
fi
while IFS= read -r f; do
  [[ " $(expected_ukis | tr '\n' ' ') " == *" $f "* ]] && continue
  sudo sbctl verify --json 2>/dev/null | jq -e --arg f "$f" 'any(.[]; .file_name == $f and .is_signed == 1)' >/dev/null ||
    warn "$f was not built here and is not signed, so it will not boot; remove it if you don't know it"
done < <(sudo find /boot/EFI/Linux -maxdepth 1 -name '*.efi')
if [[ $DRY_RUN != 1 ]]; then
  left="$(unsigned)"
  [[ -z $left ]] || die "not signed with this device's keys: $(tr '\n' ' ' <<<"$left")"
  ok "boot chain signed ($(boot_files | wc -l) files)"
fi

# 5. Enrol the keys in the firmware.
if our_pk_enrolled; then
  if secure_boot_on; then
    ok "Secure Boot is on with this device's own keys"
  else
    need_action "Turn Secure Boot on: $bios → Enabled, save and exit. That boot asks for the disk passphrase once; then rerun install.sh."
  fi
elif ! uki_mode || ! booted_uki; then
  ok "keys are enrolled once the device boots from the UKI (12-uki-boot)"
elif setup_mode_on; then
  log "enrolling Secure Boot keys (this device's and Microsoft's)"
  as_root sbctl enroll-keys --microsoft --ignore-immutable
  if [[ $DRY_RUN != 1 ]]; then
    our_pk_enrolled || die "the firmware did not keep the new Platform Key"
    # Setup Mode and SecureBoot only change at the next boot; tell
    # 15-tpm-unlock that waiting for it is expected.
    sudo touch /run/oxp3-sb-keys-enrolled
  fi
  mark_changed "enrolled Secure Boot keys"
  need_reboot "Secure Boot keys enrolled (the next boot asks for the disk passphrase once)"
  need_action "Reboot (if Secure Boot is not Enabled in the BIOS yet, turn it on: $bios), type the disk passphrase, then rerun install.sh to set up the TPM unlock."
else
  # Keys exist but the firmware lost them (a BIOS update or reset).
  need_action "$setup_steps"
fi
# "Reset To Setup Mode" also empties the revocation list (dbx), and fwupd
# offers no dbx update while it is empty (no version to upgrade from). The
# disk unlock does not depend on it: a revoked loader is Microsoft-signed,
# which records a different db authority in PCR 7, so it cannot unseal.
if our_pk_enrolled && [[ ! -e /sys/firmware/efi/efivars/dbx-d719b2cb-3d3a-4596-a3bc-dad00e67656f ]]; then
  log "the firmware's revocation list (dbx) is empty; the TPM policy does not rely on it"
fi
