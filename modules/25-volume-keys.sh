#!/usr/bin/env bash
# Prevent missing EC key releases from driving volume to minimum/maximum.
# Each press gets an immediate release; holding a key may no longer repeat.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

if install_file "$FILES_DIR/etc/udev/hwdb.d/61-oxp3-volume.hwdb" \
    /etc/udev/hwdb.d/61-oxp3-volume.hwdb; then
  as_root systemd-hwdb update
  # Reload only the AT keyboard, leaving controller devices alone.
  as_root udevadm trigger --action=change --subsystem-match=input --parent-match=/sys/devices/platform/i8042
  as_root udevadm settle
fi

ok "volume-key force-release rule installed"
