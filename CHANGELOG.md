# Changelog

All notable changes to this module. Versioning is `MAJOR.MINOR.PATCH`, and
`versionCode` in `module.prop` is `major*10000 + minor*100 + patch`.

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
