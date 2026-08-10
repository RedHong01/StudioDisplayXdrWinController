# Studio Display XDR Win Controller

Open-source PowerShell utilities for using Apple Studio Display and Studio
Display XDR on Windows PCs. The repository folder may still be named
`StudioDIsplayWithWindows` for compatibility with existing local installs, but
the public app name is `Studio Display XDR Win Controller`.

This project packages the setup work in this folder into a reusable toolset:

- a tray app for brightness sync and hot-plug display repair
- external-only topology enforcement whenever Studio Display XDR is connected
- a brightness-key bridge for external keyboards
- direct HID helpers for Studio Display brightness
- Studio Display XDR native-mode guards for 5120x2880@120 troubleshooting
- generic game-resolution troubleshooting guidance for stale fullscreen mode
  lists
- integrated topology/5K ladder/HDR/brightness repair orchestration with a
  progress window for expected display flashes
- packaging scripts so the tool can be shipped as a GitHub release ZIP

## Features

- `Studio Display XDR Win Controller`
  A tray app that mirrors internal-display brightness to Studio Display and
  repairs the external-display topology after boot or Thunderbolt reconnect.
- `BrightnessKeyBridge`
  Internal controller worker that listens for HID brightness keys and maps them
  to Studio Display brightness.
- `StudioDisplayHid`
  Direct read and write access to Studio Display brightness over HID.
- `Open-StudioDisplayColorTools`
  Opens built-in Windows color-management tools.

## Requirements

- Windows 11
- Apple Studio Display or Studio Display XDR connected over Thunderbolt, USB4,
  or Thunderbolt 5
- For Studio Display XDR 5K 120Hz, the Windows host, cable, GPU routing, and
  drivers must expose `5120x2880@120` as an available display mode
- PowerShell 5.1 or later
- Local administrator rights are not usually required for the app itself, but
  some Windows diagnostics or device troubleshooting may still need them

## Quick Start

If you downloaded a release ZIP from GitHub:

1. Extract it to a normal folder such as
   `C:\Tools\StudioDisplayXdrWinController`.
2. Open PowerShell in that folder.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayTools.ps1
```

That installs `Studio Display XDR Win Controller` with one controller
auto-start entry. The brightness mirror and brightness-key bridge run only as
workers owned by that controller.

If you want to install the controller without auto-start:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayTools.ps1 `
  -SkipAutoStart
```

## Repository Layout

- `Install-StudioDisplayTools.ps1`
  One-shot installer for the full toolset.
- `Install-StudioDisplayManager.ps1`
  Installs the tray controller and external-display repair worker.
- `StudioDisplayManager.ps1`
  Main tray host.
- `SystemBrightnessMirror.ps1`
  Internal controller worker for brightness synchronization.
- `BrightnessKeyBridge.ps1`
  Internal controller worker for external keyboard brightness keys.
- `Repair-StudioDisplayExternalMode.ps1`
  External display topology and mode repair helper.
- `Refresh-StudioDisplayXdrLink.ps1`
  Manual Studio Display XDR link refresh helper for topology refresh, graphics
  hotkey refresh, elevated PnP rescan, and native 5K 120Hz repair.
- `Apply-StudioDisplayEdidOverride.ps1`
  Dry-run-first EDID override helper for the `DISPLAY\MS_0001` fallback path.
  It can make Windows enumerate the older Studio Display 5K60 EDID and can add
  HDR10 metadata as an explicit fallback.
- `Install-StudioDisplayBootCampStyleMonitorDriver.ps1`
  Generates a Boot Camp-style Monitor INF for `MONITOR\MS_0001`, embedding the
  5K60 EDID plus HDR metadata as `EDID_OVERRIDE` so Windows can consume it
  during monitor-driver initialization.
- `Remove-StudioDisplayLocalSigningCertificate.ps1`
  Removes the local driver-signing certificate created for the signed monitor
  INF fallback.
- `Get-StudioDisplayAdvancedColorState.ps1`
  Read-only Advanced Color/HDR probe with dxdiag fallback for Windows 11
  DDisplay paths.
- `Set-StudioDisplayHdrState.ps1`
  Attempts the Win11 DisplayConfig HDR state API and reports when Windows
  refuses HDR on the current target path. WCG fallback is explicit so existing
  HDR is not silently downgraded.
- `Repair-StudioDisplayIntegrated.ps1`
  Orchestrates the current safe repair order: 5K mode-table validation, USB4
  retrain when needed, HDR attempt, and brightness HID validation.
- `Invoke-StudioDisplayAutoRepair.ps1 -ValidateOnly`
  Non-disruptive final-state validator used by automation. It returns success
  only when 5K60 is current/enumerated, HDR is supported and active, and
  Studio Display HID brightness is readable. When that final gate passes, it
  also records `StudioDisplayKnownGoodState.json` in the installed controller
  folder so later hot-plug debugging has a single known-good baseline.
- `Test-StudioDisplayHotplugAutomation.ps1`
  Read-only audit for the hot-plug automation chain. It checks that the tray,
  brightness workers, elevated scheduled task, Boot Camp-style success recipe,
  5K60/HDR/brightness gates, and known-good state are aligned. Add
  `-RunScheduledTask` to run the scheduled task once; the launcher preflights
  `code=0` first, so a healthy system exits without disruptive USB4/HDR repair.
- `Watch-StudioDisplayHotplugAutomation.ps1`
  Passive hot-plug observer. It records the current repair stage, task state,
  5K mode table, HDR gate, Apple `VID_05AC&PID_1116` `MI_08`/`MI_09` state,
  brightness worker state, and possible user-input overlap without modifying
  display state. The tray starts it for reconnect/startup/resume/topology
  events so failed automatic runs leave a structured summary.
- `Show-StudioDisplayRepairProgress.ps1`
  Displays progress while the integrated repair performs topology, USB4, HDR,
  and brightness stages.
- `StudioDisplayHid.ps1`
  Direct HID helper for Studio Display brightness.
- `Check-StudioDisplayGaming.ps1`
  Diagnostic bundle for GPU, monitor identity, HDR, EDID, USB4, and game-mode
  symptoms.
- `Remove-StudioDisplayLegacyTools.ps1`
  Upgrade cleanup helper that removes retired standalone bridge, mirror,
  studio-brightness, and per-game experiment installs from the current machine.
- `docs/Studio-Display-XDR-1080p-Resolution.md`
  Native 5K 120Hz enumeration and 1080p fallback troubleshooting guide.
- `docs/Game-Resolution-Troubleshooting.md`
  Generic method for games that cache stale 1080p/3K/4K mode lists.
- `docs/Integrated-Repair-Rules.md`
  The repair-order contract that keeps HDR, USB4 re-enumeration, brightness,
  and display-mode fixes from fighting each other.
- `Build-Release.ps1`
  Creates a clean release ZIP under `dist\`.

## Installation Notes

### Brightness Sync

Windows exposes standard brightness control primarily for internal laptop
panels, not external monitors. This project works around that by:

- reading the internal brightness value from WMI
- watching `WmiMonitorBrightnessEvent`
- forwarding brightness changes to Studio Display through the HID helper

The mirror is not installed as a separate app anymore. The tray controller
starts and stops it as an internal worker so display repair can pause brightness
writes before topology, USB4, EDID, or HDR changes and restore them afterward.
When Windows reports the internal panel brightness as `0%` during startup in an
external-only or lid-closed session, the mirror treats that as an internal-panel
off sentinel instead of a real external-backlight target. It preserves the
current Studio Display HID brightness, or falls back to a visible `70%`, so HDR
or hot-plug recovery cannot accidentally dim the external display to black.

### External Keyboard Brightness Keys

The bridge listens for HID brightness usages `0x006F` and `0x0070` and applies
fixed `10%` Studio Display steps. This works best with keyboards that expose
standard HID brightness events directly to Windows.

The brightness-key bridge is also an internal worker. It no longer creates its
own Startup shortcut, which avoids duplicate Apple HID writes after reconnect.

Some mouse or keyboard utilities do not expose brightness buttons as normal
Raw Input, F14/F15, or Consumer Control brightness usages. They can instead ask
Windows to change the internal panel brightness directly. The controller treats
that WMI internal-brightness change as the official input path for those
devices and mirrors the resulting percentage to Studio Display through Apple
HID.

Use the tray entry `亮度输入：监听鼠标按键` when adding a new device. If the
trace sees no raw brightness key but `SystemBrightnessMirror.log` shows
`Internal brightness event` followed by `Studio Display brightness synced`, that
device is using the driver-internal WMI path and does not need a separate raw
input mapping.

### HDR And Brightness

When Windows HDR is active on an external display, the Settings slider named
`SDR content brightness` controls SDR paper-white relative to HDR content. It
does not directly change the Studio Display XDR hardware backlight.

The controller therefore treats brightness as two related but separate states:

- Apple HID brightness is the hardware brightness value written to the display.
- Windows SDR content brightness is the HDR desktop paper-white value reported
  by `DISPLAYCONFIG_SDR_WHITE_LEVEL`.

The tray menu entry `HDR 亮度：查看当前语境` reports both values so you can tell
whether a brightness key changed the display backlight, the Windows HDR
paper-white level, or neither. Apple reference modes can also intentionally
limit brightness controls.

### Thunderbolt Hot-Plug Repair

On some systems, boot or hot-plug can leave Studio Display in the wrong
projection topology or with the wrong effective resolution.

Laptop lid state matters. If the Thunderbolt cable is attached while the laptop
lid is already closed, Windows may enumerate the Studio Display as a separate
second display. If the cable is attached while the internal panel is lit and
the lid is closed afterward, Windows may collapse the internal and external
paths into a combined `1/2` display topology. The controller treats those as
different transient topologies and validates the target through Apple
USB4/HID/EDID evidence rather than trusting display ordinals such as
`DISPLAY1`, `DISPLAY2`, or `DISPLAY5`.

The default policy is: when Studio Display XDR is connected, force Windows into
external-only topology before any 5K mode-table or HDR repair. This keeps HDR
and fullscreen game mode enumeration tied to the Studio Display path instead
of whichever display happened to be primary during lid-close or sleep-time
hot-plug.

This repo detects Studio Display, Studio Display XDR, and Pro Display XDR before
mode repair. For Studio Display XDR, the expected native mode is
`5120x2880@120`.

This repo currently uses:

- a staged `2560x1440@60` safety mode for startup and reconnect repair
- a follow-up restore to the highest available native mode, preferring the
  display profile refresh rate
- a direct native restore when a repair was only deferred because a fullscreen
  app was active
- a topology signature watcher that re-applies external-only mode after
  sleep/resume, Thunderbolt reconnect, lid-close topology changes, or `1/2`
  combined-display transitions
- an HDR hot-plug watcher that probes the live `HighDynamicRangeSupported` gate
  after reconnect: if HDR is supported but inactive, it sends the lightweight
  HDR enable request; if the gate is false or unknown, it queues the full
  integrated USB4/5K/HDR repair path through the installed on-demand elevated
  auto-repair task and keeps retry state pending until live probes verify HDR
- a transaction guard for the elevated auto-repair task: topology/lid-state
  events that arrive while the integrated task is already running are coalesced
  into the current repair instead of launching another topology refresh or task
  run
- an HDR-gate backoff state: when the desktop is already stable at 5K60 but
  Windows still reports `HighDynamicRangeSupported=False`, the controller stops
  looping deep repairs and waits for a fresh Thunderbolt reconnect, power
  resume, successful HDR probe, or the next controlled retry window; this
  backoff is persisted locally so restarting the tray does not immediately
  repeat the same failed HDR-gate repair
- a one-click repair preflight: the tray checks current 5K60 mode, enumerated
  5K60 support, HDR active state, brightness worker processes, and the hardware
  brightness HID read before it runs a disruptive repair; if everything is
  already healthy, it skips the repair
- a native-mode guard that refuses to treat fallback modes such as
  `1920x1080@60` as success unless `-AllowLowResolutionFallback` is passed
- a silent-first automation guard: background repair avoids `DisplaySwitch.exe`
  and the graphics reset hotkey unless an explicit manual fallback flag is
  passed, preventing Windows' projection UI from interrupting foreground work

That keeps reconnect behavior conservative while reducing extra fullscreen-exit
flash.

The tray UI intentionally keeps one safe repair entry visible:
`重建 Boot Camp-style 5K60 HDR 管线`. Lower-level user-safe actions are grouped into
`亮度控制`, `HDR/亮度`, and `高级/诊断`. Direct external-only/link-refresh tray
buttons were removed because running them separately can race the unified
topology, 5K ladder, HDR, and brightness order. The installed controller and
release package expose one working recovery path: Boot Camp-style `MS_0001`
identity, USB4 retrain, HDR gate, and brightness validation.

During a manual pipeline rebuild, the progress window plays periodic system
sounds so the user still gets feedback if the display is temporarily blank. If
the user presses `Space`, the progress host stops waiting for the full
Boot Camp-style HDR identity and applies a quick visible external fallback
instead. That fallback is deliberately not counted as HDR success; use the tray
entry above to rebuild the full 5K60 HDR pipeline afterward. While that temporary
fallback marker is present, the tray relabels the main action to
`从 fallback 重建 Boot Camp-style 5K60 HDR 管线` and keeps the degraded status visible
until independent probes confirm 5K60, HDR, and brightness again.

When the repair is launched manually from the tray, the controller first
summarizes the missing conditions. If only the brightness workers are stopped,
it restarts them without running topology/HDR repair. If deep USB4/HDR/Apple HID
repair is required and the tray is not already elevated, Windows UAC is shown
immediately before the progress window starts. The progress window tracks the
actual repair child process and stops with a useful status even if a script
exits before writing its final completion marker.

Automatic hot-plug repair instead runs through a hidden on-demand elevated
scheduled task so USB4 and HDR recovery can run without a fresh UAC prompt on
every Thunderbolt reconnect. Temporary black screens or display flashes can
still happen when Windows changes topology, re-enumerates USB4, or applies HDR,
but the integrated script now skips external-only/5K/HDR stages that are already
satisfied. Tray startup and hot-plug topology handling use the same stable-5K60
guard, so they do not bounce through the 2K safety mode when the Studio Display
is already the only active 5K60 screen. Automatic progress is reflected in the
tray status and the logs under the installed `reports` folder.

Hot-plug automation no longer runs a standalone external-topology repair before
HDR. Reconnect, resume, and topology-change events now queue the same integrated
pipeline used by the one-click repair, and that pipeline decides which stages
can be skipped.

The successful recovery recipe is persisted only after the launcher reaches
`code=0`: current 5120x2880, enumerated 5120x2880@60, HDR supported and active,
and readable Studio Display HID brightness. If the active `MS_0001` monitor
identity appears, the controller treats the Boot Camp-style monitor INF as the
single default HDR path. Generic/Digital Flat Panel `monitor.inf` can preserve a
5K mode table, but it is diagnostic-only because it has repeatedly failed to
open the HDR capability gate on this setup.

Automatic repair is intentionally quiet-first. It uses `SetDisplayConfig`,
PnP rescans, monitor restart, and Apple USB4 router retraining before any
interactive fallback. `DisplaySwitch.exe`/Win+P-style projection UI and the
graphics reset hotkey are reserved for explicit manual troubleshooting flags so
background brightness/HDR recovery does not steal focus from games, calls, or
work apps.

Discord/game-specific repair helpers are not part of the public controller.
Game resolution issues should be handled through the generic mode-table
diagnostic method in `docs/Game-Resolution-Troubleshooting.md`, not by shipping
per-app fixers in the tray or release package.

Windows does not allow a non-elevated tray app to silently grant itself
administrator rights. The controller therefore bootstraps this safely: if the
on-demand elevated task is missing, the tray can launch a one-time UAC prompt to
register it. Approve that prompt once; future hot-plug repair runs through the
registered task without asking again. You can also trigger the same prompt from
the tray entry `自动修复权限：注册/修复`.

The installer also repairs this permission path. It first checks whether the
on-demand task already exists and points at the current install folder. If the
task is missing or stale and the installer is not already elevated, it launches
the same registrar through UAC, waits for it to finish, and verifies success
through Task Scheduler or the registrar log. A normal non-elevated PowerShell
session may still fail to query the task with `Access denied` or a misleading
`schtasks` error; that does not necessarily mean hot-plug repair is broken.

### Studio Display XDR 1080p Fallback

If Windows sees the Studio Display XDR USB4/audio/camera devices but the active
monitor identity is a generic Microsoft fallback such as `DISPLAY\MS_0001`, the
available mode list may stop at `1920x1080@60`. The repair tool cannot force
`5120x2880@120` when Windows has not enumerated that mode.

Use the diagnostic script first:

```powershell
powershell -ExecutionPolicy Bypass -File .\Check-StudioDisplayGaming.ps1
```

Look for:

- `Detected profile: StudioDisplayXDR`
- `Expected native mode: Studio Display XDR native 5K 120Hz`
- `MaximumEnumerated` showing whether Windows exposes `5120x2880@120`
- `Monitor Identity` showing whether the active display is an Apple identity or
  a Microsoft fallback identity

If the expected mode is missing, check the direct Thunderbolt 5/USB4 connection,
avoid docks and passive adapters, use the Apple Thunderbolt 5 Pro cable or an
equivalent certified cable, and update BIOS, USB4/Thunderbolt, Intel graphics,
and NVIDIA drivers.

To force a refresh without changing low-resolution settings:

```powershell
powershell -ExecutionPolicy Bypass -File .\Refresh-StudioDisplayXdrLink.ps1
```

If the normal refresh still leaves Windows at `DISPLAY\MS_0001`, run the
administrator path so Windows can rescan Plug and Play devices:

```powershell
powershell -ExecutionPolicy Bypass -File .\Refresh-StudioDisplayXdrLink.ps1 -Elevate
```

For the strongest software refresh, restart the current fallback monitor device
after the elevated scan:

```powershell
powershell -ExecutionPolicy Bypass -File .\Refresh-StudioDisplayXdrLink.ps1 -Elevate -RestartFallbackMonitor
```

If the monitor driver and EDID are correct but Windows still has a stale USB4
display capability cache, run the deep retrain path. This restarts the Apple
Studio Display XDR USB4 router, so a short display/audio/camera disconnect is
expected:

```powershell
powershell -ExecutionPolicy Bypass -File .\Refresh-StudioDisplayXdrLink.ps1 -Elevate -RestartFallbackMonitor -RestartAppleUsb4Router
```

For the current all-in-one repair order, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-StudioDisplayIntegrated.ps1 -Apply -Elevate -RestartAppleUsb4Router
```

The integrated path keeps previously working features separate: brightness HID
validation does not write color state, HDR repair does not silently downgrade to
WCG unless `-AllowWcgFallback` is passed, and USB4/monitor re-enumeration runs
before HDR repair.

The rule that matters most for HDR is stricter than "the desktop is currently
5K": `5120x2880@60` must also appear in the enumerated mode table. If the
desktop is 5K but the mode table only exposes 1080p, the integrated repair
does USB4/monitor re-enumeration first and skips HDR writes until the mode table
is stable.

The integrated repair includes the Boot Camp-style monitor-driver identity for
active `MS_0001` sessions by default. This keeps hot-plug recovery on one
transactional path instead of racing Generic/Digital Flat Panel fallback against
the Boot Camp-style identity:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-StudioDisplayIntegrated.ps1 -Apply -Elevate -EnsureBootCampMonitorDriver -RestartAppleUsb4Router
```

That path pauses the brightness mirror and brightness-key bridge before display
re-enumeration, installs or verifies the monitor INF, waits for the
Boot Camp-style identity to settle, retrains USB4, attempts HDR, and only then
restores the brightness services.

See `docs/Integrated-Repair-Rules.md` for the rules this pipeline must preserve
when new HDR, USB4, display-mode, or brightness fixes are added.

If Windows still keeps the active monitor as `DISPLAY\MS_0001` and refuses
`5120x2880`, the last software fallback is an EDID override. This is Windows
registry-only; it does not change the display firmware and will not affect the
same monitor when it is later plugged into macOS.

Dry-run first:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -EnableHdrMetadata -PatchEffectiveEdidCache
```

Apply the 5K60 plus HDR metadata fallback:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -Apply -Elevate -EnableHdrMetadata -PatchEffectiveEdidCache
```

Rollback:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -Rollback -RollbackElevate
```

This fallback has limits. On the tested Windows path it restores
`5120x2880@60`; `5120x2880@120` is still rejected by the graphics stack. HDR
metadata can be written into the registry and verified by
`Check-StudioDisplayGaming.ps1`. If DisplayConfig returns Win32 error `31` on a
DDisplay path, use `dxdiag` or `Get-StudioDisplayAdvancedColorState.ps1`; the
helper falls back to dxdiag and reports the real `AdvancedColorEnabled` and HDR
mode.

If `pnputil` rejects the Boot Camp-style monitor INF as unsigned, build and
trust a local driver-signing certificate for this Windows install:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayBootCampStyleMonitorDriver.ps1 -EnableHdrMetadata -SignWithLocalCertificate -TrustLocalSigningCertificate -Apply -Elevate
```

The certificate is local to Windows and does not touch the Studio Display XDR
firmware or macOS behavior. To remove the local certificate later:

```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-StudioDisplayLocalSigningCertificate.ps1 -Elevate
```

### Boot Camp-Style HDR Identity

Apple's Boot Camp path is broader than a simple HDR toggle. It combines current
Apple Windows support software, a monitor driver/INF layer, Apple display
USB/HID control for brightness and reference presets, and a display preset that
advertises HDR/PQ capability to Windows. This repo does not redistribute Apple
Boot Camp binaries, but it can mirror the safest Windows-native part of that
stack: a Monitor INF that binds to `MONITOR\MS_0001` and writes the corrected
EDID through the standard `EDID_OVERRIDE` mechanism.

Dry-run and generate the INF:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayBootCampStyleMonitorDriver.ps1 -EnableHdrMetadata
```

Attempt installation with administrator elevation:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayBootCampStyleMonitorDriver.ps1 -EnableHdrMetadata -Apply -Elevate
```

For active `MS_0001` sessions, this is the default HDR identity used by the
integrated repair. It is still Windows-local and does not alter the display
EEPROM, firmware, or macOS behavior. If Windows rejects the unsigned INF, the
generated package and log are left under
`drivers\StudioDisplayXdrBootCampStyleMonitor\` for manual inspection or
signing.

## Game Resolution Method

The public release does not ship per-game resolution fixers. If a game only
shows `1920x1080`, 3K, or 4K while the desktop appears to be 5K, first repair
the Windows display mode table, then reset that game's cached display settings
using a backup-first workflow.

The key rule is that games often read the enumerated Windows mode table rather
than the current desktop mode. A desktop that is already `5120x2880@60` is not
enough if `EnumDisplaySettings` still exposes only `1920x1080@60`.

Use:

```powershell
powershell -ExecutionPolicy Bypass -File .\Check-StudioDisplayGaming.ps1
```

Then follow [`docs/Game-Resolution-Troubleshooting.md`](docs/Game-Resolution-Troubleshooting.md)
for the generic Unity, Unreal, registry, and config-file method.

For Resident Evil 2, 3, 4, and other RE Engine titles, treat the in-game HDR
menu as a native HDR capability probe performed at game launch. Windows HDR can
be active while a game still greys out its own HDR option if the game/driver
does not see the current primary output as an HDR flip-model target. Keep Studio
Display XDR as the only active display, launch after HDR is already active,
test borderless fullscreen first, and disable Windows Auto HDR for that game
while debugging native HDR. Intel documents Resident Evil 2 native HDR being
greyed out on some Arc GPUs as a known driver issue, so if Windows reports true
HDR but the menu remains disabled, update/test the GPU driver path before
treating it as an EDID failure.

## Build a Release ZIP

To create a distributable ZIP that is safe to upload to GitHub Releases:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Release.ps1 -Version 0.1.8
```

The script writes a clean bundle to
`dist\StudioDisplayXdrWinController-v0.1.8` and also creates
`dist\StudioDisplayXdrWinController-v0.1.8.zip`.

Runtime artifacts such as logs, backups, and build output are intentionally
excluded from version control and the release bundle.

## Privacy and Scope

- This repository does not ship Apple Boot Camp binaries.
- The project only includes PowerShell automation and small helper launchers.
- Machine-specific items such as local logs, generated backups, and the
  current user's SID are not meant to be committed.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).

## Sources

- Apple Support: [Use Apple Studio Display or Pro Display XDR with Boot Camp](https://support.apple.com/102086)
- Apple Support: [Change display settings in Windows with Boot Camp on Mac](https://support.apple.com/guide/bootcamp-control-panel/bcmp63a95ede/mac)
- Apple Support: [Use reference modes with your Apple display](https://support.apple.com/108321)
- Apple: [Studio Display Technical Specifications](https://www.apple.com/studio-display/specs/)
- Apple: [Studio Display XDR Technical Specifications](https://www.apple.com/studio-display-xdr/specs/)
- Apple Support: [Studio Display XDR Tech Specs](https://support.apple.com/en-us/126323)
- Microsoft Support: [HDR settings in Windows](https://support.microsoft.com/en-us/windows/hdr-settings-in-windows-2d767185-38ec-7fdc-6f97-bbc6c5ef24e6)
- Microsoft Support: [Change display brightness and color in Windows](https://support.microsoft.com/windows/auto-color-management-in-windows-11-64a4de7f-9c93-43ec-bdf1-3b12ffa0870b)
- Microsoft Learn: [Display brightness control](https://learn.microsoft.com/windows-hardware/drivers/hid/display-brightness-control)
- Microsoft Learn: [Supporting brightness controls for external display connectors](https://learn.microsoft.com/windows-hardware/drivers/display/supporting-brightness-controls-for-external-display-connectors)
- Microsoft Learn: [Use DirectX with Advanced Color on high/standard dynamic range displays](https://learn.microsoft.com/windows/win32/direct3darticles/high-dynamic-range)
- Microsoft Learn: [DISPLAYCONFIG_SDR_WHITE_LEVEL](https://learn.microsoft.com/windows/win32/api/wingdi/ns-wingdi-displayconfig_sdr_white_level)
- Microsoft Learn: [Using Device Profiles with WCS](https://learn.microsoft.com/windows/win32/wcs/using-device-profiles-with-wcs)
- Intel Support: [HDR Option Is Grayed Out in Resident Evil 2 with Intel Arc A770](https://www.intel.com/content/www/us/en/support/articles/000097556/graphics.html)
- GitHub: [timsutton/brigadier](https://github.com/timsutton/brigadier)
