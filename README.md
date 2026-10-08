# OneXPlayer 3 × CachyOS Handheld

Turn a fresh [CachyOS Handheld](https://cachyos.org/) install on the **OneXPlayer 3** into a Steam Deck-like console: it boots straight into Steam's Game Mode, the controller shows up in Steam as a Steam Deck controller, and Steam's own TDP slider and power button work.

## Install

1. Install CachyOS Handheld edition on the OneXPlayer 3 with **disk encryption turned on**, and use **the same password for the disk and your user account**. Then the installer below only ever needs that one password. Finish first-boot setup.
2. In Desktop Mode, open a terminal (Konsole) and run:

   ```sh
   git clone https://github.com/ZeroSegFault/CachyOS-OneXPlayer3.git
   cd CachyOS-OneXPlayer3
   ./install.sh
   ```

3. Type your password when asked; that's the only prompt in each run. Then follow the summary at the end, which tells you when to reboot and when to visit the BIOS. Run `./install.sh` again after each reboot until the summary has nothing left for you to do. A fresh setup takes three runs:
   1. **First run.** Installs everything, then asks for one BIOS visit to switch on Secure Boot with your own keys. Reboot straight into the BIOS with `systemctl reboot --firmware-setup` and follow the steps it printed.
   2. **Second run.** Signs the boot files and enrols your keys. Reboot.
   3. **Third run.** Sets up the TPM, so the disk unlocks by itself at boot from then on.

   Until the third run, every boot asks for the disk password. Don't want Secure Boot? Add `--skip 13-secure-boot` to every run; the TPM unlock is then set up on the second run. If your disk password differs from your login password, the installer asks for it separately.

Running `./install.sh` again is always safe: it only changes what isn't already set up. Use it to repair the device or after a reinstall. Each run starts by updating the whole system (`pacman -Syu`); add `--skip 00-system-update` to leave packages alone. The device won't go to sleep while the installer runs.

## What you get

| Feature | Notes |
|---|---|
| Sleep and wake | Press the power button to sleep. Fixes a bug that lost the SSD on wake. |
| No passphrase at boot | The TPM unlocks the disk; your passphrase still works if it's ever needed. |
| Secure Boot | Only your own signed boot files start, so a stolen device can't be booted from a USB stick or tampered with to unlock the disk. Uses your own keys (the factory key is an untrustworthy AMI test key). |
| Steam Deck controller | Home opens the Steam menu, ONEX opens the Quick Access Menu (…), the keyboard key opens the on-screen keyboard (shows as Steam + X in Steam's tester, the Deck's keyboard shortcut). |
| Gyro | Available to Steam Input. |
| TDP and GPU sliders | In Steam's Quick Access Menu → Performance, 8–35 W. |
| Battery charge limit | Steam's setting can stop charging early to protect the battery. |
| Fan speed | Readable; the fan stays under the device's automatic control. |
| Screen | 48–144 Hz refresh-rate slider and HDR. |
| Decky Loader | Plugin menu in the Quick Access Menu. |
| Quiet boot | No boot menu or text: firmware logo, splash animation, Game Mode. |
| Speakers | Unmuted on first run. |
| Fingerprint (experimental, opt-in) | Unlocks the Desktop Mode lock screen. Turn on with `OXP3_FINGERPRINT=1 ./install.sh --only 85-fingerprint`, then enrol: `fprintd-enroll -f right-index-finger`. sudo and logins stay password-only. |

**Not possible yet:** the back buttons M1/M2 (waiting for an upstream kernel driver fix; the installer tells you when your kernel has it), RGB lighting control, and holding the power button for the power menu (the hardware only reports short presses). Use Steam button → Power instead.

## Good to know

- TDP above 35 W needs a 100 W or stronger USB-C charger; the slider stops at 35 W by default (change it in `/etc/oxp3/tdp.conf`).
- Don't install hhd, PowerStation or TDP Decky plugins (SimpleDeckyTDP, PowerControl) alongside this. They fight over the same controls, and the installer refuses to run if one is present.
- The boot menu is hidden. To get it once: hold any key on a USB keyboard while powering on, or run `systemctl reboot --boot-loader-menu=60`.
- If it ever won't boot: turn Secure Boot off in the BIOS. Everything still starts, the disk asks for your passphrase, and in the boot menu you can press `e` to edit the kernel command line. Turn Secure Boot back on and rerun `./install.sh` afterwards.
- "Invalid signature detected" after a BIOS update or a BIOS settings reset means the factory Secure Boot keys are back. In the BIOS (Security → Secure Boot): set Factory Key Provision to Disabled, choose Reset To Setup Mode, keep Secure Boot Enabled, save. Then rerun `./install.sh` (it enrols your keys again), reboot, and run it once more.
- A BIOS update that keeps your keys, or a Secure Boot revocation update offered by Discover or `fwupdmgr`, makes the next boots ask for the disk passphrase until you rerun `./install.sh`.
- Reinstalling: turn Secure Boot off in the BIOS first (the CachyOS installer USB isn't signed with your keys). After the reinstall, `./install.sh` makes new keys and walks you through the BIOS step again.
- Keep your disk passphrase safe: it is the way back in whenever the TPM won't unlock.

## Options

```sh
./install.sh --list                # show the setup steps
./install.sh --only 30-controller  # run one step
./install.sh --skip 60-decky       # skip a step
./install.sh --dry-run             # show what would change
```

From another computer you can push and run it over SSH instead: `./deploy.sh user@onexplayer`.

How each step works, and why, is in [`docs/research/`](docs/research/).
