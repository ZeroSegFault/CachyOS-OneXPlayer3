#!/usr/bin/env bash
# Decky Loader: the Steam Deck plugin loader for Game Mode's Quick Access Menu.
#
# Mirrors upstream's install_release.sh (decky-installer) with a pinned
# release and checksum instead of "latest". It only installs when Decky is
# absent: Decky updates itself from its own settings page, so an existing
# install is never downgraded to the pinned version.
#
# Decky derives its user from UNPRIVILEGED_PATH in its unit
# (backend/decky_loader/localplatform/localplatformlinux.py), so the
# DECK_USER_HOME spelling in cachyos-handheld's environment.d file does not
# affect it.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

version=v3.2.10
sha256=c2cf316a53e1c1d318c6dda8821c827e5db275922987f9097956d7a1576e8258
url="https://github.com/SteamDeckHomebrew/decky-loader/releases/download/$version/PluginLoader"

user="$(target_user)"
home="$(getent passwd "$user" | cut -d: -f6)"
brew="$home/homebrew"

# User-owned writes below honour --dry-run as well (as_root already does).
user_do() { if [[ $DRY_RUN == 1 ]]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi; }

# Steam only lets Decky inject into its UI with CEF remote debugging enabled.
user_do mkdir -p "$brew/services" "$brew/plugins" "$home/.steam/steam"
if [[ ! -e $home/.steam/steam/.cef-enable-remote-debugging ]]; then
  user_do touch "$home/.steam/steam/.cef-enable-remote-debugging"
  mark_changed "enabled Steam CEF remote debugging for Decky"
fi

if [[ -x $brew/services/PluginLoader ]]; then
  ok "Decky present ($(cat "$brew/services/.loader.version" 2>/dev/null || echo unknown version))"
else
  log "installing Decky Loader $version"
  tmp="$(mktemp -p "$RUN_DIR")"
  curl -fsSL --retry 3 -o "$tmp" "$url"
  echo "$sha256  $tmp" | sha256sum -c --quiet - || die "Decky $version checksum mismatch"
  as_root install -m 0755 "$tmp" "$brew/services/PluginLoader"
  [[ $DRY_RUN == 1 ]] || printf '%s\n' "$version" > "$brew/services/.loader.version"
  mark_changed "installed Decky Loader $version"
fi

# Upstream's dist/plugin_loader-release.service with HOMEBREW_FOLDER filled in.
# Decky's updater restores the unit from services/.systemd/, so keep a copy.
unit="$(cat <<EOF
[Unit]
Description=SteamDeck Plugin Loader
After=network.target
[Service]
Type=simple
User=root
Restart=always
KillMode=process
TimeoutStopSec=15
ExecStart=$brew/services/PluginLoader
WorkingDirectory=$brew/services
Environment=UNPRIVILEGED_PATH=$brew
Environment=PRIVILEGED_PATH=$brew
Environment=LOG_LEVEL=INFO
[Install]
WantedBy=multi-user.target
EOF
)"
user_do mkdir -p "$brew/services/.systemd"
if [[ $DRY_RUN != 1 && "$(cat "$brew/services/.systemd/plugin_loader-release.service" 2>/dev/null)" != "$unit" ]]; then
  printf '%s\n' "$unit" > "$brew/services/.systemd/plugin_loader-release.service"
fi
if printf '%s\n' "$unit" | write_file /etc/systemd/system/plugin_loader.service; then
  as_root systemctl daemon-reload
  as_root systemctl restart plugin_loader.service
fi
enable_unit plugin_loader.service

if systemctl is-active --quiet plugin_loader.service; then
  ok "Decky running"
else
  warn "plugin_loader.service is not active"
fi
