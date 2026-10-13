#!/usr/bin/env bash
# On-device regression test through the same session-bus API Steam uses.
# Temporarily sets 80%, then disables the limit. Restores the previous positive
# target on exit (uses 100% if the old target was the broken zero value).
# Run in the handheld user's session: bash tools/charge-limit-test.sh
set -euo pipefail

threshold=/sys/class/power_supply/BAT0/charge_control_end_threshold
original=$(cat "$threshold")
(( original > 0 && original <= 100 )) || original=100
set_limit() {
  busctl --user set-property -- com.steampowered.SteamOSManager1 \
    /com/steampowered/SteamOSManager1 \
    com.steampowered.SteamOSManager1.BatteryChargeLimit1 MaxChargeLevel i "$1"
}
trap 'set_limit "$original"' EXIT

expect_target() {
  local request=$1 expected=$2 actual
  set_limit "$request"
  for ((i = 0; i < 25; i++)); do
    actual=$(cat "$threshold")
    if [[ $actual == "$expected" ]]; then
      printf 'PASS: request %s -> hardware target %s%%\n' "$request" "$actual"
      return
    fi
    sleep 0.2
  done
  printf 'FAIL: request %s -> hardware target %s%%, expected %s%%\n' "$request" "$actual" "$expected" >&2
  return 1
}

expect_target 80 80
expect_target -1 100
