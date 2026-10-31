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
id=codm-optimizer     version=v1.1.0     Android 8+     Magisk 20.4+ / KernelSU / APatch
```

It comes with a **Web UI** — you configure it by tapping, from inside your module
manager. There is nothing to type. An `adaptive` profile is on by default: it
eases the GPU and the refresh rate down *before* your phone reaches its thermal
limit, then gives it all back when the phone cools.

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
- **Five profiles, `adaptive` by default** — it steps the GPU floor and refresh
  rate down as the phone warms, before the phone throttles itself, then restores
  them when it cools. Fixed profiles (`battery`, `balanced`, `performance`,
  `extreme`) are there for phones with unreliable thermal sensors.
- **Exact rollback.** Every knob write stores the previous value first
  (`/data/adb/codm-optimizer/state/originals`), so stopping, rebooting,
  uninstalling or a thermal event puts the device back. Crash-safe: the engine
  restores leftovers before starting.
- **Android Game Mode API.** Uses `cmd game set` / `device_config game_overlay`
  (the same path the Android game dashboard uses) to ask for performance mode,
  an FPS target, or a render-scale reduction. Version-aware: Android 14, 13 and
  12 each get the call they actually support.
- **Capability probing, never assumptions.** If a device does not expose a knob,
  it is skipped and reported as "not exposed" instead of pretending. The Web
  UI's **Info** tab lists exactly what works on *your* phone.
- **Thermal guard that cannot be turned off.** At `TEMP_LIMIT_C` (default 43 °C
  battery) the whole profile is dropped to stock until the phone cools 3 °C.
- **A Web UI you tap, not a terminal you type at.** It ships inside the module,
  so KernelSU / APatch / MMRL open it with one tap: a status screen, every
  setting as a switch or slider, the log, and session history.

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

1. Download `codm-optimizer-v1.1.0.zip` from Releases, or build it (see below).
2. Install it from your module manager:
   - **KernelSU** → **Modules** → **Install from storage**
   - **APatch** → **Modules** → **Install from storage**
   - **Magisk** → **Modules** → **Install from storage**
3. Reboot.
4. Open the module manager, tap CODM Optimizer, then **Open** / **Web UI**
   (see below). You should see the battery temperature and a status pill that
   says *watching*.

That is the whole setup. No terminal, no config file, no commands.

From a computer, if you prefer:

```sh
adb push codm-optimizer-v1.1.0.zip /sdcard/Download/
adb shell su -c 'magisk --install-module /sdcard/Download/codm-optimizer-v1.1.0.zip'
adb reboot
```

The zip ships the standard `META-INF` wrapper, so flashing it from a custom
recovery with Magisk already installed also works.

## The Web UI

Everything is done by tapping. The module ships its own interface and your
module manager serves it:

| Manager | How to open it |
| --- | --- |
| **KernelSU** | **Modules** → CODM Optimizer → **Open** (Web UI) |
| **APatch** | **Modules** → CODM Optimizer → **Web UI** |
| **Magisk** | install [MMRL](https://github.com/MMRLApp/MMRL), then Modules → CODM Optimizer → **WebUI**; without MMRL, the module's **Action** button still gives you a one-shot status card |

Four tabs:

- **Status** — battery temperature on a gauge with the last two minutes as a
  sparkline, what the engine is doing right now (*watching* / *in game* /
  *cooling*), which thermal step adaptive is on, panel refresh rate, Android game
  mode, and how your last session ended.
- **Tune** — the profile cards and every setting as a switch or a slider:
  refresh lock, Android Game Mode with fps target and render scale, thermal
  limit, the GPU floor for each thermal step, how often to poll, how often to
  re-apply. Changes are written as you touch them; there is no *Save* button.
- **Logs** — the module log, and the session history with length, peak
  temperature and end reason.
- **Info** — device, root, module version, and a capability list that says
  plainly what your phone exposes. *not exposed* is not an error: it means the
  module skips that knob instead of faking it.

The interface is three local files plus a small bridge script:

```
module/webroot/
├── index.html      markup
├── style.css       the entire theme, no external fonts or images
├── app.js          polling, rendering, taps
└── actions.sh      the bridge the page calls as root (0755)
```

It makes **no network requests**: no CDN, no analytics, no fonts, no `http(s)`
URLs anywhere in the source. `tools/lint.sh` enforces that, together with
"every control in the page has a handler in the bridge" and "every value the UI
reads is actually emitted by the bridge".

> Older managers with no WebUI support: the CLI below does the same things. It
> exists because some ROMs and some setups still need it — not because you are
> expected to use it.

## Profiles

| Profile | What it does | Best for |
| --- | --- | --- |
| `adaptive` **(default)** | balanced while cool, then lowers the GPU floor and refresh rate in two steps before the thermal limit | every phone, every climate |
| `balanced` | fixed moderate ramp, GPU floor 30 % | ROMs that misreport thermals |
| `performance` | faster ramp, GPU floor 50 % | flagship-adjacent hardware |
| `extreme` | fastest ramp, GPU floor 70 % | external cooler, short sessions |
| `battery` | lowest floors, minimal tuning | long sessions, hot days |

`adaptive` is the one to leave alone unless you have a reason. Its ladder, with
the defaults (`TEMP_LIMIT_C=43`):

| Battery temperature | GPU floor | Refresh |
| --- | --- | --- |
| below 38 °C | 40 % | as configured |
| 38 °C (limit − 5) | 28 % | as configured |
| 41 °C (limit − 2) | 15 % | capped at `ADAPT_HZ_HOT` (90 Hz) |
| 43 °C (limit) | released — stock behaviour until 40 °C | stock |

Each step is a reduction, never an increase: the phone is never pushed harder
than its own thermal policy allows, it just stops being pushed in the wrong
place. Every step is adjustable in **Tune → Adaptive**. Details:
[docs/TUNING.md](docs/TUNING.md).

## Command line (optional)

The same controls exist as a CLI for scripts and for managers without WebUI
support:

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
status` from Termux is enough. Column formatting is text-only; the Web UI shows
the same data as gauges and switches.

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

GPU floor is a percentage of the frequency range the GPU itself advertises, so
the same profile means sensible things on a Snapdragon 680 and an 8 Gen 3.

## Compatibility

| Requirement | Notes |
| --- | --- |
| Android 8.0+ (API 26) | Game Mode integration needs 12+ (API 31) |
| Magisk 20.4+ / KernelSU / APatch | any recent version |
| CODM Global, Garena, VNG, Tencent | packages are built in; `EXTRA_PACKAGES=` for re-releases |
| Any SoC | Adreno and Mali devfreq are probed; unknown GPUs are left alone |

**Honest status:** this repository is validated by an offline suite — 107 shell
checks (config parsing, knob write/rollback, the adaptive thermal ladder, thermal
parsing, game-mode dispatch per API level, the WebUI bridge contract) and 43
headless UI checks that load `index.html` in jsdom and assert every panel
renders. It has not been benchmarked on retail hardware by the author. The
**Info** tab is designed to tell you what is real on your device and what is
skipped, rather than claim a number.

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

To pause instead of uninstalling: switch the engine off in **Tune**, or create
`/data/adb/modules/codm-optimizer/disable` and reboot.

## Development

```sh
./tools/lint.sh     # syntax (busybox ash), CRLF, module.prop, bashisms, dangerous patterns
./tools/test.sh     # 107 offline tests, no phone required
npm install jsdom && node tools/uitest.js   # 43 headless WebUI checks (optional)
./build.sh          # lint + test + dist/codm-optimizer-v1.1.0.zip (+ sha256)
./build.sh --fast   # package only
```

The Web UI renders without a phone: serve the folder and open it with `?demo=1`,
which fills every panel with sample data (the banner says so, and nothing is
applied):

```sh
python3 -m http.server -d module/webroot 8000
# http://localhost:8000/?demo=1
```

`tools/uitest.js` does the same thing headlessly and asserts that each tab
renders, that a slider write reaches the bridge, and that a snapshot arriving
mid-drag cannot snap a control back.

Layout:

```
module/                 contents of the zip (module.prop at the root, as Magisk requires)
  common/               sourced libraries: engine, profile, device, game, thermal, display, gamemode
  webroot/              the Web UI (index.html, style.css, app.js, actions.sh)
  system/bin/           codm-optimizer CLI
  config/default.conf   initial user config
  profiles/             per-profile kernel knobs
  *.sh                  Magisk lifecycle hooks + the Action button card
tools/                  lint, offline shell tests, headless UI test
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
