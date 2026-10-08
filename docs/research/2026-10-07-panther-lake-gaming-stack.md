# Panther Lake gaming stack on CachyOS Handheld (OneXPlayer 3), 2026-10-07

Scope: OneXPlayer 3 (Intel Core Ultra Series 3 "Arc G3 Extreme", Arc B390 Xe3 iGPU `8086:b080`, `xe` driver) on CachyOS Handheld
edition. Goal: a Steam Deck-like Game Mode with a working QAM TDP slider, power controls and sleep/resume.

Sources: primary sources were fetched live on 2026-10-07: kernel.org trees and ChangeLogs, linux-firmware WHENCE, the Mesa and xe GitLab APIs, gamescope git,
steamos-manager GitLab, hhd, PowerStation, SimpleDeckyTDP and InputPlumber GitHub, the CachyOS PKGBUILDS/Handheld/chwd repos and the mirror
listings. Device facts come from read-only `ssh` diagnostics. The device section lists exactly what was read. Claims marked
**(device)** were observed on the unit itself. **Unverified** and **speculative** mark claims that are not proven.

---

## Summary

| Area | Status | Action |
|---|---|---|
| xe kernel driver (7.2.9) | Probes `b080` by default; no `force_probe` needed. Works, but has open PTL eDP/VRR/PSR regressions and some GPU-hang reports | Keep 7.2.9. Watch xe#9252 / #8976. Optional `xe.enable_psr=0` if you see corruption |
| GPU firmware (linux-firmware 20260916) | All present and loaded: GuC 70.72.1, HuC 10.3.3, GSC 105.0.2.1397, DMC 2.36. This is the newest tag; nothing newer exists for PTL | None |
| Mesa 26.2.4 ANV/Iris | Current stable. It includes the B390 UE5.8 timestamp crash fix. Mesa 26.3 (rc1 due 10-14) switches Xe2/Xe3 to the new "Jay" compiler, which already has PTL game regressions | Stay on 26.2.x. When 26.3 lands, keep `INTEL_DEBUG=no-jay` as a fallback |
| **Suspend/resume** | **Broken, data-risking.** On resume, the Predator GM7 NVMe (`1dee:1602`) is "Disabling device after reset failure: -19", and btrfs is forced read-only. Reproduced on this unit today **(device)** | **Add `nvme.noacpi=1`** (or the targeted `nvme.quirks=1dee:1602:force_no_simple_suspend`, untested) **before relying on sleep** |
| TDP in Steam QAM | **Not possible with stock packages.** steamos-manager has no RAPL backend and no OXP3 device file, and it isn't even installed (chwd's handheld regex doesn't match "ONEXPLAYER 3") | Use hhd master (hhd-git): its only OXP3 Intel TDP support writes both RAPL zones. Or use SimpleDeckyTDP / PowerStation together with a MSR-PL1 sync service |
| RAPL double limit | MSR `intel-rapl:0` PL1 = 25 W, MMIO `intel-rapl-mmio:0` PL1 = 35 W **(device)**. The lower one wins, so the effective cap is 25 W | Any TDP tool must write **both** package zones |
| platform_profile | Provided by Intel's `SoC Power Slider` (int340x), not oxpec **(device)** | Leave it to power-profiles-daemon, or to hhd |
| oxpec (fan/charge limit) | No OXP3 support upstream. No `charge_control_end_threshold` on BAT0 **(device)** | No QAM charge limit is possible today |
| Controller | `hid_oxp` loaded. InputPlumber 0.81 has no OXP3 profile. hhd master has an OXP3 controller config | hhd-git covers the controller and TDP in one daemon |
| Game Mode boot | Works: plasmalogin `Relogin=true` + `zz-steamos-autologin.conf`. The device booted into gamescope at 19:51 **(device)** | Keep the default "oneshot" mode. Fix the `DECK_USER_HOME` typo |
| gamescope | 3.16.25 installed. 3.16.30 is in `[cachyos]` but shadowed by `cachyos-v3` (3.16.25). 3.16.29+ adds content-driven HDR and software backlight | `pacman -S cachyos/gamescope cachyos/lib32-gamescope` (pin repo) |
| Refresh-rate slider / HDR | No upstream gamescope display profile for the OXP3 panel (SDC 0x4301 AMS881KB01-0). Only the 144 Hz fixed mode is used | Ship a `known_displays` Lua in `/etc/gamescope/scripts/` (adapt the reference repo's) |
| Decky Loader | Not packaged by CachyOS. Upstream v3.2.10 (2026-10-04) | Use the upstream installer |
| Scheduler | `scx_lavd` via scx_loader, Auto mode (`--autopilot`) **(device)** | Keep it |
| Steam "updates" | `holo-update` always exits 7 ("no update") | OS updates go through pacman. This cannot be changed without a custom script |

---

## Device evidence (read-only, 2026-10-07 ~19:45–20:00 AEDT)

| Item | Observed |
|---|---|
| Kernel | `7.2.9-1-cachyos-deckify` (built 2026-10-04); cmdline `... nowatchdog quiet splash`. Bootloader systemd-boot 261.1 with `systemd-boot-manager` (`LINUX_OPTIONS="nowatchdog quiet splash"` in `/etc/sdboot-manage.conf`). Current entry `linux-cachyos-deckify.conf`, but the **default entry is `onexplayer3-cachyos.efi`** (a UKI?) |
| DMI | `ONE-NETBOOK` / `ONEXPLAYER 3`, BIOS 5.09 (2026-08-10) |
| GPU probe | `Found pantherlake (device ID b080) integrated display version 30.00 stepping B0`; `xe.force_probe` is empty |
| Firmware | `i915/xe3lpd_dmc.bin v2.36`; `xe/ptl_guc_70.bin 70.72.1` (GT0+GT1); `xe/ptl_huc.bin 10.3.3`; `xe/ptl_gsc_1.bin 105.0.2.1397` ("found GSC cv105.1.0"); NPU `vpu_50xx_v1.bin`; SOF `sof-ptl.ri` 2.15.0.1 |
| xe warnings | `WARNING intel_bios.c:2813` ("Port A asks to use VBT vswing/preemph tables"); `Selective fetch area calculation failed in pipe A`; `*ERROR* GSC proxy component not bound!` at 22.8 s, followed by `mei_gsc_proxy ... bound` at 29.7 s (a probe-order race that recovers); `*ERROR* [CRTC:151:pipe A] mismatch in vsc dp vsc sdp` (expected BT.2020 RGB 10 bpc) + WARN in `intel_modeset_verify_crtc`. That last error appears in **both** Plasma and gamescope boots. No `DSB poll error` lines in either boot today |
| gamescope log | `drm: Connector eDP-1 -> SDC - AMS881KB01-0`, "EDID with colorimetry detected", **7× `drmModeAddFB2WithModifiers failed: Invalid argument`**, `scriptmgr: Directory '/etc/gamescope/scripts' does not exist` (no OXP3 display profile loaded). gamescope runs with `--generate-drm-mode fixed ... -O *,eDP-1` |
| Panel EDID | `SDC`, product 17153 = **0x4301**, `AMS881KB01-0`, 1920x1200. Two DTDs: 144 Hz and 60 Hz, both at a 380.16 MHz clock. Range 30–144 Hz, Adaptive-Sync block 30–144 Hz. HDR static metadata only advertises "Traditional gamma – SDR"; max 1107 / avg 475 / min 0.001 nits, native gamma 2.2, 10 bpc. debugfs `vrr_range` 30–144 |
| Backlight | `intel_backlight`, type `raw`, max 472 (PWM, not DPCD/AUX) |
| GT freq | gt0: rpn 100 / rpe 900 / rpa = rp0 2300 MHz, min 850, max 2300. gt1 (media): rp0 1200. `freq0/power_profile` = `[base] power_saving`. `freq0/throttle/reason_{pl1,pl2,pl4,prochot,ratl,thermal,vr_tdc,vr_thermalert}` present |
| RAPL | MSR `intel-rapl:0` package-0: PL1 **25 W** (window 28 s, `max_power_uw` 25 W), PL2 52 W, PL4 160 W. MMIO `intel-rapl-mmio:0` package-0: PL1 **35 W**, PL2 52 W, PL4 160 W. psys/core/uncore disabled. AC online |
| platform_profile | `platform-profile-0` name **`SoC Power Slider`** (device `0000:00:04.0`, `processor_thermal_soc_slider` module), choices `low-power balanced performance`, current `balanced` |
| CPU | `intel_pstate` active, governor `powersave`, EPP `balance_performance` ×14, turbo on |
| Daemons | Running: `power-profiles-daemon` 0.30-3, `intel_lpmd` (intel-lpmd 0.1.1-2), `scx_loader` (`default_sched = "scx_lavd"`, sched_ext `lavd_1.1.3`), `ananicy-cpp`, `upower`. **Not installed:** thermald, tuned, steamos-manager, hhd, inputplumber, powerstation, decky-loader |
| OXP drivers | `hid_oxp` loaded (MCU `1a86:fe00`); **no `oxpec`**. `bmi160_i2c` loaded but `/sys/bus/iio/devices/` is empty (IMU not working) |
| Battery | `BAT0` has no `charge_control_end_threshold` / `charge_behaviour`. `energy_full` 90.26 Wh > `energy_full_design` 84.55 Wh |
| NVMe | `Predator SSD GM7 1TB`, fw `BM345CVN`, PCI `1dee:1602`; boot log shows `platform quirk: setting simple suspend` (ACPI StorageD3Enable) |
| Session | `plasmalogin.service` (plasma-login-manager 6.7.4-3). At 19:45 the session was Plasma (autologin); after a reboot at 19:51 it was `Desktop=gamescope` via `plasmalogin-autologin` |

### Suspend failure observed during this research

At uptime 1077 s an s2idle suspend was entered; it was the owner's `rtcwake` test. On resume:

```
[1079.176877] nvme nvme0: Disabling device after reset failure: -19
[1080.122666] BTRFS error (device dm-0): error while writing out transaction: -5
[1080.122671] BTRFS: error (device dm-0 state A) in btrfs_commit_transaction:2606: errno=-5 IO failure
[1080.122674] BTRFS info (device dm-0 state EA): forced readonly
```

After that, uncached files on `/` returned EIO until the reboot at 19:51. The suspend itself lasted about 2 s instead of 30 s, so an early wake
source exists as well (not investigated). This is the same SSD and the same failure that the reference repo documents (see "Reference repo review").

---

## Q1. Xe3 / Panther Lake GPU on Linux right now

### Kernel `xe` driver
- **Default probe.** `0xB080` is the first ID in `INTEL_PTL_IDS`, and `ptl_desc` has no `require_force_probe` in v7.2.9
  ([pciids.h@v7.2.9](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/include/drm/intel/pciids.h?h=v7.2.9),
  [xe_pci.c@v7.2.9](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/gpu/drm/xe/xe_pci.c?h=v7.2.9)).
  The requirement was dropped by [94de1dfd4729](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=94de1dfd4729c21c156051ffd1ee30cfdab1b58e)
  "drm/xe/ptl: Drop force_probe requirement" (2025-07-08), in kernels since 6.17. **(device)**: it probes without any parameter.
- **Versions.** 7.2.9 is the latest stable (2026-10-03); 7.3-rc6 is mainline (2026-10-04) ([releases.json](https://www.kernel.org/releases.json)).
- **PTL-relevant 7.2.y fixes** ([ChangeLog-7.2.7](https://cdn.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.7), [-7.2.8](https://cdn.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.8), [-7.2.9](https://cdn.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.9)):
  - 7.2.7: "drm/i915/cdclk: Avoid spurious cdclk sanitization on PTL+" (xe#8550), "Flush LSC untyped L1 dataport cache after rcs/ccs batches", and "Guard page-fault worker with runtime PM check".
  - 7.2.8: revert of "Clear SEL_FETCH_PLANE_CTL on plane disable", plus shrinker runtime-PM fixes.
  - 7.2.9: "drm/xe: Add wa_14025941587 to xe2, xe3 and xe3p", "harden adjust_idledly()", and "drm/i915/psr: Clear stale sel fetch enable bits" (xe#8739).
- **Power management.** GuC SLPC manages frequency, and PCODE has the final say
  ([xe_gt_freq.c](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/xe/xe_gt_freq.c)). 7.2.9 disables SLPC DCC on PTL
  ([xe_guc_pc.c@v7.3-rc6](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/gpu/drm/xe/xe_guc_pc.c?h=v7.3-rc6)).
  "Use IBC v3 on PTL" ([5c45e2dbe696](https://gitlab.freedesktop.org/drm/xe/kernel/-/commit/5c45e2dbe6967bf75a500931d643d5989291109b)) is only in drm-xe-next,
  which means 7.4. **(device)**: GT idle shows `gt-c6`, so RC6 is working.
- **Open hangs (PTL):** [xe#8954](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/8954) (device wedged while gaming with RE4 + Proton + gamescope on b080,
  after a failed GuC engine reset), xe#8971, xe#8567, and CI xe#9365 ("Timed out wait for G2H", 2026-09-23).
- **Open eDP/VRR/PSR regressions, which matter most for a handheld:**
  - [xe#9252](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/9252), on b080: vertical streaks on eDP since 7.2, because the AS SDP is sent even with VRR off.
    Opened 2026-09-13, still open; 7.1.13 is clean.
  - [xe#8976](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/8976): with VRR enabled, refresh is pinned to the panel minimum. It is tied to VRR DC-balance, which applies to display ver ≥ 30, i.e. PTL. Opened 2026-08-19, still open.
  - [xe#9253](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/9253), #9296, #8564, #8556: DSB poll errors, FIFO underruns and corruption with VRR or PSR.
  - [xe#9385](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/9385), on b080: plane fault on fullscreen direct scanout. Relevant to gamescope.
  - [xe#9516](https://gitlab.freedesktop.org/drm/xe/kernel/-/work_items/9516): 40–70 ms compositor stalls in DPT fill since 7.2.5.

### Firmware
- In 7.2.9 the driver requests `xe/ptl_guc_70.bin` (minimum 70.54.0), `xe/ptl_huc.bin`, `xe/ptl_gsc_1.bin` (minimum 105.1.0 compatibility) and `i915/xe3lpd_dmc.bin`.
  [WHENCE@20260916](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/WHENCE?h=20260916) lists GuC 70.72.1
  ([MR !1158](https://gitlab.com/kernel-firmware/linux-firmware/-/merge_requests/1158), merged 2026-08-06), HuC 10.3.3, GSC 105.0.2.1397 and DMC 2.36.
  20260916 is the newest tag. No PTL GPU firmware commits or open MRs have appeared since.
- **(device)**: all four load with exactly those versions. The single `GSC proxy component not bound!` error is a probe-order race with
  `mei_gsc_proxy`, and it binds 7 s later. It only matters for HuC-authenticated media (protected content) and is harmless for gaming
  (this is my interpretation, not checked against a source).

### Mesa ANV / Iris
- ANV and Iris have supported Xe3 by default since 25.1.6 ([relnotes 25.1.6](https://docs.mesa3d.org/relnotes/25.1.6.html)).
- **26.2.4** (2026-10-01) is the current stable and is installed. It fixes *"VK_EXT_calibrated_timestamps returns a GPU timestamp ahead of CPU time on Arc B390 (Panther Lake), crashing Unreal Engine 5.8"*,
  using the driconf option `anv_disable_xe_engine_cycles` ([relnotes 26.2.4](https://docs.mesa3d.org/relnotes/26.2.4.html), mesa#16373).
  26.2.3 added the `anv_always_bindless` driconf ([relnotes](https://docs.mesa3d.org/relnotes/26.2.3.html)). 26.2.0 enabled `VK_EXT_descriptor_heap`
  on ANV by default ([relnotes](https://docs.mesa3d.org/relnotes/26.2.0.html)).
- **Next releases:** 26.2.5 on 2026-10-14; 26.3.0-rc1 on 2026-10-14, final around 2026-11-04 ([calendar](https://docs.mesa3d.org/release-calendar.html)).
- **Main / 26.3:** [MR !44694](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/44694) "intel: enable Jay by default on Xe2 and Xe3",
  merged 2026-09-24. It has already caused PTL regressions: mesa#16423 (CS2), #16412 (Cyberpunk), #16411, #16413, and #16463 (Ghost of Tsushima rcs hang).
  `INTEL_DEBUG=no-jay` or driconf `anv_disable_jay` reverts to the old brw compiler. 26.2.x is not affected.
- **Other open PTL game bugs:** #15478 (Wukong RT hang), #14928 (Schedule I), #15202 (Ghostwire), #15506 (Ready or Not), #12784 (Ghost of Tsushima flicker),
  and #16500 (Borderlands 4, main only) ([issue search](https://gitlab.freedesktop.org/mesa/mesa/-/issues/?search=PTL)).

### DXVK / VKD3D-Proton
- DXVK v3.1.1 (2026-09-15) enables descriptor heap on ANV automatically
  ([dcc0438c](https://github.com/doitsujin/dxvk/commit/dcc0438c3d95aa2c73e909e3bd9367c5e9827704), commented "Not really tested"). If a game misbehaves, set
  `dxvk.enableDescriptorHeap = False`. DXVK hides the Intel vendor ID for old XeSS versions, and `dxgi.hideIntelGpu` is available
  ([dbfb8677](https://github.com/doitsujin/dxvk/commit/dbfb8677186c5b9e7bab408d1b94905274e2f47e)).
- VKD3D-Proton: the latest tag is still v3.0.1 (2026-05-05). Master loads the Intel vendor hack DLLs (49eff6dc, unreleased).
- No ANV-specific env var is required by either project.

### VRR / HDR / video
- **VRR.** The panel supports 30–144 Hz Adaptive-Sync **(device: EDID + `vrr_range`)**. The session exports `STEAM_GAMESCOPE_VRR_SUPPORTED=1` **(device)**.
  Given xe#8976 and #9252, treat VRR on PTL eDP as experimental and leave it off by default.
- **HDR.** The xe display code exposes connector `Colorspace` and `HDR_OUTPUT_METADATA`
  ([intel_dp.c@v7.2.9](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/gpu/drm/i915/display/intel_dp.c?h=v7.2.9)), and a
  `drm_colorop` plane pipeline on ver ≥ 12, with no 3D LUT on PTL
  ([intel_color_pipeline.c](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/gpu/drm/i915/display/intel_color_pipeline.c?h=v7.2.9)).
  gamescope only uses `AMD_PLANE_*` properties plus connector properties, so on Intel all HDR work is done in shader composition
  ([DRMBackend.cpp](https://github.com/ValveSoftware/gamescope/blob/master/src/Backends/DRMBackend.cpp)).
  - The panel's EDID advertises only the SDR EOTF but gives HDR luminance values and native gamma 2.2 **(device)**. The session sets `STEAM_GAMESCOPE_HDR_SUPPORTED=1`.
  - The repeated `vsc sdp mismatch (expected BT.2020 10 bpc)` WARN suggests that something requests BT.2020 output and the state check fails.
  - The reference repo reports that native BT.2020/PQ blanks this panel and that the brightness slider is dead in that mode. Their fix is a gamma-2.2 HDR display profile, the same approach as the Deck OLED and the OXP F1 upstream profile
    ([onexplayer.f1.oled.lua, bde0e60](https://github.com/ValveSoftware/gamescope/commit/bde0e60)).
- **gamescope 3.16.29+** ([tag 3.16.29, 8f21264, 2026-09-15](https://github.com/ValveSoftware/gamescope/releases/tag/3.16.29)) adds:
  - a content-driven HDR output mode ([6513879](https://github.com/ValveSoftware/gamescope/commit/6513879)),
  - software backlight emulation while in PQ ([21c7e25](https://github.com/ValveSoftware/gamescope/commit/21c7e25)), enabled per display with `software_backlight = true`, as for the Legion Go 2 OLED ([9eeb855](https://github.com/ValveSoftware/gamescope/commit/9eeb855)),
  - EDID fallback for luminance ([2dbc84d](https://github.com/ValveSoftware/gamescope/commit/2dbc84d)),
  - "allow uncapped frame rates with adaptive sync" (3521d6bf).

  Note that the Legion Go 2 profile matches `vendor == "SDC" and product == 0x4301`, which is **the same EDID vendor and product code as this OXP3 panel** **(device)**. This
  needs checking: upstream gamescope may apply the Legion Go 2 profile (48–144 Hz VFP table, PQ, content-driven HDR, software backlight) to the OXP3 panel once
  3.16.29+ is installed. 3.16.25 does not ship that file.
- **VA-API.** For PTL, iHD supports decode and encode of AVC, HEVC 8/10-bit, VP9 8/10-bit and AV1 8/10-bit, plus VVC decode
  ([media-driver README](https://github.com/intel/media-driver/blob/master/README.md)). 26.3.5 (2026-09-30) is installed and is the latest
  ([releases](https://github.com/intel/media-driver/releases)). ANV Vulkan video decode is opt-in with `ANV_DEBUG=video-decode`, and there is no Vulkan encode on Xe2/Xe3
  ([anv_physical_device.c](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/intel/vulkan/anv_physical_device.c)).

### Env vars / kernel params
- **Not needed:** `xe.force_probe`, `i915.force_probe`.
- **Exist; use when needed:** `INTEL_DEBUG=no-jay` (Mesa 26.3+), `ANV_DEBUG=video-decode`, `ANV_DEBUG=no-sparse`, and in dxvk.conf `dxvk.enableDescriptorHeap = False` and `dxgi.hideIntelGpu = True`.
- **xe display parameters in 7.2:** `enable_psr`, `enable_panel_replay`, `enable_psr2_sel_fetch`, `enable_dsb` (default Y, marked unsafe), `enable_dpcd_backlight` (-1 means follow the VBT)
  ([intel_display_params.c@v7.2](https://github.com/torvalds/linux/blob/v7.2/drivers/gpu/drm/i915/display/intel_display_params.c)).
- **Speculative, only if symptoms appear:**
  - `xe.enable_psr=0` for corruption (xe#8564); the device logs a PSR2 "selective fetch area calculation failed".
  - `xe.enable_dsb=0` for DSB poll-error floods (xe#9253). It is cosmetic, and none were seen today.

---

## Q2. TDP and power control

### What controls what on this unit
- **Two package RAPL zones.** MSR `intel-rapl:0` has PL1 25 W and MMIO `intel-rapl-mmio:0` has PL1 35 W **(device)**. The hardware enforces the lower PL1
  (coreboot documents the MSR and MMIO limits as independent, with the minimum applying:
  [coreboot a247d8e5](https://review.coreboot.org/plugins/gitiles/coreboot/+/a247d8e53cebbd754e46f76412ed9d17df752308%5E%21)). hhd's code says the same:
  "Discover one package, including its independently enforced MMIO cap" ([rapl.py](https://github.com/hhd-dev/hhd/blob/master/src/adjustor/core/rapl.py)).
  hhd issue [#338](https://github.com/hhd-dev/hhd/issues/338) confirms the OXP3 "exposes a 25 W MSR PL1 under Linux". **Effective sustained cap today: 25 W.**
- **platform_profile** comes from the int340x **SoC Power Slider** (an MMIO hint register, 0 = performance … 6 = efficiency), not from oxpec
  ([processor_thermal_soc_slider.c@v7.2](https://github.com/torvalds/linux/blob/v7.2/drivers/thermal/intel/int340x_thermal/processor_thermal_soc_slider.c); **(device)** name `SoC Power Slider`).
- **power-profiles-daemon 0.30** writes EPP/EPB and platform_profile and does **not** touch RAPL
  ([ppd-driver-intel-pstate.c](https://gitlab.freedesktop.org/upower/power-profiles-daemon/-/blob/main/src/ppd-driver-intel-pstate.c)). CachyOS's build also
  switches scx_loader modes (see Q3).
- **intel_lpmd** reads RAPL PL1 to pick a config, and writes EPP/EPB, `intel_pstate` perf_pct, ITMT, the SoC slider module parameters and platform-profile. On PTL it
  has GFX-load "gaming states" ([52e3471](https://github.com/intel/intel-lpmd/commit/52e3471),
  [intel_lpmd_config_F6_M204.xml](https://github.com/intel/intel-lpmd/blob/master/data/intel_lpmd_config_F6_M204.xml)). It overlaps with PPD and hhd on EPP and the slider.
  **(device)**: running, with `F6_M204` config present.
- **thermald** 2.5.13 runs PTL in adaptive mode and can rewrite RAPL
  ([thd_platform_intel.cpp](https://github.com/intel/thermal_daemon/blob/master/src/thd_platform_intel.cpp)). It is not installed, so keep it that way.

### Options for a QAM TDP slider
| Tool | OXP3 Intel status | Writes | Shows in Steam QAM? |
|---|---|---|---|
| **steamos-manager** 26.4.1 (`[cachyos]` 26.4.1-1) | `TdpLimitingMethod` is only `AmdgpuHwmon`, `FirmwareAttribute` or `RemoteInterface` ([power.rs](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/master/steamos-manager/src/power.rs)). No OXP3 device file (the OneXPlayer files are only `onexplayer-2/f1/g1a.toml` in [data/devices](https://gitlab.steamos.cloud/holo/steamos-manager/-/tree/master/data/devices)). The Claw 8 EX gets TDP via `msi-wmi-platform` firmware attributes, not RAPL ([7de5caad](https://gitlab.steamos.cloud/holo/steamos-manager/-/commit/7de5caad5e4d4f3bd9f179ddd7acc94e1cb2d677)) | — | Only through a **remote** `TdpLimit1` implementation registered in `/etc/steamos-manager/remotes.d/*.toml` ([README "Interoperability"](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/master/README.md)) |
| **hhd** master / `hhd-git` | Intel support for OneXPlayer/GPD ([e5b6a4a](https://github.com/hhd-dev/hhd/commit/e5b6a4ae81), 2026-09-07). OXP3 preset `{"minTdp":3,"defaultTdp":25,"pl1":35,"pl2":37}` ([adbd50f](https://github.com/hhd-dev/hhd/commit/adbd50ff30), [const.py](https://github.com/hhd-dev/hhd/blob/master/src/adjustor/core/const.py)). OXP3 controller config ([5e7ee0b](https://github.com/hhd-dev/hhd/commit/5e7ee0b)). **Unreleased**: the latest release is [v4.1.12](https://github.com/hhd-dev/hhd/releases/tag/v4.1.12) (2026-07-10), which is the one CachyOS ships | **All** enabled `package-*` zones (MSR + MMIO); PL2 = PL1 + 2 when boost is on | hhd's own overlay (`HHD_QAM_GAMESCOPE=1`, the line CachyOS ships commented out in `hhd@.service.d/override.conf`). The native Steam slider needs a patched steamos-manager ([Anatase overrides.patch](https://github.com/anatase-org/anatase/blob/78d5fc7ffd1a228a1137f9087f392a7ee0d85a47/cards/gaming/steamos-manager/overrides.patch)) |
| **PowerStation** v0.8.2 / v0.8.3 | "Add ONEXPLAYER 3 TDP support" ([0813052](https://github.com/ShadowBlip/PowerStation/commit/0813052d38dedcfb2fa059b160ad0d00bd23bc71), released in v0.8.2 2026-09-28): min 8, max 35, boost 17 | **MMIO zone only** (prefers `intel-rapl-mmio`, then stops) ([tdp.rs](https://github.com/ShadowBlip/PowerStation/blob/main/src/performance/gpu/intel/tdp.rs)) | No (it serves OpenGamepadUI). Not in CachyOS repos; AUR `powerstation-bin` is stale (0.7.0) |
| **SimpleDeckyTDP** v1.0.7 | Intel is "experimental"; ceiling hard-coded to 40 W | **MMIO only** if it exists, otherwise MSR ([cpu_utils.py](https://github.com/aarron-lee/SimpleDeckyTDP/blob/main/py_modules/cpu_utils.py)) | Yes, as a Decky plugin panel (not the native slider) |

**Conclusion (confirmed).** No packaged tool gives a native Steam TDP slider on the OXP3 today. hhd master is the only OXP3-aware tool that
writes both RAPL zones. PowerStation and SimpleDeckyTDP cannot raise the effective limit above the MSR PL1 of 25 W unless something else syncs the MSR value.

### Sane ranges
- Intel ARK for the Arc G3 Extreme: base power 25 W, minimum assured 15 W, maximum turbo 80 W
  ([ARK](https://www.intel.com/content/www/us/en/products/sku/245625/intel-arc-g3-extreme-processor-12m-cache-up-to-4-70-ghz/specifications.html)).
- OneXPlayer advertises a configurable TDP of 8–35 W ([product page](https://onexplayerstore.com/products/onexplayer-3-next-gen-3-in-1-ai-gaming-and-productivity-handheld)).
- The firmware's own battery limits are 35 W / 52 W ([reference README](https://github.com/HHHHanasak1/onexplayer3-steamos-setup)), which matches the MMIO PL1/PL2 seen on AC **(device)**.
- **Recommended:** PL1 8–35 W (default 15–25 W); PL2 up to the PL1+2 cap of 37 W (hhd) or the firmware's 52 W.
- Above 35 W needs a ≥100 W USB-PD charger, otherwise the AC/DC flapping resets the limits (reference README, observation).

### GPU frequency limiting
- Paths: `/sys/class/drm/card0/device/tile0/gt0/freq0/{min_freq,max_freq}` are read-write; `act_freq, cur_freq, rpn/rpe/rpa/rp0_freq` are read-only. gt0 is render,
  gt1 is media ([xe_gt_freq.c DOC](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/xe/xe_gt_freq.c)). **(device)**: the range is 100–2300 MHz.
- `freq0/power_profile` takes `base` or `power_saving` (the SLPC power profile, [xe_guc_pc.c@v7.2](https://github.com/torvalds/linux/blob/v7.2/drivers/gpu/drm/xe/xe_guc_pc.c)).
- Throttle diagnosis: `freq0/throttle/reasons` and `reason_pl1` etc.
- xe hwmon power limits are not registered on integrated GPUs ([xe_hwmon.c](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/xe/xe_hwmon.c)), so use RAPL.
- steamos-manager's `[gpu_performance] driver = "intel"` (used by `msi-claw-intel.toml`) drives min/max_freq for Steam's manual GPU clock slider
  ([gpu.rs](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/master/steamos-manager/src/gpu.rs)).

### Daemon interaction (recommended combination)
- **With hhd:** hhd treats an active PPD or tuned as a conflict and disables its power section, unless `HHD_PPD_MASK=1` lets it mask them
  ([gpu/__init__.py](https://github.com/hhd-dev/hhd/blob/master/src/adjustor/drivers/gpu/__init__.py)). It can also manage intel_lpmd (23fbc34). Do not run SimpleDeckyTDP or
  PowerStation alongside it.
- **Without hhd** (SimpleDeckyTDP): keep PPD (for EPP + slider + scx mode). Consider stopping intel_lpmd, because it rewrites EPP and the slider under load (speculative,
  but the overlap is documented above). Never install thermald.

---

## Q3. CachyOS Handheld edition practice

### Game Mode boot and "Switch to Desktop" (confirmed on device)
- **Display manager.** Plasma Login Manager. `cachyos-handheld.install` links `plasmalogin.service` as `display-manager.service`
  ([cachyos-handheld.install](https://github.com/CachyOS/CachyOS-PKGBUILDS/blob/master/handheld/cachyos-handheld/cachyos-handheld.install)).
- **`/etc/plasmalogin.conf.d/steam-deckify.conf`** contains `[Autologin] Relogin=true, Session=gamescope-session.desktop, User=<user>` **(device)**.
  `Relogin` is a real plasma-login-manager key ([mainconfig.kcfg](https://invent.kde.org/plasma/plasma-login-manager/-/blob/master/src/common/mainconfig.kcfg)), and drop-ins are read in sorted order.
- **`/etc/plasmalogin.conf.d/zz-steamos-autologin.conf`** is written by `pkexec /usr/lib/steamos/steam-set-session <session>.desktop`. That helper picks the plasmalogin or sddm path
  from `display-manager`'s Id **(device)**.
- **`steamos-session-select`** (from gamescope-session-cachyos 1.1.6, [CachyOS/gamescope-session](https://github.com/CachyOS/gamescope-session)) **(device)**:
  - `plasma` writes `plasma.desktop`, runs `steam -shutdown` and stops `gamescope-session.target`. Relogin then lands in Plasma. This is Steam's "Switch to Desktop".
  - `gamescope` writes the gamescope session and logs out of Plasma via `qdbus6 org.kde.Shutdown`.
  - `oneshot` (the default) is enforced by the user unit `cachyos-gamescope-autologin.service` (enabled through `graphical-session.target.wants`, skipped when
    `/run/user/$UID/gamescope-environment` exists). Whenever a desktop session starts, it resets autologin to gamescope, so **every boot goes to Game Mode**.
  - `persistent` masks that unit, so the device boots into whatever session was last used.
- **Why it booted into Plasma earlier today.** `zz-steamos-autologin.conf` was rewritten at 19:31:40, after the 19:30:56 boot. The 19:51 boot went straight to gamescope **(device)**.
  The mechanism is working. The earlier Plasma boot was most likely a prior "Switch to Desktop" (inference).
- **Known bug (device + source).** The install script's `sed` writes `DECK_USER_HOME=` instead of `DECKY_USER_HOME=` in `/etc/environment.d/handheld.conf`. **(device)**: the file contains
  `DECK_USER_HOME=/home/<user>`.
- **Unreleased.** cachyos-handheld **1.4.0** ([48289ff](https://github.com/CachyOS/CachyOS-PKGBUILDS/commit/48289ff6f5c518643a9fbdbfd26c83acd38bb8e8), 2026-08-26) and
  steamos-manager **26.4.1-2** with a plasmalogin patch ([aedff2d](https://github.com/CachyOS/CachyOS-PKGBUILDS/commit/aedff2da2f96a48bae07ec35fda9a6ae3ac2fcb7)) are in git but not on the mirror.
  The mirror serves 1.3.2-2 and 26.4.1-1, and 26.4.1-1 contains `sddm.service.d/reset-oneshot-boot.conf`, i.e. it targets SDDM. 1.4.0 switches "Return to Gaming Mode" to
  `steamosctl switch-to-game-mode` ([a2a30f4](https://github.com/CachyOS/CachyOS-Handheld/commit/a2a30f4)).
- **Boot entry anomaly (device).** systemd-boot's default entry is `onexplayer3-cachyos.efi`, but the current boot used `linux-cachyos-deckify.conf`.
  Any cmdline change must reach whichever entry actually boots.

### `cachyos-handheld` 1.3.2 contents (device `pacman -Ql`)
- **/etc:** `environment.d/handheld.conf`, `plasmalogin.conf.d/{cachyos,steam-deckify}.conf`, `logind.conf.d/steam-deckify.conf` (`HandlePowerKey=ignore`,
  `KillUserProcesses=True`), `security/limits.d/memlock.conf`, `xdg/autostart/steam.desktop` (`steam -silent -steamdeck`), KDE xdg configs.
- **/usr/lib:** `hwsupport/valve-hardware`, `modprobe.d/blacklist-handheld.conf` (`wdat_wdt`), `modules-load.d/hid-preload.conf`, `sdboot-manage.conf.d/10-handheld.conf`
  (Deck-only options), `sysctl.d/20-steamos-customizations.conf`, the `hhd@.service.d/override.conf` (commented), and udev rules.
- **Other:** audio presets for the Ally, Legion Go and Claw only, and pacman hooks (`blocked-packages`, `steam-force-handheld`).
- **Dependencies:** gamescope-session-cachyos, jupiter-hw-support, lib32-gamescope, mangohud, plasma-login-manager, scx-scheds, steam-jupiter-stable and others.
  **No** steamos-manager, hhd or inputplumber ([CachyOS-Handheld](https://github.com/CachyOS/CachyOS-Handheld)).
- **chwd's generic `[handheld]` profile** installs `steamos-manager inputplumber steamos-powerbuttond`, but its anchored product-name regex lists `ONEXPLAYER` and other models and **not
  `ONEXPLAYER 3`** ([profiles.toml](https://github.com/CachyOS/chwd/blob/master/profiles/pci/handhelds/profiles.toml), verified). That is why none of them are installed **(device)**.

### Repo versions vs installed (mirror listings fetched 2026-10-07)
| Package | Installed | Repo | Note |
|---|---|---|---|
| linux-cachyos-deckify | 7.2.9-1 | 7.2.9-1 | current |
| mesa / vulkan-intel | 26.2.4 | 26.2.4 | current |
| **gamescope / lib32-gamescope** | 3.16.25 | `cachyos-v3`: 3.16.25; **`cachyos`: 3.16.30**; PKGBUILD 3.16.31 ([7aa5ff0](https://github.com/CachyOS/CachyOS-PKGBUILDS/commit/7aa5ff0fd6)) | `cachyos-v3` comes first in pacman.conf and hides the newer build |
| gamescope-session-cachyos | 1.1.6 | 1.1.6 | current |
| cachyos-handheld | 1.3.2-2 | 1.3.2-2 (git 1.4.0) | — |
| steamos-manager | — | 26.4.1-1 | no OXP3 profile |
| hhd | — | 4.1.12 | no OXP3 Intel TDP; that is only in master |
| inputplumber | — | 0.81.0 (`cachyos-extra-v3`) | no OXP3 profile ([PR #672](https://github.com/ShadowBlip/InputPlumber/pull/672) open) |
| linux-firmware, intel-media-driver, mangohud, scx-* | current | current | — |
| plasma-login-manager | 6.7.4-3 | 6.7.4-3 (Arch 6.7.5) | minor lag |

### Decky Loader
Not packaged by CachyOS. The AUR package is stale (3.2.8). Upstream's method is
`curl -L https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh | sh`
([decky-loader README](https://github.com/SteamDeckHomebrew/decky-loader)). The latest release is
[v3.2.10](https://github.com/SteamDeckHomebrew/decky-loader/releases/tag/v3.2.10) (2026-10-04). It reads `DECKY_USER` from `handheld.conf`, so fix the typo first.

### Scheduler
- `/etc/scx_loader.toml` has `default_sched = "scx_lavd"` with no mode, which means Auto: `scx_lavd --autopilot`
  ([scx-loader config.rs](https://github.com/sched-ext/scx-loader/blob/main/crates/scx_loader/src/config.rs)). **(device)**: running lavd 1.1.3.
- CachyOS's PPD switches scx modes: power-saver → PowerSave (`--powersave`), performance → Gaming (`--performance`)
  ([wiki sched-ext](https://wiki.cachyos.org/configuration/sched-ext/)).
- lavd is designed for gaming handhelds ([lavd README](https://github.com/sched-ext/scx/tree/main/scheds/rust/scx_lavd)).
- **Keep lavd in Auto.** If hhd masks PPD, scx mode switching via PPD goes away too. Lavd's `--autopower` (which follows EPP) is then the alternative (speculative).

---

## Q4. Steam client / gamescope integration
- **Frame limiter.** Works: `STEAM_GAMESCOPE_DYNAMIC_FPSLIMITER=1` and `GAMESCOPE_LIMITER_FILE` are exported by `/usr/lib/steamos/gamescope-session` **(device)**.
- **Refresh rate slider.** gamescope only offers rates from a `known_displays` profile with `dynamic_refresh_rates` and `dynamic_modegen`, loaded from
  `/usr/share/gamescope/scripts`, `/etc/gamescope/scripts` or `~/.config/gamescope/scripts`. There is no upstream OXP3 profile (master
  [displays/](https://github.com/ValveSoftware/gamescope/tree/master/scripts/00-gamescope/displays)), and today the device loads none **(device log)**.
  - `STEAM_DISPLAY_REFRESH_LIMITS` is only set for Jupiter and Galileo, and `STEAM_GAMESCOPE_DYNAMIC_REFRESH_IN_STEAM_SUPPORTED=0` **(device)**.
  - Fix: ship a profile (see Reference repo review). The two native modes share the 380.16 MHz clock and differ only in VFP, so front-porch modegen is valid **(device EDID)**.
  - Caveat: upstream's Legion Go 2 profile matches the same `SDC/0x4301` code (see Q1).
- **Brightness.** `STEAM_ENABLE_DYNAMIC_BACKLIGHT=1` **(device)**. gamescope watches `/sys/class/backlight/*`. `intel_backlight` (raw PWM, 0–472) exists **(device)**.
  Whether the QAM slider works in SDR is **unverified**. The reference repo says it is dead while the output is BT.2020/PQ and works with the gamma-2.2 profile.
- **Battery charge limit.** Steam's QAM toggle comes from steamos-manager `BatteryChargeLimit1`, which needs `charge_control_end_threshold`. There is none on this unit **(device)**,
  oxpec has no OXP3 entry ([pdx86 for-next, newest is X2 Mini Pro 1b3c002](https://git.kernel.org/pub/scm/linux/kernel/git/pdx86/platform-drivers-x86.git/commit/?id=1b3c0028dc060d760791638b770396c8998f7306)),
  and lore was not checked (**unverified** whether a patch has been posted). **Not achievable today.**
- **Fan control.** `STEAM_ENABLE_FAN_CONTROL=1` is set, but there is no fan hwmon besides `acpi_fan` (read-only) **(device)**. Fan stays under firmware control.
- **OTA updates.** `holo-update` (installed as `steamos-update`) always exits 7, "nothing to update". Branch select is a stub. `steamos-firmware-update` only handles Lenovo
  devices via fwupd **(device)**. System updates are done with `pacman -Syu` or CachyOS's update tool from Desktop Mode.

---

## Q5. What changed in the last ~14 days (2026-09-23 → 2026-10-07)
- **Kernel:** 7.2.8 (09-25) and 7.2.9 (10-03), with PSR selective-fetch fixes and wa_14025941587. The linux-cachyos 7.2.9 deckify build was published 10-04 (installed).
  drm-xe-next added PTL ID 0xB0A1 (aee2d33da882, targets 7.4).
- **Mesa:** 26.2.4 (10-01) fixes the B390 UE5.8 crash. Jay became the default compiler on Xe2/Xe3 in main (09-24), with several PTL regressions since. 26.3-rc1 and 26.2.5 are due 10-14.
- **gamescope:** 3.16.30 (09-23) and 3.16.31 (09-27). CachyOS built 3.16.30 (09-26) but only into `[cachyos]`, not `cachyos-v3`.
- **PowerStation:** v0.8.2 (09-28) released OXP3 TDP support (MMIO only); v0.8.3 followed (10-04).
- **Decky Loader:** v3.2.10 (10-04).
- **hhd:** atomic config writes and Anatase checks (09-26 to 09-30). Still no release containing the OXP3 Intel TDP (09-07/08) or the controller support (09-09).
  Issue [#342](https://github.com/hhd-dev/hhd/issues/342) (09-23) reports the OXP3 volume rocker getting stuck (the same EC bug the reference repo describes).
- **intel-lpmd:** cpuset/IRQ fixes (d3d6301, 09-23).
- **SimpleDeckyTDP and steamos-manager:** refactors only.
- **Reference repo:** v1.6.0 (09-25) added the MSR-PL1 sync; v1.6.1 (09-25).
- **No change:** linux-firmware (no new PTL firmware); no new CachyOS ISO (latest release 26.08).
- **New PTL bug reports:** xe#9516, #9431, #9464, #9385, #9252; mesa#16463, #16423, #16500.

---

## Reference repo review: [HHHHanasak1/onexplayer3-steamos-setup](https://github.com/HHHHanasak1/onexplayer3-steamos-setup)

This repo targets **SteamOS 3.10** (kernel `7.2.x-valve-neptune`), not CachyOS. I reviewed it at HEAD [ea371b3](https://github.com/HHHHanasak1/onexplayer3-steamos-setup/commit/ea371b3) (2026-09-26, fix pack v1.6.1),
using the README, `oxp3-apply-fixes.sh`, `reference/` and `issues/`. Verdicts are for CachyOS Handheld with the versions above.

| Step | What it does | Verdict | Evidence |
|---|---|---|---|
| 0. Wi-Fi/BT firmware from `linux-firmware-intel` | SteamOS's `linux-firmware-neptune` lacks the BE201 files | **Not needed** | CachyOS ships `linux-firmware-intel 20260916`. **(device)**: iwlwifi `sc-a0-wh-b0-c106` and `ibt-00a0-01a1` load |
| 1. `nvme.noacpi=1` (GM7 `1dee:1602` only) | Stops the ACPI StorageD3 "simple suspend" path that kills the SSD on s2idle resume | **Adopt (critical)**, but put it in `LINUX_OPTIONS` in `/etc/sdboot-manage.conf` (or the UKI cmdline), not GRUB | Failure reproduced on this unit today. `noacpi` skips the `acpi_storage_d3()` → `NVME_QUIRK_SIMPLE_SUSPEND` path ([nvme pci.c](https://github.com/torvalds/linux/blob/master/drivers/nvme/host/pci.c), the `if (!noacpi && ... acpi_storage_d3())` block). Narrower alternative: `nvme.quirks=1dee:1602:force_no_simple_suspend` (the `quirks=VID:DID:names` parameter is present in v7.2 and `force_no_simple_suspend` is a named quirk; **untested**). The reference author reports 2/2 resumes OK with S0ix reached |
| 2. `options xe enable_dsb=0` | Silences a per-frame DSB poll-error flood under gamescope | **Not needed now / keep in reserve** | 0 DSB errors in today's gamescope boot **(device)**. The parameter is marked unsafe; upstream bug xe#9253. Add it only if the flood appears |
| 3a. gamescope Lua: 30–144 Hz `dynamic_modegen` | Gives Steam's per-game refresh slider real modes | **Adapt** | Panel EDID: identical 380.16 MHz clock at 60 and 144 Hz, range 30–144 **(device)**. Put it in `/etc/gamescope/scripts/` (system-wide; the session warns that directory is missing). Lua API as in upstream profiles ([onexplayer.f1.oled.lua](https://github.com/ValveSoftware/gamescope/blob/master/scripts/00-gamescope/displays/onexplayer.f1.oled.lua)). Use a high match score, because upstream's Legion Go 2 profile matches the same SDC/0x4301 code on gamescope ≥ 3.16.29. Verify VFP values with `drm_info`/`modetest` |
| 3b. Same Lua: HDR via `eotf = gamma22`, `force_enabled = true` | Avoids BT.2020/PQ output, which blanks this panel and kills the brightness slider | **Adapt (verify)** | Matches the Deck OLED and OXP F1 upstream approach. The repeated `vsc sdp mismatch (BT.2020 10 bpc)` WARN suggests BT.2020 output is being requested on this unit **(device)**. On gamescope ≥ 3.16.29, `software_backlight = true` is an alternative for PQ ([21c7e25](https://github.com/ValveSoftware/gamescope/commit/21c7e25)). Consider `force_enabled = false` so HDR stays a user choice |
| 4. Volume-key evdev forwarder (`oxp3-volkey-fix.py`) | The EC drops key-release scancodes | **Adapt, if the bug reproduces** | Same bug reported upstream in hhd [#342](https://github.com/hhd-dev/hhd/issues/342) (an hwdb workaround is suggested there). If hhd is adopted, try hhd's handling first. Not tested on this unit |
| 5. InputPlumber composite device + capability map | Home/Console/Keyboard keys, paddles, `deck-uhid` target | **Superseded by hhd-git, or adapt** | InputPlumber 0.81.0 has no OXP3 profile ([PR #672](https://github.com/ShadowBlip/InputPlumber/pull/672) open). hhd master has an OXP3 controller config (5e7ee0b). Do not run InputPlumber and hhd together |
| 6. Battery clamp service (bind-mounts over sysfs `capacity`/`energy_full`) | Steam shows 101–104 % after a full charge | **Optional / cosmetic** | Precondition present: `energy_full` 90.26 > design 84.55 Wh **(device)**. Bind-mounting over sysfs is hacky; skip it unless the display bothers you |
| 7. Gyro: ACPI SSDT override (`10EC5280` → `BMI0260`) + patched InputPlumber | IMU is a BMI260 claimed by the wrong driver | **Not now (experimental)** | **(device)**: `bmi160_i2c` loaded, no IIO device, which matches the diagnosis. Proper fix is a kernel ACPI-ID quirk in `bmi270_i2c` (not upstream; unverified). The patch is tied to InputPlumber 0.78 and BIOS 5.09 |
| 8. TDP sync service (copy MMIO PL1 → MSR PL1 every 2 s) | MMIO-only TDP tools leave the 25 W MSR PL1 in force | **Adopt if using SimpleDeckyTDP/PowerStation; not needed with hhd-git** | **(device)** MSR 25 W vs MMIO 35 W. The "GPU obeys MSR, CPU obeys MMIO" explanation is the author's interpretation. The documented behaviour is that both are enforced and the lower wins ([coreboot a247d8e5](https://review.coreboot.org/plugins/gitiles/coreboot/+/a247d8e53cebbd754e46f76412ed9d17df752308%5E%21)); the fix is the same either way. hhd writes both zones natively ([rapl.py](https://github.com/hhd-dev/hhd/blob/master/src/adjustor/core/rapl.py)) |
| Install via recovery image + `nomodeset 3 pci=noaer modprobe.blacklist=rtsx_pci` | SteamOS recovery-image workarounds | **Not applicable** | CachyOS is already installed. xe works on 7.2.9 **(device)** |
| README: charger note (≥100 W PD for TDP around 50 W) | AC/DC flapping resets firmware limits to 35/52 W | **Adopt as guidance** | Consistent with the MMIO 35/52 W values seen on AC **(device)** |
| README: never unbind/rebind `hid-oxp` (kernel Oops) | `oxp_rgb_status_store` NULL dereference | **Adopt as a rule** | `issues/hid_oxp_oops_rebind.txt`. `hid_oxp` is loaded on this kernel **(device)** |

---

## Recommended actions for postinstall scripts

**Confirmed** means it is backed by source plus device evidence. **Speculative** means it has not been tested on this unit.

1. **[Confirmed, do first] NVMe resume fix.** Append `nvme.noacpi=1` to `LINUX_OPTIONS` in `/etc/sdboot-manage.conf`, then run `sdboot-manage gen`. **Also** make sure the
   default `onexplayer3-cachyos.efi` entry (UKI: `/etc/kernel/cmdline`) carries it. Verify after reboot that `cat /proc/cmdline` shows it and that dmesg lacks `platform quirk: setting simple suspend`,
   then do one `rtcwake -m mem -s 30` test with a writable fs check.
   - Optional narrower variant (speculative): `nvme.quirks=1dee:1602:force_no_simple_suspend`.
   - Separately, investigate the early wake source: the suspend lasted about 2 s (`/sys/power/pm_wakeup_irq`, `/proc/acpi/wakeup`).
2. **[Confirmed] Newer gamescope.** Run `pacman -S cachyos/gamescope cachyos/lib32-gamescope` (3.16.30). Keep the explicit `cachyos/` repo prefix in the
   script. Without it, a later `-Syu` may still prefer `cachyos-v3` once that repo catches up or downgrades. Re-check whether the Legion Go 2 profile (SDC 0x4301) gets applied: grep the gamescope log for `[lenovo_legiongo2_oled] Matched`.
3. **[Confirmed] Fix the Decky env typo.** In `/etc/environment.d/handheld.conf`, replace `DECK_USER_HOME` with `DECKY_USER_HOME`. Re-apply after `cachyos-handheld`
   upgrades, because its install script re-runs the sed. Then install Decky v3.2.10 with the upstream installer.
4. **[Confirmed mechanism / speculative tuning] TDP.**
   - **Path A (recommended, closest to Deck UX):**
     - Install `hhd-git` (AUR) and enable `hhd@<user>`.
     - Uncomment `Environment="HHD_QAM_GAMESCOPE=1"` through a drop-in at `/etc/systemd/system/hhd@.service.d/` (not the packaged override).
     - Set `HHD_PPD_MASK=1`, or mask `power-profiles-daemon` yourself. Let hhd manage intel_lpmd, or disable it.
     - Do not install InputPlumber, PowerStation or SimpleDeckyTDP.
     - Range 3–35 W (preset), default 25 W.
   - **Path B (packaged pieces only):**
     - Install Decky + SimpleDeckyTDP.
     - Add a root `oxp3-tdp-sync.service` that mirrors the MMIO PL1 into the MSR PL1 (reference step 8).
     - Keep PPD. Consider disabling intel_lpmd.
     - Cap at 35 W.
   - **Native Steam slider (speculative, more work):** write a tiny system-bus service that implements `com.steampowered.SteamOSManager1.TdpLimit1` by writing both RAPL zones.
     Register it in `/etc/steamos-manager/remotes.d/oxp3.toml`, install `steamos-manager`, and add a local device TOML. Device TOMLs are only read from `/usr/share/steamos-manager/devices`,
     so the TOML is package-owned territory.
5. **[Speculative] gamescope display profile** at `/etc/gamescope/scripts/90-oxp3-oled.lua`:
   - Adapt the reference Lua: 30–144 Hz VFP table, gamma22 HDR, EDID colorimetry, matching `vendor=="SDC" and model contains "AMS881KB01"`, score above 5000 to beat the LGo2 profile.
   - Test the refresh slider, brightness slider and HDR toggle.
6. **[Speculative, reserve only]**
   - `options xe enable_dsb=0` in `/etc/modprobe.d/` if the DSB flood appears. The `kms` + `modconf` hooks mean you must regenerate the initramfs.
   - `xe.enable_psr=0` if screen corruption or streaks appear.
   - Keep VRR off until xe#8976 / #9252 are fixed.
7. **[Confirmed] Leave as is:**
   - scx_lavd Auto, linux-firmware 20260916, Mesa 26.2.x, intel-media-driver 26.3.5.
   - No `xe.force_probe`.
   - Do not install thermald.
   - When Mesa 26.3 arrives, keep `INTEL_DEBUG=no-jay` ready as a per-game launch option.
8. **[Confirmed] Session.** Keep `oneshot` mode, which is the default. `steam-deckify.conf` already has the user and `Relogin=true`. Nothing to change unless the user wants `persistent`.
9. **[Optional] Volume-key fix** (if the stuck-key bug reproduces) and the battery clamp (cosmetic). Adapt them from the reference repo.

## Open questions
- Does `nvme.noacpi=1` (or the targeted quirk) make s2idle reliable on this unit? Does it still reach S0ix (`/sys/kernel/debug/pmc_core/slp_s0_residency_usec`)? What woke the system after about 2 s?
- What is `onexplayer3-cachyos.efi`, and why did the current boot use `linux-cachyos-deckify.conf` instead? Cmdline changes must reach whichever entry actually boots.
- Does gamescope ≥ 3.16.29 apply the Legion Go 2 profile to this panel (same `SDC`/`0x4301`)? If so, is PQ plus software backlight acceptable here, or does the gamma22 profile still win?
- Is the QAM brightness slider functional with `intel_backlight` in SDR mode on this unit?
- Where does the `vsc sdp mismatch (BT.2020)` WARN come from, given it appears even in Plasma? Is it a gamescope/KWin colorspace request, or BIOS/VBT state?
- What causes the 7× `drmModeAddFB2WithModifiers failed: Invalid argument` in gamescope? It is probably a modifier probe and harmless; unverified.
- When will hhd cut a release with the OXP3 Intel TDP code, and will CachyOS package it? When will cachyos-handheld 1.4.0 and steamos-manager 26.4.1-2 reach the mirror?
- Is an oxpec patch for the OXP3 (fan, charge limit) posted on lore? lore was not checked.
- Is the volume-rocker EC bug present on this unit's BIOS 5.09 under CachyOS? Is the GSC proxy race visible to media apps?
