#!/usr/bin/env bash
# Run the OneXPlayer 3 postinstall modules on this machine.
#
#   ./install.sh                             run every module in order
#   ./install.sh --list                      list modules
#   ./install.sh --only 40-steamos-manager   run only the named module(s) (repeatable)
#   ./install.sh --skip 00-system-update     skip the named module(s) (repeatable)
#   ./install.sh --dry-run                   show privileged commands instead of running them
#
# Every module is idempotent, so rerunning the whole set is safe and is the
# expected way to restore the device after a fresh CachyOS Handheld install.
set -euo pipefail

cd "$(dirname "$0")"
MODULE_NAME=install
# This run owns its scratch directory (modules inherit it); never adopt one
# from the environment, since cleanup removes it as root.
RUN_DIR="$(mktemp -d -t oxp3-postinstall.XXXXXX)"
export RUN_DIR
own_run_dir=$RUN_DIR
# shellcheck source=lib/common.sh
source lib/common.sh

inhibitor=oxp3-install-inhibit
inhibited=0
# The password typed at the start, kept for 15-tpm-unlock: the README has the
# disk passphrase set to the login password. Root-only, in RAM, this run only.
secret_dir=/run/oxp3-install
export OXP3_PASSWORD_FILE=$secret_dir/password
cleanup() {
  set +e # best effort; never abort or prompt on the way out
  sudo -n rm -rf -- "$secret_dir" 2>/dev/null
  (( inhibited )) && sudo -n systemctl stop "$inhibitor" >/dev/null 2>&1
  [[ -n ${keepalive:-} ]] && kill "$keepalive" 2>/dev/null
  sudo -n rm -rf -- "$own_run_dir" 2>/dev/null || rm -rf -- "$own_run_dir" 2>/dev/null
  return 0
}
trap cleanup EXIT

modules=()
for m in modules/*.sh; do modules+=("$(basename "${m%.sh}")"); done
known() {
  local m
  for m in "${modules[@]}"; do [[ $m == "$1" ]] && return 0; done
  die "no module named '$1' (see --list)"
}

only=() skip=()
while (( $# )); do
  case $1 in
    --list)    printf '%s\n' "${modules[@]}"; exit 0 ;;
    --only)    known "${2:?--only needs a module name}"; only+=("$2"); shift ;;
    --skip)    known "${2:?--skip needs a module name}"; skip+=("$2"); shift ;;
    --dry-run) export DRY_RUN=1 ;;
    -h|--help) sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
  shift
done

(( EUID != 0 )) || die "run as the handheld's login user, not root (sudo is used where needed)"
require_onexplayer3

# One run at a time: modules rebuild the initramfs and write the LUKS header.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/oxp3-install.lock"
flock -n 9 || die "another install.sh run is in progress"

if [[ $DRY_RUN != 1 ]]; then
  # Ask for the password once, then keep the sudo ticket fresh through long
  # package builds so no module stalls on a prompt.
  sudo -n rm -rf -- "$secret_dir" 2>/dev/null || true
  if [[ ! -t 0 ]]; then
    sudo -v # no terminal to ask on (sudo must not need a password)
  else
    sudo -k # always ask, so the password is at hand for the disk too
    pw='' valid=0
    for try in 1 2 3; do
      IFS= read -rsp "Password for $(id -un): " pw; echo
      if printf '%s\n' "$pw" | sudo -S -p '' -v 2>/dev/null; then valid=1; break; fi
      warn "wrong password (try $try of 3)"
    done
    (( valid )) || { unset pw; die "no valid password given"; }
    sudo install -d -m 0700 "$secret_dir"
    printf '%s' "$pw" | sudo install -m 0600 /dev/stdin "$OXP3_PASSWORD_FILE"
    unset pw
  fi
  # Stops on its own once install.sh is gone; never holds the run lock.
  while kill -0 $$ 2>/dev/null && sleep 60; do sudo -n -v 2>/dev/null || exit; done 9>&- &
  keepalive=$!
  # No sleep, idle suspend or lid suspend while modules run: until the NVMe
  # fix is active after a reboot, a resume loses the SSD (10-nvme-suspend).
  # The inhibitor follows this process (tail --pid), so even a killed run
  # cannot leave sleep blocked; a leftover from a crashed run is cleared first.
  sudo systemctl stop "$inhibitor" >/dev/null 2>&1 || true
  sudo systemctl reset-failed "$inhibitor" >/dev/null 2>&1 || true
  sudo systemd-run --quiet --collect --unit="$inhibitor" \
    systemd-inhibit --what=sleep:idle:handle-lid-switch --who=oxp3-postinstall \
    --why="OneXPlayer 3 setup is running" --mode=block tail --pid=$$ -f /dev/null
  inhibited=1
fi

selected() {
  local name=$1 m
  if (( ${#only[@]} )); then
    for m in "${only[@]}"; do [[ $m == "$name" ]] && return 0; done
    return 1
  fi
  for m in "${skip[@]}"; do [[ $m == "$name" ]] && return 1; done
  return 0
}

run=()
for name in "${modules[@]}"; do selected "$name" && run+=("$name"); done
# Modules may adapt to what else runs (15-tpm-unlock waits for 13-secure-boot).
export OXP3_SELECTED="${run[*]}"

failed=()
for name in "${run[@]}"; do
  printf '\n%s── %s ──%s\n' "$_c_blue" "$name" "$_c_off"
  MODULE_NAME=$name bash "modules/$name.sh" 9>&- || failed+=("$name")
done

printf '\n%s── summary ──%s\n' "$_c_blue" "$_c_off"
if [[ -s $RUN_DIR/changed ]]; then
  sed 's/^/  changed: /' "$RUN_DIR/changed"
else
  echo "  nothing changed; system already matches"
fi
if [[ -s $RUN_DIR/reboot ]]; then
  echo "  ${_c_yellow}reboot required:${_c_off}"
  sort -u "$RUN_DIR/reboot" | sed 's/^/    /'
fi
if [[ -s $RUN_DIR/action ]]; then
  echo "  ${_c_yellow}your turn:${_c_off}"
  sed 's/^/    /' "$RUN_DIR/action"
fi
if (( ${#failed[@]} )); then
  echo "  ${_c_red}failed modules:${_c_off} ${failed[*]}"
  exit 1
fi
