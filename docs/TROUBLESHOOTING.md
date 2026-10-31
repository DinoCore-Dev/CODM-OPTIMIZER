# Troubleshooting

Start with the Web UI — open the module manager, tap CODM Optimizer, **Open**:

1. **Status** — is the pill *watching* (engine alive), *in game*, *cooling*, or
   *engine off*? Is the battery temperature moving?
2. **Info** — the capability list. Anything marked *not exposed* is a knob your
   kernel does not offer; the module skips it on purpose.
3. **Logs** — the last lines, newest at the bottom.

That is enough for almost every problem. The commands below are the same things
as text, for a root shell or for pasting into a bug report:

| Web UI | Command |
| --- | --- |
| **Info** (capability list) | `codm-optimizer doctor` |
| **Status** | `codm-optimizer status` |
| **Logs** | `codm-optimizer log 60` |
| **Tune → Engine** off/on | `codm-optimizer off` / `on` |
| **Tune → profile card** | `codm-optimizer profile <name>` |
| any switch or slider | `codm-optimizer set <KEY> <VALUE>` |
| **Tune → Revert everything** | `codm-optimizer reset` |

`doctor` is written to be readable by people who did not write the module. A
`WARN` almost always means "your kernel/ROM does not expose this", not "you did
something wrong" — the **Info** tab says the same thing in fewer words.

---

## The engine is not running

`doctor` → `FAIL engine not running`.

```sh
su -c codm-optimizer start
```

If it still refuses, read the log:

```sh
su -c tail -40 /data/adb/codm-optimizer/logs/module.log
```

| Log line | Meaning |
| --- | --- |
| `engine already running (pid ...)` | a pid file survived; the module refuses to run two engines |
| `module directory not found` | the module is installed but not mounted (reboot, or check Magisk) |
| nothing at all | `service.sh` did not run: check that the module is enabled and not in Magisk's "core only" mode |

A module id in `/data/adb/modules/codm-optimizer/disable` disables it entirely —
`codm-optimizer on` removes the flag and starts the engine.

## "cpu frequency control FAIL"

The kernel exposes no `/sys/devices/system/cpu/cpufreq/*`. That is unusual on a
retail phone; it happens with some emulators, containers and locked-down kernels.
The module then only does display + game mode, and says so.

## "gpu frequency control WARN — no devfreq/sysfs GPU node"

The GPU is controlled by a vendor driver that does not publish a standard
devfreq node (some MediaTek and older Exynos kernels). GPU floors are skipped.
This is intentional: writing to undocumented GPU interfaces is how tuning modules
break displays.

## "refresh rate settings WARN — ROM ignores min/peak_refresh_rate"

`settings get system peak_refresh_rate` returns `null` and the ROM does not react
to writes. `REFRESH_LOCK` cannot do anything on this device; the panel is
controlled by the OEM framework (common with MIUI/HyperOS, One UI and ColorOS).
Options:

- use the OEM's own per-game refresh/perf setting,
- or accept 60 fps in the game if the panel falls back.

## The game is not detected

`status` shows `game not installed` or `[none]` while CODM is open.

1. Confirm the package name:
   ```sh
   su -c pm list packages | grep -i -E 'codm|callofduty'
   ```
2. If it is not one of the built-in names, add it:
   ```sh
   su -c codm-optimizer set EXTRA_PACKAGES "com.example.codm"
   ```
3. Some ROMs hide the `top-app` cpuset; the module falls back to `dumpsys
   activity`. `doctor` shows which path is used under *foreground detection*.
4. Cloud-gaming or cloned/dual-app instances run under a different user id and
   package suffix and are not detected.

## Applied, but the game feels the same

Check that something was actually written:

```sh
su -c codm-optimizer status     # while CODM is in the foreground
```

Then, one at a time:

- **Try another profile**: `codm-optimizer profile performance`.
- **Check the FPS the game offers.** If CODM only lists "High" and not "Very
  High"/90/120, the limit is the game's own device profile, not the panel.
  Refresh locking cannot add an option the game does not offer.
- **Check the panel is actually running at the rate you think.** Many phones drop
  to 60 Hz in games regardless of the setting.
- **Check throttling**: `codm-optimizer sessions` shows the peak battery
  temperature per session. If a session ends with `(hot)`, the guard fired and
  the profile was released mid-match — that is the phone, not the module.
- **Are you thermal limited before you start?** Play the first match without the
  module to see whether the difference is real.

The module cannot exceed what the SoC and the game allow. What it removes is
*avoidable* stutter: slow ramping, GPU downclocking between frames, the panel
dropping to 60 Hz.

## "cmd game ... not supported by package"

The platform refuses the game mode call. Usually the game does not declare
`android:appCategory="game"` on that ROM's build, or the ROM has no GameManager
service (AOSP-only ports). Everything else in the module still works.

## Values stayed applied after a crash

They should self-heal on the next engine start:

```sh
su -c codm-optimizer restart
su -c codm-optimizer log 40      # look for "found leftover knobs"
```

To force it:

```sh
su -c codm-optimizer release
```

## The module fights another tuning module

See [SAFETY.md](SAFETY.md#conflicts-with-other-tuning-modules). Short version:
two writers, one truth. Disable the overlapping blocks in one of them.

## Battery drain

The engine itself is one process waking every 5–15 s. Real drain comes from the
profile you chose, the refresh lock, and holding high clocks: that is the point.
If it is too much:

```sh
su -c codm-optimizer profile battery
su -c codm-optimizer set REFRESH_HZ 90
su -c codm-optimizer set TEMP_LIMIT_C 40
```

## Collecting a useful bug report

```sh
su -c codm-optimizer doctor      > /sdcard/Download/codm-doctor.txt
su -c codm-optimizer status      >> /sdcard/Download/codm-doctor.txt
su -c codm-optimizer log 200     >> /sdcard/Download/codm-doctor.txt
su -c cat /data/adb/codm-optimizer/config.conf >> /sdcard/Download/codm-doctor.txt
su -c getprop | grep -E 'ro.product|ro.soc|ro.board|ro.build.version' >> /sdcard/Download/codm-doctor.txt
```

That is everything needed to say whether a knob exists on your hardware, and it
contains no personal data beyond model and ROM version.
