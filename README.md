# CODM Optimizer

A Magisk / KernelSU / APatch module that makes **Call of Duty: Mobile** hold its
frame rate on phones that *should* be able to run it.

It does one thing, and tries to do it well: while CODM is in the foreground it
tunes the parts of Android that decide how quickly the CPU ramps, how much the
GPU is allowed to downclock, what refresh rate the panel runs at, and what game
mode the platform applies. The moment the game leaves the screen — or the phone
gets hot, or you turn it off — every value is written back to exactly what it
was before.

It never touches the game's files, its memory, or its network traffic.

```
id=codm-optimizer     version=v1.0.0     Android 8+     Magisk 20.4+ / KernelSU / APatch
```

---

## Why this exists

CODM is a 2019 Unity title with a 2026 content pipeline. On a mid-range 2023
phone it does not run badly — it runs *inconsistently*. The usual causes are not
the GPU and not RAM:

| What actually happens | Why the phone does it | What this module does |
| --- | --- | --- |
| Frame drops in the first seconds of a firefight | `schedutil` measures load *after* it appears; the ramp takes 4–20 ms | lowers `up_rate_limit_us` while the game is visible |
| Frame pacing falls apart after a while | GPU devfreq drops the clock between frames | raises the GPU floor as a percentage of its range |
| The game caps at 60 fps on a 120 Hz panel | the ROM drops to 60 Hz when it thinks nothing needs more | locks `min/peak_refresh_rate` to the panel maximum |
| Stutter after a menu or a respawn | TCP restarts from a small congestion window after idle | keeps congestion state warm |
| Throttling after ~15 minutes | vendor thermal policy, sometimes far below the chassis limit | *optionally* nudges passive trips, and hard-stops at a battery temperature you choose |

None of that lives in the game. All of it is OS behaviour, which is why a module
can change it and why uninstalling really does undo it.

## What it does

- **Foreground-aware engine.** One tiny shell loop. Idle cost is a `pidof` every
  15 seconds. Nothing runs while you are not gaming.
- **Four profiles** — `battery`, `balanced` (default), `performance`, `extreme`.
  Switch at runtime; the engine notices within 15 seconds.
- **Exact rollback.** Every knob write stores the previous value first
  (`/data/adb/codm-optimizer/state/originals`), so stopping, rebooting,
  uninstalling or a thermal event puts the device back. Crash-safe: the engine
  restores leftovers before starting.
- **Android Game Mode API.** Uses `cmd game set` / `device_config game_overlay`
  (the same path the Android game dashboard uses) to ask for performance mode,
  an FPS target, or a render-scale reduction. Version-aware: Android 14, 13 and
  12 each get the call they actually support.
- **Capability probing, never assumptions.** If a device does not expose a knob,
  it is skipped and reported as "not supported here" instead of pretending.
  `codm-optimizer doctor` prints exactly what works on *your* phone.
- **Thermal guard that cannot be turned off.** At `TEMP_LIMIT_C` (default 43 °C
  battery) the whole profile is dropped to stock until the phone cools 3 °C.
- **Diagnostics built in.** `status`, `doctor`, `sessions`, a log, and a Magisk
  action-button snapshot.

## What it does **not** do

This matters more than the feature list, so it is not buried:

- **No cheats.** No aimbot, ESP, radar, macros, recoil scripts or sensitivity
  changes. Nothing here gives an in-game advantage.
- **No anti-cheat evasion.** No Zygisk injection into the game, no memory
  patching, no APK or OBB modification, no hooking. The module runs entirely
  outside the game process.
- **No game file edits.** The FPS options CODM shows are decided by the game and
  by the device identity it reads. This module changes the *system* side (panel
  refresh, platform game mode) and leaves the game's own data alone. If you want
  to edit `PlayerPrefs` to force a frame cap, that is a different project with a
  different risk profile — see [docs/SAFETY.md](docs/SAFETY.md#modifying-the-game-itself).
- **No benchmark numbers invented in a readme.** No hardware results are claimed
  for this module. What your device supports is printed by `doctor` on your
  device, not by a table here.

> Editing game preferences, spoofing a device model, or patching GPU drivers to
> unlock frame rates can violate the CODM terms of service. This module avoids
> all three on purpose. Root use itself is not against the rules, but any account
> you value deserves its own risk assessment.

## Install

### Magisk (recommended)

1. Download `codm-optimizer-v1.0.0.zip` from Releases, or build it (see below).
2. Magisk → **Modules** → **Install from storage** → pick the zip.
3. Reboot.
4. Unlock the phone, wait ~15 seconds, then check:

```sh
su -c codm-optimizer doctor
```

From a computer:

```sh
adb push codm-optimizer-v1.0.0.zip /sdcard/Download/
adb shell su -c 'magisk --install-module /sdcard/Download/codm-optimizer-v1.0.0.zip'
adb reboot
```

### KernelSU / APatch

Same zip: KernelSU → **Modules** → **Install from storage**, or APatch → **Modules**.
The module only needs `sh`, so there are no architecture or binary-compat issues.
The CLI lands on `PATH` for any root shell.

### Recovery (optional)

The zip ships the standard `META-INF` wrapper, so flashing it from a custom
recovery with Magisk already installed also works.

### After installing

Open CODM and play one match. Then:

```sh
su -c codm-optimizer status     # what is applied right now
su -c codm-optimizer sessions   # length, peak temperature, how each match ended
```

## Command line

```sh
codm-optimizer status              # one screen: device, engine, game, CPU/GPU, thermal, display
codm-optimizer doctor              # capability checks with PASS/WARN/FAIL and hints
codm-optimizer profile             # list profiles and mark the active one
codm-optimizer profile performance # switch profile (takes effect live)
codm-optimizer on | off            # enable or disable the engine, persistently
codm-optimizer apply | release     # apply or revert immediately, without the engine
codm-optimizer game on|off         # Android Game Mode API integration
codm-optimizer game fps 90         # ask the platform for 90 fps (0 = device default)
codm-optimizer game downscale 0.8  # render scale 0.5–1.0, or off
codm-optimizer display 120         # lock the panel at 120 Hz while gaming
codm-optimizer hide on            # add CODM to the Magisk DenyList (root hiding)
codm-optimizer log 60              # last 60 log lines
codm-optimizer sessions            # recent gaming sessions
codm-optimizer set KEY VALUE       # change one config key
codm-optimizer reset               # revert everything and restore default config
```

The CLI re-executes itself through `su` if you forget it, so `codm-optimizer
status` from Termux is enough.

## How it works

```
              ┌──────────────── engine loop (one sh process) ────────────────┐
              │                                                             │
  every 15 s  │  pidof CODM ──── no ───▶ idle (nothing applied)              │
              │      │                                                      │
              │     yes                                                     │
              │      ▼                                                      │
              │  in top-app cpuset? ── no ──▶ 45 s grace ──▶ release + idle  │
              │      │ yes                                                  │
              │      ▼                                                      │
  every 5 s   │  screen on? ── no ──▶ release                               │
              │      │ yes                                                  │
              │      ▼                                                      │
              │  apply profile ──▶ re-apply every 60 s (ROMs reset knobs)   │
              │      │                                                      │
  every 20 s  │  temperature ──▶ over limit? ──▶ full rollback until cool   │
              └─────────────────────────────────────────────────────────────┘
```

Foreground detection uses the `top-app` cpuset (`/sys/fs/cgroup/top-app/cgroup.procs`
or `/dev/cpuset/top-app/cgroup`), which is what Android itself uses to decide
which process gets priority. A `dumpsys activity` fallback covers ROMs without
cpusets. Screen state comes from `dumpsys power`.

The engine runs from `service.sh` after `sys.boot_completed`, never from
`post-fs-data` — the boot-blocking stage only clears a stale runtime directory.
The only failure mode that could cost you a bootloop is deliberately absent: the
module does not set properties, does not mount anything at boot, and does not
replace system files.

## Profiles

| Profile | CPU ramp | GPU floor | uclamp | Best for |
| --- | --- | --- | --- | --- |
| `battery` | relaxed | 15 % | off | long sessions, hot climates |
| `balanced` *(default)* | moderate | 30 % | off | most phones |
| `performance` | fast | 50 % | 20 % | flagship-adjacent hardware |
| `extreme` | fastest | 70 % | 40 % | external cooler, short sessions |

GPU floor is a percentage of the frequency range the GPU itself advertises, so
the same profile means sensible things on a Snapdragon 680 and an 8 Gen 3.
Details and every knob: [docs/TUNING.md](docs/TUNING.md).

## Compatibility

| Requirement | Notes |
| --- | --- |
| Android 8.0+ (API 26) | Game Mode integration needs 12+ (API 31) |
| Magisk 20.4+ / KernelSU / APatch | any recent version |
| CODM Global, Garena, VNG, Tencent | packages are built in; `EXTRA_PACKAGES=` for re-releases |
| Any SoC | Adreno and Mali devfreq are probed; unknown GPUs are left alone |

**Honest status:** this repository has been validated with an offline test suite
(79 checks: config parsing, knob write/rollback, thermal parsing, game-mode
dispatch per API level, report generation) and syntax-checked against busybox
`ash`. It has not been benchmarked on retail hardware by the author. Run
`codm-optimizer doctor` on your phone: it is designed to tell you what is real on
your device and what is skipped, rather than claim a number.

## Safety

- Everything the module writes is saved first and restored on exit, on disable,
  on uninstall and on the next boot after a crash.
- The thermal guard is always on and has priority over everything else.
- `THERMAL_LIFT_C` (raising thermal trips) defaults to `0` — off.
- Recovery instructions, including Magisk safe mode and manual disable:
  [docs/SAFETY.md](docs/SAFETY.md).

Read [docs/SAFETY.md](docs/SAFETY.md) before setting `THERMAL_LIFT_C`, and
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) if `doctor` reports warnings.

## Uninstall

Magisk → Modules → remove **CODM Optimizer** → reboot. `uninstall.sh` stops the
engine, restores every saved knob, removes the Game Mode overrides, and deletes
`/data/adb/codm-optimizer`.

To pause instead of uninstalling: `codm-optimizer off` (or create
`/data/adb/modules/codm-optimizer/disable` and reboot).

## Development

```sh
./tools/lint.sh     # syntax (busybox ash), CRLF, module.prop, bashisms, dangerous patterns
./tools/test.sh     # 79 offline tests, no phone required
./build.sh          # lint + test + dist/codm-optimizer-v1.0.0.zip (+ sha256)
./build.sh --fast   # package only
```

Layout:

```
module/                 contents of the zip (module.prop at the root, as Magisk requires)
  common/               sourced libraries: engine, profile, device, game, thermal, display, gamemode
  system/bin/           codm-optimizer CLI
  config/default.conf   initial user config
  profiles/             per-profile kernel knobs
  *.sh                  Magisk lifecycle hooks
tools/                  lint + offline test suite
docs/                   tuning reference, safety, troubleshooting
build.sh                packaging
```

Runtime state (not in the zip, survives module updates):

```
/data/adb/codm-optimizer/
├── config.conf         your settings
├── logs/module.log     rotated at 512 KiB
├── state/originals/    pre-write values used for rollback
├── sessions/sessions.tsv
└── run/                pid, lock, engine state
```

## Credits

Built on the work of others: [Magisk module documentation](https://topjohnwu.github.io/Magisk/guides.html)
(Topjohn Wu), [Android Game Mode API and interventions](https://developer.android.com/games/optimize/adpf/gamemode/gamemode-interventions)
(Google), the kernel scheduler documentation for util-clamp and schedutil, and
the long tradition of XDA tuning threads that established which of these knobs
are real and which are folklore.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

Flashing anything is your decision and your risk. The module is designed to be
reversible and conservative, but no shell script can promise a smooth ride on
every ROM. Keep a working boot image and a backup, and do not use this on a
phone you cannot afford to fix. Not affiliated with Activision, Tencent, Garena,
VNG, Google or the Magisk project. "Call of Duty" is a trademark of Activision
Publishing, Inc.
