# OneXPlayer 3 on CachyOS Handheld: device support state (2026-10-07)

Scope: ONE-NETBOOK "ONEXPLAYER 3" (BIOS 5.09 2026-08-10, EC fw 0.13, Panther Lake, Arc B390 `8086:b080`) running CachyOS Handheld with `linux-cachyos-deckify 7.2.9-1`, gamescope 3.16.25, gamescope-session-cachyos 1.1.6, cachyos-handheld 1.3.2, steam-jupiter-stable. Goal from the user: TDP control, the full controller (all buttons and gyro), sleep/resume and the power button should work as close to a native Steam Deck as possible.

Method:
- Primary sources were checked on 2026-10-07: lore.kernel.org mbox exports, git.kernel.org trees, GitHub repos (cloned), gitlab.steamos.cloud, and the CachyOS repos.
- On-device evidence came from read-only commands over ssh, run 2026-10-07 19:30-19:55 AEDT. The only writes were `/tmp` scratch files on the device, which were deleted.
- Lines tagged **[device]** were observed directly. **[inference]** marks reasoning without a primary source. **[unverified]** marks claims that were not confirmed.

> **Warning, observed today [device].** Someone ran `sudo systemctl suspend` at 19:48 (journal of boot -1).
> - On resume the NVMe disappeared: `nvme nvme0: Disabling device after reset failure: -19`.
> - btrfs then aborted a transaction and forced the root filesystem read-only (`BTRFS info (device dm-0 state EA): forced readonly`). A reboot was needed.
> - **Do not suspend this device until the NVMe fix is in place** (see §6).

---

## Summary

| Feature | Status today (7.2.9, stock CachyOS packages) | What is needed |
|---|---|---|
| Gamepad sticks, face buttons, triggers, rumble | Works. xpad binds `045e:028e` **[device]** | Nothing. Hide the pad behind a virtual Deck controller (see the next rows) |
| Back paddles M1/M2 | `hid-oxp` is **bound** to all three `1a86:fe00` interfaces **[device]**, contrary to the initial note. Paddles are programmed to `KEY_F16`/`KEY_F17` **[device]** | A userspace mapper so Steam sees L4/R4. Pending kernel series fixes OXP3 button-map format and suspend reinit |
| Home / ONEX(Console) / Keyboard keys → Steam Guide / QAM / OSK | Not mapped. No hhd or InputPlumber installed, and the chwd handheld profile does not match "ONEXPLAYER 3" | InputPlumber 0.81 + local OXP3 device yaml (from IP PR #672 / reference repo), or hhd master. See §1 |
| Gyro | **Not working.** The IMU is a **BMI260** (chip id `0x27` at I2C1 `0x68` **[device]**) behind ACPI `10EC5280`. Only `bmi160_i2c` claims that ID and it fails with -121 **[device]** | ACPI table upgrade renaming the HID to `BMI0260` so `bmi270_i2c` binds (mkinitcpio `acpi_override` hook, `CONFIG_ACPI_TABLE_UPGRADE=y` **[device]**), then InputPlumber/hhd IMU source with a mount matrix |
| RGB rings | `hid-oxp` LED class exists, but writes have no effect on OXP3 (reference repo). This is consistent with the pending "Gen3" RGB protocol patch | Wait for the hid-oxp v2 series, or use hhd master |
| Fan / charge limit / bypass / turbo takeover (oxpec) | `oxpec` does not load: no DMI match, no `force_load` parameter | Upstream patch "Add OneXPlayer 3 quirk" (maps to `oxp_g1_i`) was **accepted 2026-10-05**, not yet in any public release. Carry it as a 7-line patch (DKMS or a custom kernel) or wait |
| TDP (Steam slider) | No Steam slider. Firmware PL1: MSR **25 W**, MMIO **35 W**; PL2 52 W both **[device]**. The GPU obeys the MSR PL1 (reference repo) | steamos-manager has **no Intel RAPL backend**. Use a small `TdpLimit1` D-Bus remote that writes both MSR and MMIO PL1/PL2 (§1.6), or hhd master + patched steamos-manager |
| Power button | logind `HandlePowerKey=ignore` (cachyos-handheld) **[device]**, and steamos-powerbuttond is **not installed** **[device]**, so a short press currently does nothing in Game Mode | Install `steamos-powerbuttond` 4.2 (and steamos-manager) |
| Suspend (s2idle) | **Broken / dangerous**: the Predator GM7 NVMe (`1dee:1602`, fw BM345CVN) dies on resume through the ACPI StorageD3Enable path **[device]** | `nvme.noacpi=1` on the kernel cmdline (sdboot-manage `LINUX_OPTIONS`) |
| Display orientation | Native landscape. EDID DTD 1920x1200, DRM `panel orientation` = Normal **[device]** | Nothing. No quirk needed |
| Refresh / VRR / HDR | Samsung AMS881KB01-0 (EDID SDC product `0x4301`), 30-144 Hz continuous, `vrr_capable=1`, PQ/BT.2020 **[device]**. gamescope 3.16.25 has no profile for it | gamescope **≥ 3.16.29**, which ships `lenovo.legiongo2.oled.lua`. It matches SDC/0x4301 exactly, giving 48-144 Hz, PQ HDR and a software backlight |
| xe PSR errors | `Selective fetch area calculation failed`, `mismatch in vsc dp vsc sdp` **[device]**. Reported upstream for this exact device, no fix merged | Watch the Högander PSR series. Optionally `xe.enable_panel_replay=0` (does not cure the tearing per the upstream report) |
| Speakers | Plain HDA: Realtek ALC245, speaker pin 0x17, SOF `sof-hda-generic` **[device]**. RT1308 and TXNW3643 ACPI nodes have `_STA=0` **[device]**. TXNW3643 is a TI LM3643 camera-flash LED, not an amp. The sink is currently **muted at 0 %** **[device]** | Unmute and set a volume. No driver or firmware fix needed (the reference repo dropped its speaker issue on 2026-09-26) |
| Volume rocker | The EC drops key-release scancodes on the i8042 keyboard (reference repo; hhd issue #342) | systemd hwdb `!` force-release entry for the volume scancodes (cleaner than the reference repo's evdev proxy). Scancodes to be confirmed with `evtest` |

---

## 1. Built-in controller

### 1.1 Hardware topology [device]

| USB device | Kernel driver | Role |
|---|---|---|
| `045e:028e` bcdDevice 0x0316, port 3-7 | xpad ("Microsoft X-Box 360 pad") | Gamepad |
| `1a86:fe00` bcdDevice 0x0155, port 3-5, iface 0 | hid-oxp | Keyboard (EV KEY + LEDs) |
| `1a86:fe00` iface 1 | hid-oxp | Mouse / consumer |
| `1a86:fe00` iface 2 | hid-oxp | Vendor page 0xFF00, 64-byte in/out reports (descriptor `06 00 ff 09 01 … 95 40 81 06 … 95 40 91 06`) |
| `1a86:1305` | hid-generic / hid-multitouch | Detachable keyboard "Juer Xin Keyboard K2445" with touchpad |
| i8042 "AT Translated Set 2 keyboard" | atkbd | EC keys: volume rocker |

### 1.2 hid-oxp: kernel driver state

- **Origin:** Derek J. Clark's series v1 (2026-03-22) through v4 (2026-04-19), https://lore.kernel.org/all/20260419042624.625746-1-derekjohn.clark@gmail.com/.
  - Five commits were committed to the HID tree on 2026-05-12: 84910c459d65, 252c4bf1d931, 2f424f28fb39, e4c850a6e750, 99bde1dfe878.
  - They were merged for **v7.2** via b7556c8e713c (2026-06-18).
  - Stable 7.2.y log: https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/log/drivers/hid/hid-oxp.c?h=linux-7.2.y
- **Fixes since:** "use cancel_delayed_work_sync() in remove" (Tristan Madani), mainline abd24922c2a9, backported to 7.2.y about 2026-10-03.
  - It fixes the delayed-work use-after-free on remove, the same class as the reference repo's rebind Oops (`issues/hid_oxp_oops_rebind.txt`, Oops in `oxp_rgb_queue_fn`).
  - [inference] It is therefore likely fixed in 7.2.9, but that is unverified on the device. Still do not unbind or rebind.
- **Device table:** `0x1a2c:0xb001` (Gen1) and `0x1a86:0xfe00` (Gen2). This matches the `modinfo` aliases **[device]**.
- **Features:**
  - Multicolor LED `oxp:rgb:joystick_rings` (effects, speed, brightness).
  - `gamepad_mode` `xinput|debug`. This is the former "takeover" mode, renamed between v1 and v4.
  - Two-page button remap (`button_*`, targets in `button_mapping_options`).
  - `rumble_intensity` 0-5 and `reset_buttons`.
  - Settings are re-applied when the MCU reports a reset after resume (`oxp_mcu_init_fn`).
  - Upstream file: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/hid/hid-oxp.c?h=v7.3-rc6
- **On this device [device]:** all three `0003:1A86:FE00.000{1,2,3}` are bound to `hid-oxp`. `lsmod` refcount 0 is normal for HID drivers. The sysfs on `.0003` reads:
  - `gamepad_mode=xinput`, `button_m1=KEY_F16`, `button_m2=KEY_F17`, `rumble_intensity=5`
  - LED `effect=cyberpunk`, `enabled=true`
- **There is no OXP3-specific code upstream.** The only DMI list is the "hybrid MCU" list (APEX, G1 A, G1 i).
- **Pending OXP3 work:** Andrei Aldea, "[PATCH 00/15] HID: hid-oxp: fix and extend X2-family controller support", 2026-09-10, https://lore.kernel.org/all/20260910032115.28669-1-andrei1998@gmail.com/ (mbox verified).
  - Tested on an ONEXPLAYER 3 (Bazzite, kernel 7.2.0-ogc6.1). Also carried in OpenGamingCollective/linux-unstable PR #13.
  - Patch 01: M1/M2 defaults should be F15/F16. Upstream's indexes 48/49 resolve to F16/F17, which explains the values above.
  - Patch 10: controller reinitialisation across suspend.
  - Patch 12: `DMI_EXACT_MATCH(DMI_SYS_VENDOR,"ONE-NETBOOK")` + `DMI_EXACT_MATCH(DMI_PRODUCT_NAME,"ONEXPLAYER 3")`. It selects config interface 2 and button-map format 0x02 with a third page "preserving the extra buttons' factory mappings". [inference] Mainline's two-page write on OXP3 may therefore be partially wrong.
  - Patches 14/15: Gen3 ring RGB (zones 1, 2, 7) plus Guide-button and rear-logo LEDs (zones 5, 6). This explains why mainline Gen2 RGB writes do nothing on OXP3.
  - Status: Derek Clark replied 2026-09-10 asking for v2 with `Cc: stable` and corrected Fixes tags. **No v2 on lore as of 2026-10-07. Not in hid.git for-next or linux-next.**
- **CachyOS:** kernel-patches 17bb0bb (2026-10-04, `7.2/misc/0001-handheld.patch`) does not touch hid-oxp, https://github.com/CachyOS/kernel-patches/commit/17bb0bb818d2

### 1.3 What the extra buttons emit

| Physical control | Event | Source |
|---|---|---|
| Home key | Vendor iface 2 frame `B2 3F 01 01 1F 80 24 02 02 05 00 00 [01 press / 02 release]` (button 0x24) | Reference repo `issues/02-inputplumber.md`; hhd ff48c25 "fix home button on oxp3" maps 0x24 → mode |
| ONEX / "Console" key | Ctrl+Alt+Meta on the `HID 1a86:fe00` keyboard | InputPlumber issue #693, https://github.com/ShadowBlip/InputPlumber/issues/693 ; reference repo |
| Keyboard key | Ctrl+Meta+O on the same keyboard | same |
| Illuminated triangle / Xbox-style button | `BTN_MODE` on the xpad device | IP issue #693 [unverified on this unit] |
| M1 / M2 paddles | Keyboard `KEY_F16`/`KEY_F17` (hid-oxp defaults), plus vendor frames `B2 3F 01 … 22/23 …` that InputPlumber's `oxp_hid` decodes as Left/RightPaddle1. On OXP3 the physical left paddle is 0x22 = LeftPaddle1, so no swap is needed | Reference repo v1.2.0 notes; IP `src/drivers/oxp_hid` |
| Volume +/- | i8042 AT keyboard; release scancodes are dropped by the EC | Reference repo `issues/04`; hhd issue #342 (2026-09-23) |

I did not capture events myself (no physical access).

### 1.4 Userspace options compared

**InputPlumber** (ShadowBlip)
- Latest release v0.81.0, ea60d873, 2026-09-14. CachyOS has `inputplumber 0.81.0-1.1` in cachyos-extra-v3 **[device: pacman -Si]**.
- No OXP3 device config on main. The existing `50-onexplayer_intel.yaml` matches only `product_name: ONEXPLAYER` exactly.
- OXP3 support is in **open PR #672**, "Add OneXPlayer X2 Mini Pro and 3" (pastaq, head 7116a1b8, 2026-09-20), https://github.com/ShadowBlip/InputPlumber/pull/672. It folds in the closed #660.
  - Sources: xpad, the `HID 1a86:fe00` keyboard (filtered to the modifier/O keys), hidraw 1a86:fe00 iface 2, and IIO `bmi260` with an x/y-swapping mount matrix.
  - New capability map `oxp9`: Ctrl+Alt+Meta → QuickAccess, Ctrl+Meta+O → QuickAccess2.
  - The maintainer requested paddle testing with the kernel driver.
- The `oxp_hid` source driver only reads 0xB2 frames. It ignores B3/B4/B8 acks "from the kernel hid-oxp driver", so it **coexists with hid-oxp** (added in PR #567, merged 2026-05-07).
- steamos-manager puts every InputPlumber composite device on the `deck-uhid` target unless the device toml says otherwise (`src/inputplumber.rs`, steamos-manager 08c45b54). This gives a virtual Steam Deck controller, so Steam shows Steam/QAM/L4/R4/R5/gyro natively.

**hhd** (hhd-dev)
- OXP3 support exists **only on master**:
  - 0568a66 and e5b6a4a (2026-09-07)
  - adbd50f TDP (2026-09-08)
  - 5e7ee0b, befdfc9 (2026-09-09)
  - d1e01c3 matching + hwdb, ff48c25 home button, 93ddb40, 70b7439, 5242344 RGB zones (2026-09-10)
  - d775bfe AT keyboards (2026-09-14)
- `const.py` has an `"ONEXPLAYER 3"` entry: quirk `oxp3`, `rgb_secondary`, protocol `hid_v2_x2` (verified, https://github.com/hhd-dev/hhd/blob/master/src/hhd/device/oxp/const.py).
- hwdb `evdev:name:HID 1a86:fe00:dmi:*:pnONEXPLAYER3:*` sets `KEYBOARD_KEY_700e2=f17` (verified, https://github.com/hhd-dev/hhd/blob/master/usr/lib/udev/hwdb.d/83-hhd.hwdb).
- The latest **release is v4.1.12 (2026-07-10)**, which predates all of this. CachyOS packages `hhd 4.1.12-1` **[device: pacman -Si]**, which does **not** support OXP3.
- Conflicts with the kernel driver [inference]:
  - hhd programs the MCU button map itself (M1/M2 → F15/F16, three 0xB4 pages), and hid-oxp also writes the map and re-applies it after resume.
  - hhd's hwdb remaps LeftAlt to F17, which is also hid-oxp's default M2 code.

**Steam-native / SDL**
- SDL master (21928ce2, 2026-10-06) has no OneXPlayer HIDAPI driver and no `1a86:fe00`/`1a2c` IDs. Without a mapper Steam sees a plain Xbox 360 pad: no paddles, Home or QAM, and no gyro.
- The CachyOS direction is steamos-manager + InputPlumber + steamos-powerbuttond.
  - The chwd generic `[handheld]` profile installs exactly these three, but its anchored `hwd_product_name_pattern` lacks `ONEXPLAYER 3`: https://github.com/CachyOS/chwd/blob/master/profiles/pci/handhelds/profiles.toml (verified).
  - CachyOS wiki changelog 26.01: "Replaced HHD with steamos-manager and inputplumber".
- **Recommendation:** InputPlumber.
  - It is the distro-supported path, coexists with hid-oxp, gets `deck-uhid` from steamos-manager, and its OXP3 config is in review upstream.
  - hhd master is the fastest "everything incl. RGB + TDP" route, but it is unreleased, fights the CachyOS stack, and needs a patched steamos-manager for the Steam TDP slider.

### 1.5 Gyro path
See §3. hid-oxp has no IMU code, and all userspace stacks read IIO.

### 1.6 TDP (user requirement)

**Device state [device]**
- `intel-rapl:0` (MSR) package: PL1 = 25 W, PL2 = 52 W.
- `intel-rapl-mmio:0` package: PL1 = 35 W, PL2 = 52 W.
- `platform_profile` choices `low-power balanced performance`, provided by processor_thermal "SoC Power Slider".
- `intel_lpmd` and power-profiles-daemon are present (ppd disabled).

**Reference repo finding:** the GPU obeys the MSR PL1, while TDP tools and firmware AC/DC switching write only the MMIO PL1. Their fix keeps MSR PL1 = MMIO PL1 (v1.6.0, commit 5750ad9, 2026-09-25). The 25 W vs 35 W split is confirmed on this unit.

**steamos-manager** (CachyOS 26.4.1; main 08c45b54, 2026-09-15)
- TDP backends: `AmdgpuHwmon`, `FirmwareAttribute` and `RemoteInterface`. **No Intel RAPL backend.**
- With no `[tdp_limit]` it falls back to `RemoteInterface` (cbc992c, 2026-01-16).
- Remotes register via a TOML in `/etc/steamos-manager/remotes.d/` with a `[TdpLimit1]` section holding `bus_name` and `object_path`, on the **system bus**. They can only fill holes. The README lists the remotable interfaces as BatteryChargeLimit1, CpuBoost1, FanControl1, PerformanceProfile1, **TdpLimit1** and others (verified, https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/main/README.md#interoperability).
- `TdpLimit1` has the properties `TdpLimit` (u, rw), `TdpLimitMin` (u) and `TdpLimitMax` (u) (`data/interfaces/com.steampowered.SteamOSManager1.xml`).
- Device tomls are read only from `/usr/share/steamos-manager/devices` (`hardware.rs:45`). There is no OXP3 toml.

**PowerStation** v0.8.3 (5f692d7, 2026-10-04)
- Has an OXP3 entry (8-35 W): 0813052, 2026-08-23, "fix: Add ONEXPLAYER 3 TDP support".
- It writes **only** `intel-rapl-mmio` [per source read by sub-agent], which leaves the MSR cap at 25 W.
- No steamos-manager bridge, and not in CachyOS repos.

**hhd master** e5b6a4a (2026-09-07)
- Writes PL1 on every `intel-rapl*:*` package zone, covering both MSR and MMIO.
- OXP3 preset: pl1 35 / pl2 37 (adbd50f).
- Steam slider integration needs Bazzite's patched steamos-manager (hhd v4.1.0 release notes).

**Best Steam-Deck-like option [inference]:** a ~100-line system-bus service implementing `com.steampowered.SteamOSManager1.TdpLimit1`, registered with `/etc/steamos-manager/remotes.d/oxp3-tdp.toml`.
- It writes PL1 to both `intel-rapl:0` and `intel-rapl-mmio:0` and sets PL2 to max(PL1, …).
- It reasserts on AC plug/unplug, because the firmware resets the limits (reference repo README).
- Min/max: hhd uses min 3 W, PowerStation 8-35 W; the reference repo users run 50 W on AC. The safe default range is 8-35 W, with up to 52 W (firmware PL2) as an option.
- Steam's per-game TDP slider then works natively.

---

## 2. oxpec (EC platform driver)

- **Why it does not load [device]:** the DMI modalias is `…svnONE-NETBOOK:pnONEXPLAYER3:…rvnONE-NETBOOK:rnONEXPLAYER3:rvr1002-B:…`.
  - The module alias `rn*ONEXPLAYER*` matches (spaces are stripped), so udev may try to load it.
  - But `oxp_platform_init()` does `dmi_first_match()` against `DMI_EXACT_MATCH(DMI_BOARD_NAME, …)` entries and returns `-ENODEV` (`oxpec.c` l.977-993).
  - `hwmon` shows only `acpi_fan`, whose `fan1_input` returns EIO.
- **No `force_load`:** there is no `module_param` in `oxpec.c` (torvalds master, fetched 2026-10-07).
- **The upstream patch exists and was accepted:** "[PATCH v1 2/2] platform/x86: oxpec: Add OneXPlayer 3 quirk", Antheas Kapenekakis, 2026-09-20, https://lore.kernel.org/all/20260920190438.3444923-2-lkml@antheas.dev/ (mbox verified).
  - It adds `DMI_MATCH(DMI_BOARD_VENDOR,"ONE-NETBOOK")` + `DMI_EXACT_MATCH(DMI_BOARD_NAME,"ONEXPLAYER 3")` → `oxp_g1_i`.
  - Commit text: "uses the same registers as the G1 Intel edition… Battery bypass, capacity limits, fan curves, fan tachometer, and turbo button override were confirmed to work."
  - Derek Clark gave Reviewed-by on 2026-09-20.
  - **Ilpo Järvinen, 2026-10-05: "I took this series as is"**, https://lore.kernel.org/all/272b2d3c-243a-cfb8-bf34-c6cffc7e5fec@linux.intel.com/ (verified). Sub-agent reports it as fdf2034a0e82 in pdx86 `review-ilpo-next` [unverified hash].
  - No `Cc: stable` tag, so expect it in v7.4 (merge window after v7.3), not 7.2.y, unless CachyOS picks it up. Not in CachyOS kernel-patches as of 17bb0bb.
- **What `oxp_g1_i` gives** (current oxpec.c):

  | Function | Register / interface |
  |---|---|
  | Fan tach | EC 0x58 (16-bit) |
  | `pwm1_enable` | 0x4A |
  | `pwm1` | 0x4B, EC range 0-184 scaled to 0-255 |
  | Turbo takeover `tt_toggle` | 0xEB mask 0x40 |
  | Charge limit `charge_control_end_threshold` | 0xA3 |
  | `charge_behaviour` | 0xA4 (auto / inhibit-charge / inhibit-charge-awake) via the `oxp-charge-control` power-supply extension |
  | Turbo LED (`tt_led`) | Not exposed: X1 only |

  - The DSDT EC field map on this unit corroborates the fan registers: `UFAN` at 0x4B (16-bit) and `FSPD` at 0x58 (16-bit) in `\_SB.PC00.LPCB.H_EC` region `ECF2` **[device: decompiled DSDT]**.
- **Risks of emulating another board** (e.g. a DKMS fork that matches OXP3 to a different map):
  - The register maps differ between boards. Examples: 232b41d3c2ce "Fix turbo register for G1 AMD"; APEX charge registers moved to 0xE5/0xE6 in patch 1/2 of the same series.
  - Writes are raw `ec_write`s with no validation.
  - Only `oxp_g1_i` is vendor/author-confirmed for OXP3. Do not use `oxp_x1` (unverified turbo-LED register 0x57).
- **Steam integration:**
  - Once `charge_control_end_threshold` exists on BAT0, steamos-manager's `battery_charge_limit` `method = "acpi_sb"` works. It reads `/sys/bus/platform/drivers/acpi-battery/PNP0C0A:00/firmware_node/power_supply/*/charge_control_end_threshold`, and that path exists here **[device]**. It needs a device toml (§Recommended actions).
  - Fan: Steam's fan toggle (`STEAM_ENABLE_FAN_CONTROL=1` in the session) needs a FanControl1 implementation, which does not exist for oxpec. Leave the EC in auto.

## 3. IMU / gyro

- **Hardware [device]:**
  - ACPI `\_SB.PC00.I2C1.SPBA`, `_HID`/`_CID` `10EC5280`, `I2cSerialBusV2(0x0068, 100 kHz, "\_SB.PC00.I2C1")`, `_STA` 0x0F (SSDT26, OEM ID `Rtd3`/`I2C_DEVT` rev 0x1000).
  - **`i2cget -y 1 0x68 0x00` returns `0x27` = BMI260** (BMI160 would be 0xD1, BMI270 0x24, per `bmi270_core.c` defines).
  - The firmware also provides a mount-matrix method named `ROMS` returning `"0 1 0" / "1 0 0" / "0 0 -1"`.
- **Why no IIO device:** `bmi160_i2c` claims `10EC5280`. That is a firmware-bug workaround, ca2f16c31568 (v6.9), "Some manufacturers like GPD, Lenovo or Aya used the incorrect ID 10EC5280 for bmi160".
  - bmi160 soft-resets and then reads the chip ID. This fails with `-121` (`Error reading chip id`) **[device]**.
  - `bmi270_i2c` supports the BMI260 but matches only `BMI0160`/`BMI0260` (torvalds `bmi270_i2c.c`).
  - `bmi260-init-data.fw` is present (`linux-firmware-other 20260916`) **[device/host]**.
- **Upstream fix status:** Philip Mueller, "[PATCH 0/4] iio: imu: bmi270: Match PNP ID found on gaming handheld firmwares", 2026-07-31, https://lore.kernel.org/all/20260731195325.44453-1-philm@manjaro.org/. Patch 2/4 adds `10EC5280` → bmi260 to bmi270.
  - Jonathan Cameron (2026-08-02) pushed back: the ID is shared with bmi160, so this should be a platform quirk.
  - No v2. **Stalled.**
- **Fix options:**
  1. **ACPI table upgrade (recommended).** Ship the device's own SSDT26 with only `_HID`/`_CID` changed to `BMI0260` and the OEM revision bumped to 0x1001. Load it with mkinitcpio's `acpi_override` hook (`/etc/initcpio/acpi_override/*.aml`, present in mkinitcpio 42.2) and add `acpi_override` to `HOOKS`.
     - `CONFIG_ACPI_TABLE_UPGRADE=y` in the deckify kernel **[device]**.
     - The reference repo ships exactly this table, `gyro/SSDT26-oxp3-imu.dsl`. Diffed against this unit's SSDT26, the only differences are the OEM revision and `_HID`/`_CID`; the remaining hunks are iasl decompiler representation of identical resource buffers **[device]**.
     - Must be gated on BIOS 5.09 / table checksum, because a BIOS update can change SSDT26.
     - Optionally add a `_DSD` `mount-matrix` property so `in_mount_matrix` is populated. bmi270 reads it via `iio_read_mount_matrix()` [inference].
  2. hhd-dev/bmi260 DKMS. It matches 10EC5280 and reads the `ROMS` matrix, but is out of tree (HEAD 2d764db, 2025-02-28). Requires blacklisting `bmi160_i2c`.
  3. A one-line kernel patch adding `10EC5280` to bmi270 plus blacklisting bmi160. This needs a custom kernel.
- **Mount matrix for userspace:**
  - InputPlumber PR #672 uses an x/y swap.
  - The reference repo derived the following empirically for the deck-uhid frame (2026-09-19 pose tests):

    ```yaml
    mount_matrix:
      x: [0, -1, 0]
      y: [-1, 0, 0]
      z: [0, 0, -1]
    ```

  - The reference repo additionally needed a **patched InputPlumber 0.78** to order gyro fields the way Steam's Deck HID path expects, plus a drift-relaxing filter.
  - [unverified] whether stock InputPlumber 0.81 + PR #672 config gives correct axes on deck-uhid. Test before shipping.

## 4. Display

- **Panel [device]:** EDID manufacturer SDC, product 17153 = **0x4301**, "AMS881KB01-0", OLED, week 40/2024.
  - DTD 1920x1200 @144 Hz (pixel clock 380.16 MHz).
  - Range limits 30-144 Hz; DisplayID adaptive-sync 30-144.
  - HDR static metadata: max 1107 / avg 475 / min 0.0005 nits, BT2020RGB, ST2084.
  - Connector props: `panel orientation`=Normal, `vrr_capable`=1, `max bpc`=12, Colorspace currently BT2020_RGB.
- **Orientation:** native landscape. No `drm_panel_orientation_quirks` entry is needed.
  - Upstream OneXPlayer entries cover only "ONE XPLAYER" models (d3cbc6e323c9, b24dcc183583).
  - CachyOS handheld.patch adds X1/F1/G1 entries, not OXP3.
  - Nothing to do for gamescope orientation.
- **gamescope profile:** the same panel is used in the Lenovo Legion Go 2. Upstream `scripts/00-gamescope/displays/lenovo.legiongo2.oled.lua` matches `display.vendor == "SDC" and display.product == 0x4301` (verified, https://github.com/ValveSoftware/gamescope/blob/master/scripts/00-gamescope/displays/lenovo.legiongo2.oled.lua; commits 94667ca 2026-04-25, 9eeb855 2026-08-04, first in tag **3.16.29**).
  - Dynamic refresh: 48-144 Hz with a vertical-front-porch table identical to the reference repo's derived values (60 Hz → 1904, 144 Hz → 56).
  - PQ HDR with `content_driven = true` and **`software_backlight = true`**, because "the panel ignores hardware backlight control while in PQ mode".
  - That is the same root cause the reference repo hit (black panel / dead brightness slider under HDR). They worked around it with a gamma-2.2 lua.
- **Installed:** gamescope 3.16.25 from `cachyos-v3`. The `cachyos` repo has 3.16.30 and `extra` has 3.16.31 **[device: pacman -Si]**, so the v3 repo is lagging. [inference] Upgrading to ≥3.16.29 picks up the profile automatically, and no local lua is needed.
- **xe PSR / Panel Replay [device]:** `Selective fetch area calculation failed in pipe A` and `*ERROR* mismatch in vsc dp vsc sdp` (BT.2020 10 bpc expected vs sRGB found).
  - Reported for this exact device by Fredrik Nicol on intel-gfx, 2026-08-26, https://lore.kernel.org/all/CAE3tsCV8SS0Tb51Wj=nuh9pJ=fLMwc=4qswFec3_dw7dHT6D5Q@mail.gmail.com/.
    - `xe.enable_panel_replay=0` or `xe.enable_psr=0`: display works but tearing remains.
    - Disabling selective fetch gives a black screen.
    - Jani Nikula requested a freedesktop bug (2026-09-09).
  - Related pending fixes: Jouni Högander's 8-patch PSR series, 2026-09-29, https://patchwork.kernel.org/project/intel-gfx/patch/20260929094434.77129-2-jouni.hogander@intel.com/ (1/8 clears the selective-fetch area when duplicating plane state). Not merged.
- **DSB:** the reference repo's `xe enable_dsb=0` (DSB poll error flood) is not reproduced here. There were 0 `DSB 0 poll error` lines this boot and last boot **[device]**.
- **VRR:** the reference repo's "~74 fps with VRR on" issue (#1, closed 2026-09-22 as not planned) was dropped as "not reproducible after the 20260921.1000 update" (commit a370e8b). That was on a different kernel/gamescope; [unverified] here.

## 5. Audio

- **[device]**
  - SOF PTL (`sof-audio-pci-intel-ptl`), firmware 2.15.0.1 (`sof-firmware 2026.09.1`), topology `sof-ipc4-tplg/sof-hda-generic.tplg`, machine `skl_hda_dsp_generic`.
  - HDA codec **Realtek ALC245**, subsystem `0x1f751602`: speaker pin 0x17 (fixed, internal), HP 0x21, internal mic 0x12, jack mic 0x19.
  - NHLT shows no DMICs and BT on SSP2. Card name `ONE_NETBOOK-ONEXPLAYER3-Defaultstring`.
- **The other ACPI audio-ish nodes are disabled [device]:**
  - `10EC1308` (RT1308) at `\_SB.PC00.I2C3.HDC1` has `_STA=0`. Its `_STA` returns 0x0F only when `I2SC == 2` (DSDT).
  - `INT34C2` has `_STA=0`.
  - The six `TXNW3643` (`\_SB.FLM0-5`) all have `_STA=0`. SSDT2's `FHCI` method returns `"TXNW3643"` for flash-module type 0.
  - **TXNW3643 is the TI LM3643 camera flash/IR LED driver, not an amplifier** (an LM3643 flash driver is under review on linux-leds, v2 2026-09-28).
  - These are reference-BIOS template nodes.
- **No smart-amp driver is needed.** No OneXPlayer/ONE-NETBOOK quirk exists in `sound/hda/codecs/realtek/alc269.c` (torvalds, tiwai for-next as of about 2026-10-05). TAS2781 HDA side-codec IDs do not include TXNW3643.
- **Current state [device]:** ALSA `Master` and `Speaker` are at 0 % and off. The PipeWire default sink "Speaker" is at 0.00 and MUTED; Headphone is at 60 % but off.
  - The reference repo removed its "speakers occasionally silent after boot" note on 2026-09-26 (dc6fe57), saying "not seen since earlier fixes".
  - [unverified] actual speaker output, which needs a listening test.

## 6. Suspend / resume and power button

- **s2idle [device]:** `/sys/power/mem_sleep` shows `[s2idle] deep`. The kernel prints "Low-power S0 idle used by default". `intel_pmc_core` is loaded. `slp_s0_residency_usec` was non-zero after the 19:48 suspend, so S0ix was entered.
- **NVMe resume failure [device]:**
  - The drive is a `Predator SSD GM7 1TB`, PCI `1dee:1602`, fw `BM345CVN`.
  - At boot: `nvme 0000:01:00.0: platform quirk: setting simple suspend`. The DSDT `_DSD` sets `StorageD3Enable = One`.
  - On resume: `nvme nvme0: Disabling device after reset failure: -19`, followed by btrfs `Transaction aborted (error -5)` and `forced readonly`.
  - This is the same failure as reference repo `issues/04` item 3.
  - Upstream `drivers/nvme/host/pci.c` has no quirk for `0x1dee` (fetched 2026-10-07).
  - Fix: `nvme.noacpi=1`, which disables the ACPI StorageD3 hint. The parameter exists and currently reads `N` **[device]**. The reference repo reports S0ix still reached with it (2/2 tests).
  - On this CachyOS install the cmdline comes from sdboot-manage (`LINUX_OPTIONS="nowatchdog quiet splash"` in `/etc/sdboot-manage.conf`) **[device]**.
- **Power button [device]:** ACPI `PNP0C0C` and `LNXPWRBN` "Power Button" (event2, event3). logind has `HandlePowerKey=ignore` from cachyos-handheld `/etc/systemd/logind.conf.d/steam-deckify.conf`. **steamos-powerbuttond is not installed**, so Game Mode currently ignores the button.
  - steamos-powerbuttond v4.2 (https://gitlab.steamos.cloud/holo/powerbuttond, 9392e68, 2026-02-26; CachyOS `steamos-powerbuttond 4.2-1`):
    - Its hwdb tags any device with `KEY_POWER`, `SW_LID`, or LeftMeta+F16 as `STEAMOS_POWER_BUTTON`.
    - A press arms `alarm(1)`. A release within 1 s sends `steam://shortpowerpress`, which suspends via Steam. A 1 s hold or Meta+F16 sends `longpowerpress` (`powerbuttond.c` l.245-305, verified).
  - [inference] The ACPI button driver emits press and release back to back on notify, so long-press probably cannot be detected via ACPI. Short press is the important one.
  - [inference] The `HID 1a86:fe00` keyboard advertises LeftMeta+F16, so powerbuttond will watch it too. Bare F16 (M1) is ignored; only Meta+F16 triggers `longpowerpress`.
- **Volume rocker:** the EC drops releases (reference repo `issues/04` item 1; hhd #342).
  - The reference repo grabs the AT keyboard with a Python uinput proxy.
  - Cleaner fix: systemd hwdb force-release. `60-keyboard.hwdb` documents `!` as "add the scan code to the AT keyboard's force-release list". Many laptops use `KEYBOARD_KEY_ae=!volumedown` / `KEYBOARD_KEY_b0=!volumeup`.
  - Current `/sys/bus/serio/devices/serio0/force_release` = `369-370` **[device]**.
  - [unverified] that OXP3 uses `ae`/`b0`. Confirm with `evtest` `MSC_SCAN` while pressing the rocker.

## 7. Changes in the last ~7-14 days (2026-09-23 to 2026-10-07)

| Date | Change | Relevance |
|---|---|---|
| 2026-10-05 | Ilpo Järvinen took "oxpec: Fix Apex charge limit control" and "Add OneXPlayer 3 quirk" (lore, above) | Fan / charge / turbo for OXP3, upstream v7.4 |
| 2026-10-04 | CachyOS kernel-patches 17bb0bb "7.2: Update handheld branch"; linux-cachyos 7.2.9-1 (ee39638, 2026-10-03) | No OXP3 content |
| 2026-10-04 | PowerStation v0.8.3 (5f692d7); OXP3 TDP entry since 0813052 (2026-08-23) | MMIO-only RAPL writes |
| about 2026-10-03 | Stable 7.2.y: "HID: hid-oxp: use cancel_delayed_work_sync() in remove" | Rebind/remove UAF fix |
| 2026-09-29 | Högander xe PSR series v1 (not merged) | Selective-fetch errors |
| 2026-09-29 | CachyOS-PKGBUILDS gamescope 3.16.31 (7aa5ff0) | Brings the SDC/0x4301 profile |
| 2026-09-26 / 25 | Reference repo v1.6.1 / v1.6.0 (TDP MSR sync, Wi-Fi offline) | Leads, reviewed below |
| 2026-09-23 | hhd issue #342 (OXP3 sticky volume rocker) | Volume keys |
| 2026-09-20 | InputPlumber PR #672 updated (OXP3 + X2 Mini Pro); oxpec OXP3 patch posted | Controller config |
| 2026-09-14 | InputPlumber v0.81.0 (no OXP3); hhd d775bfe | — |
| 2026-09-10 | hid-oxp X2-family series v1 (OXP3) | Pending v2 |

Nothing OXP3-specific landed in a CachyOS package in this window: cachyos-handheld 1.4.0 is unrelated, and chwd has no OXP3 entry.

---

## Reference repo review: HHHHanasak1/onexplayer3-steamos-setup

Reviewed at ea371b3 (2026-09-26). It targets SteamOS 3.10 (kernel 7.2.0/7.2.4-valve), not CachyOS.

| Step (their version) | Verdict for CachyOS 7.2.9 | Evidence |
|---|---|---|
| 0. Wi-Fi/BT firmware for BE201 (`linux-firmware-intel`) | **Not needed** | CachyOS ships `linux-firmware-intel 20260916`; iwlwifi loads `sc-a0-wh-b0-c106.ucode` and BT `ibt-00a0-01a1` **[device]** |
| 1. `nvme.noacpi=1` (only for GM7 `1dee:1602`) | **Adopt** (via sdboot-manage `LINUX_OPTIONS`, gated on `1dee:1602`) | Same SSD, same `-19` failure and btrfs going read-only reproduced today **[device]**; no upstream quirk |
| 2. `options xe enable_dsb=0` | **Not needed** (re-evaluate if the flood appears) | 0 DSB errors on 7.2.9 **[device]**; purely cosmetic per their own notes |
| 3. gamescope gamma-2.2 HDR lua + 30-144 Hz modegen | **Adapt → replace with gamescope ≥3.16.29** | Upstream `lenovo.legiongo2.oled.lua` matches SDC 0x4301 (this EDID) with an identical VFP table and PQ + `software_backlight`. Only consider a local lua if gamescope stays at 3.16.25 |
| Volume key evdev proxy (grabs i8042, Python uinput) | **Adapt** → hwdb `!` force-release | Same symptom (hhd #342). The hwdb route has no daemon and no grab, so powerbuttond/gamescope still see the raw device. Scancodes need confirming |
| InputPlumber composite yaml + capability map (Home 0x24 → Guide, Console → QAM, KB → OSK, no paddle swap) | **Adapt** | Base on upstream PR #672 (`oxp9` map) plus their Home-key (0x24) and paddle-order findings. Drop their exclusion of the AT keyboard if the volume proxy is not used. Put it in `/etc/inputplumber/devices.d/` |
| Back paddles via hid-oxp (assert `gamepad_mode=xinput`, M1/M2 = F16/F17) | **Adopt (check only)** | Already the state on 7.2.9 **[device]**. No writes needed |
| Battery 101-104 % clamp (bind-mounts over sysfs) | **Not adopted (defer)** | Cosmetic. Here `energy_full` 90.3 Wh > design 84.5 Wh **[device]**. Bind-mounting sysfs is fragile; prefer an upstream acpi-battery fix or Steam/UPower clamping. Open question |
| TDP sync service (MSR PL1 := MMIO PL1 every 2 s) | **Adapt** | Root cause confirmed (MSR 25 W vs MMIO 35 W) **[device]**. Fold into a TdpLimit1 remote that writes both domains, instead of polling |
| Gyro: SSDT26 override (`BMI0260`) + patched InputPlumber 0.78 + drift filter | **Adapt.** Adopt the ACPI override via mkinitcpio `acpi_override` (not GRUB); re-test with stock InputPlumber 0.81 before carrying a fork | Chip ID 0x27 confirmed **[device]**; table diff equivalent **[device]**; `CONFIG_ACPI_TABLE_UPGRADE=y` **[device]** |
| Lighting via HueSync fork (not in the pack) | **Not needed / defer** | hid-oxp Gen3 RGB is pending upstream; hhd master supports zones |
| "Never unbind/rebind hid-oxp" | **Adopt as a rule** | Oops trace in their repo; the remove UAF fix is now in 7.2.y, but the rebind path is untested |
| Install method (SteamOS recovery, `nomodeset`, `steamos-readonly disable`) | **Not applicable** | CachyOS installer and read-write root |

---

## Recommended actions for postinstall scripts

These are ordered for `modules/NN-*.sh`. **C** = confirmed by primary source and/or device. **S** = speculative and needs a test on the device.

1. **`10-nvme-suspend`** (C)
   - If `/sys/class/nvme/nvme*/device/{vendor,device}` is `0x1dee/0x1602`, append `nvme.noacpi=1` to `LINUX_OPTIONS` in `/etc/sdboot-manage.conf`.
   - Run `sdboot-manage gen`, then `need_reboot`.
   - Verify with `cat /sys/module/nvme/parameters/noacpi` = `Y` and the absence of `platform quirk: setting simple suspend` in dmesg.
   - Only then test suspend.
2. **Steam Deck stack packages** (C): `pkg_install steamos-manager steamos-powerbuttond inputplumber`. These are the CachyOS repo versions 26.4.1 / 4.2 / 0.81.0, which the chwd profile would install if it matched "ONEXPLAYER 3".
   - Keep logind `HandlePowerKey=ignore` (powerbuttond handles it).
   - Enable `inputplumber.service`. powerbuttond is pulled in by `gamescope-session.service.wants` (verify the unit is linked after install).
3. **gamescope ≥ 3.16.29** (C for the profile match, S for the repo route): get gamescope from the `cachyos` (3.16.30) or `extra` (3.16.31) repo, or wait for `cachyos-v3` to catch up. Verify that `gamescope` logs `[lenovo_legiongo2_oled] Matched vendor: SDC`.
4. **InputPlumber OXP3 config** (S):
   - Install `/etc/inputplumber/devices.d/50-onexplayer_3.yaml`, based on PR #672 head 7116a1b8, with:
     - `matches: dmi_data product_name "ONEXPLAYER 3", sys_vendor "ONE-NETBOOK"`
     - Sources: xpad evdev; `HID 1a86:fe00` keyboard (`unique: false`); hidraw `1a86:fe00` iface 2; IIO `bmi260`
     - Targets `deck-uhid`, `keyboard`, `mouse`
   - Add a capability map with these entries:
     - Ctrl+Alt+Meta → QuickAccess
     - Ctrl+Meta+O → Keyboard (OSK)
     - native `Keyboard` (vendor 0x24 Home) → Guide
     - no paddle swap
   - Avoid `QuickAccess2` on deck-uhid: the reference repo saw R1 latch.
   - Restart inputplumber. Test every button in Steam's controller tester.
5. **steamos-manager device toml** (S): steamos-manager reads only `/usr/share/steamos-manager/devices`, so ship this as a tiny local package (`onexplayer3-support`) rather than writing into `/usr` directly.

   ```toml
   [[device]]
   dmi.sys_vendor = "ONE-NETBOOK"
   dmi.product_name = "ONEXPLAYER 3"
   device = "onexplayer_3"
   friendly_name = "ONEXPLAYER 3"

   [gpu_performance]
   driver = "intel"

   [inputplumber]
   target_devices = ["deck-uhid", "keyboard", "mouse"]

   [battery_charge_limit]   # only once oxpec loads
   method = "acpi_sb"
   ```

   - Leave out `[tdp_limit]` so the remote is used.
6. **TDP remote** (S, design confirmed against the steamos-manager README/XML):
   - A system-bus service, e.g. `org.oxp3.Tdp` at `/org/oxp3/Tdp`, implementing `com.steampowered.SteamOSManager1.TdpLimit1`.
   - `TdpLimit` set → write `constraint_0_power_limit_uw` on **both** `intel-rapl:0` and `intel-rapl-mmio:0`, and raise PL2 if needed.
   - Min 8 W, max 35 W by default; 52 W optional.
   - Re-apply on `power_supply` change uevents.
   - Register it with `/etc/steamos-manager/remotes.d/oxp3-tdp.toml`:

     ```toml
     [TdpLimit1]
     bus_name = "org.oxp3.Tdp"
     object_path = "/org/oxp3/Tdp"
     ```

   - Until that exists, the minimal fallback is the reference repo's MSR := MMIO PL1 sync service.
7. **oxpec** (C patch, S packaging):
   - Build `oxpec` out of tree via DKMS from 7.2.9 `drivers/platform/x86/oxpec.c` plus Antheas' 7-line patch (`oxp_g1_i`). The installed module must take precedence (DKMS installs to `updates/`).
   - Drop it once CachyOS or mainline carries the patch.
   - Do not map OXP3 to any other board type.
   - After loading, keep `pwm1_enable` = auto. Optionally set `charge_control_end_threshold` (e.g. 80) via steamos-manager's battery-limit UI.
8. **Gyro** (C for the root cause and override mechanics, S for the axes):
   - Put the compiled `SSDT26` (HID/CID → `BMI0260`, OEM rev 0x1001) in `/etc/initcpio/acpi_override/oxp3-imu.aml` and add `acpi_override` to `HOOKS` via `/etc/mkinitcpio.conf.d/oxp3.conf`.
   - Gate it on `bios_version == 5.09` **and** the sha256 of `/sys/firmware/acpi/tables/SSDT26` matching the table it was built from.
   - Blacklist `bmi160_i2c` (cosmetic; avoids the failed probe).
   - Verify `/sys/bus/iio/devices/iio:device*/name` and then the axes in Steam's gyro test.
9. **Volume keys** (S): create `/etc/udev/hwdb.d/61-oxp3-volume.hwdb`:

   ```
   evdev:atkbd:dmi:bvn*:bvr*:svnONE-NETBOOK:pnONEXPLAYER3:*
    KEYBOARD_KEY_ae=!volumedown
    KEYBOARD_KEY_b0=!volumeup
   ```

   - Then run `systemd-hwdb update` and `udevadm trigger -s input`.
   - Confirm the scancodes with `evtest` first.
10. **Audio** (C for the hardware path): no driver work. Unmute the speaker sink and set a sane default volume once, in the user session (`wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.5`). Then do a listening test.
11. **Do not:**
    - unbind or rebind hid-oxp, or write raw reports to `1a86:fe00` hidraw;
    - install hhd 4.1.12 from the CachyOS repo (no OXP3 support, conflicts with InputPlumber);
    - set `xe enable_dsb=0` without a reproduced problem.

## Open questions

- Does stock InputPlumber 0.81 with the PR #672 config give correct gyro axes and paddles on `deck-uhid`, or is the reference repo's IP fork (field ordering) still required?
- Does mainline hid-oxp's two-page Gen2 button-map write clobber any OXP3 factory mappings? The Aldea patch 12 says OXP3 needs format 0x02 with three pages. When will the hid-oxp v2 series land, and will CachyOS carry it?
- Will CachyOS pick up the oxpec OXP3 quirk into the 7.2/7.3 handheld patch before v7.4?
- Volume-rocker scancodes (`ae`/`b0`?) and whether force-release fully fixes the repeat.
- Long-press power: does the EC deliver a held state at all, or does ACPI notify emit an instant press+release? This needs `evtest` on event2/event3.
- PSR/selective-fetch tearing on xe: is there a usable workaround short of the upstream fix? `enable_panel_replay=0` reportedly does not fix tearing.
- Battery `energy_full` > design (90.3 vs 84.5 Wh): is this worth a fix, given that Steam reads `capacity`?
- Whether the turbo-takeover (`tt_toggle`) changes what the ONEX/Console key emits on OXP3. Not tested; oxpec is not loaded.
- The gamescope `cachyos-v3` repo lag (3.16.25 vs 3.16.30 in `cachyos`): is it intentional?
