#!/usr/bin/env bash
# Fingerprint unlock for the Plasma lock screen (opt-in, experimental).
#
# The sensor in the power button is a Betterlife BF63112 (ACPI BF63112, chip
# 0x6683) on LPSS SPI1. No libfprint release supports it. This builds
# libfprint 1.94.100 plus pythontyphon's BF63112 driver at a pinned commit,
# with our patches (files/pkg/libfprint-bf63112-oxp3), as a pacman package
# that installs the library to /usr/lib/libfprint-bf63112. Only fprintd loads
# it, through a systemd drop-in; the distro libfprint stays in place.
#
# Scope: convenience unlock for the Desktop Mode lock screen only. The open
# matcher's false-accept rate is unmeasured, so sudo, polkit and the login
# screen stay password-only, and failed touches count toward pam_faillock.
# Details: docs/research/2026-10-07-tpm-unlock-and-fingerprint.md section B.
#
#   OXP3_FINGERPRINT=1 ./install.sh --only 85-fingerprint   # opt in
#   OXP3_FINGERPRINT=0 ./install.sh --only 85-fingerprint   # remove again
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

pkgname=libfprint-bf63112-oxp3
pkgsrc="$FILES_DIR/pkg/$pkgname"
libdir=/usr/lib/libfprint-bf63112
marker=/etc/oxp3/fingerprint-enabled
rules=/etc/udev/rules.d/69-oxp3-fingerprint.rules
modconf=/etc/modprobe.d/oxp3-spidev.conf
dropin=/etc/systemd/system/fprintd.service.d/50-oxp3-bf63112.conf
pamfile=/etc/pam.d/kde-fingerprint
spi=/sys/bus/spi/devices/spi-BF63112:00
# sha256 of kscreenlocker 6.7.5's /usr/lib/pam.d/kde-fingerprint, which our
# /etc/pam.d/kde-fingerprint override is based on.
pam_base_sha=32734b4e1ec8b7f7e32b6cb2d68285c5c4f15f53736bba085096e76095181241
user="$(target_user)"

disable() {
  local changed=0
  if pacman -Qq "$pkgname" &>/dev/null; then
    # Prints are in the driver's own format; nothing else can read them.
    as_root fprintd-delete "$user" >/dev/null 2>&1 || true
    as_root pacman -Rns --noconfirm "$pkgname"
    mark_changed "removed $pkgname and $user's fingerprints"
    changed=1
  fi
  remove_file "$dropin" && changed=1
  remove_file "$pamfile" && changed=1
  remove_file "$rules" && changed=1
  remove_file "$modconf" && changed=1
  remove_file "$marker" && changed=1
  if (( changed )); then
    as_root systemctl daemon-reload
    as_root systemctl try-restart fprintd.service
    as_root udevadm control --reload
    need_reboot "the fingerprint sensor is released from spidev at the next boot"
  fi
  ok "fingerprint unlock is off"
  exit 0
}

case ${OXP3_FINGERPRINT:-} in
  0) disable ;;
  1) ;;
  *)
    if [[ ! -e $marker ]]; then
      ok "fingerprint unlock not enabled (opt in: OXP3_FINGERPRINT=1 ./install.sh --only 85-fingerprint)"
      exit 0
    fi
    ;;
esac

[[ -e $spi ]] || die "no $spi: the sensor's ACPI device is missing"
[[ "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)" == 5.09 ]] ||
  warn "the driver was tested with BIOS 5.09; this is $(cat /sys/class/dmi/id/bios_version 2>/dev/null)"

pkg_install fprintd base-devel git meson glib2-devel patchelf

# Build and install the package when it is missing, out of date, or no longer
# loads (an opencv soname bump).
want="$(sed -n 's/^pkgver=//p' "$pkgsrc/PKGBUILD")-$(sed -n 's/^pkgrel=//p' "$pkgsrc/PKGBUILD")"
have="$(pacman -Q "$pkgname" 2>/dev/null | awk '{print $2}' || true)"
rebuild=0
[[ $have == "$want" ]] || rebuild=1
if [[ -n $have ]] && ldd "$libdir/libfprint-2.so.2" 2>/dev/null | grep -q 'not found'; then
  warn "$libdir/libfprint-2.so.2 no longer loads; rebuilding"
  rebuild=1
fi
if (( rebuild )); then
  build="$(mktemp -d -p "$RUN_DIR" fpbuild.XXXXXX)"
  cp "$pkgsrc"/PKGBUILD "$pkgsrc"/*.patch "$build"/
  log "building $pkgname $want (pinned commit, checksums verified)"
  if [[ $DRY_RUN == 1 ]]; then
    printf '   [dry-run] makepkg in %s\n' "$build"
  else
    # --syncdeps installs the PKGBUILD's dependencies (opencv, libgusb, ...)
    # through sudo; output location and format are pinned over any user
    # makepkg.conf.
    (cd "$build" && PKGDEST="$build" PKGEXT=.pkg.tar.zst \
      makepkg --syncdeps --cleanbuild --force --noconfirm) || die "makepkg failed in $build"
    as_root pacman -U --noconfirm "$build/$pkgname-$want-x86_64.pkg.tar.zst"
  fi
  mark_changed "built and installed $pkgname $want"
fi

reload_udev=0 reload_unit=0
install_file "$FILES_DIR$modconf" "$modconf" && reload_udev=1
install_file "$FILES_DIR$rules" "$rules" && reload_udev=1
install_file "$FILES_DIR$dropin" "$dropin" && reload_unit=1
install_file "$FILES_DIR$pamfile" "$pamfile" || true

if (( reload_udev )); then
  as_root udevadm control --reload
  as_root udevadm trigger --action=add --subsystem-match=spi --subsystem-match=gpio
  as_root udevadm settle
fi
if (( reload_unit || rebuild )); then
  as_root systemctl daemon-reload
  as_root systemctl try-restart fprintd.service
fi

# Matching depends on OpenCV's SIFT and RANSAC; flag upgrades so the matcher
# is re-checked (and prints re-enrolled if it got worse).
opencv="$(pacman -Q opencv 2>/dev/null | awk '{print $2}' || true)"
recorded="$(sed -n 's/^opencv=//p' "$marker" 2>/dev/null || true)"
if [[ -n $recorded && $recorded != "$opencv" ]]; then
  warn "opencv changed from $recorded to $opencv since fingerprints were set up: re-run the matcher check and re-enrol if unlocks got worse"
fi
printf 'opencv=%s\n' "$opencv" | write_file "$marker" || true

# --- checks ---
[[ $DRY_RUN == 1 ]] && exit 0
if [[ "$(basename "$(readlink -f "$spi/driver" 2>/dev/null)")" == spidev ]]; then
  ok "sensor bound to spidev"
else
  warn "sensor not bound to spidev (reboot, then rerun)"
fi
bufsiz="$(cat /sys/module/spidev/parameters/bufsiz 2>/dev/null || echo 0)"
if (( bufsiz >= 16384 )); then
  ok "spidev buffer $bufsiz bytes"
else
  need_reboot "spidev was loaded with a ${bufsiz}-byte buffer before $modconf existed"
fi
if [[ -e /dev/oxp3-fingerprint-gpiochip ]]; then
  ok "reset GPIO controller at /dev/oxp3-fingerprint-gpiochip"
else
  warn "/dev/oxp3-fingerprint-gpiochip is missing; fprintd cannot release the sensor from reset"
fi
# Only our drop-in's two thresholds may be set (a dump dir, looser
# thresholds or debug output would come from someone else's drop-in).
fprintd_env="$(systemctl show fprintd.service -p Environment --value | tr ' ' '\n' |
  grep -vxF -e LIBFPRINT_BF63112_SIGFM_THRESHOLD=1000000000 -e LIBFPRINT_BF63112_RANSAC_THRESHOLD=16 || true)"
if grep -qE 'LIBFPRINT_BF63112_|G_MESSAGES_DEBUG' <<<"$fprintd_env"; then
  warn "fprintd has LIBFPRINT_BF63112_* or debug variables set by another drop-in: $(systemctl show fprintd.service -p DropInPaths --value)"
fi
if [[ "$(sha256sum /usr/lib/pam.d/kde-fingerprint | cut -d' ' -f1)" != "$pam_base_sha" ]]; then
  warn "kscreenlocker changed /usr/lib/pam.d/kde-fingerprint; review $pamfile against it"
fi
# As root: polkit only lets the user's own active local session list prints,
# so a run over SSH would otherwise report a false "no sensor".
list="$(sudo fprintd-list "$user" 2>&1 || true)"
if ! grep -q 'BF63112' <<<"$list"; then
  warn "fprintd does not see the sensor: journalctl -u fprintd -b"
elif grep -q 'no fingers enrolled' <<<"$list"; then
  log "enrol one finger in Desktop Mode: fprintd-enroll -f right-index-finger"
else
  ok "fingerprint enrolled; the Plasma lock screen accepts it"
fi
