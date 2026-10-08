#!/usr/bin/env bash
# gamescope new enough to know this panel.
#
# The OneXPlayer 3 uses the same Samsung OLED as the Legion Go 2, and
# gamescope gained a display profile for it in 3.16.29 (refresh-rate slider,
# HDR with software backlight). CachyOS's cachyos-v3 repo, which pacman.conf
# lists first, still serves 3.16.25 while [cachyos] carries 3.16.30, so
# install both halves explicitly from whichever repo is newest. Because
# cachyos-v3 is listed first, pacman -Syu keeps a newer local copy but never
# moves it forward again, so every run re-checks both repos (00-system-update
# has refreshed the sync databases) and reinstalls if a library update left
# the binary unable to load.
# See docs/research/2026-10-07-panther-lake-gaming-stack.md (Q4, repo table).
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

min=3.16.29
installed="$(pacman -Q gamescope 2>/dev/null | awk '{print $2}' || true)"

# Newest gamescope among the CachyOS repos that also carry lib32-gamescope.
best_repo="" best_ver=""
for repo in cachyos-v3 cachyos; do
  list="$(pacman -Sl "$repo" 2>/dev/null || true)"
  ver="$(awk '$2 == "gamescope" {print $3}' <<<"$list")"
  grep -q '^[^ ]* lib32-gamescope ' <<<"$list" || continue
  [[ -n $ver ]] || continue
  if [[ -z $best_ver ]] || (( $(vercmp "$ver" "$best_ver") > 0 )); then
    best_repo=$repo best_ver=$ver
  fi
done
[[ -n $best_ver ]] || die "no CachyOS repo offers gamescope and lib32-gamescope"
(( $(vercmp "${best_ver%-*}" "$min") >= 0 )) || die "newest gamescope in the repos is $best_ver (< $min)"

broken=0
missing_libs="$(ldd /usr/bin/gamescope 2>/dev/null | grep -c 'not found' || true)"
if [[ -n $installed ]] && (( ${missing_libs:-0} > 0 )); then
  warn "installed gamescope cannot load its libraries; reinstalling"
  broken=1
fi

if [[ -n $installed ]] && (( broken == 0 )) && (( $(vercmp "$installed" "$best_ver") >= 0 )); then
  ok "gamescope $installed (newest available: $best_repo $best_ver)"
  exit 0
fi

log "installing gamescope $best_ver from [$best_repo] (was ${installed:-absent})"
as_root pacman -S --noconfirm "$best_repo/gamescope" "$best_repo/lib32-gamescope"
mark_changed "gamescope ${installed:-absent} -> $best_ver ($best_repo)"
need_reboot "Game Mode picks up the new gamescope after the session restarts"
