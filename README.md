# Studio Display Tools for Windows

Open-source PowerShell utilities for using Apple Studio Display on Windows PCs.

This project packages the setup work in this folder into a reusable toolset:

- a tray app for brightness sync and hot-plug display repair
- a brightness-key bridge for external keyboards
- direct HID helpers for Studio Display brightness
- optional gaming helpers for fullscreen and Auto HDR troubleshooting
- packaging scripts so the tool can be shipped as a GitHub release ZIP

## Features

- `Studio Display Manager`
  A tray app that mirrors internal-display brightness to Studio Display and
  repairs the external-display topology after boot or Thunderbolt reconnect.
- `BrightnessKeyBridge`
  Listens for HID brightness keys and maps them to Studio Display brightness.
- `StudioDisplayHid`
  Direct read and write access to Studio Display brightness over HID.
- `Open-StudioDisplayColorTools`
  Opens built-in Windows color-management tools.
- `Overwatch helpers`
  Optional scripts for exclusive fullscreen and Auto HDR tuning on systems
  where fullscreen transitions or reconnect timing are sensitive.

## Requirements

- Windows 11
- Apple Studio Display connected over Thunderbolt or USB4
- PowerShell 5.1 or later
- Local administrator rights are not usually required for the app itself, but
  some Windows diagnostics or device troubleshooting may still need them
- Internet access only if you want `Install-StudioDisplayBrightness.ps1` to
  download the upstream `studio-brightness` executable

## Quick Start

If you downloaded a release ZIP from GitHub:

1. Extract it to a normal folder such as `C:\Tools\studio-display-tools-windows`.
2. Open PowerShell in that folder.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayTools.ps1
```

That installs the tray manager, the optional upstream `studio-brightness`
utility, and the brightness-key bridge with auto-start enabled.

If you want only the tray manager:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayTools.ps1 `
  -SkipBrightnessUtility `
  -SkipBrightnessKeyBridge
```

## Repository Layout

- `Install-StudioDisplayTools.ps1`
  One-shot installer for the full toolset.
- `Install-StudioDisplayManager.ps1`
  Installs the tray app and external-display repair worker.
- `Install-BrightnessKeyBridge.ps1`
  Installs the keyboard brightness bridge.
- `Install-StudioDisplayBrightness.ps1`
  Downloads the latest upstream `studio-brightness` release.
- `StudioDisplayManager.ps1`
  Main tray host.
- `SystemBrightnessMirror.ps1`
  Internal worker for brightness synchronization.
- `Repair-StudioDisplayExternalMode.ps1`
  External display topology and mode repair helper.
- `StudioDisplayHid.ps1`
  Direct HID helper for Studio Display brightness.
- `Set-OverwatchExclusiveFullscreenProfile.ps1`
  Optional gaming profile helper. Defaults to `5120x2880@60`.
- `Set-OverwatchAutoHDR.ps1`
  Optional helper for disabling Overwatch Auto HDR via registry.
- `Check-StudioDisplayGaming.ps1`
  Diagnostic bundle for game and display troubleshooting.
- `Build-Release.ps1`
  Creates a clean release ZIP under `dist\`.

## Installation Notes

### Brightness Sync

Windows exposes standard brightness control primarily for internal laptop
panels, not external monitors. This project works around that by:

- reading the internal brightness value from WMI
- watching `WmiMonitorBrightnessEvent`
- forwarding brightness changes to Studio Display through the HID helper

### External Keyboard Brightness Keys

The bridge listens for HID brightness usages `0x006F` and `0x0070` and applies
fixed `10%` Studio Display steps. This works best with keyboards that expose
standard HID brightness events directly to Windows.

### Thunderbolt Hot-Plug Repair

On some systems, boot or hot-plug can leave Studio Display in the wrong
projection topology or with the wrong effective resolution.

This repo currently uses:

- a staged `2560x1440@60` safety mode for startup and reconnect repair
- a follow-up restore to the highest available native mode
- a direct native restore when a repair was only deferred because a fullscreen
  app was active

That keeps reconnect behavior conservative while reducing extra fullscreen-exit
flash.

## Optional Gaming Helpers

The gaming scripts are intentionally optional and not required for the main
Studio Display workflow.

- `Set-OverwatchExclusiveFullscreenProfile.ps1`
  Edits Overwatch settings and matching registry values for exclusive
  fullscreen. It now auto-detects the current user SID and tries to locate
  `Overwatch.exe` automatically. If your game is installed in a nonstandard
  path, pass `-OverwatchPath`.
- `Set-OverwatchAutoHDR.ps1`
  Disables Auto HDR for Overwatch using the current user's registry hive.
- `Check-StudioDisplayGaming.ps1`
  Collects a diagnostic snapshot for GPU, monitor, registry, and Overwatch
  state.

## Build a Release ZIP

To create a distributable ZIP that is safe to upload to GitHub Releases:

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-Release.ps1 -Version 0.1.0
```

The script writes a clean bundle to `dist\studio-display-tools-windows-v0.1.0`
and also creates `dist\studio-display-tools-windows-v0.1.0.zip`.

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
- Apple: [Studio Display Technical Specifications](https://www.apple.com/studio-display/specs/)
- Microsoft Support: [Change display brightness and color in Windows](https://support.microsoft.com/windows/auto-color-management-in-windows-11-64a4de7f-9c93-43ec-bdf1-3b12ffa0870b)
- Microsoft Learn: [Display brightness control](https://learn.microsoft.com/windows-hardware/drivers/hid/display-brightness-control)
- Microsoft Learn: [Supporting brightness controls for external display connectors](https://learn.microsoft.com/windows-hardware/drivers/display/supporting-brightness-controls-for-external-display-connectors)
- Microsoft Learn: [Using Device Profiles with WCS](https://learn.microsoft.com/windows/win32/wcs/using-device-profiles-with-wcs)
- GitHub: [sfjohnson/studio-brightness](https://github.com/sfjohnson/studio-brightness)
- GitHub: [timsutton/brigadier](https://github.com/timsutton/brigadier)
