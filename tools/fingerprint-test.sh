#!/usr/bin/env bash
# Measure the BF63112 fingerprint matcher on this device before relying on it
# (issue #5). Captures touches from the finger to enrol and one other (the
# stand-in for someone else's finger), then replays
# them through the driver's matcher: each capture against a template of the
# same finger (should be accepted) and of every other finger (must never be).
#
#   tools/fingerprint-test.sh            capture (resumes where it stopped), then report
#   tools/fingerprint-test.sh --report   only replay what was captured
#   tools/fingerprint-test.sh --clean    delete the captured images
#
# Images stay in $XDG_RUNTIME_DIR (RAM, gone at logout). fprintd is stopped
# while capturing and started again afterwards.
set -euo pipefail

bin=/usr/lib/libfprint-bf63112/bin
chip=0x6683
read -ra fingers <<<"${OXP3_FINGERS:-right-index right-middle}"
touches=${OXP3_TOUCHES:-12}
out="${XDG_RUNTIME_DIR:-/tmp}/oxp3-fingerprint-test"

case ${1:-} in
  --clean) rm -rf -- "$out"; echo "deleted $out"; exit 0 ;;
  --report|'') ;;
  *) echo "usage: $0 [--report|--clean]" >&2; exit 2 ;;
esac
[[ -x $bin/img-capture ]] || { echo "the fingerprint package is not installed (OXP3_FINGERPRINT=1 ./install.sh --only 85-fingerprint)" >&2; exit 1; }

if [[ ${1:-} != --report ]]; then
  sudo -v
  while kill -0 $$ 2>/dev/null && sleep 60; do sudo -n -v 2>/dev/null || exit; done &
  # fprintd is D-Bus activated (the lock screen would start it again and
  # take the sensor), so hold it off for this boot until we are done.
  sudo systemctl mask --runtime --now fprintd.service >/dev/null 2>&1
  trap 'sudo systemctl unmask --runtime fprintd.service >/dev/null 2>&1' EXIT

  cat <<EOF
The sensor is the power button. Rest a finger flat on it without pressing,
wait for "ok", lift, and vary the placement a little between touches.
$touches touches each from: ${fingers[*]}

EOF
  for f in "${fingers[@]}"; do
    mkdir -p "$out/$f"
    [[ -s "$out/$f/$(printf '%02d' "$touches").pgm" ]] && continue # finger done
    finger="${f^^}"
    printf '\n=== Use your %s finger only. Press Enter when ready. ===' "${finger//-/ }"
    read -r _
    for ((i = 1; i <= touches; i++)); do
      file="$out/$f/$(printf '%02d' "$i").pgm"
      [[ -s $file ]] && continue
      while :; do
        printf '%s finger %2d/%d  touch... ' "${finger//-/ }" "$i" "$touches"
        # img-capture exits 1 even after saving an image, so judge by the file.
        sudo rm -f -- "$file"
        sudo env G_MESSAGES_DEBUG= "$bin/img-capture" "$file" >/dev/null 2>"$out/last-error.log" || true
        if sudo test -s "$file"; then
          sudo chown "$(id -u):$(id -g)" "$file"
          echo "ok, lift"
          sleep 1.2
          break
        fi
        echo "no image, try again"
        sleep 1
      done
    done
    echo
  done
fi

echo "Replaying through the matcher (takes a minute)..."
"$bin/bf63112-replay" "$chip" "$out" > "$out/replay.txt"
grep -E '^(FALSE-ACCEPT|retry)' "$out/replay.txt" || true
tail -n 2 "$out/replay.txt"
cat <<EOF

Safe to use only if "impostor accepted" is 0. Full log: $out/replay.txt
Delete the images afterwards: $0 --clean
EOF
