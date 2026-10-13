# OneXPlayer 3: disabling the charge limit stops charging

## Reproduction and cause

The battery reported `Charging` but drew 0 W, lost charge overnight, and did
not recover after swapping a cable/port or powering off and on. The driver
reported automatic charging and `charge_control_end_threshold=0`.

On-device measurements isolated the cause: setting the threshold to 100
restored about 36.8 W into the battery and increasing stored energy. Restoring
0 stopped charging after the controller/ACPI readings settled; setting 100
restored it again. Allow roughly 10–30 seconds for the physical readings to
catch up with a setting change.

A reboot initially retained 100, then the target changed to 0 during login.
A temporary session-bus monitor captured Steam setting
`BatteryChargeLimit1.MaxChargeLevel` to `-1` twice during startup. The sender
was resolved to the Steam process. Thus a boot-only write of 100 races Steam
and is insufficient.

SteamOS Manager v26.4.1 documents `-1` as resetting to the default, but its
root daemon translates `-1` to 0 for the native battery backend. Its user
daemon also presents a hardware value of 0 as `-1`. Those software semantics
do not match the observed OneXPlayer 3 controller behaviour.

Primary sources, pinned to the installed version:

- [BatteryChargeLimit1 API](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/v26.4.1/data/interfaces/com.steampowered.SteamOSManager1.xml)
- [Root daemon's SetMaxChargeLevel translation](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/v26.4.1/steamos-manager/src/manager/root.rs)
- [User daemon's battery property](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/v26.4.1/steamos-manager/src/manager/user.rs)
- [Native battery sysfs backend](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/v26.4.1/steamos-manager/src/power.rs)
- [Supported remote interfaces](https://gitlab.steamos.cloud/holo/steamos-manager/-/blob/v26.4.1/README.md#interoperability)

The symptom was reported after a system update. The kernel changed from
7.2.9-1 to 7.2.9-2; SteamOS Manager and the charging driver's source did not
change. The [kernel packaging diff](https://github.com/CachyOS/linux-cachyos/compare/ee39638ff003...59f65f1b18e6)
shows an NVIDIA rebuild and Rust-header packaging changes. The timing does
not establish which update triggered the first occurrence.

## Required fix and verification

Implement a device-specific `BatteryChargeLimit1` remote, using the existing
oxpec sysfs control. Translate the API's disabled/default limit to 100%, keep
positive user limits, and reject invalid values without changing hardware.
Remove the native `acpi_sb` configuration so it cannot take precedence over
the remote. Avoid polling that fights Steam, kernel forks, and editing Steam's
private configuration. Continue to leave battery bypass and fan control alone.

The installer must deploy this idempotently and retain it through package
updates and reboots. Verify the D-Bus interface, an 80% limit, disabling that
limit, and actual increasing battery energy after Steam finishes startup.

Run `bash tools/charge-limit-test.sh` on the handheld in its user's session.
Before the fix it reports:

```text
PASS: request 80 -> hardware target 80%
FAIL: request -1 -> hardware target 0%, expected 100%
```

The test restores the previous positive target, or 100% if it started at the
broken zero value. It does not suspend or reboot the device.
