# Tuning reference

Every knob the module can write, what it is for, and what happens if it is not
there. Nothing is written unless it exists **and** is writable.

If a path is not listed as writable by `codm-optimizer doctor`, the module skips
it silently (verbose logging shows why: `codm-optimizer set VERBOSE_LOG 1`).

---

## Engine keys (`/data/adb/codm-optimizer/config.conf`)

| Key | Default | Meaning |
| --- | --- | --- |
| `PROFILE` | `balanced` | `battery`, `balanced`, `performance`, `extreme` |
| `ENGINE_ENABLED` | `1` | `0` releases everything and parks the engine |
| `POLL_GAME_SEC` | `5` | poll interval while CODM is visible |
| `POLL_IDLE_SEC` | `15` | poll interval otherwise |
| `REAPPLY_SEC` | `60` | re-apply cadence while gaming (some ROMs reset knobs) |
| `GUARD_INTERVAL_SEC` | `20` | temperature sampling interval |
| `VERBOSE_LOG` | `0` | log every skipped/blocked knob write |
| `GAME_MODE` | `1` | use the Android Game Mode API while gaming |
| `GAME_MODE_FPS` | `0` | request N fps (`0` = leave it alone) |
| `GAME_MODE_DOWNSCALE` | `off` | `0.5`–`1.0`, the platform render-scale intervention |
| `REFRESH_LOCK` | `1` | pin the panel to `REFRESH_HZ` while gaming |
| `REFRESH_HZ` | `auto` | `auto` = highest the panel advertises, or e.g. `90` |
| `EXTRA_PACKAGES` | *(empty)* | additional CODM package names, space separated |
| `TEMP_LIMIT_C` | `43` | battery °C at which the profile is dropped |
| `TEMP_RESUME_DELTA_C` | `3` | hysteresis before resuming |
| `THERMAL_LIFT_C` | `0` | raise passive thermal trips by N °C (`0` = never) |

Lower polling intervals cost more power and win little; the defaults are already
aggressive enough to catch the game within one poll.

---

## Profile keys

Set in `<module>/profiles/<profile>.conf`, and **overridden by the same key in
`config.conf`** if you add it there.

| Key | Default (balanced) | What is written | Notes |
| --- | --- | --- | --- |
| `CPU_TUNE` | `1` | enables the CPU block | |
| `CPU_GOVERNOR` | `auto` | `scaling_governor` | only if the governor is in `scaling_available_governors` |
| `CPU_UP_RATE_US` | `2000` | `schedutil/up_rate_limit_us` (and `rate_limit_us`) | the main latency knob |
| `CPU_DOWN_RATE_US` | `8000` | `schedutil/down_rate_limit_us` | higher = holds clocks longer |
| `CPU_MIN_PCT` | `0` | `scaling_min_freq` as % of the range | `0` leaves the vendor floor alone |
| `GPU_TUNE` | `1` | enables the GPU block | |
| `GPU_GOVERNOR` | `auto` | devfreq `governor` | rarely has more than one option |
| `GPU_MIN_PCT` | `30` | GPU `min_freq` as % of its range | the single biggest anti-jank knob |
| `UCLAMP_TOPAPP_MIN` | `0` | `top-app/uclamp.min` or `cpu.uclamp.min` | percentage; raises the priority floor |
| `STUNE_BOOST` | `-1` | `top-app/schedtune.boost` | legacy cgroup v1 kernels; `-1` = skip |
| `IO_SCHED` | `auto` | `/sys/block/*/queue/scheduler` | e.g. `none` for UFS |
| `TOPAPP_CPUS` | `auto` | `top-app/cpus` | e.g. `0-7`; `auto` leaves the ROM's set |
| `TCP_TWEAK` | `1` | network block | |
| `TCP_CC` | `auto` | congestion control | `bbr` if the kernel allows it |
| `THERMAL_LIFT_C` | `0` | thermal trip points | see below, off by default |

### Notable knobs, in detail

**`CPU_UP_RATE_US`** — the delay `schedutil` applies before raising frequency.
Vendors set 5000–20000 µs to save power; a firefight appears and disappears
inside that window. 1000–2000 µs is a reasonable gaming value. Setting it below
~500 usually just raises power without improving frames.

**`GPU_MIN_PCT`** — a percentage, so it adapts: 30 % of a 670 MHz Adreno 643 is a
different number than 30 % of an 1100 MHz Adreno 750, and both are sensible.
Values above ~70 % cost real battery and heat.

**`UCLAMP_TOPAPP_MIN`** — a floor on the utilisation signal for the whole top-app
cgroup, i.e. "keep at least this much performance available for the foreground".
Percentages above ~50 mostly waste power; `0` disables the write.

**`REFRESH_HZ`** — writes `settings put system min_refresh_rate` and
`peak_refresh_rate`. Some ROMs (several One UI and HyperOS builds) honour these;
some ignore them. `doctor` tells you whether the panel modes are readable, and
`status` shows the current values. If the keys are ignored, your device has no
`REFRESH_LOCK` path and the panel is controlled elsewhere.

**`GAME_MODE_*`** — this is the platform's own intervention mechanism, not a
hack. It is the same call an OEM game booster uses. Consequences depend on the
OEM: `downscale` in particular visibly reduces sharpness. `0.8`–`0.9` is subtle,
`0.5`–`0.6` is dramatic. If the platform rejects every call, the log says so —
`cmd game list-modes <pkg>` returning "not of game type" means the game does not
declare itself as a game on your build.

---

## What is *not* here, and why

Tuning modules collect folklore. These were deliberately left out:

| Rejected | Reason |
| --- | --- |
| `dirty_ratio`, `swappiness`, `vfs_cache_pressure` tweaks | measurable only in synthetic tests, can hurt real I/O on flash |
| killing background apps / "RAM boosters" | causes more cold starts and more jank |
| `debug.hwui.renderer=skiagl`, misc `debug.*` props | either placebo or breaks composition |
| forcing CPU to `performance` governor | clocks stay high in menus, throttling arrives sooner; the ramp tuning above gets the same latency without the heat |
| disabling SELinux | opens the device up for no gaming gain |
| deleting/wiping `dalvik-cache` | one-time placebo, guaranteed battery cost on the next boot |
| "network booster" DNS/prop changes | DNS does not decide your ping in a match |

If you want one of these, the module's structure makes it easy to add in your own
fork — but the default answer is no.
