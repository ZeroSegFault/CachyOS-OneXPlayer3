# Intermittent stuck volume keys

In Game Mode, rapid volume-button taps can leave volume changing after release,
eventually reaching minimum or maximum. Isolated taps did not reproduce it.

## Evidence

- The physical AT keyboard reports volume down with scan code `ae` and up with
  `b0`. Both produced normal releases during the first short-tap test.
- After rapid taps reproduced the symptom, `EVIOCGKEY` on that same physical
  keyboard reported both `KEY_VOLUMEDOWN` and `KEY_VOLUMEUP` held across four
  samples one second apart, despite both buttons being released. PipeWire's
  default sink volume reached 100% during the capture.
- An assertion that neither volume key remained held failed before the fix.
  This puts the fault upstream of Steam and InputPlumber. Missing firmware
  releases are consistent with the evidence; the capture alone cannot distinguish
  firmware omission from a keyboard-driver problem.
- The keyboard's initial `force_release` list contained only `369-370`.

## Fix

`25-volume-keys` installs a model-specific AT-keyboard hwdb rule for `ae` and `b0`.
The `!` prefix tells atkbd to synthesize releases instead of expecting hardware
release events. This is documented in systemd's [keyboard hardware database](https://github.com/systemd/systemd/blob/main/hwdb.d/60-keyboard.hwdb).

Reload only the i8042 input devices after rebuilding the hardware database.
The live `force_release` list becomes `174,176,369-370`, and udev exposes
`KEYBOARD_KEY_ae=!volumedown` and `KEYBOARD_KEY_b0=!volumeup`. A second module run
does not rewrite the rule or reload devices. No reboot is needed.

Tradeoff: holding a button may no longer repeat. Repeated taps still adjust volume.

## Verification

Shell syntax, ShellCheck and whitespace checks pass. Live hardware verification
must include repeated rapid taps in both directions, checking for paired press
and release events and that neither key remains held after release. A userspace
synthetic keyboard does not exercise the EC/i8042/atkbd path, so it would not be
a meaningful automated regression test for this fault.
