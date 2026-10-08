#!/usr/bin/env bash
# Copy this repo to the OneXPlayer 3 over SSH and run install.sh there.
#
#   ./deploy.sh [user@host] [install.sh args...]
#   OXP3_FINGERPRINT=1 ./deploy.sh --only 85-fingerprint   # settings pass through
#
# The host defaults to $OXP3_HOST. The checkout lands in
# ~/.local/share/oxp3-postinstall on the device; a TTY is allocated so sudo
# can prompt when passwordless sudo is not configured yet.
#
# CachyOS Handheld sets logind KillUserProcesses=yes, so if the SSH
# connection drops mid-run the install stops with it. Every module is
# idempotent: run deploy.sh again to finish. For a first install prefer
# running ./install.sh on the device itself (see README).
set -euo pipefail

cd "$(dirname "$0")"

host="${OXP3_HOST:-}"
if (( $# )) && [[ $1 != -* ]]; then
  host=$1
  shift
fi
[[ -n $host ]] || { echo "usage: $0 user@host [install.sh args...] (or set OXP3_HOST)" >&2; exit 2; }
dest='.local/share/oxp3-postinstall'

rsync -a --delete --exclude .git --exclude .scratch --exclude __pycache__ ./ "$host:$dest/"

# Forward OXP3_* settings (e.g. OXP3_FINGERPRINT=1) to the remote run.
envs=""
while IFS='=' read -r name _; do
  [[ $name == OXP3_* && $name != OXP3_HOST ]] && envs+="$name=$(printf '%q' "${!name}") "
done < <(env)

# The device's login shell is fish, so hand the command to bash explicitly.
args=$(printf '%q ' "$@")
ssh -t "$host" "bash -c 'cd ~/$dest && env $envs./install.sh $args'"
