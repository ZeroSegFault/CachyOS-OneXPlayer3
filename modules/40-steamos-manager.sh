#!/usr/bin/env bash
# Steam's own TDP and GPU clock sliders (Quick Access Menu → Performance).
#
# steamos-manager is the system API Steam uses for these sliders. It has no
# Intel RAPL backend, so this installs a small local package, oxp3-support:
#   - the steamos-manager device profile for the OneXPlayer 3 (Intel GPU
#     clock backend, remote TDP, InputPlumber targets), which steamos-manager
#     only reads from /usr/share/steamos-manager/devices;
#   - oxp3-tdp, a system-bus TdpLimit1 remote that writes both RAPL package
#     zones (MSR and MMIO; the lower PL1 wins on this firmware).
# Decision and evidence: docs/research/2026-10-07-input-power-architecture.md.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3
refuse_conflicting_daemons

pkg_install steamos-manager python-gobject fakeroot

# The TDP value used to persist across boots; it is now per-boot (/run).
remove_file /var/lib/oxp3-tdp/limit || true

# 1. oxp3-support: rebuilt only when its sources differ from the installed build.
src="$REPO_ROOT/files/pkg/oxp3-support"
sources=(onexplayer-3.toml oxp3-tdp oxp3-tdp.service local.oxp3.Tdp.service PKGBUILD)
want="$(cd "$src" && cat "${sources[@]}" | sha256sum | cut -d' ' -f1)"
have="$(cat /usr/share/oxp3-support/source.sha256 2>/dev/null || true)"
pkg_changed=0
if [[ $want != "$have" && $DRY_RUN == 1 ]]; then
  log "[dry-run] would build and install oxp3-support"
  pkg_changed=1
elif [[ $want != "$have" ]]; then
  log "building oxp3-support"
  build="$(mktemp -d -p "$RUN_DIR")"
  (cd "$src" && cp "${sources[@]}" "$build"/)
  printf '%s\n' "$want" > "$build/source.sha256"
  # Pin output location and format over any user makepkg.conf.
  (cd "$build" && PKGDEST="$build" PKGEXT=.pkg.tar.zst makepkg -f --cleanbuild --noconfirm >/dev/null) ||
    die "makepkg failed for oxp3-support"
  as_root pacman -U --noconfirm "$build"/oxp3-support-*.pkg.tar.zst
  mark_changed "installed oxp3-support ($want)"
  pkg_changed=1
else
  ok "oxp3-support current"
fi

# 2. /etc configuration.
user="$(target_user)"
policy_changed=1
write_file /etc/dbus-1/system.d/local.oxp3.Tdp.conf <<EOF && policy_changed=0
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<!-- Managed by CachyOS-OneXPlayer3 (modules/40-steamos-manager.sh). -->
<busconfig>
  <policy context="default">
    <deny send_destination="local.oxp3.Tdp"/>
  </policy>
  <policy user="root">
    <allow own="local.oxp3.Tdp"/>
    <allow send_destination="local.oxp3.Tdp"/>
  </policy>
  <!-- steamos-manager's user daemon relays Steam's TDP slider from this user. -->
  <policy user="$user">
    <allow send_destination="local.oxp3.Tdp"/>
  </policy>
</busconfig>
EOF
# dbus-broker does not watch policy files; ask it to re-read them.
(( policy_changed == 0 )) && as_root busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig

remote_changed=1
write_file /etc/steamos-manager/remotes.d/oxp3-tdp.toml <<'EOF' && remote_changed=0
# Managed by CachyOS-OneXPlayer3: Steam's TDP slider → oxp3-tdp (both RAPL zones).
[TdpLimit1]
bus_name = "local.oxp3.Tdp"
object_path = "/local/oxp3/Tdp"
EOF

# Range of the slider. Left alone once it exists so local edits survive.
# max is what Steam applies while its TDP toggle is off; set max=25 to keep the
# firmware's 25 W sustained default. Above 35 W needs a 100 W+ USB-PD charger
# or the firmware resets the limits; values above the 52 W PL2 gain nothing.
if [[ ! -e /etc/oxp3/tdp.conf ]]; then
  write_file /etc/oxp3/tdp.conf <<'EOF'
# TDP slider range in watts for oxp3-tdp. OneXPlayer rates the OXP3 at 8-35 W.
# max is also what applies while Steam's TDP toggle is off (the firmware's own
# sustained limit is 25 W via the MSR zone; set max=25 to keep it).
min=8
max=35
EOF
fi

# 3. Services.
enable_unit steamos-manager.service oxp3-tdp.service
if (( pkg_changed )) && systemctl is-active --quiet oxp3-tdp.service; then
  as_root systemctl restart oxp3-tdp.service
fi
if (( pkg_changed || remote_changed == 0 )); then
  # steamos-manager reads the device profile and remotes.d at startup only;
  # restarting it under a running Game Mode is not safe.
  need_reboot "steamos-manager loads the OXP3 profile and TDP remote at next login"
fi

if busctl --system introspect local.oxp3.Tdp /local/oxp3/Tdp 2>/dev/null | grep -q TdpLimit; then
  ok "oxp3-tdp answering on the system bus (TdpLimit $(busctl --system get-property local.oxp3.Tdp /local/oxp3/Tdp com.steampowered.SteamOSManager1.TdpLimit1 TdpLimit | cut -d' ' -f2) W)"
else
  warn "oxp3-tdp not answering on the system bus; check: journalctl -b -u oxp3-tdp"
fi
