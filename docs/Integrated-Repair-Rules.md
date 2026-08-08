# Integrated Repair Rules

These rules are the project contract for Studio Display XDR repair. They are
intended to keep HDR, brightness, resolution, and topology fixes working
together instead of letting one successful path disable another.

## Order Of Operations

1. Capture the current display, HDR, USB4, and brightness state before writing.
2. Pause `SystemBrightnessMirror` and `BrightnessKeyBridge` before any display,
   EDID, monitor-driver, USB4, or HDR operation.
3. Force Studio Display XDR into external-only topology before 5K mode-table
   repair or HDR repair. The external display must be the only active screen
   for the public integrated repair path.
4. Ensure the Boot Camp-style monitor/EDID fallback only when explicitly
   requested, and prefer Apple `APPAE3A` source EDID over the current
   `MS_0001` fallback cache.
5. Restore a stable Studio Display mode table before HDR. `5120x2880@60` must
   be enumerated, not merely active through `CDS_TEST`.
6. Repair failed Apple Studio Display USB/HID control interfaces before HDR.
   If `VID_05AC&PID_1114` or `VID_05AC&PID_1116` interfaces are present but
   failed to start, restart them through the elevated path before sending HDR
   state packets.
7. Attempt HDR only after the active target is the Studio Display path, the
   5K60 mode table is stable, and the Apple USB/HID control side has been
   checked.
8. Hot-plug automation must probe the live HDR gate before writing. If
   `HighDynamicRangeSupported=True` but HDR is inactive, send only the
   lightweight HDR enable request. If the gate is false or unknown after
   Thunderbolt reconnect, run the deep integrated repair path with cooldown
   instead of spamming rejected HDR packets. Automatic deep repair must run
   through the installed on-demand elevated task, and it must keep HDR pending
   until live probes verify `5120x2880@60` is enumerated and HDR is active.
9. Never silently downgrade HDR to WCG. WCG fallback is allowed only when the
   caller explicitly passes the fallback flag.
10. Leave per-game cache editing outside the public integrated repair pipeline.
   The public tool may diagnose stale game mode lists, but it must not hard-code
   game-specific paths or settings.
11. Restart brightness mirror and brightness-key bridge last, then validate HID
   brightness readback.
12. Interactive repairs should run through the progress host. A short black
    screen is expected during topology, USB4, or HDR state changes, so the user
    must see which stage is currently running before the display flashes.

## Guardrails

- If Apple display evidence is absent, external-mode repair must not target the
  current primary display. That prevents the internal panel from being repaired
  as if it were the Studio Display.
- Laptop lid state can change Windows display topology. Attaching Thunderbolt
  while the lid is already closed can enumerate the Studio Display as a second
  display; attaching while the internal panel is lit and closing the lid later
  can collapse Windows into a combined `1/2` topology. Repair code must not
  trust display ordinals alone and must re-identify the target through Apple
  USB4/HID/EDID evidence.
- Sleep-time hot-plug and resume must be treated like a fresh topology event:
  clear cached PnP evidence, re-check screen topology, and re-apply
  external-only mode before HDR. The tray controller must then queue HDR restore
  for that reconnect event.
- A reconnect/topology-change event must release stale integrated-repair
  cooldown from the previous cable session. Cooldown is a retry throttle, not a
  proof that the new Thunderbolt link has already been repaired.
- Starting a repair process is not success. The controller may clear pending
  HDR only after probing live state and confirming current 5K, enumerated 5K60,
  and HDR active. If an automatic task never produces a stable state, a
  watchdog must release the retry path.
- If external-only topology cannot be verified, HDR repair must be skipped.
- If HDR is already active and the current Studio Display path is already
  external-only 5K, topology repair must preserve it instead of staging a safety
  mode first.
- If the current mode is `5120x2880@60` but `5120x2880@60` is missing from the
  enumerated mode table, the state is unstable. Games and Windows HDR UI can
  still see a 1080p/low-mode capability list.
- If `5120x2880@60` is present in the enumerated mode table, the game
  resolution gate may pass even when `ChangeDisplaySettingsEx(CDS_TEST)` rejects
  the same mode on an active HDR/DDisplay path. Treat `CDS_TEST` as diagnostic
  evidence, not the only source of truth for game mode-list readiness.
- If `DisplayConfigSetDeviceInfo` rejects HDR state, the tool must report that
  result instead of treating `AdvancedColorEnabled` or WCG as equivalent to HDR.
- If `DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2` reports
  `HighDynamicRangeSupported=False`, do not repeatedly send HDR packets in the
  default path. This is a Windows/driver capability gate; repair EDID, monitor
  binding, reference mode, USB/HID control interfaces, or link topology first.
- Brightness HID writes must remain isolated from HDR/reference-mode state.
  Brightness repair validates and restarts the bridge; it does not write color
  state.
- During external-only or lid-closed startup, an internal WMI brightness value
  of `0%` must be treated as an internal-panel-off sentinel. The mirror must
  preserve the current Studio Display HID brightness, or use a visible fallback,
  instead of syncing `0%` to the external display.
- When HDR is active on an external display, Windows' `SDR content brightness`
  controls SDR paper-white relative to HDR content. It is not a replacement for
  Apple HID hardware brightness, and changing HID brightness must not imply
  that the Windows SDR white level changed.
- Any local game helper kept outside the public release must stay dry-run-first
  and backup-before-write.
- Default tray UI must expose the unified repair path, not separate EDID,
  Boot Camp-style driver, and HDR rollback buttons. Those scripts can remain as
  explicit advanced CLI fallbacks, but they must not be the default hot-plug
  path because they are not transaction-safe by themselves.
- Automatic repair must be quiet-first. It may use `SetDisplayConfig`, PnP
  rescan, monitor restart, and Apple USB4 router retraining, but it must not
  launch `DisplaySwitch.exe`, Win+P-style projection UI, or the graphics reset
  hotkey unless the user explicitly requests that interactive fallback.
- Automatic administrator repair must be bootstrapped through a normal UAC
  prompt or a previously registered highest-privilege scheduled task. The tool
  must not attempt to bypass UAC; after the task is registered once, hot-plug
  automation may run it without prompting again.

## Evidence Rules

- `AdvancedColorSupported` means Windows believes the display path supports
  HDR10-capable advanced color.
- `AdvancedColorEnabled` means advanced color is currently enabled.
- `HighDynamicRangeSupported` from `GET_ADVANCED_COLOR_INFO_2` is the gate for
  Win11 HDR state packets. If it is false while dxdiag still says monitor
  capabilities include HDR metadata, Windows sees HDR metadata in the EDID but
  has not accepted the active display path as HDR-capable.
- `Active Color Mode` from dxdiag is the practical cross-check for whether the
  path is actually in HDR or only WCG.
- Microsoft documents that external HDR displays may need the correct display
  topology, especially extended display mode, before HDR controls appear.
- Microsoft documents `DISPLAYCONFIG_SDR_WHITE_LEVEL` as a read path for the
  current SDR white level in nits on an HDR monitor.
- Microsoft documents that `DisplayConfigSetDeviceInfo` can reject packets; the
  tool must surface those Win32 results.

Sources:

- Microsoft Support: [HDR settings in Windows](https://support.microsoft.com/en-us/windows/hdr-settings-in-windows-2d767185-38ec-7fdc-6f97-bbc6c5ef24e6)
- Microsoft Learn: [DISPLAYCONFIG_SDR_WHITE_LEVEL](https://learn.microsoft.com/windows/win32/api/wingdi/ns-wingdi-displayconfig_sdr_white_level)
- Microsoft Learn: [DisplayConfigSetDeviceInfo](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-displayconfigsetdeviceinfo)
