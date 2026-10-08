#!/usr/bin/env bash
# EC platform driver (oxpec) for the OneXPlayer 3: fan readout and control,
# battery charge limit and bypass, turbo-button takeover.
#
# Linux's oxpec has no "ONEXPLAYER 3" DMI entry before v7.4. The quirk (same
# EC registers as the G1 Intel, confirmed on OXP3 hardware by its author) was
# taken into pdx86 review-ilpo-next on 2026-10-05. Until the running kernel's
# oxpec knows the device, this builds the kernel's own oxpec.c plus that one
# DMI entry as a DKMS module (files/dkms/oxpec-oxp3); once the in-tree module
# carries the entry, the DKMS copy is removed again.
# See docs/research/2026-10-07-onexplayer3-device-support.md §2.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

name=oxpec-oxp3
version="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$FILES_DIR/dkms/$name/dkms.conf")"
running="$(uname -r)"
src="/usr/src/$name-$version"

# Does kernel K's own oxpec know the OneXPlayer 3? DKMS moves the in-tree
# module aside when it installs the backport, so look there too.
intree_supports() {
  local k=$1 ko
  for ko in "/usr/lib/modules/$k/kernel/drivers/platform/x86/oxpec.ko.zst" \
            $(sudo find "/var/lib/dkms/$name/original_module/$k" -name 'oxpec.ko*' 2>/dev/null); do
    sudo test -e "$ko" || continue
    if [[ -r $ko ]]; then
      module_has_string "$ko" 'ONEXPLAYER 3' && return 0
    else
      local tmp; tmp="$(mktemp -p "$RUN_DIR")"
      # shellcheck disable=SC2024 # read as root into our own temp file
      sudo cat "$ko" > "$tmp" && module_has_string "$tmp" 'ONEXPLAYER 3' && return 0
    fi
  done
  return 1
}
dkms_installed() { dkms status "$name/$version" -k "$1" 2>/dev/null | grep -q installed; }

# Installed kernels (pacman-owned trees carry vmlinuz).
kernels=()
for d in /usr/lib/modules/*/; do
  [[ -e $d/vmlinuz ]] && kernels+=("$(basename "$d")")
done

needed=()
for k in "${kernels[@]}"; do
  intree_supports "$k" || needed+=("$k")
done

if (( ${#needed[@]} == 0 )); then
  if [[ -d $src ]] || dkms status "$name" 2>/dev/null | grep -q .; then
    log "every installed kernel's oxpec supports the OneXPlayer 3; retiring the DKMS backport"
    as_root dkms remove "$name/$version" --all 2>/dev/null || true
    as_root rm -rf -- "$src"
    mark_changed "retired $name DKMS backport (in-tree support)"
    need_reboot "the in-tree oxpec replaces the backport at next boot"
  fi
  ok "in-tree oxpec supports the OneXPlayer 3"
else
  pkg_install dkms
  # Headers for every installed kernel, so DKMS can build for each of them.
  headers=()
  while read -r k; do headers+=("$k-headers"); done < <(pacman -Qqs '^linux-cachyos' | grep -vE -- '-(headers|nvidia.*|zfs)$' || true)
  (( ${#headers[@]} )) && pkg_install "${headers[@]}"

  rebuild=0
  for f in dkms.conf Makefile oxpec.c; do
    install_file "$FILES_DIR/dkms/$name/$f" "$src/$f" && rebuild=1
  done
  if (( rebuild )) && dkms status "$name/$version" 2>/dev/null | grep -q .; then
    as_root dkms remove "$name/$version" --all
  fi
  # Running kernel first; a failed build for another kernel must not stop it.
  ordered=()
  for k in "${needed[@]}"; do
    if [[ $k == "$running" ]]; then ordered=("$k" "${ordered[@]}"); else ordered+=("$k"); fi
  done
  for k in "${ordered[@]}"; do
    dkms_installed "$k" && continue
    if [[ ! -d /usr/lib/modules/$k/build ]]; then
      warn "no headers for kernel $k; skipping the oxpec backport for it"
      continue
    fi
    log "building $name $version for $k"
    if ! as_root dkms install "$name/$version" -k "$k"; then
      [[ $k == "$running" ]] && die "oxpec backport failed to build for the running kernel $k"
      warn "oxpec backport failed to build for $k; skipping it"
      continue
    fi
    mark_changed "built and installed $name $version for $k"
    if [[ $k == "$running" ]]; then rebuild=1; fi
  done
  # Kernels whose own oxpec knows the OXP3 do not keep the backport.
  for k in "${kernels[@]}"; do
    [[ " ${needed[*]} " == *" $k "* ]] && continue
    dkms_installed "$k" || continue
    log "kernel $k's in-tree oxpec supports the OneXPlayer 3; removing the backport for it"
    as_root dkms remove "$name/$version" -k "$k"
    mark_changed "removed $name backport for $k (in-tree support)"
    if [[ $k == "$running" ]]; then need_reboot "the in-tree oxpec replaces the backport at next boot"; fi
  done
  # A new build for the running kernel replaces the loaded driver now.
  if (( rebuild )) && [[ $DRY_RUN != 1 ]] && dkms_installed "$running"; then
    as_root modprobe -r oxpec 2>/dev/null || true
  fi
fi

# Load it now if the running kernel has nothing bound yet.
if [[ $DRY_RUN != 1 ]] && ! compgen -G '/sys/bus/platform/drivers/oxp-platform/oxp-platform*' >/dev/null; then
  as_root modprobe oxpec || warn "oxpec failed to load; see dmesg"
fi

hwmon="$(grep -lx oxp_ec /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 || true)"
if [[ -n $hwmon ]]; then
  ok "oxpec bound: fan $(cat "$(dirname "$hwmon")/fan1_input" 2>/dev/null || echo ?) RPM, charge limit $(cat /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/dev/null || echo ?) %"
else
  warn "oxpec hwmon not present"
fi
