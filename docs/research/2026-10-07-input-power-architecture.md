# Controller, TDP and power-button architecture (decided 2026-10-07)

Produced by a workflow: three source-verified plans (hhd-git all-in-one, SteamOS-native, hybrid), three judges (Deck UX, robustness, adversarial verification), one synthesis. Device checks were read-only.

## Recommendation

Adopt the SteamOS-native stack, built from stock CachyOS repo packages. It merges Plans B and C and drops Plan A (hhd):

- **Controller.** InputPlumber 0.81.0 with a local OXP3 composite config and a local capability map, outputting the `deck-uhid` target. This alone fixes the "Xbox 360 controller" complaint: InputPlumber hides the raw xpad 045e:028e and gives Steam a virtual Steam Deck controller with L4/R4, a Steam (Home) button, a QAM button, gyro and rumble.
- **TDP and GPU sliders.** Stock steamos-manager 26.4.1 with a valid OXP3 device TOML. The TOML includes `variant` (which C's version lacked) and lives in a small repo-built package, oxp3-support, instead of B's ExecStart drop-ins. A ~150-line root RAPL TdpLimit1 remote (local.oxp3.Tdp) feeds Steam's own QAM TDP slider and writes both RAPL package zones, MSR and MMIO. The GPU clock slider comes from steamos-manager's built-in Intel xe backend.
- **Power button.** steamos-powerbuttond 4.2 handles the short press in Game Mode.
- **Volume rocker.** A small hwdb force-release module covers the rocker's stuck-key bug.

**Modules, in run order:**
- 25-volume-keys
- 30-controller: InputPlumber. This is the module that answers the user's complaint, and it does not depend on any later module.
- 40-steamos-manager: oxp3-support, the TDP remote, GPU clocks.
- 45-power-button

They slot in beside the existing 10/15/20/50/60/70 modules. 30-controller must run after 20-gyro, because it needs the IIO device named bmi260.

**Defer** a patched InputPlumber with fixed gyro scaling until Steam's gyro test shows it is needed. **Never install** hhd/hhd-git, PowerStation, SimpleDeckyTDP or thermald next to this stack.

## Rationale

**Root cause.** The "Xbox 360" symptom is confirmed. Nothing in userspace owns the controller, so Steam sees the raw xpad device 045e:028e "Microsoft X-Box 360 pad". The 28de:11ff "Microsoft X-Box 360 pad 0" on the device is Steam Input's own virtual pad, which a real Deck also has. It stays after the fix, so C's acceptance check that expected it to disappear is wrong and has been dropped.

**Why B/C's stack over A (hhd):**
- Every Game Mode surface is Valve's own code path: deck-uhid, enforced by steamos-manager DeckService (inputplumber.rs:79-123); the remote fallback for the TDP slider (power.rs:171-198); the native Intel xe GPU backend; powerbuttond. There is no extra overlay or gesture layer to learn.
- Everything comes from official repos, and the input side is YAML only.
- InputPlumber only reads hid-oxp's hidraw frames. It never writes the MCU button map. That avoids A's real post-s2idle problem: hid-oxp and hhd both write the map, so after resume M2 would open the on-screen keyboard. It also avoids A's RGB/reset feedback-loop risk.
- A needs unreleased hhd master plus 2-3 local patches, a BETA output mode, a udev write into hid-oxp's sysfs, and still needs steamos-manager plus a bridge to reach Steam's slider.
- Two of C's arguments against hhd were refuted and are not used here: that a patched steamos-manager is needed, and that PPD must be masked for TDP. A loses on maintenance burden and conflict risk, not on those points.

**Grafts:**
- **From B:** a TOML that actually parses (`variant` is a required String in DeviceMatch, hardware.rs:126-132; checked in the source this session), and a unique capability-map id.
- **From C:** pacman-owned /usr/share TOML packaging instead of ExecStart drop-ins (robustness judge), the gated volume module, a hardened and group-restricted TDP remote, and Deck semantics for PL2 (the slider is a true cap).
- **From A:** the PL2 caveat and the RAPL zone facts. hhd's get_rapl() was run read-only on the device and found both package zones (MSR intel-rapl:0 and MMIO intel-rapl-mmio:0).

**Claims re-checked this session against v0.81.0 and v26.4.1:**
- InputPlumber creates a composite from the first matching config in sort order, and later sources join that composite (manager.rs:961-1110). So a /etc/inputplumber/devices.d/50-onexplayer_3.yaml beats an upstream file of the same name. Both are parsed, but ours claims the sources. This corrects both judges: removing ours when upstream lands would lose Home→Guide, because upstream's oxp9 map sends the Keyboard key to QuickAccess2 (Screenshot) and leaves Home to the default profile, which opens the OSK.
- No stock 50-onexplayer_*.yaml DMI glob matches "ONEXPLAYER 3", so nothing else claims the pad.
- 17 of 19 upstream steamos-manager TOMLs use targets [deck-uhid, keyboard, mouse].
- `[tdp_limit] method="remote_interface"` is a valid enum value.

Long-press power is impossible for every plan: acpi/button.c reports press and release back to back.

## Architecture

| Component | Source | Role |
|---|---|---|
| hid-oxp (kernel, untouched) | linux-cachyos-deckify 7.2.9-1; drivers/hid/hid-oxp.c v7.2.9 | Keeps the MCU in xinput mode (button_m1=KEY_F16, button_m2=KEY_F17) and exposes hidraw 1a86:fe00 iface 2 with 0xB2 vendor frames (0x22/0x23 paddles, 0x24 Home). Only read, never written; never unbound or rebound (known Oops). |
| bmi270_i2c + ACPI table upgrade | existing modules/20-gyro.sh (commit 3b01c21); device iio:device0 name=bmi260 | Provides the IMU that InputPlumber's IIO source matches (iio.rs:119 glob includes bmi260). |
| inputplumber | CachyOS cachyos-extra-v3 inputplumber 0.81.0-1.1 (upstream tag v0.81.0 = ea60d87). Do NOT build PR #672: it sits on 0.78.1 and would drop the 0.79.1 QAM-chord fix 50263d3. | Owns all controller input. Grabs and hides xpad 045e:028e, the MCU keyboard 'HID 1a86:fe00' input0 and the vendor hidraw, reads IIO bmi260, and emits one deck-uhid virtual Steam Deck controller (28de:12f0) plus keyboard and mouse targets. |
| /etc/inputplumber/devices.d/50-onexplayer_3.yaml (repo file) | PR #672 head 7116a1b (sources, phys paths, include filter, mount matrix) with target_devices changed from xbox-elite to deck-uhid and the capability map id changed to oxp3_local | Defines the OXP3 composite device. The same filename as upstream PR #672 plus /etc tie priority means this file wins once upstream ships one. |
| /etc/inputplumber/capability_maps.d/oxp3_local.yaml (repo file) | Mapping semantics from reference repo HHHHanasak1/onexplayer3-steamos-setup ea371b3 (reported working on IP 0.78 + deck-uhid) and the PR #672 ONEX chord | Home (gamepad Keyboard from 0x24) → Guide (Steam button). ONEX (Ctrl+Alt+Meta) → QuickAccess (Deck '...'). Keyboard key (Ctrl+Meta+O) → gamepad Keyboard, which the default profile turns into Guide+North = OSK. No paddle swap. QuickAccess2 is not used. |
| steamos-manager | CachyOS [cachyos] steamos-manager 26.4.1-1 (tag v26.4.1 = a0d399d) | Steam's system D-Bus API. Exposes TdpLimit1 (through the remote) and GpuPerformanceLevel1/manual GPU clock (Intel xe backend, tile0/gt0/freq0). The root DeckService keeps the InputPlumber composite on the TOML's target list. gamescope-session.target already Wants the user unit. |
| oxp3-support (local arch=any pacman package) | New: files/pkg/oxp3-support/PKGBUILD in this repo, built with makepkg and installed with pacman -U | Owns /usr/share/steamos-manager/devices/onexplayer-3.toml (the only path steamos-manager reads, hardware.rs:42), /usr/lib/oxp3/oxp3-tdp, /usr/lib/systemd/system/oxp3-tdp.service and /usr/share/dbus-1/system-services/local.oxp3.Tdp.service. pacman -Syu never touches them; a future upstream file with the same name produces a loud file conflict. |
| oxp3-tdp (TdpLimit1 RAPL remote) | New Python 3 + Gio (python-gobject) system-bus service in this repo; interface contract from steamos-manager v26.4.1 data/interfaces XML (TdpLimit u rw, TdpLimitMin u, TdpLimitMax u, in watts) and power.rs:613-660,757-783 | The only RAPL writer. Sets PL1 on intel-rapl:0 AND intel-rapl-mmio:0, with PL2 = PL1 below max and the firmware PL2 at max. Re-applies after resume and when the firmware resets values on AC/DC change. |
| steamos-powerbuttond | CachyOS [cachyos] steamos-powerbuttond 4.2-1 (tag v4.2 = 9392e68) | In Game Mode a short ACPI power press becomes steam://shortpowerpress (suspend). Started via gamescope-session.service.wants. In Desktop Mode PowerDevil handles the button (PowerButtonAction=1). |
| cachyos-handheld defaults (kept) | cachyos-handheld 1.3.2-2: logind HandlePowerKey=ignore, powerdevilrc, inert hhd@ override | Left untouched. HandlePowerKey=ignore must stay, or one press would suspend twice. |
| /etc/udev/hwdb.d/61-oxp3-volume.hwdb | Standard atkbd force-release pattern. Scancodes 0xae/0xb0 (E0 2E / E0 30 volume down/up) come from hhd issue #342 on OXP3 BIOS 5.09 | Forces a release for the EC-dropped volume-key releases on the AT keyboard. That keyboard stays outside InputPlumber so Steam's volume handler and gamescope keep reading it. |

## Module plan

### modules/25-volume-keys.sh

Fix the stuck or auto-repeating volume rocker (the EC drops key releases) without touching InputPlumber.

**Details**

1. require_onexplayer3.
2. write_file /etc/udev/hwdb.d/61-oxp3-volume.hwdb containing:
   evdev:atkbd:dmi:bvn*:bvr*:bd*:svnONE-NETBOOK:pnONEXPLAYER3:*
    KEYBOARD_KEY_ae=!volumedown
    KEYBOARD_KEY_b0=!volumeup
3. Only if write_file returned 0 (changed): `as_root systemd-hwdb update` and `as_root udevadm trigger -s input --action=change`.
Idempotent: install_file compares content and mode, so a rerun is a no-op.
The AT keyboard (event4, 0001:0001) is deliberately NOT added to InputPlumber.

**Verify**

1. `udevadm info /dev/input/by-path/platform-i8042-serio-0-event-kbd | grep -i KEYBOARD_KEY` shows ae and b0.
2. `cat /sys/bus/serio/devices/serio0/force_release` now includes 174 and 176 (0xae, 0xb0) besides 369-370.
3. Physical test: `sudo evtest` on the AT keyboard shows MSC_SCAN ae/b0 with an immediate release for each press. In Game Mode, volume steps once per press and never sticks.
4. If evtest shows different scancodes, change the two lines.

**Risk:** Low. Scancodes are not yet confirmed on this unit by evtest; wrong codes simply have no effect. Holding a volume key no longer auto-repeats.

### modules/30-controller.sh

The user's request: make the built-in controller appear to Steam as a Steam Deck controller instead of an Xbox 360 pad, with paddles (L4/R4), Home (Steam), ONEX (QAM), Keyboard key (OSK), gyro and rumble.

**Details**

Runs after 20-gyro, because it needs iio name=bmi260.

1. **Guard (read-only).**
   - require_onexplayer3.
   - die if `pacman -Qq hhd hhd-git adjustor powerstation powerstation-bin inputplumber-git thermald` finds anything, with a message telling the user to remove it; never auto-remove.
   - warn if ~/homebrew/plugins contains SimpleDeckyTDP or PowerControl.
   - Read-only asserts, warn only: /sys/bus/hid/drivers/hid-oxp/*/gamepad_mode == xinput; /sys/bus/iio/devices/iio:device0/name == bmi260 (warn 'gyro unavailable, run 20-gyro + reboot').
   - Never write hid-oxp sysfs; never unbind.
2. **Packages:** `pkg_install inputplumber`.
3. **Composite config.** install_file files/etc/inputplumber/devices.d/50-onexplayer_3.yaml:
   - version 1, kind CompositeDevice, name 'ONEXPLAYER 3', single_source false.
   - matches: dmi_data product_name 'ONEXPLAYER 3', sys_vendor ONE-NETBOOK.
   - source_devices:
     - (a) group gamepad, evdev name 'Microsoft X-Box 360 pad', phys_path usb-0000:00:14.0-7/input0, handler event*.
     - (b) group keyboard, evdev name 'HID 1a86:fe00', phys_path usb-0000:00:14.0-5/input0, handler event*, events exclude ['*'] include [Keyboard:KeyLeftCtrl, Keyboard:KeyLeftAlt, Keyboard:KeyLeftMeta, Keyboard:KeyO]. Grabbing this node also swallows the F16/F17 paddle keystrokes, so they no longer leak as keys.
     - (c) group gamepad, hidraw vendor_id 0x1a86, product_id 0xfe00, interface_num 2.
     - (d) group imu, iio name bmi260, mount_matrix x [0,1,0] y [1,0,0] z [0,0,1]. This is PR #672's matrix, written for stock InputPlumber axis handling. The reference repo's x [0,-1,0] y [-1,0,0] z [0,0,-1] is kept as a commented alternative, because it was posed against a patched IP.
   - options auto_manage true.
   - target_devices [deck-uhid, keyboard, mouse]. This matches the TOML in 40, so DeckService only re-sets targets once per boot.
   - capability_map_id oxp3_local.
4. **Capability map.** install_file files/etc/inputplumber/capability_maps.d/oxp3_local.yaml:
   - version 1, kind CapabilityMap, id oxp3_local.
   - Mapping 'Home': source gamepad button Keyboard → target gamepad button Guide.
   - Mapping 'ONEX': keyboard [KeyLeftCtrl, KeyLeftAlt, KeyLeftMeta] → gamepad QuickAccess.
   - Mapping 'Keyboard key': keyboard [KeyLeftCtrl, KeyLeftMeta, KeyO] → gamepad Keyboard.
   - filtered_events: [].
   - Map outputs go to handle_event and do not chain (composite_device/mod.rs:1435-1470), so the Keyboard key does not turn into Guide.
   - Paddle fallback, PADDLE_SOURCE=keys (off by default): add Keyboard:KeyF16/KeyF17 to the (b) include list and map KeyF16→LeftPaddle1, KeyF17→RightPaddle1. Use it only if the acceptance test shows that hidraw 0x22/0x23 frames never arrive; never enable both paths at once.
5. **Upstream check.** If /usr/share/inputplumber/devices/50-onexplayer_3.yaml exists, warn that upstream OXP3 support has landed and should be diffed. Keep ours: it wins the filename tie, and the manager builds the composite from the first matching config (manager.rs:961-1110).
6. **Units.** `enable_unit inputplumber.service inputplumber-suspend.service`. The InputPlumber autostart hwdb has no OXP3 line, so explicit enabling is required. If step 3 or 4 changed a file and the unit was already running: `as_root systemctl restart inputplumber`, then need_reboot 'restart Game Mode so Steam picks up the Steam Deck controller'.

Rerun with no changes: no writes, no restarts.

**Verify**

Read-only over ssh:
1. `systemctl is-active inputplumber` → active.
2. `journalctl -b -u inputplumber | grep -E 'Found a matching|50-onexplayer_3|bmi260'` shows the composite created from /etc/inputplumber/devices.d/50-onexplayer_3.yaml, with all four sources added.
3. `busctl --system tree org.shadowblip.InputPlumber` shows exactly one CompositeDevice plus targets; `busctl --system introspect org.shadowblip.InputPlumber /org/shadowblip/InputPlumber/CompositeDevice0` lists TargetDevices containing a deck-uhid target.
4. `grep -B1 -A3 'Vendor=28de' /proc/bus/input/devices` shows a 28de:12f0 UHID Steam controller. Steam's own 28de:11ff 'Microsoft X-Box 360 pad 0' virtual pad is EXPECTED to remain.
5. The xpad event node (045e:028e) has mode 000 (`ls -l /dev/input/eventN`).

In the hand, after a Game Mode restart:
1. Steam > Settings > Controller shows a Steam Deck-type controller with Deck glyphs, and no Xbox 360 controller.
2. Controller tester: A/B/X/Y, sticks, triggers, bumpers, d-pad, L3/R3, Start/Select, M1→L4, M2→R4, Home opens the Steam menu, ONEX opens the QAM, the Keyboard key opens the OSK.
3. Rumble test.
4. Gyro calibration screen: direction of all three axes; whether gravity appears in the accelerometer.
5. Short-press suspend, resume, repeat 2-4.

**Risk:** Medium.
- Every button row is untested on this unit; the same path is reported working on another OXP3 under SteamOS with IP 0.78.
- Paddle and Home frames depend on mainline hid-oxp's 2-page MCU map. Home 0x24 is known to arrive; 0x22/0x23 are not yet seen here, hence the keys fallback.
- Resume re-init may be fragile until the Aldea hid-oxp series lands.
- Stock 0.81 sends accel in raw m/s² and gyro ×12 to deck-uhid: rate gyro at about 0.73x, gravity modes broken.
- ONEX vs Keyboard key identity is contested by hhd; fix by swapping two map entries.
- Restarting InputPlumber re-enumerates the pad; Steam may need a Game Mode restart.

### modules/40-steamos-manager.sh

Steam's own QAM TDP slider and manual GPU clock slider, with no third-party overlay.

**Details**

1. **Guard:** same conflict guard as 30. Warn on Decky TDP plugins: they write only MMIO PL1 and would fight the remote.
2. **Packages:** `pkg_install steamos-manager python-gobject`. python-gobject is currently only installed as a dependency of meld, so list it explicitly. steamos-manager's .install enables the system unit.
3. **Build oxp3-support** from files/pkg/oxp3-support (PKGBUILD arch=any, pkgver 1, bump pkgrel on any change).
   - Run `makepkg -f --cleanbuild` as the login user in $RUN_DIR, then `as_root pacman -U --noconfirm`.
   - Skip when `pacman -Q oxp3-support` equals the PKGBUILD's pkgver-pkgrel (parse with `source PKGBUILD` in a subshell).
4. **Package contents:**
   a) /usr/share/steamos-manager/devices/onexplayer-3.toml:
      [[device]]
      dmi.sys_vendor="ONE-NETBOOK"
      dmi.product_name="ONEXPLAYER 3"
      device="onexplayer_3"
      variant="ONEXPLAYER 3"   (required)
      friendly_name="ONEXPLAYER 3"
      [gpu_performance] driver="intel"
      [tdp_limit] method="remote_interface"
      [inputplumber] target_devices=["deck-uhid","keyboard","mouse"]
      No [performance_profile]: PPD and intel_lpmd own platform_profile and EPP. No [battery_charge_limit] until oxpec has an OXP3 quirk.
   b) /usr/lib/oxp3/oxp3-tdp (Python + Gio): owns local.oxp3.Tdp on the system bus and exports com.steampowered.SteamOSManager1.TdpLimit1 at /local/oxp3/Tdp.
      - On first start it saves the firmware PL1/PL2 of both package zones to /var/lib/oxp3-tdp/firmware, only if that file is absent.
      - With no stored user value it writes nothing and reports TdpLimit = min(MSR PL1, MMIO PL1), so boot behaviour is unchanged until the slider is touched.
      - Set(W): clamp to tdp.conf [min,max]; write W*1e6 to constraint_0_power_limit_uw of intel-rapl:0 and intel-rapl-mmio:0, each zone independently (log EACCES/EIO if the BIOS locks one, keep going). Write constraint_1 = W when W < max, else the saved firmware PL2 (52 W). Persist to /var/lib/oxp3-tdp/limit and emit PropertiesChanged.
      - Re-apply: on logind PrepareForSleep(false), and in a 5 s reconcile loop that re-writes when either zone drifts (the firmware resets MMIO on AC/DC change).
      - ExecStop restores the saved firmware values.
   c) oxp3-tdp.service: Type=dbus, BusName=local.oxp3.Tdp, User=root, ProtectSystem=strict, ReadWritePaths=/sys/class/powercap /sys/devices/virtual/powercap /var/lib/oxp3-tdp, StateDirectory=oxp3-tdp, WantedBy=multi-user.target, Before=display-manager.service.
   d) /usr/share/dbus-1/system-services/local.oxp3.Tdp.service (SystemdService=oxp3-tdp.service).
5. **/etc files** via write_file:
   - /etc/dbus-1/system.d/local.oxp3.Tdp.conf: root may own; only `<policy user="$(target_user)">` may send_destination; default deny. Generated per user, so it lives in /etc, not in the package.
   - /etc/steamos-manager/remotes.d/oxp3-tdp.toml: [TdpLimit1] bus_name="local.oxp3.Tdp" object_path="/local/oxp3/Tdp".
   - /etc/oxp3/tdp.conf: min=8, max=35, default=25. Raising max toward 52 W is opt-in, with a note that a charger of 100 W or more is needed.
6. **Units.** `enable_unit steamos-manager.service oxp3-tdp.service`. If the TOML, remotes.d or policy changed: need_reboot, because steamos-manager reads remotes.d and the device TOML only at startup. Do not restart the user steamos-manager under a running Game Mode.

Idempotent: version-gated package, content-compared /etc files, enable_unit no-ops.

**Verify**

1. `pacman -Q oxp3-support`; `pacman -Qo /usr/share/steamos-manager/devices/onexplayer-3.toml`.
2. `journalctl -b -u steamos-manager; journalctl --user -b -u steamos-manager` contain NO 'Failed to read config file' (catches the missing-variant failure).
3. `busctl --user introspect com.steampowered.SteamOSManager1 /com/steampowered/SteamOSManager1 | grep -E 'TdpLimit1|GpuPerformanceLevel1|ManualGpuClock1'` shows all three.
4. `busctl --system introspect local.oxp3.Tdp /local/oxp3/Tdp` shows TdpLimit/TdpLimitMin/TdpLimitMax.
5. `sudo cat /sys/class/powercap/intel-rapl{,-mmio}:0/constraint_0_power_limit_uw`: both follow the QAM slider (e.g. 15 W gives 15000000 on both).
6. GPU manual clock changes /sys/class/drm/card0/device/tile0/gt0/freq0/{min,max}_freq.
7. Unplug and replug AC, wait 5 s, check both PL1 values again.
8. Suspend and resume, check again.
9. Steam > Switch to Desktop and Return to Gaming Mode still work.

**Risk:** Medium.
- The remote is new code, not yet written or tested.
- Whether Steam shows the slider on non-Valve hardware, and what it sends when the 'limit' toggle is off, is closed-source behaviour.
- Writing the MSR PL1 above its 25 W max_power_uw is untested here (hhd and the reference repo do it).
- PL2 = PL1 below max reduces burst performance; this is Deck semantics.
- Installing steamos-manager may change how Switch to Desktop works. 26.4.1-1 predates CachyOS's plasmalogin patch, so it must be tested.
- In Auto mode the GPU floor rises from 800 to 900 MHz (RPe).
- intel_lpmd reads PL1 and may change behaviour.

### modules/45-power-button.sh

Deck-style Game Mode power button: a short press suspends through Steam.

**Details**

1. `pkg_install steamos-powerbuttond`. It ships the user unit, the gamescope-session.service.wants symlink, 70-steamos-power-button.hwdb and the uaccess rule.
2. If newly installed: `as_root systemd-hwdb update; as_root udevadm trigger -s input --action=change`.
3. Read-only asserts, warn only:
   - `systemd-analyze cat-config systemd/logind.conf | grep HandlePowerKey=ignore`. It must stay, or one press would suspend twice.
   - /etc/xdg/powerdevilrc PowerButtonAction=1 (Desktop Mode).
   - The wants symlink /usr/lib/systemd/user/gamescope-session.service.wants/steamos-powerbuttond.service exists.
4. Print once: 'long press cannot be detected on this hardware; open the power menu via the Steam button → Power'.
Writes nothing else; rerun is a no-op.

**Verify**

1. `udevadm info /dev/input/event2 /dev/input/event3 | grep STEAMOS_POWER_BUTTON`.
2. In Game Mode: `systemctl --user is-active steamos-powerbuttond` → active.
3. In the hand: a short press suspends (the NVMe s2idle fix is already verified) and a press wakes; in Desktop Mode, PowerDevil suspends.
4. Optional: evtest on event2/3/4 while holding the button, to confirm only an instant press/release arrives.

**Risk:** Low. Long press is impossible: drivers/acpi/button.c v7.2.9 l.474-477 reports press and release back to back. Meta+F16 (powerbuttond's long-press chord) cannot be triggered by M1, because InputPlumber grabs the MCU keyboard.

## Feature expectations

| Feature | Expected | Confidence |
|---|---|---|
| Steam sees a Steam Deck controller instead of an Xbox 360 pad (the user's complaint) | Works after 30-controller plus a Game Mode restart. The raw xpad 045e:028e is hidden (mode 000) and Steam lists a deck-uhid 28de:12f0 controller with Deck glyphs. Steam's own 28de:11ff 'Microsoft X-Box 360 pad 0' virtual pad remains by design, as on a real Deck. | High in the source chain; Steam's handling of 0x12f0 is closed source, but Valve's steamos-manager defaults every InputPlumber device to deck-uhid. Unverified on this unit. |
| Face buttons, sticks, triggers, bumpers, d-pad, L3/R3, Start/Select | Works through the xpad evdev source into deck-uhid. | High (steam_deck_uhid.rs:126-149); unverified on the unit |
| Back paddles M1/M2 as bindable L4/R4 | Works if the MCU emits 0xB2 frames 0x22/0x23 on hidraw iface 2 under mainline hid-oxp in xinput mode; otherwise switch to PADDLE_SOURCE=keys (F16/F17, known to arrive). | Medium (reference repo saw the frames on kernel 7.2.4; not observed here) |
| Home key opens the Steam menu | Works: vendor 0x24 → gamepad Keyboard → map → Guide. | Medium-high (0x24 is known to arrive on this unit; mapping verified in source) |
| ONEX key opens the Quick Access Menu; Keyboard key opens the OSK | Works per the project's own notes and PR #672's evtest: ONEX = Ctrl+Alt+Meta, Keyboard = Ctrl+Meta+O. If hhd's opposite labelling turns out correct, swap the two map entries. | Medium (key identity contested) |
| Gyro in Steam Input | Partial. Rate-based gyro (camera, mouse) should work at about 0.73x sensitivity. Gravity, world and player space are wrong on stock 0.81 because the accelerometer goes out in raw m/s². Axis signs depend on the mount matrix (two candidates). Full fidelity needs a deferred patched-InputPlumber module. | Medium for rate gyro, low for gravity modes |
| Rumble | Works: deck-uhid 0xEB rumble → OutputEvent::SteamDeckRumble → xpad FF_RUMBLE. | Medium-high; unverified on the unit |
| Controller after suspend/resume | Should work: inputplumber-suspend.service runs HookSleep/HookWake and the re-created xpad node rejoins the composite. Paddles and Home depend on hid-oxp's MCU re-init, which the pending Aldea patch 10 targets. | Medium; must be tested |
| Desktop Mode controller | Works while Steam is running (cachyos-handheld autostarts it with -steamdeck). Without Steam, non-Steam apps see no gamepad: xpad is hidden and SDL/hid-steam do not know 0x12f0. | Medium |
| TDP slider in Steam's own QAM | Works through steamos-manager's remote fallback plus oxp3-tdp, writing PL1 to both MSR and MMIO zones in the 8-35 W range. | Medium (source-verified path; the remote is not yet written; Steam UI is closed source) |
| GPU clock slider in Steam's QAM | Works through steamos-manager's Intel xe backend (900-2300 MHz) once the TOML with `variant` loads. | Medium-high |
| Power button short press = suspend (Game Mode) | Works through steamos-powerbuttond → steam://shortpowerpress. | High |
| Power button long press = power menu | Does not work on any stack: the ACPI button reports press and release back to back. Use Steam button → Power. | High (it will not work) |
| Volume rocker without sticking | Works with the hwdb force-release, assuming scancodes 0xae/0xb0. | Medium (scancodes not evtest-confirmed) |
| LED/RGB control | Not provided. Needs the unmerged hid-oxp Gen3 RGB patches (Aldea 14/15). | High (out of scope) |

## Rejected options

- **A: hhd master a87fb308 (pinned local PKGBUILD) with hori_steam/sd output plus a TdpLimit1 bridge**: It covers the most hardware (RGB, a volume patch, Deck-scaled gyro) but owns the most fragile code:
- unreleased master with failing upstream tests, plus 2-3 local patches (bmi260 IMU name, volume taps, maybe key roles);
- a BETA output mode on Legion Go S PID 0x12FF;
- relies on Python ≥3.14 semantics (NotRequired used without import);
- a hid-oxp/hhd button-map conflict after s2idle that needs an untested udev write into hid-oxp sysfs, and a possible RGB/MCU-reset feedback loop;
- an extra overlay/gesture layer;
- still needs steamos-manager plus a bridge for Steam's slider, and a second bridge for GPU.
Revisit only if InputPlumber's vendor frames prove absent or broken after resume AND the user accepts that maintenance burden. Not used as reasons, because they were refuted: that hhd needs a patched steamos-manager, and that it must mask PPD for TDP.
- **B as written: steamos-manager device TOML in /etc plus ExecStart= drop-ins on the system and user units with --device-config**: The TOML content was correct and is adopted. The ExecStart override is rejected: a changed ExecStart or binary path after pacman -Syu breaks it silently, and the flag bypasses DMI matching. A pacman-owned file in /usr/share/steamos-manager/devices fails loudly instead.
- **C's device TOML without `variant`**: Refuted: DeviceMatch.variant is a required String, so the file is skipped with 'Failed to read config file'. GpuPerformanceLevel1 then disappears and DeckService falls back to [deck-uhid] alone.
- **C's acceptance criterion 'the Microsoft X-Box 360 pad 0 virtual device is gone'**: Refuted: that is 28de:11ff, Steam Input's own virtual pad, which also exists on a real Deck. The symptom is the raw xpad 045e:028e.
- **Building InputPlumber from PR #672**: Its commits sit on 0.78.1 and would drop the 0.79.1 QuickAccess chord fix 50263d3. Its OXP3 content is config only, so it ships as /etc files on stock 0.81.0. It also targets xbox-elite and uses the oxp9 map, which sends the Keyboard key to QuickAccess2 (Screenshot) and leaves Home to open the OSK.
- **Patched InputPlumber (gyro scaling port) up front**: Deferred. The reference patch's steam_deck_uhid.rs hunk does not apply to 0.81, and it would become a maintained fork. Add it as a later module (e.g. 35-inputplumber-gyro) only if Steam's gyro test fails in a way the user cares about.
- **AUR hhd-git**: Unpinned. It lacks 83-hhd.hwdb (the OXP3 key rule) and the python-dbus/pyroute2/gobject/pyserial/lsof deps.
- **Removing our InputPlumber config when upstream ships 50-onexplayer_3.yaml**: Unnecessary and harmful. The manager builds the composite from the first matching config in sort order, and our /etc file wins the filename tie (manager.rs:961-1110). Removing it would lose Home→Guide and deck-uhid. Warn and diff instead.
- **PowerStation, SimpleDeckyTDP, thermald, or masking power-profiles-daemon**: Each would write RAPL or compete with the single TDP writer. PPD and intel_lpmd stay as they are: they do not write RAPL.

## Open risks

- Every button, paddle, gyro, rumble and resume row is unverified until someone holds the device and runs evtest plus Steam's controller tester. All research was read-only over ssh.
- Paddle frames 0x22/0x23 on hidraw iface 2 have not been observed on this unit under mainline hid-oxp, which writes a 2-page Gen2 map where OXP3 wants 3 pages (Aldea patch 12). The PADDLE_SOURCE=keys fallback covers the paddles; if Home ever goes silent there is no fallback.
- s2idle re-init of the MCU may leave paddles or Home dead until reboot (the pending Aldea hid-oxp patch 10 targets this). Never work around it by unbinding or rebinding hid-oxp (known kernel Oops).
- Gyro on stock InputPlumber 0.81 is mis-scaled for deck-uhid: accel in m/s², gyro ×12. The mount matrix must be settled empirically between the PR #672 and reference-repo candidates. BMI260 yaw drift is temperature-dependent.
- Physical identity of the ONEX and Keyboard keys is contested between hhd (commit 93ddb40) and the project notes / PR #672. A swap is a two-line map edit.
- Steam's treatment of 28de:12f0 (Deck glyphs, gyro, QAM bit) and of the TDP slider on non-Valve hardware is closed source.
- oxp3-tdp is new code and does not exist yet. An MSR PL1 write above its 25 W max_power_uw is untested; if the BIOS locks it, only MMIO moves. TDP above 35 W needs a charger of 100 W or more, or AC/DC flapping resets the firmware limits.
- steamos-manager 26.4.1-1 changes the Switch to Desktop / Return to Gaming Mode path (SessionManagement1). The CachyOS plasmalogin patch is only in -2 in git. Test the session switch after 40.
- DeckService re-sets the 3-target list once per boot, because is_deck() requires exactly one target. Expect a brief controller re-enumeration at session start.
- Volume scancodes 0xae/0xb0 are taken from hhd #342, not captured on this unit.
- No LED/RGB control until the hid-oxp Gen3 RGB patches land.
- chwd may later match ONEXPLAYER 3 and install the same three packages (compatible). The guard must keep blocking hhd and PowerStation, which pacman does not declare as conflicts.
