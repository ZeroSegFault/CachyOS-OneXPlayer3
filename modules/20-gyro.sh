#!/usr/bin/env bash
# Make the gyro/accelerometer (Bosch BMI260) bind to its in-kernel driver.
#
# The firmware describes the IMU at \_SB.PC00.I2C1.SPBA with the ACPI ID
# 10EC5280, which bmi160_i2c claims for older handhelds and then fails on
# (chip ID 0x27 is a BMI260; bmi160 logs "Error reading chip id"). bmi270_i2c
# drives the BMI260 but only matches BMI0160/BMI0260. Upstream's fix has
# stalled (lore 20260731195325.44453-1-philm@manjaro.org).
#
# This builds an ACPI table upgrade from the device's own SSDT: the same
# table with _HID/_CID renamed to BMI0260 and the OEM revision bumped by one,
# loaded early by mkinitcpio's acpi_override hook (CONFIG_ACPI_TABLE_UPGRADE).
# It is generated on the device rather than shipped, and tied to the BIOS it
# was built from: a BIOS update drops it so the next run rebuilds it.
# See docs/research/2026-10-07-onexplayer3-device-support.md §3.
# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
require_onexplayer3
pkg_install acpica

dir=/etc/initcpio/acpi_override
aml="$dir/oxp3-imu.aml"
stamp="$dir/oxp3-imu.bios"
dropin=/etc/mkinitcpio.conf.d/oxp3-acpi-override.conf
bios="$(cat /sys/class/dmi/id/bios_version) $(cat /sys/class/dmi/id/bios_date)"
rebuild=0 stale=0

# A table built for another BIOS could replace a changed SSDT with stale AML.
# Drop it (and the hook, which errors without any .aml) and regenerate from
# the new firmware's table after the next boot.
if [[ -e $aml && "$(cat "$stamp" 2>/dev/null)" != "$bios" ]]; then
  remove_file "$aml" || true
  remove_file "$stamp" || true
  stale=1
  need_reboot "dropped IMU override built for an older BIOS; rerun install.sh after reboot"
fi

find_table() { # find_table ID — print the live SSDT that contains ID
  local t
  for t in /sys/firmware/acpi/tables/SSDT*; do
    sudo grep -qa "$1" "$t" && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

if (( stale )); then
  :
elif table="$(find_table '"\?10EC5280')" && [[ $DRY_RUN == 1 ]]; then
  log "[dry-run] would generate the BMI0260 override from $(basename "$table")"
elif table="$(find_table '"\?10EC5280')"; then
  log "generating BMI0260 override from $(basename "$table")"
  work="$(mktemp -d -p "$RUN_DIR")"
  # Read as root, write to our own temp file.
  # shellcheck disable=SC2024
  sudo cat "$table" > "$work/orig.dat"
  (cd "$work" && iasl -d orig.dat >/dev/null 2>&1) || die "iasl failed to disassemble $table"
  # Rename only inside the IMU device and bump OEM revision so the kernel
  # treats it as an upgrade of the same table (signature, OEM ID, table ID).
  awk '
    /^DefinitionBlock \(/ && !bumped {
      match($0, /0x[0-9A-Fa-f]+\)$/)
      rev = strtonum(substr($0, RSTART, RLENGTH - 1))
      $0 = substr($0, 1, RSTART - 1) sprintf("0x%08X)", rev + 1); bumped = 1
    }
    /Device \(SPBA\)/ { in_dev = 1 }
    in_dev && /"10EC5280"/ { gsub(/"10EC5280"/, "\"BMI0260\""); renamed++ }
    in_dev && /^        }/ { in_dev = 0 }
    { print }
    END { if (renamed != 2 || !bumped) exit 1 }
  ' "$work/orig.dsl" > "$work/oxp3-imu.dsl" ||
    die "SSDT layout changed (expected SPBA with _HID and _CID 10EC5280); not overriding"
  (cd "$work" && iasl -p oxp3-imu oxp3-imu.dsl >/dev/null 2>&1) || die "iasl failed to compile the IMU override"
  install_file "$work/oxp3-imu.aml" "$aml" && rebuild=1
  printf '%s\n' "$bios" | write_file "$stamp" || true
elif find_table '"\?BMI0260' >/dev/null; then
  if [[ -e $aml ]]; then
    ok "IMU override active (firmware table now reports BMI0260)"
  else
    ok "firmware already reports the IMU as BMI0260; no override needed"
  fi
else
  warn "no IMU ACPI node (10EC5280/BMI0260) found; skipping"
fi

# The acpi_override hook fails the whole mkinitcpio run when no .aml exists,
# so the hook is configured only together with the override file.
if [[ -e $aml ]]; then
  write_file "$dropin" <<'EOF' || true
# Managed by CachyOS-OneXPlayer3 (modules/20-gyro.sh): load /etc/initcpio/acpi_override/*.aml early.
HOOKS+=(acpi_override)
EOF
else
  remove_file "$dropin" || true
fi

# Rebuild when the images disagree with the override's presence (this also
# repairs an interrupted earlier run) or when this run changed the override.
if [[ $DRY_RUN != 1 ]]; then
  want_in=0; [[ -e $aml ]] && want_in=1
  have_in=0; initramfs_contains kernel/firmware/acpi/oxp3-imu.aml && have_in=1
  if (( rebuild || want_in != have_in )); then
    rebuild_initramfs "IMU ACPI override applies at next boot"
  fi
fi

if compgen -G '/sys/bus/iio/devices/iio:device*' >/dev/null &&
   grep -qi bmi260 /sys/bus/iio/devices/iio:device*/name 2>/dev/null; then
  ok "gyro available: $(grep -il bmi260 /sys/bus/iio/devices/iio:device*/name | xargs -n1 dirname | xargs -n1 basename | tr '\n' ' ')"
else
  warn "BMI260 IIO device not present yet (expected until the next boot)"
fi
