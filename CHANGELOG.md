# Changelog

All notable changes to this module. Versioning is `MAJOR.MINOR.PATCH`, and
`versionCode` in `module.prop` is `major*10000 + minor*100 + patch`.

## v1.1.0 — web interface, adaptive thermal ladder

### Added

- **Web UI** (`webroot/`) for KernelSU, APatch and any WebUI host: status,
  profile switching, every toggle, thermal sliders, logs, sessions and a
  capability report — no terminal needed. Self-contained HTML/CSS/JS, no CDN,
  no network access.
- `webroot/actions.sh`, a strictly validated bridge between the page and the
  module (whitelisted keys, range-checked values, JSON-free output format).
- **`adaptive` profile**, now the default: instead of holding maximum clocks
  until the thermal limit and then collapsing, it steps the GPU floor
  (40 → 28 → 15 %) and caps the refresh rate only at the hottest step, so the
  frame rate stays consistent and the phone stays cool. The hard thermal guard
  is unchanged.
- Simpler start/stop plumbing (`common/control.sh`) shared by the CLI, the WebUI
  and the boot service; a re-apply marker so a UI toggle takes effect on the
  engine's next tick instead of waiting for the 60 s cycle.
- Faster, cached lookups for the UI: panel maximum refresh (1 h) and installed
  game packages (2 min, via the app's data directory instead of `pm`).

### Changed

- Default profile is now `adaptive` (was `balanced`). Nothing else changes for
  existing users — the config file keeps its own `PROFILE=`.
- `codm-optimizer profile` accepts `adaptive`; help text shortened.
- Installer output now points at the Web UI first and the CLI second.

## v1.0.0 — first release

### Added

- Foreground-aware engine that applies a gaming profile only while CODM is
  visible, and always reverts it.
- Four profiles: `battery`, `balanced`, `performance`, `extreme`.
- CPU control: schedutil `up_rate_limit_us` / `down_rate_limit_us`, optional
  minimum-frequency floor as a percentage of the available range, optional
  governor switching.
- GPU control: devfreq / sysfs minimum-frequency floor as a percentage of the
  GPU's own frequency table (Adreno, Mali and generic devfreq nodes).
- Scheduler control: top-app `uclamp.min`, legacy `schedtune.boost`, optional
  top-app CPU set, optional I/O scheduler.
- Network: TCP slow-start/congestion state kept warm, optional congestion
  control selection, optional Wi-Fi power-save disable.
- Display: refresh-rate lock while gaming (`min_refresh_rate` /
  `peak_refresh_rate`) with automatic panel-maximum detection.
- Android Game Mode integration, version aware: `cmd game set` on Android 14+,
  `device_config game_overlay` on Android 13, `cmd game mode` on Android 12, with
  full restore in every case.
- Thermal guard: drops the whole profile at a configurable battery temperature
  and resumes with hysteresis. Optional passive trip-point lift, off by default,
  never touching `critical`, battery or charger zones.
- Exact rollback: every write stores its previous value; leftovers from a crash
  or a reboot mid-match are restored at the next engine start.
- CLI (`codm-optimizer`) with `status`, `doctor`, `profile`, `on/off`,
  `apply/release`, `game`, `display`, `hide`, `log`, `sessions`, `set`, `reset`.
- Magisk action button snapshot, session history (duration, peak temperature,
  how each session ended), rotating log.
- Offline test suite (79 checks) and a linter covering busybox `ash` syntax,
  CRLF, `module.prop` format, bashisms and dangerous patterns.
- Support for Magisk, KernelSU and APatch; installable from recovery through the
  standard `META-INF` wrapper.
