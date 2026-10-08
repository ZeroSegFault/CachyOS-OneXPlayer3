#!/usr/bin/env bash
# Built-in controller as a Steam Deck controller (InputPlumber, deck-uhid).
#
# Without this Steam sees the raw xpad "Microsoft X-Box 360 pad" and none of
# the extra buttons. InputPlumber hides the raw devices and merges the xpad
# pad, the MCU keyboard chords, the MCU vendor frames (paddles, Home) and the
# BMI260 gyro into one virtual Steam Deck controller:
#   M1/M2 -> L4/R4, Home -> Steam button, ONEX -> "..." (Quick Access Menu),
#   Keyboard key -> on-screen keyboard, gyro and rumble.
# Decision and evidence: docs/research/2026-10-07-input-power-architecture.md.
#
# hid-oxp is only read, never written: never unbind or rebind it (kernel Oops).
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

refuse_conflicting_daemons

if ! grep -qx bmi260 /sys/bus/iio/devices/iio:device*/name 2>/dev/null; then
  warn "no bmi260 IIO device: gyro will be missing until 20-gyro has run and the device rebooted"
fi

pkg_install inputplumber

changed=1
install_tree etc/inputplumber && changed=0

if [[ -e /usr/share/inputplumber/devices/50-onexplayer_3.yaml ]]; then
  warn "InputPlumber now ships its own OXP3 profile; ours in /etc still takes precedence (compare them)"
fi

enable_unit inputplumber.service
# A sleep.target hook: starting it now would run HookSleep on the live pad.
enable_unit_only inputplumber-suspend.service
if (( changed == 0 )) && systemctl is-active --quiet inputplumber.service; then
  log "restarting InputPlumber to load the OXP3 profile"
  as_root systemctl restart inputplumber.service
  need_reboot "restart Game Mode (or reboot) so Steam picks up the Steam Deck controller"
fi

# Back paddles need hid-oxp's OXP3 three-page button map (pending upstream,
# tracked in issue #4). Report once the running kernel's hid-oxp knows the OXP3.
hidoxp="$(modinfo -n hid_oxp 2>/dev/null || true)"
if module_has_string "$hidoxp" 'ONEXPLAYER 3'; then
  ok "kernel hid-oxp has OneXPlayer 3 support: test the back paddles and follow issue #4"
else
  warn "back paddles M1/M2 stay silent until the kernel's hid-oxp gains OXP3 support (issue #4)"
fi

# Report what InputPlumber built (informational).
sleep 2
if busctl --system tree org.shadowblip.InputPlumber 2>/dev/null | grep -q CompositeDevice; then
  ok "InputPlumber composite device present"
else
  warn "InputPlumber has no composite device yet; check: journalctl -b -u inputplumber"
fi
