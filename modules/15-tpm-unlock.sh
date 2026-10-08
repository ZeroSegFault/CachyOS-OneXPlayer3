#!/usr/bin/env bash
# Unlock the root LUKS volume with the TPM2 at boot, keeping the passphrase.
#
# Policy (docs/research/2026-10-08-secure-boot-uki.md):
# - PCR 7: Secure Boot state, keys and the db entry that verified the boot
#   chain. Stable across kernel and initramfs updates.
# - PCR 15 sealed to all-zero, with tpm2-measure-pcr=yes: once the initrd has
#   unlocked the disk it extends PCR 15 with the volume key, so nothing later
#   in the boot can unseal again.
# - PCR 12, once the device boots a UKI (12-uki-boot): systemd-boot and
#   systemd-stub measure anything added at boot time into it (an edited or
#   injected command line, an extra initrd from a Type #1 entry, credentials,
#   addons). A clean UKI boot holds only systemd's os-separator there.
#
# PCR 15 (and the os-separator in PCR 7 and 12) only appear on a "measured
# OS", which needs a UKI booted through systemd-stub. Every switch (Type #1 to
# UKI, Secure Boot keys, Secure Boot on) changes PCR 7, so the next boot asks
# for the passphrase once and this module re-seals the TPM in the run after.
# No seal is made while a later step would change PCR 7 anyway (the first
# UKI boot, or 13-secure-boot running but Secure Boot not on yet), never to
# a boot whose PCR 12 shows additions, and never while Secure Boot is off
# with this device's own keys enrolled (a repair state where unsigned code
# boots): Secure Boot must go back on first.
#
# The passphrase is needed only when there is no usable TPM slot to unlock
# with. It is the password install.sh asked for when that unlocks the disk
# (the README has both set the same), otherwise it is asked on the terminal;
# either way it reaches root through a tmpfs key file, never a command line.
# Set OXP3_RECOVERY_KEY=1 to also enrol a printed recovery key.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3
pkg_install jq

root_src="$(findmnt -no SOURCE /)"
root_src="${root_src%%\[*}"
[[ $root_src == /dev/mapper/* ]] || { ok "root is not on dm-crypt ($root_src); nothing to do"; exit 0; }
name="${root_src#/dev/mapper/}"
dev="$(sudo cryptsetup status "$name" | awk '$1 == "device:" {print $2}')"
uuid="$(sudo cryptsetup luksUUID "$dev")"
[[ -e /dev/tpmrm0 ]] || die "no TPM2 resource manager (/dev/tpmrm0)"

zero="$(printf '0%.0s' {1..64})"
# A clean UKI boot extends PCR 12 once, with systemd-pcrosseparator's
# "os-separator", before cryptsetup runs.
clean_pcr12="$({ head -c 32 /dev/zero; printf %s os-separator | openssl dgst -sha256 -binary; } |
  openssl dgst -sha256 -r | cut -d' ' -f1)"
pcr12="$(cat /sys/class/tpm/tpm0/pcr-sha256/12 2>/dev/null || true)"
# Once the device boots UKIs, PCR 12 is always part of the policy: a boot
# with something added (PCR 12 not clean) is never sealed to, rather than
# sealed without PCR 12.
strict=0 clean12=0
if booted_uki || uki_mode; then strict=1; fi
if booted_uki && [[ ${pcr12,,} == "$clean_pcr12" ]]; then clean12=1; fi
if (( strict )); then
  want_pcrs='[7,12,15]' pcrs="7+12+15:sha256=$zero"
else
  want_pcrs='[7,15]' pcrs="7+15:sha256=$zero"
fi

# 1. crypttab: the root line carries the TPM options and x-initrd.attach,
#    which mkinitcpio >= 41.1 copies into the initramfs (rd.luks.name on the
#    kernel command line picks up options from the same-UUID line).
want="$name UUID=$uuid none tpm2-device=auto,tpm2-measure-pcr=yes,x-initrd.attach"
current="$(sudo cat /etc/crypttab 2>/dev/null || true)"
desired="$(awk -v n="$name" -v w="$want" '
  $1 == n { if (!done) print w; done = 1; next } { print } END { if (!done) print w }
' <<<"$current")"
if [[ $current != "$desired" ]]; then
  printf '%s\n' "$desired" | write_file /etc/crypttab 0600 || true
fi
# The initramfs copy is what counts at boot; rebuild whenever it differs, so
# an interrupted earlier run is repaired (step 5).

# 2. inspect LUKS2 tokens
meta="$(sudo cryptsetup luksDump --dump-json-metadata "$dev")"
tpm_any="$(jq '[.tokens[] | select(.type == "systemd-tpm2")] | length' <<<"$meta")"
tpm_ok="$(jq --argjson want "$want_pcrs" '[.tokens[] | select(.type == "systemd-tpm2")
             | select((.["tpm2-pcrs"] | sort) == $want and (.["tpm2-pin"] // false) == false)]
             | length' <<<"$meta")"
has_recovery="$(jq '[.tokens[] | select(.type == "systemd-recovery")] | length' <<<"$meta")"
fell_back="$(sudo journalctl -b -o cat -u 'systemd-cryptsetup@*' 2>/dev/null |
             grep -c 'falling back to traditional unlocking' || true)"

# A re-enrolment earlier in this boot already answered the fall-back.
reenrolled=/run/oxp3-tpm-reenrolled
[[ -e $reenrolled ]] && fell_back=0
need_enrol=0
(( tpm_ok == 1 && tpm_any == 1 && fell_back == 0 )) || need_enrol=1
[[ ${OXP3_FORCE:-0} == 1 ]] && need_enrol=1
sealed=$(( ! need_enrol ))
# Reasons not to seal now; each leaves any existing slot alone.
if (( need_enrol )); then
  if (( strict && ! clean12 )); then
    warn "this boot measured additions into PCR 12 ($pcr12), not sealing the TPM to it. Remove anything added on the ESP (/boot/loader/credentials, /boot/loader/addons, *.efi.extra.d, entries in /boot/loader/entries), don't edit the boot menu command line, reboot and rerun."
    need_enrol=0
  elif ! booted_uki && [[ "$(loader_var LoaderEntryOneShot)" == *.efi ]]; then
    # 12-uki-boot's first UKI boot changes PCR 7 (os-separator).
    ok "TPM unlock is set up after the first boot from the UKI (12-uki-boot)"
    need_enrol=0
  elif our_pk_enrolled && ! secure_boot_on; then
    if setup_mode_on || [[ -e /run/oxp3-sb-keys-enrolled ]]; then
      ok "TPM unlock is set up after the reboot into Secure Boot"
    else
      # Off for a repair: sealing would trust a boot where unsigned code runs.
      warn "Secure Boot is off although this device's keys are enrolled: not sealing the TPM to that state"
      need_action "Turn Secure Boot back on (systemctl reboot --firmware-setup, Security → Secure Boot → Enabled), then rerun install.sh."
    fi
    need_enrol=0
  elif [[ " ${OXP3_SELECTED:-} " == *" 13-secure-boot "* ]] && ! secure_boot_on; then
    # 13-secure-boot is under way: its remaining steps change PCR 7 anyway.
    ok "TPM unlock is set up once Secure Boot is on (13-secure-boot; --skip 13-secure-boot to go without it)"
    need_enrol=0
  fi
fi
need_recovery=0
[[ ${OXP3_RECOVERY_KEY:-0} == 1 ]] && (( has_recovery == 0 )) && need_recovery=1

# 3. choose how to unlock the volume for enrolment
unlock=()
keyfile=/run/oxp3-luks-unlock
cleanup() { sudo rm -f "$keyfile"; }
trap cleanup EXIT
if (( need_enrol || need_recovery )); then
  pcr15="$(cat /sys/class/tpm/tpm0/pcr-sha256/15 2>/dev/null || true)"
  if [[ $DRY_RUN == 1 ]]; then
    log "[dry-run] would enrol the TPM (needs the passphrase unless the TPM slot can unlock)"
    need_enrol=0 need_recovery=0
  elif (( tpm_any >= 1 && fell_back == 0 )) && [[ ${pcr15,,} == "$zero" ]] && (( ! need_recovery )); then
    # PCR 15 is still zero this boot, so the existing TPM slot can unseal.
    unlock=(--unlock-tpm2-device=auto)
  elif [[ -n ${OXP3_PASSWORD_FILE:-} ]] && sudo test -s "$OXP3_PASSWORD_FILE" &&
       sudo cryptsetup open --test-passphrase --disable-external-tokens \
         --key-file "$OXP3_PASSWORD_FILE" "$dev" 2>/dev/null; then
    # The password install.sh asked for is also the disk passphrase (README).
    unlock=(--unlock-key-file="$OXP3_PASSWORD_FILE")
  elif [[ -t 0 ]]; then
    # Keep the passphrase byte-exact (IFS=, -r) and check it before any
    # enrolment, with a few tries for typos on an on-screen keyboard.
    for try in 1 2 3; do
      IFS= read -rsp "Disk encryption passphrase (to enrol the TPM): " pw; echo
      printf '%s' "$pw" | sudo install -m 0600 /dev/stdin "$keyfile"
      unset pw
      # Tokens must not answer for the typed text: with a TPM2 token in the
      # header, cryptsetup would otherwise unlock through the TPM and accept
      # anything.
      if sudo cryptsetup open --test-passphrase --disable-external-tokens --key-file "$keyfile" "$dev" 2>/dev/null; then
        unlock=(--unlock-key-file="$keyfile")
        break
      fi
      warn "that passphrase does not unlock $dev (try $try of 3)"
      sudo rm -f "$keyfile"
    done
    (( ${#unlock[@]} )) || die "no valid passphrase given; TPM not enrolled (rerun install.sh to retry)"
  else
    warn "TPM enrolment needs the disk passphrase; rerun install.sh from a terminal"
    need_enrol=0 need_recovery=0
  fi
fi

# 4. enrol (sleep inhibited: a LUKS header write must not race a suspend)
enroll() {
  as_root systemd-inhibit --what=sleep:idle:handle-lid-switch --why="LUKS enrolment" \
    systemd-cryptenroll "$dev" "${unlock[@]}" "$@"
}
if (( need_recovery )); then
  log "enrolling a recovery key: write down the key printed below"
  enroll --recovery-key
  mark_changed "enrolled LUKS recovery key"
fi
if (( need_enrol )); then
  log "enrolling TPM2 slot bound to PCR $pcrs (replacing older TPM2 slots)"
  enroll --tpm2-device=auto --tpm2-pcrs="$pcrs" --wipe-slot=tpm2
  mark_changed "enrolled TPM2 keyslot (PCR ${pcrs%%:*})"
  sealed=1
  if (( fell_back > 0 )); then sudo touch "$reenrolled"; fi
fi

# 5. initramfs carries crypttab. sd-encrypt prefers the deprecated
#    /etc/crypttab.initramfs over the x-initrd.attach lines of /etc/crypttab.
[[ -e /etc/crypttab.initramfs ]] &&
  die "/etc/crypttab.initramfs overrides /etc/crypttab in the initramfs (deprecated by mkinitcpio); merge it into /etc/crypttab and rerun"
# mkinitcpio copies only the x-initrd.attach lines, so look for our line.
if [[ $DRY_RUN != 1 ]] && ! initramfs_has_line etc/crypttab "$want"; then
  rebuild_initramfs "TPM unlock options take effect at next boot"
fi

# 6. Boot menu command line editing. Before Secure Boot, the TPM unlocks
#    the disk for any command line, so 'e' plus init=/bin/sh would be a root
#    shell. With Secure Boot on our keys, the slot bound to PCR 12 and no
#    Type #1 entries, a UKI's command line cannot be edited, and with Secure
#    Boot turned off for a repair an edit works but PCR 7 and 12 change, so
#    the passphrase is needed: then the editor is a recovery tool, not a hole.
editor=no
if (( sealed )) && [[ $want_pcrs == '[7,12,15]' ]] && secure_boot_on && our_pk_enrolled &&
   [[ -z "$(type1_entries)" ]]; then
  editor=yes
fi
loader=/boot/loader/loader.conf
if ! sudo grep -qx "editor $editor" "$loader"; then
  # vfat: modes come from the mount options, so edit content in place.
  log "boot menu command line editor: $editor"
  # shellcheck disable=SC2016 # sed's $a (append after last line)
  as_root sed -i -e '/^editor /d' -e "\$a editor $editor" "$loader"
  mark_changed "boot menu command line editor set to $editor"
fi

if (( fell_back > 0 )); then
  warn "TPM unlock failed this boot (passphrase was used); slot re-enrolled for the current PCR 7"
fi
ok "$(sudo systemd-cryptenroll "$dev" | tr -s ' \n' ' ')"
