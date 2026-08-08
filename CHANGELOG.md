# Changelog

## Unreleased

## 0.1.12 - 2026-08-07

- Renamed the public app/package branding to `Studio Display XDR Win
  Controller` while keeping existing internal install paths and mutex names for
  upgrade compatibility.
- Added `Publish-GitHubRelease.ps1` for authenticated GitHub Release uploads.
- Tightened `.gitignore` so local signing certificates and related private key
  material cannot enter the public repository.
- Moved per-game resolution repairers out of the public integrated repair and
  release bundle. The public package now ships a generic game-resolution
  troubleshooting method instead of hard-coded game config writers.
- Collapsed runtime automation into one installed controller. The brightness
  mirror and brightness-key bridge now run only as `Studio Display XDR Win
  Controller` workers, and the standalone bridge/system-mirror/studio-brightness
  startup paths are treated as legacy cleanup targets.
- Added a progress-window host for the unified repair flow so topology, USB4,
  5K ladder, HDR, and brightness recovery show stage feedback before expected
  display flashes or temporary black screens.
- Added an on-demand elevated auto-repair task for Thunderbolt hot-plug
  recovery. The tray watcher now starts that task for background 5K/HDR
  restoration and keeps HDR pending until live probes verify 5K60 plus HDR,
  instead of clearing cooldown as soon as a repair process is launched.
- Added a one-time UAC permission bootstrap for the auto-repair task. If the
  elevated task is missing, the tray can launch the task registrar through UAC
  and then retry automatic hot-plug repair after registration.
- Changed automatic topology/link repair to avoid `DisplaySwitch.exe` and the
  graphics reset hotkey by default. Background repair now prefers SetDisplayConfig,
  PnP rescan, monitor restart, and Apple USB4 router retraining so Windows'
  projection UI is not pulled over the foreground app.
- Added SDR white-level reporting to the Advanced Color probe so HDR-on
  brightness diagnostics can distinguish Apple HID hardware brightness from
  Windows' external-display SDR content brightness/paper-white setting.
- Added `Trace-StudioDisplayBrightnessInput.ps1` and a tray menu entry for
  tracing mouse/keyboard brightness input. This confirmed Logitech-style
  brightness buttons can bypass Raw Input and low-level hooks while still
  changing Windows' internal brightness through WMI, so the WMI mirror path is
  treated as the supported route for those devices.
- Added lid-state topology guidance: Thunderbolt attach while the laptop lid is
  closed can enumerate differently from attach-then-close, so repairs must
  target Apple USB4/HID/EDID evidence instead of trusting display ordinals.
- Added external-only topology enforcement for Studio Display XDR connect,
  startup, sleep/resume, and lid-close topology changes before any HDR repair.
- Added Studio Display XDR detection for PID `1116`, USB4 router evidence, and
  the expected `5120x2880@120` native mode.
- Fixed Studio Display XDR brightness control by binding HID device interfaces
  to the matching Apple display device instead of mixing SetupAPI enumeration
  indexes, and by using the display's advertised brightness logical range.
- Removed the non-brightness Studio Display XDR HID fallback so brightness
  changes only write the advertised luminance usage and do not disturb
  HDR/reference-mode state.
- Fixed brightness-key bridge updates so installing a new helper stops the old
  bridge process before copying the XDR-capable HID helper and restarting.
- Improved brightness-key bridge install diagnostics so a missing PID file no
  longer hides an already-running bridge instance held by the named mutex.
- Fixed the brightness-key bridge stop script so it no longer collides with
  PowerShell's read-only `$PID` variable, and added raw keyboard fallback
  support for F14/F15 brightness keys with optional F1/F2 capture.
- Changed brightness-key handling to use press/release state tracking so one
  physical brightness-key press applies exactly one 10% step instead of
  repeating while the same key is held down.
- Added `Refresh-StudioDisplayXdrLink.ps1` plus tray menu entries for normal
  and elevated Studio Display XDR link refresh.
- Added `Apply-StudioDisplayEdidOverride.ps1` for the `DISPLAY\MS_0001`
  fallback path, including optional HDR10 metadata patching, effective EDID
  cache synchronization, and rollback.
- Added `Install-StudioDisplayBootCampStyleMonitorDriver.ps1` to generate and
  optionally install a Boot Camp-style Monitor INF for `MONITOR\MS_0001`, with
  5K60 plus HDR metadata embedded through `EDID_OVERRIDE`; the installer can
  now create and trust a local signing certificate when Windows rejects an
  unsigned monitor INF.
- Fixed the Boot Camp-style monitor INF generator to prefer the Apple
  `APPAE3A` source EDID instead of re-packaging the `MS_0001` target-effective
  fallback EDID by default.
- Added `Get-StudioDisplayAdvancedColorState.ps1` for read-only Windows
  DisplayConfig Advanced Color/HDR state probing, with dxdiag fallback for
  Windows 11 DDisplay paths that return Win32 error `31` despite active HDR.
- Fixed the Advanced Color probe structure/header layout for Windows 11
  DisplayConfig calls and added `Set-StudioDisplayHdrState.ps1` for explicit
  HDR/WCG state attempts.
- Retired the Zenless Zone Zero and The Alters public repair scripts in favor
  of the generic game-resolution troubleshooting method.
- Added `Repair-StudioDisplayIntegrated.ps1` plus a tray entry for the safe
  5K/HDR/brightness/game repair order.
- Added `docs/Integrated-Repair-Rules.md` to lock in the repair ordering rules
  for HDR, USB4 re-enumeration, brightness, and game-cache fixes.
- Hardened the integrated and XDR link refresh paths so non-elevated repairs
  do not run DisplaySwitch-only fallback when the Studio Display mode table is
  missing, and so external-mode repair refuses to target the internal panel
  when Apple display evidence is absent.
- Hardened integrated HDR repair so it requires an enumerated Studio Display
  5K60 mode table before writing HDR state, avoiding WCG-only fallback when the
  desktop is 5K but Windows still exposes only a low-resolution mode list.
- Changed default unified repair so it no longer refreshes the Boot Camp-style
  monitor fallback driver unless explicitly requested, preventing hot-plug
  repair from pinning a recovered Apple/XDR path back to `MS_0001`.
- Changed external-mode repair so `CDS_TEST`-accepted 5K modes are diagnostic
  only by default. `5120x2880@60` must be in the enumerated mode table before
  HDR and game-mode-list repair can be treated as successful.
- Fixed lid-closed/external-only brightness startup by treating internal WMI
  brightness `0%` as an internal-panel-off sentinel. The mirror now preserves
  the current Studio Display HID brightness, or falls back to a visible `70%`,
  instead of dimming the external display to black.
- Updated HDR probing and setting to include dxdiag `Active Color Mode`
  verification and to report rejected HDR packets as failures instead of
  silently treating WCG as HDR.
- Hardened integrated brightness validation so missing Apple HID devices do not
  trigger bridge recovery while the Studio Display itself is not enumerated.
- Fixed integrated brightness recovery so it no longer passes an unsupported
  `-StepPercent` parameter to the brightness-key bridge installer.
- Updated the integrated repair order so brightness mirror/key bridge services
  are paused before Boot Camp-style EDID/HDR/USB4 repair and restored only
  after display re-enumeration and HDR attempts complete.
- Added `Remove-StudioDisplayLocalSigningCertificate.ps1` to remove the local
  driver-signing certificate created by the monitor INF fallback.
- Added an optional `-RestartAppleUsb4Router` deep refresh step so Windows can
  retrain the Studio Display XDR USB4 link after monitor INF/EDID changes.
- Added a native-mode guard so the resolution repair tool refuses to treat
  `1920x1080` fallback modes as a successful repair.
- Removed direct tray buttons for applying/rolling back HDR EDID fallback and
  Boot Camp-style monitor-driver installation. Those scripts remain explicit
  advanced CLI fallbacks, but the tray keeps one transaction-safe repair path.
- Retired Overwatch-specific fullscreen profile automation in favor of the
  generic game-resolution troubleshooting method.
- Expanded gaming diagnostics with monitor identity, EDID cache, maximum
  enumerated display mode, HDR EDID metadata decoding, and Apple display USB4
  evidence.
- Added Discord + Studio Display + Overwatch stability diagnostics.
- Added a dry-run-first Discord settings helper for gaming stability testing.
- Added troubleshooting documentation for Discord voice, 5K fullscreen, and
  Studio Display Thunderbolt/USB audio interactions.

## 0.1.0 - 2026-06-19

- First open-source packaging of the Studio Display Windows toolset
- Added `Install-StudioDisplayTools.ps1` as a one-shot installer
- Added `Build-Release.ps1` for GitHub release ZIP creation
- Converted Overwatch helper scripts to auto-detect the current user SID
- Converted Overwatch helpers to auto-detect common `Overwatch.exe` install paths
- Updated repository docs, license, and ignore rules for public distribution
