#!/usr/bin/env bash
# Steam Deck power button behaviour in Game Mode.
#
# cachyos-handheld sets logind HandlePowerKey=ignore so Steam can own the
# button, but nothing reads it: CachyOS's hardware detection does not match
# "ONEXPLAYER 3", so steamos-powerbuttond is never installed and the button
# does nothing in Game Mode. powerbuttond forwards a press to Steam
# (steam://shortpowerpress → suspend, as on a Deck); the lid switch goes to
# steam://lidswitch. Its user unit is pulled in by gamescope-session.
#
# Long press cannot work on this hardware: the ACPI power button reports press
# and release back to back (drivers/acpi/button.c), so the power menu is under
# the Steam button → Power.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

if ! pacman -Qq steamos-powerbuttond &>/dev/null; then
  pkg_install steamos-powerbuttond
  # The package's hwdb tags power buttons and lid switches for uaccess.
  as_root systemd-hwdb update
  as_root udevadm trigger -s input --action=change
  need_reboot "power button handling starts with the next Game Mode session"
fi

# logind must keep ignoring the key, or one press would suspend twice.
if systemd-analyze cat-config systemd/logind.conf 2>/dev/null | grep -qx 'HandlePowerKey=ignore'; then
  ok "logind leaves the power key to Steam"
else
  warn "logind handles the power key itself; Steam and logind would both act on a press"
fi

if [[ -e /usr/lib/systemd/user/gamescope-session.service.wants/steamos-powerbuttond.service ]]; then
  ok "steamos-powerbuttond starts with Game Mode"
else
  warn "steamos-powerbuttond is not wanted by gamescope-session.service"
fi
