# Game Resolution Troubleshooting

This guide covers the generic failure mode where a game only offers low
resolutions such as `1920x1080`, 3K, or 4K even though the Windows desktop is
currently running the Studio Display XDR at 5K.

## Core Rule

Fix the Windows display mode table before editing a game config.

Many games do not trust the current desktop mode. They ask Windows for the
enumerated fullscreen modes through APIs similar to `EnumDisplaySettings`. If
Windows currently draws the desktop at `5120x2880@60` but the enumerated mode
table still tops out at `1920x1080@60`, the game may cache or display only the
low modes.

Run the display diagnostics first:

```powershell
powershell -ExecutionPolicy Bypass -File .\Check-StudioDisplayGaming.ps1
powershell -ExecutionPolicy Bypass -File .\Test-StudioDisplayResolutionLadder.ps1
```

The repair is not complete until `5120x2880@60` appears as an enumerated mode,
not merely as the current desktop mode.

## Generic Fix Order

1. Close the game and any launcher that may rewrite its settings on exit.
2. Run the integrated Studio Display repair:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-StudioDisplayIntegrated.ps1 -Apply -Elevate -RestartAppleUsb4Router
```

3. Re-run the resolution ladder and confirm 5K is enumerated.
4. Start the game once, select borderless fullscreen if available, then exit.
5. Back up the game's config or registry values before editing anything.
6. Reset only display-mode fields: width, height, fullscreen/window mode,
   render resolution, HDR toggle, and "last confirmed" resolution values.
7. Start the game again and prefer borderless fullscreen while debugging. Move
   back to exclusive fullscreen only after Windows exposes a stable 5K mode
   table.

## HDR Games

Treat in-game HDR as a startup-time capability check, not just a Windows toggle.
Many DirectX games decide whether to enable their HDR menu by checking the
current primary/output display, fullscreen swap-chain mode, and driver-reported
HDR color space when the game starts.

For Resident Evil 2, 3, 4, and other RE Engine titles:

1. Turn on Windows HDR before launching the game.
2. Keep Studio Display XDR as the only active display while testing.
3. Prefer borderless/fullscreen-window mode first, then retry exclusive
   fullscreen only after 5K modes are stable.
4. Disable Windows Auto HDR for the game while testing native HDR. Auto HDR can
   coexist with Windows HDR, but it is not the same capability path as the
   game's own HDR menu.
5. Back up the RE Engine config before editing fields such as `HDRmode`,
   `PCWindowMode`, `WindowMode`, width, height, refresh rate, and last-confirmed
   display values.
6. If Windows reports `AdvancedColorEnabled=True` and `ActiveColorMode=HDR` but
   the game still greys out HDR, treat it as a driver/game output detection
   issue rather than an EDID issue. Update the GPU driver and test both
   borderless and exclusive fullscreen.

Intel documents Resident Evil 2 native HDR being greyed out on some Arc GPUs as
a known driver issue. That matches the symptom where Windows HDR is valid but
the RE Engine menu still refuses HDR.

## Common Cache Locations

- Unity games often store display settings in the current user's registry hive
  under the publisher or game key.
- Unreal Engine games often store display settings in `GameUserSettings.ini`
  below `%LOCALAPPDATA%`.
- Some games store launch options in their launcher, Steam app manifest,
  cloud-sync profile, or an engine-specific JSON/TOML/INI file.

## Safe Editing Rules

- Always make a timestamped backup before writing.
- Do not hard-code a game path in the public controller.
- Do not write a game config while that game is running unless the user
  explicitly accepts that the game may overwrite the file.
- Prefer changing only generic keys such as width, height, fullscreen mode,
  last-confirmed width/height, desired screen width/height, render scale, and
  in-game HDR enablement.
- If HDR is unstable in Windows, leave in-game HDR disabled until dxdiag shows
  true HDR rather than WCG-only advanced color.

## How To Interpret Results

- If Windows still does not enumerate 5K, keep debugging Thunderbolt/USB4,
  monitor identity, EDID, and graphics drivers. Per-game config edits will only
  hide the symptom temporarily.
- If Windows enumerates 5K but the game still shows stale modes, the game has a
  local cache. Back it up and reset the display keys.
- If borderless fullscreen works but exclusive fullscreen does not, the game is
  likely reading a stricter fullscreen mode list. Keep borderless enabled until
  the display path remains stable across hot-plug, lid-close, and reboot.

## Sources

- Microsoft Learn: [Use DirectX with Advanced Color on high/standard dynamic range displays](https://learn.microsoft.com/windows/win32/direct3darticles/high-dynamic-range)
- Intel Support: [HDR Option Is Grayed Out in Resident Evil 2 with Intel Arc A770](https://www.intel.com/content/www/us/en/support/articles/000097556/graphics.html)
