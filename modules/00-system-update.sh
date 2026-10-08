#!/usr/bin/env bash
# Bring the whole system up to date before anything else is installed.
#
# Later modules install packages with pacman -S. On Arch-based systems that is
# only safe against a fresh sync database plus a full upgrade (a partial
# upgrade can pull libraries newer than the installed packages expect), and a
# fresh install used days later otherwise asks mirrors for files they have
# already dropped. Skip with --skip 00-system-update.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

before="$(pacman -Q 2>/dev/null | sha256sum)"
log "updating the system (pacman -Syu)"
as_root pacman -Syu --noconfirm
if [[ $DRY_RUN != 1 && "$(pacman -Q | sha256sum)" != "$before" ]]; then
  mark_changed "system packages updated"
fi

# A kernel update only takes effect after a reboot; DKMS modules are built
# for every installed kernel by modules/35-oxpec.sh.
running="$(uname -r)"
if [[ ! -d /usr/lib/modules/$running/kernel ]]; then
  need_reboot "the kernel was updated (running $running)"
fi
