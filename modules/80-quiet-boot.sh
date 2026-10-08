#!/usr/bin/env bash
# Console-like boot: no boot menu, no text, just the firmware logo and the
# Plymouth splash into Game Mode.
#
# - The installer can write an X11 layout name such as "au" as the console
#   KEYMAP; no such console keymap exists, so loadkeys fails in the initrd and
#   systemd prints a red "Failed to start Virtual Console Setup" every boot.
# - "quiet" still prints kernel errors, and this firmware logs several ACPI
#   "BIOS Error" lines at boot; loglevel=3 keeps only critical messages.
# - vt.global_cursor_default=0 hides the blinking text cursor.
# - systemd-boot's menu is hidden (hold a key during power-on to show it).
# Kernel options go through sdboot-manage while it owns Type #1 boot entries;
# once 12-uki-boot has moved to UKIs they live in /etc/kernel/cmdline.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

# 1. A console keymap that exists.
keymap="$(sed -n 's/^KEYMAP=//p' /etc/vconsole.conf 2>/dev/null | tr -d '"')"
if [[ -n $keymap ]] && ! localectl list-keymaps 2>/dev/null | grep -qx -- "$keymap"; then
  log "console keymap '$keymap' does not exist; using 'us'"
  sed "s/^KEYMAP=.*/KEYMAP=us/" /etc/vconsole.conf | write_file /etc/vconsole.conf || true
else
  ok "console keymap '${keymap:-default}' is valid"
fi

# 2. Kernel options via sdboot-manage (sourced after /etc/sdboot-manage.conf).
opts=("${QUIET_KERNEL_OPTIONS[@]}")
write_file /etc/sdboot-manage.conf.d/50-oxp3-quiet-boot.conf <<EOF || true
# Managed by CachyOS-OneXPlayer3 (modules/80-quiet-boot.sh).
LINUX_OPTIONS+=" ${opts[*]}"
EOF
# Regenerate whenever an entry lacks the options (also repairs a run that was
# interrupted before sdboot-manage ran), then check the result.
entries_ok() {
  local entry o n=0
  while IFS= read -r entry; do
    n=$((n + 1))
    for o in "${opts[@]}"; do
      sudo grep -q "^options .*\b$o\b" "$entry" || return 1
    done
  done < <(sudo find /boot/loader/entries -name '*.conf')
  (( n > 0 ))
}
if uki_mode; then
  ok "kernel options are in the UKI command line (12-uki-boot)"
elif [[ $DRY_RUN != 1 ]] && ! entries_ok; then
  log "regenerating boot entries"
  as_root sdboot-manage gen
  mark_changed "regenerated boot entries with quiet options"
  entries_ok || die "boot entries still lack ${opts[*]} after sdboot-manage gen"
fi
grep -qw loglevel=3 /proc/cmdline || need_reboot "quiet kernel options apply at next boot"

# 3. No boot menu; holding a key while powering on still shows it.
loader=/boot/loader/loader.conf
if ! sudo grep -qx 'timeout menu-hidden' "$loader"; then
  # vfat: modes come from the mount options, so edit content in place.
  log "hiding the boot menu"
  # shellcheck disable=SC2016 # sed's $a (append after last line)
  as_root sed -i -e '/^timeout /d' -e '$a timeout menu-hidden' "$loader"
  mark_changed "boot menu hidden"
fi
# A menu timeout chosen in the menu itself is stored in an EFI variable and
# overrides loader.conf; drop it so the hidden menu sticks.
timeout_var=/sys/firmware/efi/efivars/LoaderConfigTimeout-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
if [[ -e $timeout_var ]]; then
  as_root bootctl set-timeout ''
  mark_changed "cleared the boot menu timeout EFI variable"
fi
# A default entry stored in EFI that no longer exists only confuses the menu.
default="$(sudo bootctl status 2>/dev/null | sed -n 's/^ *Default Entry: //p' || true)"
if [[ -n $default && $default != *'@'* ]] && ! sudo bootctl list 2>/dev/null | grep -q "id: $default\$"; then
  log "clearing stale default boot entry '$default'"
  as_root bootctl set-default ''
  mark_changed "cleared stale default boot entry $default"
fi

# 4. The initramfs carries vconsole.conf (sd-vconsole hook); compare the
#    images' copies rather than this run's changes, so an interrupted run
#    recovers.
if [[ $DRY_RUN != 1 ]] && ! initramfs_matches /etc/vconsole.conf; then
  rebuild_initramfs "console keymap fix applies at next boot"
fi

theme="$(plymouth-set-default-theme 2>/dev/null || true)"
ok "Plymouth theme: ${theme:-unknown}"
