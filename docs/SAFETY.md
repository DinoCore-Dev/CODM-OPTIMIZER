# Safety and recovery

## The rollback model

Before any value is changed, it is written to
`/data/adb/codm-optimizer/state/originals/<sanitised-path>`:

```
line 1: the key   (sys:/sys/devices/system/cpu/cpufreq/policy0/scaling_min_freq
                   or settings:system:min_refresh_rate)
line 2: the value it had when the module first touched it
```

Restore paths, in order of how often they happen:

| Event | What reverts it |
| --- | --- |
| Game leaves foreground | engine `deactivate()` |
| Screen off / game in background > 45 s | engine |
| Phone gets hot | thermal guard (also drops thermal lifts) |
| `codm-optimizer off` / `reset` | CLI |
| Engine killed with SIGTERM | trap in `engine.sh` |
| Engine killed with SIGKILL / crash / reboot mid-match | next engine start restores leftovers before doing anything |
| Module disabled in Magisk and rebooted | `service.sh` never starts, so nothing is applied; leftovers still restore on the next enabled boot |
| Module uninstalled | `uninstall.sh` stops the engine, restores, removes state |

The files are plain text. If you ever want to see exactly what was changed on
your phone:

```sh
su -c 'ls /data/adb/codm-optimizer/state/originals'
su -c 'cat /data/adb/codm-optimizer/state/originals/*'
```

If a restore could not be written (knob disappeared after a kernel change), the
line stays in the log as a warning and the file is kept, so you can restore it by
hand.

## The thermal guard

Always on, cannot be disabled from `config.conf`:

- battery ≥ `TEMP_LIMIT_C` (default 43 °C) → full rollback to stock, state `hot`
- SoC zone ≥ `TEMP_LIMIT_C + 20` → same
- resumes when the battery is `TEMP_RESUME_DELTA_C` (default 3 °C) below the limit

43 °C on the battery is a normal gaming temperature, not a danger limit. The
guard exists so that a lifted thermal policy does not win over the phone's own
protection, and so a hot phone gets the most conservative configuration instead
of the most aggressive one.

## `THERMAL_LIFT_C` — read this first

Default is `0`: **the module does not touch thermal policy at all.**

If you set it to, say, `3`:

- only `passive` / `hot` trip points of CPU, GPU and SoC zones are raised
- `critical` trips are never touched
- battery, charger and PMIC zones are never touched
- values outside 30–105 °C are ignored
- the maximum accepted value is 8 °C
- the guard above still triggers

What can still go wrong: the phone runs 3 °C hotter for longer, which is fine in
a cool room and not fine on a bed in a 35 °C ambient. Lithium cells age faster at
sustained high temperature, and the chassis can become uncomfortable. If you do
not have an external cooler, leave it at `0`.

## Bootloop / "it will not boot"

This module is built so that the usual causes cannot happen: it sets no
properties, mounts nothing, replaces no system files, and its `post-fs-data.sh`
only deletes a runtime directory. Still, if something goes wrong:

1. **Magisk safe mode** — hold Volume Down while the device boots. All modules
   are disabled for that boot.
2. Or from a root shell / recovery terminal:
   ```sh
   touch /data/adb/modules/codm-optimizer/disable     # disable it
   touch /data/adb/modules/codm-optimizer/remove      # remove it next boot
   ```
3. Or restore stock values immediately:
   ```sh
   sh /data/adb/modules/codm-optimizer/uninstall.sh
   ```
4. If the phone is already bootlooping: boot to recovery and use the Magisk
   app's "remove modules" or the `magisk --remove-modules` option from a
   recovery shell.

A reboot alone also clears any applied state, because the engine restores
leftovers on start and the kernel resets most of these knobs at boot anyway.

## Modifying the game itself

There is a whole genre of CODM modules that edit the game's Unity preferences
(`PlayerPrefs`) to force a frame cap, or spoof the device model so the game
offers more graphics options. This module does not, and here is the honest
reasoning:

- Those files are the game's own data. Editing them is a game-level change, and
  CODM's terms of service and security policy treat unauthorised modification as
  a violation. Enforcement has historically ranged from a temporary suspension
  to a permanent ban.
- Device identity spoofing (`ro.product.model`, GPU layers) is detectable and is
  exactly the sort of thing an anti-cheat is built to notice.
- The benefit is real but situational: it can unlock an option the game already
  supports. The system-side approach in this module gets most of the *smoothness*
  without touching a file the game owns.

If you decide to go that route, use an account you can lose, keep backups of the
original files, and do not expect any anti-cheat module to keep you safe.

## Root hiding

`codm-optimizer hide on` adds CODM to the Magisk DenyList. That is the same
mechanism used for banking apps: it hides the root *mount namespace*, not what
the module does. It is optional and never applied automatically.

Some phones report "root/emulator detected" in CODM with root present even
without this module. That is a root detection question, not a performance one,
and the fix is a hiding setup (DenyList plus, depending on your ROM, a Play
Integrity fix), not this module.

## Conflicts with other tuning modules

Two modules writing the same knobs will fight, and the loser is whatever ran
last — possibly after your game closed. Common conflicts:

- FDE.AI, L Speed, "game booster" scripts, thermal-null modules
- kernel managers (EX Kernel Manager, Kernel Adiutor, Franco) with "apply on boot"
- OEM game boosters that also change `min_refresh_rate` or game mode

Pick one. If you keep another one, disable its overlapping blocks
(refresh rate, GPU floor, CPU governor) or accept that `status` may show values
this module did not set.
