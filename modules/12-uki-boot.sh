#!/usr/bin/env bash
# Boot a Unified Kernel Image (UKI): kernel, initramfs and kernel command
# line in one file that Secure Boot can sign (13-secure-boot).
#
# sdboot-manage's Type #1 entries keep the initramfs and command line as
# loose, unsigned files on the vfat ESP, which Secure Boot cannot cover. A
# UKI booted through systemd-stub also makes this a "measured OS", which the
# TPM policy in 15-tpm-unlock builds on (PCR 12 and 15). Research:
# docs/research/2026-10-08-secure-boot-uki.md.
#
# mkinitcpio builds each preset's default_uki into /boot/EFI/Linux, where
# systemd-boot finds it, with the command line from /etc/kernel/cmdline and
# the kernel from a copy on the encrypted root (files/usr/local/lib/oxp3/
# uki-presets). The plain initramfs image stays for the lsinitcpio checks in
# lib/common.sh.
#
# The switch takes two runs so the old entry stays until the UKI has booted:
# 1. build the UKI and boot it once (bootctl set-oneshot). That boot asks
#    for the disk passphrase: PCR 7 gains systemd's os-separator measurement.
# 2. once booted from it, make it the default, stop sdboot-manage writing
#    Type #1 entries and remove them.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3
pkg_install systemd-ukify

# 1. The kernel command line, derived from the running system. root= and
#    rootflags= are required: the partition type is plain "Linux filesystem"
#    and the btrfs default subvolume is not @, so nothing finds root alone.
#    nohibernate: the initrd would resume an image named by an EFI variable
#    before the TPM policy is sealed off; swap is zram, so nothing is lost.
cmdline=("root=UUID=$(findmnt -no UUID /)" rw)
fsroot="$(findmnt -no FSROOT /)"
[[ "$(findmnt -no FSTYPE /)" == btrfs && $fsroot != / ]] && cmdline+=("rootflags=subvol=$fsroot")
root_src="$(findmnt -no SOURCE /)"
root_src="${root_src%%\[*}"
if [[ $root_src == /dev/mapper/* ]]; then
  name="${root_src#/dev/mapper/}"
  dev="$(sudo cryptsetup status "$name" | awk '$1 == "device:" {print $2}')"
  cmdline+=("rd.luks.name=$(sudo cryptsetup luksUUID "$dev")=$name")
fi
cmdline+=(nowatchdog quiet splash "${QUIET_KERNEL_OPTIONS[@]}" nohibernate)
printf '%s\n' "${cmdline[*]}" | write_file /etc/kernel/cmdline || true

# 2. systemd 262 NvPCRs. On a measured OS it sets up extra NV-index "PCRs",
#    which needs a signed PCR policy in the UKI; without one every boot logs
#    "Failed to initialize NvPCR index" (systemd #43848, open) and fails
#    Early TPM SRK Setup in the initrd, visibly before Plymouth, plus
#    systemd-pcrproduct and systemd-pcrlogin@ later. Nothing here uses
#    NvPCRs (the TPM policy is PCR 7+12+15), so mask their definitions in
#    the system and the initramfs (before the first UKI is built), and the
#    units that only extend them.
while IFS= read -r def; do
  mask="/etc/nvpcr/${def##*/}"
  [[ "$(readlink "$mask" 2>/dev/null)" == /dev/null ]] && continue
  as_root install -d /etc/nvpcr
  as_root ln -sfn /dev/null "$mask"
  mark_changed "masked NvPCR ${def##*/}"
done < <(find /usr/lib/nvpcr -maxdepth 1 -name '*.nvpcr' 2>/dev/null | sort)
for u in systemd-pcrproduct.service systemd-pcrlogin@.service; do
  if [[ "$(systemctl is-enabled "$u" 2>/dev/null || true)" != masked ]]; then
    as_root systemctl mask "$u"
    mark_changed "masked $u"
  fi
done
install_file "$FILES_DIR/etc/initcpio/install/oxp3-nvpcr-off" /etc/initcpio/install/oxp3-nvpcr-off || true
write_file /etc/mkinitcpio.conf.d/oxp3-nvpcr-off.conf <<'EOF' || true
# Managed by CachyOS-OneXPlayer3 (modules/12-uki-boot.sh).
HOOKS+=(oxp3-nvpcr-off)
EOF
first_nvpcr="$(find /usr/lib/nvpcr -maxdepth 1 -name '*.nvpcr' -printf '%f\n' 2>/dev/null | sort | head -n 1 || true)"

# 3. One UKI per installed kernel. The preset script (also run by a pacman
#    hook for kernels installed later) builds each from a kernel copy on the
#    encrypted root, never from the ESP.
install_file "$FILES_DIR/usr/local/lib/oxp3/uki-presets" /usr/local/lib/oxp3/uki-presets 0755 || true
install_file "$FILES_DIR/etc/pacman.d/hooks/95-oxp3-uki-presets.hook" \
  /etc/pacman.d/hooks/95-oxp3-uki-presets.hook || true
install_file "$FILES_DIR/etc/pacman.d/hooks/zzz-oxp3-sdboot-update.hook" \
  /etc/pacman.d/hooks/zzz-oxp3-sdboot-update.hook || true
if [[ $DRY_RUN == 1 ]]; then
  log "[dry-run] would run /usr/local/lib/oxp3/uki-presets"
else
  while IFS= read -r base; do
    mark_changed "UKI preset for $base"
  done < <(sudo /usr/local/lib/oxp3/uki-presets)
fi
kver_of() {
  local d
  for d in /usr/lib/modules/*/; do
    [[ "$(cat "$d/pkgbase" 2>/dev/null)" == "$1" ]] && { basename "$d"; return 0; }
  done
  return 1
}
presets=()
while IFS= read -r p; do
  base="$(basename "$p" .preset)"
  kver_of "$base" >/dev/null && presets+=("$base") # else a removed kernel's
done < <(find /etc/mkinitcpio.d -maxdepth 1 -name '*.preset' | sort)
(( ${#presets[@]} )) || die "no mkinitcpio preset for an installed kernel"

# uki_dump UKI SECTION — print the path of a root-only file holding the
# section (sudo closes inherited pipes, so no process substitution).
uki_dump() {
  local out
  out="$(mktemp -p "$RUN_DIR")"
  sudo objcopy -O binary --only-section="$2" "$1" "$out" 2>/dev/null || : > "$out"
  printf '%s\n' "$out"
}
# uki_section UKI SECTION — a text section of a UKI, whitespace-normalised.
uki_section() {
  sudo cat "$(uki_dump "$1" "$2")" | tr -d '\0' | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}
uki_current() {
  local uki=/boot/EFI/Linux/$1.efi
  sudo test -f "$uki" &&
    [[ "$(uki_section "$uki" .uname)" == "$(kver_of "$1")" ]] &&
    [[ "$(uki_section "$uki" .cmdline)" == "${cmdline[*]}" ]] &&
    sudo cmp -s "$(uki_dump "$uki" .linux)" "/usr/lib/modules/$(kver_of "$1")/vmlinuz"
}
if [[ $DRY_RUN != 1 ]]; then
  stale=''
  for base in "${presets[@]}"; do
    uki_current "$base" || { stale="UKI for $base with the current kernel and command line"; break; }
  done
  if [[ -z $stale && -n $first_nvpcr ]] && ! initramfs_contains "etc/nvpcr/$first_nvpcr"; then
    stale="NvPCR masks in the initramfs (no FAILED line at boot)"
  fi
  [[ -z $stale ]] || rebuild_initramfs "$stale"
  for base in "${presets[@]}"; do
    uki_current "$base" || die "/boot/EFI/Linux/$base.efi is missing or stale after mkinitcpio -P"
  done
fi

# 4. Boot the UKI once before relying on it. Right after a kernel update the
#    running kernel's modules (and its pkgbase file) are gone; the new
#    kernel's UKI is what the next boot should try anyway.
running="$(cat "/usr/lib/modules/$(uname -r)/pkgbase" 2>/dev/null || true)"
[[ -n $running && " ${presets[*]} " == *" $running "* ]] || running="${presets[0]}"
uki_id="$running.efi"
selected="$(loader_var LoaderEntrySelected)"
if ! booted_uki || [[ $selected != *.efi ]]; then
  if [[ "$(loader_var LoaderEntryOneShot)" != "$uki_id" ]]; then
    log "the next boot tries $uki_id once; the current entry stays as the default"
    as_root bootctl set-oneshot "$uki_id"
    mark_changed "next boot tries the UKI ($uki_id)"
  fi
  need_reboot "first boot from the UKI: type the disk passphrase once, then rerun install.sh"
  exit 0
fi
ok "booted from UKI $selected"

# 5. Cut over: the UKI is the default and Type #1 entries are gone for good.
write_file "$UKI_MODE_CONF" <<'EOF' || true
# Managed by CachyOS-OneXPlayer3 (modules/12-uki-boot.sh). mkinitcpio builds
# UKIs, so sdboot-manage writes no Type #1 entries, and systemd-boot updates
# come from zzz-oxp3-sdboot-update.hook after sbctl has signed them.
NO_AUTOGEN="yes"
NO_AUTOUPDATE="yes"
EOF
# Keep a default that names an existing UKI (a kernel chosen on purpose).
loader=/boot/loader/loader.conf
current="$(sudo sed -n 's/^default[[:space:]]\+//p' "$loader" | tail -n 1)"
if [[ $current != *.efi ]] || ! sudo test -f "/boot/EFI/Linux/$current"; then
  log "making $uki_id the default boot entry"
  # vfat: modes come from the mount options, so edit content in place.
  # shellcheck disable=SC2016 # sed's $a (append after last line)
  as_root sed -i -e '/^default /d' -e "\$a default $uki_id" "$loader"
  mark_changed "default boot entry is $uki_id"
fi
while IFS= read -r entry; do
  [[ -n $entry ]] || continue
  log "removing Type #1 entry $entry"
  as_root rm -f -- "$entry"
  mark_changed "removed boot entry $entry"
done < <(type1_entries)
# The kernel copies on the ESP only served those entries.
if [[ $DRY_RUN != 1 ]]; then
  while IFS= read -r base; do mark_changed "UKI preset for $base"; done < <(sudo /usr/local/lib/oxp3/uki-presets)
fi
# kernel-install's copies (from the installer) under the entry token dir.
token="/boot/$(cat /etc/machine-id)"
while IFS= read -r d; do
  log "removing unused kernel copy $d"
  as_root rm -rf -- "$d"
  mark_changed "removed $d"
done < <(sudo find "$token" -mindepth 1 -maxdepth 1 2>/dev/null || true)
