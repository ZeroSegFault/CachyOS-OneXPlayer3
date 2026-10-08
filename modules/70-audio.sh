#!/usr/bin/env bash
# Unmute the internal speakers once.
#
# The speakers hang directly off the Realtek ALC245 (snd_hda_codec_alc269)
# and need no driver work, but a fresh install comes up with the "Speaker"
# sink muted at 0 %, and WirePlumber restores that state on every boot.
# This applies a sane default the first time only; later runs leave the
# user's own volume and mute choices alone.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/oxp3-postinstall"
marker="$state_dir/audio-defaults-applied"
if [[ -e $marker ]]; then
  ok "speaker defaults already applied once; leaving user volume alone"
  exit 0
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if ! wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1; then
  warn "no PipeWire session reachable; rerun from the handheld's session to set speaker defaults"
  exit 0
fi

sink="$(wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n 's/.*node.description = "\(.*\)"/\1/p')"
log "unmuting default sink ($sink) at 40 %"
if [[ $DRY_RUN != 1 ]]; then
  wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
  wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.4
  mkdir -p "$state_dir"
  touch "$marker"
fi
mark_changed "unmuted speakers at 40 %"
