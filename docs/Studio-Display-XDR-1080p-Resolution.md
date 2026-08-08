# Studio Display XDR 1080p Resolution Fallback

This note covers the failure mode where Windows detects the Apple Studio
Display XDR USB4, audio, camera, or HID devices, but the active display mode is
limited to `1920x1080` instead of the native `5120x2880@120`.

## Expected Native Mode

Apple lists Studio Display XDR as a 27-inch 5K Retina XDR display with
`5120-by-2880` resolution and `120Hz` refresh rate with Adaptive Sync:

- https://www.apple.com/studio-display-xdr/specs/
- https://support.apple.com/en-us/126323

Apple also notes that other devices may support video output with resolution
and refresh rate dependent on device capabilities. On Windows PCs, the whole
chain has to expose the mode: GPU, USB4/Thunderbolt controller, cable,
firmware, drivers, and the display EDID/mode table.

## Failure Signature

The important clue is a split between USB detection and display-mode detection:

- Present PnP devices show Apple Studio Display XDR USB4/audio/camera/HID
  devices.
- `WmiMonitorID` or the monitor registry identity shows a fallback monitor such
  as `DISPLAY\MS_0001`.
- `EnumDisplaySettings` only exposes modes up to `1920x1080@60`.
- The repair script reports that the native Apple display mode is missing.

When this happens, the tool cannot force `5120x2880@120`; Windows has not made
that mode available to the graphics stack.

## Tool Behavior

`Repair-StudioDisplayExternalMode.ps1` now:

- detects `StudioDisplay`, `StudioDisplayXDR`, `ProDisplayXDR`, and generic
  displays
- expects `5120x2880@120` for Studio Display XDR
- tries a PnP rescan when the native mode is missing
- refuses to continue with a low-resolution fallback unless
  `-AllowLowResolutionFallback` is explicitly passed

Run the repair manually:

```powershell
powershell -ExecutionPolicy Bypass -File .\Repair-StudioDisplayExternalMode.ps1 -Topology External -SkipSafetyMode
```

Run diagnostics:

```powershell
powershell -ExecutionPolicy Bypass -File .\Check-StudioDisplayGaming.ps1
```

Check these sections in the output:

- `Display Modes`
- `Monitor Identity`
- `Apple Display / USB4 Evidence`
- `Display EDID Registry Cache`
- `Recent Display / GPU Events`

## Fix Order

1. Connect the Studio Display XDR directly to the Windows PC Thunderbolt 5 or
   USB4 port. Avoid docks, hubs, adapters, and questionable cables while
   testing.
2. Use the Apple Thunderbolt 5 Pro cable from the display box, or an equivalent
   certified cable that can carry the required bandwidth.
3. Power-cycle the display and PC after changing ports or cables.
4. Update BIOS/UEFI, USB4 or Thunderbolt controller firmware, Intel graphics
   drivers, NVIDIA drivers, and any OEM display routing firmware.
5. Run PowerShell as administrator and rescan devices:

```powershell
pnputil /scan-devices
```

6. Re-run the diagnostic script and confirm that Windows enumerates
   `5120x2880@120` before testing games or Discord voice.

## Interpreting Results

If the Apple USB4 devices are present but the maximum enumerated mode is still
`1920x1080@60`, focus on link training, cable, port, controller firmware, and
GPU routing. If `5120x2880` appears but only at `60Hz`, the link is at least
enumerating 5K and the remaining issue is refresh-rate bandwidth or driver
capability.

If `5120x2880@120` is listed but games still show stale fullscreen modes, use
the generic game-resolution troubleshooting workflow instead:

- `docs/Game-Resolution-Troubleshooting.md`

## EDID Override Fallback

If Windows keeps the active monitor under `DISPLAY\MS_0001` and the normal
USB4/Thunderbolt refresh path does not recover 5K modes, use the EDID override
helper as a software fallback.

The intended use is:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -EnableHdrMetadata -PatchEffectiveEdidCache
powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -Apply -Elevate -EnableHdrMetadata -PatchEffectiveEdidCache
```

Rollback:

```powershell
powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -Rollback -RollbackElevate
```

This writes only to the Windows monitor registry instance for the current
fallback device. It does not change the display firmware or EDID EEPROM, so the
same Studio Display XDR will not carry this override into macOS.

Expected result on this fallback path:

- `5120x2880@60` becomes available and can be applied.
- `5120x2880@120` may still be rejected if the Intel/USB4/Thunderbolt display
  path does not expose enough capability to Windows.
- HDR metadata can be written into `EDID_OVERRIDE` and the effective Windows
  `EDID` cache, but `dxdiag` may continue to report `HDR Not Supported` until
  Windows reloads the display target capabilities after a reboot or deeper
  display stack re-enumeration.

Check the local state with:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-StudioDisplayResolutionLadder.ps1
powershell -ExecutionPolicy Bypass -File .\Check-StudioDisplayGaming.ps1
powershell -ExecutionPolicy Bypass -File .\Get-StudioDisplayAdvancedColorState.ps1
dxdiag
```

In `Check-StudioDisplayGaming.ps1`, the `Display EDID Registry Cache` section
should show `MS_0001` with `HdrStaticMetadata=True`, `Eotf2084=True`, and at
least one BT.2020 flag after the HDR fallback is applied.

## Boot Camp-Style HDR Fallback

Apple's Boot Camp solution for Apple XDR displays appears to have multiple
layers:

- Apple Windows support software installed through Boot Camp or Apple Software
  Update.
- A monitor driver/INF layer so Windows does not stay on the generic
  `monitor.inf` `Laptop640x480x60.Install` fallback.
- Apple display USB/HID companion support for brightness and reference preset
  switching.
- A reference preset that exposes HDR/PQ behavior to Windows, such as an XDR or
  HDR Video preset.

The tool cannot ship Apple's Boot Camp binaries, and the 2026 Studio Display
XDR preset protocol may still need reverse engineering. The Windows-native part
we can safely reproduce is the Monitor INF layer:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayBootCampStyleMonitorDriver.ps1 -EnableHdrMetadata
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayBootCampStyleMonitorDriver.ps1 -EnableHdrMetadata -SignWithLocalCertificate -TrustLocalSigningCertificate -Apply -Elevate
```

This generates `drivers\StudioDisplayXdrBootCampStyleMonitor\StudioDisplayXdrBootCampStyleMonitor.inf`
and embeds the corrected EDID in `EDID_OVERRIDE` values under the hardware key,
matching Microsoft's documented monitor EDID override model.

Windows rejects third-party monitor INFs that have no catalog signature. The
`-SignWithLocalCertificate -TrustLocalSigningCertificate` path creates a
dedicated local code-signing certificate, signs the generated catalog, and adds
that certificate to this Windows install's local trust stores. It can be removed
later:

```powershell
powershell -ExecutionPolicy Bypass -File .\Remove-StudioDisplayLocalSigningCertificate.ps1 -Elevate
```

Use this after the direct EDID override if Windows still shows:

- Monitor driver: `monitor.inf`
- Driver section: `Laptop640x480x60.Install`
- Monitor capabilities: `HDR Not Supported`
- Active display target still failing Advanced Color probing

This is not a separate conflicting repair. It is the same EDID/HDR fallback
applied one layer earlier in Windows' display initialization path. It is also
Windows-local: it does not rewrite the Studio Display XDR's EEPROM, firmware, or
macOS behavior.

## USB4 Deep Retrain

After the signed monitor INF is installed, Windows may still keep a stale
`1920x1080` mode table until the Studio Display XDR USB4 router is retrained.
Use the deep refresh path:

```powershell
powershell -ExecutionPolicy Bypass -File .\Refresh-StudioDisplayXdrLink.ps1 -Elevate -RestartFallbackMonitor -RestartAppleUsb4Router
```

Expected successful progression:

- Before: active monitor may be `DISPLAY\MS_0001`, maximum enumerated mode
  `1920x1080@60`.
- After the signed INF: `DISPLAY\MS_0001` can bind to the generated
  `oem*.inf`, but the mode table may still be stale.
- After USB4 router restart: active monitor should normally reappear as
  `DISPLAY\APPAE3A`, with `5120x2880@60` enumerated and HDR reported by dxdiag.

`Get-StudioDisplayAdvancedColorState.ps1` uses DisplayConfig first. On some
Windows 11 DDisplay paths, DisplayConfig can return Win32 error `31` even while
dxdiag reports HDR active. In that case the helper falls back to dxdiag and
reports `StateSource=DxDiagFallback`, `AdvancedColorEnabled=True`, and
`ActiveColorMode=DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR`.
