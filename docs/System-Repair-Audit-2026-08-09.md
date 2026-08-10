# System Repair Audit - 2026-08-09

This audit records the cleanup after the Studio Display XDR repair work.

## Current Repair Truth

- Earlier 2026-08-09 sessions reached stable `5120x2880@60Hz`, but the
  17:04-17:19 log review found the active Thunderbolt session degraded to
  `1920x1080@60Hz` with no 5K modes enumerated.
- While degraded, HDR is downstream-blocked by the missing 5K mode table and by
  the active Windows/driver capability gate: `HighDynamicRangeSupported=False`.
- Windows can still show WCG/Advanced Color in this state:
  `ActiveColorMode=DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG`.
- WCG/Advanced Color is not HDR and must never be reported as `code=0`.

## Kept

- `StudioDisplayManager.ps1` as the only tray entry point.
- `Repair-StudioDisplayIntegrated.ps1` as the single topology/5K/HDR/brightness
  transaction.
- `Invoke-StudioDisplayAutoRepair.ps1` as the elevated scheduled-task launcher
  plus `-ValidateOnly` final-state validator.
- Direct diagnostic scripts for EDID, Boot Camp-style monitor fallback, HDR
  identity rollback, USB4/link refresh, and game mode-table analysis as explicit
  CLI tools.

## Removed From The Default Path

- Standalone tray buttons for external-only repair and link refresh.
- Automatic hot-plug behavior that ran external topology repair before HDR.
- Discord microphone repair from the tray, installer, release list, and source
  tree.
- Old package artifacts under `dist/`.

## 2026-08-09 Log Review

- `StudioDisplayAutoRepairTask.log` showed repeated exit code `2` runs from
  17:04 through 17:19. Each run completed, but validation stayed incomplete
  because Windows exposed only `1920x1080@60Hz`.
- `StudioDisplayXdrLinkRefresh-20260809-171356.log` showed PnP rescan,
  `DISPLAY\MS_0001` restart, and Apple USB4 router restart all returning exit
  code `0`, but the final mode table still maxed out at `1920x1080@60Hz`.
- The tray loop was not caused by concurrent task launches. It was caused by
  the old controller treating a failed 5K mode-table repair as immediate retry
  instead of a blocked Thunderbolt/EDID bandwidth session.
- The controller now persists a 5K mode-table backoff so it waits for a fresh
  Thunderbolt reconnect, power resume, or successful 5K probe instead of
  repeatedly restarting USB4.
- Brightness startup also showed `mutexHeld=True` without pid files. The tray
  now treats that as an existing worker to avoid duplicate instances, and the
  installer attempts command-line cleanup of orphan controller workers.

## Rule

The public controller should expose one safe repair path. Anything that can
rewrite monitor identity, EDID, topology, USB4, HDR state, or app/game settings
must either be inside the integrated transaction or remain an explicit advanced
CLI diagnostic.
