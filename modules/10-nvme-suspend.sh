#!/usr/bin/env bash
# Keep the NVMe alive across s2idle suspend.
#
# The OneXPlayer 3 firmware sets ACPI StorageD3Enable on the NVMe root port,
# so the nvme driver logs "platform quirk: setting simple suspend" and shuts
# the controller down to D3 for s2idle. With an Acer Predator GM7
# (1dee:1602) on BIOS 5.09 the drive never returns ("Disabling device after
# reset failure: -19"), btrfs aborts and the root filesystem goes read-only.
#
# nvme.noacpi=1 skips only that StorageD3Enable check (drivers/nvme/host/pci.c,
# nvme_pci_alloc_dev), so the driver uses host-managed NVMe power states and
# keeps the link in ASPM L1.2 instead. nvme is a module, and mkinitcpio's
# modconf hook copies modprobe.d into the initramfs, so no kernel command
# line edit is needed.
#
# Until the option is active (after the next boot) sleep is masked for the
# rest of this boot, so no idle, lid or button suspend can lose the SSD.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3

conf=/etc/modprobe.d/oxp3-nvme.conf
write_file "$conf" <<'EOF' || true
# Managed by CachyOS-OneXPlayer3 (modules/10-nvme-suspend.sh).
# Ignore ACPI StorageD3Enable: D3 during s2idle loses the NVMe on resume.
options nvme noacpi=1
EOF

if [[ $DRY_RUN != 1 ]] && ! initramfs_matches "$conf"; then
  rebuild_initramfs "nvme noacpi option takes effect at next boot"
fi

sleep_targets=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)
if [[ "$(cat /sys/module/nvme/parameters/noacpi 2>/dev/null)" == Y ]]; then
  ok "nvme noacpi active in running kernel"
  # Lift the guard from an earlier run in this boot, if any.
  if [[ -L /run/systemd/system/sleep.target ]]; then
    as_root systemctl unmask --runtime "${sleep_targets[@]}"
    mark_changed "sleep re-enabled (NVMe fix active)"
  fi
else
  if [[ ! -L /run/systemd/system/sleep.target ]]; then
    log "blocking sleep until reboot: a resume now would lose the NVMe"
    as_root systemctl mask --runtime "${sleep_targets[@]}"
    mark_changed "sleep blocked until reboot"
  fi
  need_reboot "NVMe sleep fix becomes active (sleep is blocked until then)"
fi
