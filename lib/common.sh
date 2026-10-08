# shellcheck shell=bash
# Shared helpers for OneXPlayer 3 postinstall modules.
#
# Every helper is idempotent: it inspects the current state first and only
# changes the system when it differs from the desired state. Helpers that
# change something call `mark_changed` so the summary can report it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES_DIR="$REPO_ROOT/files"

# install.sh exports RUN_DIR so modules running as separate processes share
# one change/reboot ledger; a module run on its own gets a private one.
: "${RUN_DIR:=$(mktemp -d -t oxp3-postinstall.XXXXXX)}"
export RUN_DIR

: "${DRY_RUN:=0}"
MODULE_NAME="${MODULE_NAME:-$(basename "${0%.sh}")}"

if [[ -t 1 ]]; then
  _c_blue=$'\e[1;34m' _c_green=$'\e[1;32m' _c_yellow=$'\e[1;33m' _c_red=$'\e[1;31m' _c_off=$'\e[0m'
else
  _c_blue='' _c_green='' _c_yellow='' _c_red='' _c_off=''
fi

log()  { printf '%s==>%s [%s] %s\n' "$_c_blue" "$_c_off" "$MODULE_NAME" "$*"; }
ok()   { printf '%s ok%s [%s] %s\n' "$_c_green" "$_c_off" "$MODULE_NAME" "$*"; }
warn() { printf '%swarn%s [%s] %s\n' "$_c_yellow" "$_c_off" "$MODULE_NAME" "$*" >&2; }
die()  { printf '%sfail%s [%s] %s\n' "$_c_red" "$_c_off" "$MODULE_NAME" "$*" >&2; exit 1; }

mark_changed() { printf '%s: %s\n' "$MODULE_NAME" "$*" >> "$RUN_DIR/changed"; }
need_reboot()  { printf '%s: %s\n' "$MODULE_NAME" "$*" >> "$RUN_DIR/reboot"; }
# need_action TEXT — a step only the person at the device can do (BIOS setup).
need_action()  { printf '%s: %s\n' "$MODULE_NAME" "$*" >> "$RUN_DIR/action"; }

# Kernel options for a quiet boot, shared by the Type #1 entries
# (80-quiet-boot) and the UKI command line (12-uki-boot).
# shellcheck disable=SC2034 # used by the modules that source this file
QUIET_KERNEL_OPTIONS=(loglevel=3 vt.global_cursor_default=0)

# Run a command as root, via sudo when not already root.
as_root() {
  if [[ $DRY_RUN == 1 ]]; then
    printf '   [dry-run] %s\n' "$*"
    return 0
  fi
  if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

# The login user that owns the handheld session (not root under sudo).
target_user() { printf '%s\n' "${SUDO_USER:-${USER:-$(id -un)}}"; }

is_onexplayer3() {
  [[ "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" == "ONEXPLAYER 3" ]]
}

require_onexplayer3() {
  is_onexplayer3 || [[ ${FORCE:-0} == 1 ]] ||
    die "DMI product_name is not 'ONEXPLAYER 3' (set FORCE=1 to override)"
}

# pkg_install PKG... — install official-repo packages that are missing.
pkg_install() {
  local missing=() p
  for p in "$@"; do
    pacman -Qq "$p" &>/dev/null || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "packages present: $*"
    return 0
  fi
  log "installing: ${missing[*]}"
  as_root pacman -S --needed --noconfirm "${missing[@]}"
  mark_changed "installed ${missing[*]}"
}

# install_file SRC DEST [MODE] — copy SRC to DEST when content or mode differs.
# Returns 0 when DEST changed, 1 when it was already current, so callers can
# trigger reloads: `install_file a b && systemctl daemon-reload`.
install_file() {
  local src=$1 dest=$2 mode=${3:-0644} cmp=(cmp -s)
  # Root-only files (crypttab, sudoers) can only be compared as root.
  [[ -e $dest && ! -r $dest ]] && cmp=(sudo cmp -s)
  if [[ -f $dest ]] && "${cmp[@]}" "$src" "$dest" &&
     [[ "$(stat -c '%a' "$dest")" == "${mode#0}" ]]; then
    return 1
  fi
  log "writing $dest"
  as_root install -Dm "$mode" "$src" "$dest"
  mark_changed "wrote $dest"
  return 0
}

# install_tree DIR — mirror every file under $FILES_DIR/DIR to /DIR's
# matching absolute path (files/etc/foo -> /etc/foo). Executables keep 0755.
# Returns 0 when any file changed.
install_tree() {
  local root="$FILES_DIR/$1" f rel mode changed=1
  [[ -d $root ]] || die "missing $root"
  while IFS= read -r -d '' f; do
    rel="${f#"$FILES_DIR"}"
    mode=0644
    [[ -x $f ]] && mode=0755
    install_file "$f" "$rel" "$mode" && changed=0
  done < <(find "$root" -type f -print0 | sort -z)
  return "$changed"
}

# write_file DEST [MODE] < content — like install_file with content on stdin.
write_file() {
  local tmp
  tmp="$(mktemp -p "$RUN_DIR")"
  cat > "$tmp"
  install_file "$tmp" "$@"
}

# remove_file PATH — delete PATH when it exists. Returns 0 when removed.
remove_file() {
  [[ -e $1 || -L $1 ]] || return 1
  log "removing $1"
  as_root rm -f -- "$1"
  mark_changed "removed $1"
}

# --- initramfs: decide rebuilds from what the images contain, not from what
# this run changed, so an interrupted run repairs itself on the next one. ---

# initramfs_images — print the non-fallback initramfs images (root-only /boot).
initramfs_images() {
  sudo find /boot -maxdepth 1 -name 'initramfs-*.img' ! -name '*fallback*' | sort
}

# initramfs_contains REL — true when every image lists REL (e.g. etc/crypttab).
initramfs_contains() {
  local img n=0
  while IFS= read -r img; do
    n=$((n + 1))
    sudo lsinitcpio "$img" 2>/dev/null | grep -qxF -- "$1" || return 1
  done < <(initramfs_images)
  (( n > 0 ))
}

# initramfs_matches ABS — true when every image carries ABS with the same
# content as the live file (e.g. /etc/modprobe.d/oxp3-nvme.conf).
initramfs_matches() {
  local abs=$1 rel=${1#/} img work n=0
  while IFS= read -r img; do
    n=$((n + 1))
    work="$(mktemp -d -p "$RUN_DIR")"
    (cd "$work" && sudo lsinitcpio -x "$img" "$rel" >/dev/null 2>&1) || return 1
    sudo cmp -s "$work/$rel" "$abs" || return 1
  done < <(initramfs_images)
  (( n > 0 ))
}

# initramfs_has_line REL LINE — true when every image's REL contains LINE
# exactly (for files mkinitcpio filters, such as crypttab).
initramfs_has_line() {
  local rel=$1 line=$2 img work n=0
  while IFS= read -r img; do
    n=$((n + 1))
    work="$(mktemp -d -p "$RUN_DIR")"
    (cd "$work" && sudo lsinitcpio -x "$img" "$rel" >/dev/null 2>&1) || return 1
    sudo grep -qxF -- "$line" "$work/$rel" || return 1
  done < <(initramfs_images)
  (( n > 0 ))
}

# rebuild_initramfs REASON — regenerate all images once and ask for a reboot.
rebuild_initramfs() {
  log "rebuilding initramfs: $1"
  as_root mkinitcpio -P
  mark_changed "rebuilt initramfs ($1)"
  need_reboot "$1"
}

# --- UEFI boot state (efivarfs: 4 attribute bytes, then the value) ---

EFI_GLOBAL_GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c
EFI_LOADER_GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
SBCTL_DIR=/var/lib/sbctl
# Present once 12-uki-boot has moved booting from Type #1 entries to UKIs.
UKI_MODE_CONF=/etc/sdboot-manage.conf.d/90-oxp3-uki.conf

efivar_flag() {
  [[ "$(sudo od -An -t u1 -j 4 -N 1 "/sys/firmware/efi/efivars/$1" 2>/dev/null | tr -d ' ')" == 1 ]]
}
secure_boot_on() { efivar_flag "SecureBoot-$EFI_GLOBAL_GUID"; }
setup_mode_on()  { efivar_flag "SetupMode-$EFI_GLOBAL_GUID"; }

# loader_var NAME — a systemd-boot string variable (UTF-16), e.g.
# LoaderEntrySelected; empty when unset.
loader_var() {
  local f=/sys/firmware/efi/efivars/$1-$EFI_LOADER_GUID
  [[ -e $f ]] || return 0
  sudo tail -c +5 "$f" | iconv -f UTF-16LE -t UTF-8 | tr -d '\0' || true
}

# booted_uki — this boot came from a UKI that systemd-stub measured, which
# makes it a "measured OS" (PCR 11/15 measurements happen).
booted_uki() { [[ -e /sys/firmware/efi/efivars/StubPcrKernelImage-$EFI_LOADER_GUID ]]; }
uki_mode()   { [[ -e $UKI_MODE_CONF ]]; }

# type1_entries — boot entries that load a bare kernel (sdboot-manage's).
type1_entries() {
  sudo find /boot/loader/entries -maxdepth 1 -name '*.conf' -exec grep -l '^linux ' {} + 2>/dev/null || true
}

# our_pk_enrolled — the firmware's Platform Key is the one sbctl made here.
our_pk_enrolled() {
  local pem=$SBCTL_DIR/keys/PK/PK.pem der pk
  sudo test -f "$pem" || return 1
  der="$(sudo openssl x509 -in "$pem" -outform DER | od -An -v -t x1 | tr -d ' \n')"
  pk="$(sudo od -An -v -t x1 "/sys/firmware/efi/efivars/PK-$EFI_GLOBAL_GUID" 2>/dev/null | tr -d ' \n' || true)"
  [[ -n $der && $pk == *"$der"* ]]
}

# module_has_string KO STRING — true when the kernel module file contains
# STRING as a whole string (e.g. a DMI board name). grep -c reads to the end,
# so pipefail never sees SIGPIPE from an early-exiting grep -q.
module_has_string() {
  local ko=$1 count
  [[ -e $ko ]] || return 1
  if [[ $ko == *.zst ]]; then
    count="$(zstd -dcq -- "$ko" 2>/dev/null | strings | grep -cxF -- "$2" || true)"
  else
    count="$(strings -- "$ko" 2>/dev/null | grep -cxF -- "$2" || true)"
  fi
  (( ${count:-0} > 0 ))
}

# refuse_conflicting_daemons — InputPlumber, steamos-manager and oxp3-tdp own
# the controller and RAPL; these packages would fight them for both.
refuse_conflicting_daemons() {
  local p found=()
  for p in hhd hhd-git adjustor powerstation powerstation-bin inputplumber-git thermald; do
    pacman -Qq "$p" &>/dev/null && found+=("$p")
  done
  (( ${#found[@]} == 0 )) ||
    die "remove conflicting input/TDP daemons first: sudo pacman -R ${found[*]}"
  local plugin
  for plugin in SimpleDeckyTDP PowerControl; do
    [[ -d $HOME/homebrew/plugins/$plugin ]] &&
      warn "Decky plugin $plugin also writes RAPL limits and will fight the Steam TDP slider"
  done
  return 0
}

# enable_unit UNIT... — enable and start system units that are not yet enabled.
enable_unit() {
  local u
  for u in "$@"; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
      as_root systemctl start "$u" >/dev/null 2>&1 || true
      continue
    fi
    log "enabling $u"
    as_root systemctl enable --now "$u"
    mark_changed "enabled $u"
  done
}

# enable_unit_only UNIT... — enable without starting, for hook units such as
# sleep.target-wanted oneshots whose ExecStart must only run around suspend.
enable_unit_only() {
  local u
  for u in "$@"; do
    systemctl is-enabled --quiet "$u" 2>/dev/null && continue
    log "enabling $u (not starting it)"
    as_root systemctl enable "$u"
    mark_changed "enabled $u"
  done
}

# disable_unit UNIT... — disable and stop system units that are enabled.
disable_unit() {
  local u
  for u in "$@"; do
    systemctl is-enabled --quiet "$u" 2>/dev/null || continue
    log "disabling $u"
    as_root systemctl disable --now "$u"
    mark_changed "disabled $u"
  done
}

# enable_user_unit UNIT... — enable units in the target user's systemd instance.
enable_user_unit() {
  local u
  for u in "$@"; do
    systemctl --user is-enabled --quiet "$u" 2>/dev/null && continue
    log "enabling user unit $u"
    [[ $DRY_RUN == 1 ]] || systemctl --user enable --now "$u"
    mark_changed "enabled user unit $u"
  done
}
