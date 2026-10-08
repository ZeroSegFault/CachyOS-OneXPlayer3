# Secure Boot, signed UKI and the TPM policy on the OneXPlayer 3

Date: 2026-10-08. Device: ONE-NETBOOK ONEXPLAYER 3, AMI firmware 5.39 / BIOS 5.09, CachyOS Handheld, kernel `7.2.9-1-cachyos-deckify`.
Versions: systemd 262, mkinitcpio 42.2, sbctl 0.18, systemd-boot-manager (sdboot-manage) 21.
Implemented by `modules/12-uki-boot.sh`, `modules/13-secure-boot.sh` and `modules/15-tpm-unlock.sh`. Source lines below refer to systemd tag v262, sbctl tag 0.18, and the scripts installed on the device.

## Why

Before this change the TPM unlock (PCR 7 + 15) did not hold up against someone holding the whole device:

- **Secure Boot was off and the factory Platform Key was an AMI test key.** fwupd reports the PK as "DO NOT TRUST - AMI Test PK" and `fwupdmgr security` says "UEFI platform key: Invalid" (PKfail, [CVE-2024-8105](https://kb.cert.org/vuls/id/455367)).
- **PCR 7 is the same for anything that boots.** With Secure Boot off, a USB stick, an edited kernel command line (`init=/bin/sh`) or a swapped initramfs on the vfat ESP all leave PCR 7 unchanged, so the TPM releases the key.
- **PCR 15 never moved.** It only changes on a "measured OS", meaning a UKI booted through systemd-stub. `efi_measured_os()` falls back to `efi_measured_uki()`, which tests for `StubPcrKernelImage` (`src/shared/efi-loader.c` L267–338). The Type #1 boot never set it, so the PCR 15 binding never did anything.

## Design

### 1. Boot a UKI (`12-uki-boot`)

- **Preset.** mkinitcpio builds `default_uki="/boot/EFI/Linux/<pkgbase>.efi"`, using ukify when `systemd-ukify` is installed (`/usr/bin/mkinitcpio` `uki_init`, L472–542). systemd-boot finds Type #2 entries in `/EFI/Linux/` (`man systemd-boot`). `default_image` stays for the `lib/common.sh` initramfs checks.
- **Kernel copy on the encrypted root.** `ALL_kver="/var/lib/oxp3/vmlinuz-<pkgbase>"`. The stock `/boot/vmlinuz-*` sits on the unencrypted ESP: someone could swap it offline, and any later `mkinitcpio -P` (firmware, systemd or DKMS updates trigger one) would embed it in a UKI that the post hook then signs.
  - mkinitcpio's libalpm script copies the kernel to any preset `kver` path that no package owns (`is_kernelcopy`/`install_kernel` in `/usr/share/libalpm/scripts/mkinitcpio`), so the copy stays current.
  - `uki_current` also compares the UKI's `.linux` section byte-for-byte with `/usr/lib/modules/<kver>/vmlinuz`.
  - Presets are written by `/usr/local/lib/oxp3/uki-presets`, which `95-oxp3-uki-presets.hook` also runs after a kernel install. A kernel added later (e.g. via cachyos-kernel-manager) gets mkinitcpio's stock preset and would otherwise have no UKI and no entry.
- **Command line.** It is taken from `/etc/kernel/cmdline`, and only from there: with no cmdline file, mkinitcpio falls back to `/proc/cmdline`, which here starts with an `initrd=` (L590–611). The installer's `/etc/kernel/cmdline` was stale (`rd.luks.uuid`, `root=/dev/mapper/…`, no quiet options), so the module derives it from the running system:
  - `root=UUID=… rw rootflags=subvol=/@` — required. The partition type is plain "Linux filesystem" and the btrfs default subvolume is 5, so gpt-auto cannot find root.
  - `rd.luks.name=…` and the CachyOS options `nowatchdog quiet splash loglevel=3 vt.global_cursor_default=0`.
  - `nohibernate`. The initrd's hibernate-resume generator trusts the `HibernateLocation` EFI variable (`src/hibernate-resume/hibernate-resume-config.c` L117–140), so a resume could run before the TPM policy closes. Swap is zram only, so nothing is lost.
- **No `.splash` section.** Plymouth's BGRT theme draws the firmware logo; a stub splash would flicker (`stub.c` `display_splash`).
- **Unaffected.** The ACPI table override and microcode stay first in the early cpio inside `.initrd`. Lockdown is `none` (`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE`), so ACPI table upgrades and the unsigned DKMS `oxpec` keep working under Secure Boot.
- **Cut-over takes two runs.** Run one builds the UKI and calls `bootctl set-oneshot`. The next run, once booted from it, does the switch:
  - writes `NO_AUTOGEN`/`NO_AUTOUPDATE` for sdboot-manage (its `gen` ignores `NO_AUTOGEN`, which is why 80-quiet-boot skips entry management in UKI mode);
  - sets `default <pkgbase>.efi`;
  - removes the Type #1 entry and the installer's kernel-install copy under `/boot/<machine-id>/`.
- **ESP lag fix.** `zzz-oxp3-sdboot-update.hook` runs `bootctl --graceful update` after sbctl's `zz-sbctl.hook` has re-signed systemd-boot. sdboot-manage's own update hook runs earlier and left the ESP one release behind ([sbctl #119](https://github.com/Foxboron/sbctl/issues/119)).
- **NvPCRs masked.** systemd 262 initialises NvPCRs on a measured OS, which needs a signed PCR policy (`.pcrpkey`/`.pcrsig`) in the UKI (`tpm2_nvpcr_initialize`, `src/shared/tpm2-util.c`). Without one, `systemd-tpm2-setup-early` fails in the initrd before Plymouth ("Failed to initialize NvPCR index: No such file or directory", [systemd #43848](https://github.com/systemd/systemd/issues/43848), open), and `systemd-pcrproduct` and `systemd-pcrlogin@` fail later. Nothing here uses NvPCRs, so:
  - `/etc/nvpcr/*.nvpcr` are masked (conf-files masking), also inside the initramfs via the `oxp3-nvpcr-off` mkinitcpio hook;
  - the two extend units are masked.

### 2. Secure Boot with our own keys (`13-secure-boot`)

- **Keys.** sbctl keeps everything in `/var/lib/sbctl` (`config/config.go` L78–108). Keys are RSA-4096, which this firmware verifies fine. `db.key` is effectively a disk-unlock credential, so it is not backed up; a reinstall makes new keys and repeats the BIOS step.
- **What gets signed.**
  - systemd-boot is registered with `sbctl sign -s -o …efi.signed …efi`. bootctl copies a `.signed` file in preference (`src/bootctl/bootctl-install.c` L866–881). `bootctl install` forces the first copy, because `update` skips an equal version.
  - UKIs are signed only as they are built, by `files/etc/initcpio/post/sbctl`. 13-secure-boot never signs a file it finds on the ESP: an unsigned expected UKI is rebuilt from root, an unsigned fallback loader is removed, and any other unsigned file is left to fail verification. It replaces sbctl's hook: mkinitcpio runs one post hook per name, `/etc` first. sbctl's hook signs the bare kernel when no UKI is passed.
  - A **bare kernel is never signed**. A signed vmlinuz would boot with any command line and initrd. sbctl's kernel-install plugin is masked as well.
  - sbctl 0.18 does not register or refresh an output that is already signed ([#482](https://github.com/Foxboron/sbctl/issues/482), [#488](https://github.com/Foxboron/sbctl/issues/488)), so the module deletes the `.signed` file before re-registering. `sbctl verify` exits 0 even with unsigned files ([#512](https://github.com/Foxboron/sbctl/issues/512)), so checks parse `--json`.
- **Enrolment.** `sbctl enroll-keys --microsoft --ignore-immutable`, only in Setup Mode (`cmd/sbctl/enroll-keys.go` L266–275).
  - Microsoft's KEK/db are kept, so dbx updates and option ROMs keep working. Anything Microsoft signs records a different db authority in PCR 7 and cannot unseal.
  - The event log has no `EV_EFI_BOOT_SERVICES_DRIVER` events, so no option ROMs were in use.

### 3. TPM policy (`15-tpm-unlock`)

- **The policy is PCR 7 + 12 + 15**, with 15 sealed to zero, once the device boots a UKI and PCR 12 holds the clean value.
- **Why PCR 12.** systemd-boot measures loader-supplied options into it, including the `initrd=` of a Type #1 entry (`src/boot/boot.c` L3077–3105). systemd-stub measures credentials, addons and command-line overrides there too.
  - Without PCR 12, an attacker-written Type #1 entry could load our signed UKI as `linux` with an extra initrd. sd-stub accepts a previously registered initrd unchecked (`stub.c` L511–523), so that code would run after the unseal.
- **The clean PCR 12 value.** On a clean UKI boot, PCR 12 holds only `systemd-pcrosseparator`'s "os-separator". The module computes SHA256(0³² ‖ SHA256("os-separator")) = `3345a4e7…c99c`. **This matched the device** on its first UKI boot.
- **The separator also lands in PCR 7.** It is extended before cryptsetup, so a slot sealed on a Type #1 boot fails on the first UKI boot. Seal from a running measured boot with `--tpm2-pcrs=7+12+15:sha256=<zero>`.
- **When not to seal.** Each case leaves any existing slot alone:
  - Once the device boots UKIs, PCR 12 is mandatory. A boot whose PCR 12 is not clean is never sealed to; the policy is not dropped to PCR 7 + 15 instead, since that would turn a planted credential into a downgrade.
  - Never while Secure Boot is off but our PK is enrolled (the repair state), except in the run that just enrolled the keys, which waits for the reboot.
  - Not while the first UKI boot is pending (one-shot set) or 13-secure-boot is running but Secure Boot is not on: the next step changes PCR 7 anyway.
- **Boot menu editor.** `editor yes` only when the slot is [7,12,15] and sealed, Secure Boot is on with our PK, and no Type #1 entries exist.
  - With Secure Boot on, systemd-boot refuses to edit a UKI that has a `.cmdline` (`boot.c` L77–80, L846–853), and sd-stub drops overrides anyway (`stub.c` L1152–1158).
  - With Secure Boot off for a repair, edits work but PCR 7 and 12 change, so the passphrase is needed.

## Firmware behaviour found on this unit

- **Signed loaders are checked even though Secure Boot reads as off.**
  - The firmware setup showed Secure Boot **Enabled**, mode **Custom**, yet the OS read `SecureBoot=0` with the AMI test PK.
  - It booted unsigned systemd-boot, but rejected systemd-boot signed with our not-yet-enrolled key: "Invalid signature detected. Check Secure Boot Policy in Setup".
  - So 13-secure-boot creates keys and signs nothing until the firmware is in Setup Mode, and enrols in that same run.
- **Factory Key Provision.** It sits in an advanced menu under Security → Secure Boot. While enabled, "Reset To Setup Mode" is undone at the next boot: the AMI test keys come back. Disable it first.
- **What "Reset To Setup Mode" deleted.** With Factory Key Provision disabled it removed PK, KEK, db **and dbx**.
  - After enrolment, dbx stays empty: fwupd 2.1.8 lists the dbx device with no version and offers no release for it (`fwupdmgr get-releases` is empty, "latest available" after a metadata refresh, checked 2026-10-08).
  - The disk policy does not depend on it: revoked loaders are Microsoft-signed, so they would measure a different PCR 7.
- **Boot entries.** `bootctl install` registered a "Fallback Linux Boot Manager" boot entry (Boot0007) whose file does not exist yet. It is harmless; systemd-boot ≥ 262 fills it on the next update, and 13-secure-boot signs it.
- **Built-in EFI Shell.** "UEFI: Built-in EFI Shell" (Boot000B) is a firmware-internal option.
  - A pre-OS attacker with the boot menu could start it. Its memory-editing commands are the remaining software path to forging PCRs.
  - A BIOS admin password, and disabling the shell if the BIOS offers it, close that path. Only a TPM PIN resists hardware attacks (SPI flash is unlocked and BootGuard is off).

## Recovery

- **Won't boot.** Turn Secure Boot off in the BIOS. Everything still starts, the disk asks for the passphrase, and the boot menu editor works. Turn Secure Boot back on, then rerun `install.sh`; 15-tpm-unlock refuses to re-seal while it is off.
- **BIOS update reset the keys** (red screen with Secure Boot on). Go to Setup Mode in the BIOS, then rerun `install.sh`. The existing keys are enrolled again, and the TPM is re-sealed on the run after.
