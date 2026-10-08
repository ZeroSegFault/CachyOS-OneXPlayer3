#!/usr/bin/env bash
# Quiet Game Mode's optional helpers that cannot run here.
#
# gamescope-session-cachyos starts three user services whose programs no
# dependency provides, so each fails on every Game Mode login:
# - steam-notif-daemon runs SteamOS's /usr/bin/steam_notif_daemon, which no
#   Arch or CachyOS package ships;
# - gamescope-xbindkeys needs xbindkeys and an /etc/xbindkeysrc that no
#   package ships;
# - ibus-gamescope needs ibus (an optional dependency, for typing non-Latin
#   languages).
# A helper is masked for the user while anything its ExecStart names is
# missing, and unmasked again once it is all there (e.g. after installing
# ibus).
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

for u in steam-notif-daemon gamescope-xbindkeys ibus-gamescope; do
  unit=/usr/lib/systemd/user/$u.service
  [[ -e $unit ]] || continue
  usable=1
  read -ra exec <<<"$(sed -n 's/^ExecStart=//p' "$unit" | head -n 1)"
  for word in "${exec[@]}"; do
    [[ $word == /* && ! -e $word ]] && usable=0
  done
  state="$(systemctl --user is-enabled "$u.service" 2>/dev/null || true)"
  if (( usable )) && [[ $state == masked ]]; then
    log "unmasking $u (its programs are installed now)"
    [[ $DRY_RUN == 1 ]] || systemctl --user unmask "$u.service"
    mark_changed "unmasked user unit $u"
  elif (( ! usable )) && [[ $state != masked ]]; then
    log "masking $u (${exec[0]} or its config is not installed)"
    if [[ $DRY_RUN != 1 ]]; then
      systemctl --user mask "$u.service"
      systemctl --user reset-failed "$u.service" 2>/dev/null || true
    fi
    mark_changed "masked user unit $u"
  else
    ok "$u: ${state:-static}"
  fi
done
