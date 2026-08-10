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
4. Treat the Boot Camp-style monitor identity as the only default HDR-capable
   pipeline for an active `MS_0001` display. Generic/Digital Flat Panel
   `monitor.inf` fallback may preserve a 5K mode table, but it must not be used
   as the HDR repair path. Ensure the Boot Camp-style monitor INF when
   `MS_0001` is bound to Microsoft `monitor.inf`, the generated driver package
   is missing, the current binding is not this project's `oem*.inf`, or the
   active EDID cache lacks HDR static metadata.
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
- If an elevated USB4/monitor restart completes and Windows still exposes only
  a degraded non-5K mode table, the automatic tray path must enter a persisted
  5K mode-table backoff instead of immediately starting another deep repair.
  Repeated USB4 restarts are noisy, can black-screen the user, and do not create
  new EDID bandwidth data without a fresh Thunderbolt reconnect, power resume,
  or successful 5K probe.
- If `5120x2880@60` is present in the enumerated mode table, the game
  resolution gate may pass even when `ChangeDisplaySettingsEx(CDS_TEST)` rejects
  the same mode on an active HDR/DDisplay path. Treat `CDS_TEST` as diagnostic
  evidence, not the only source of truth for game mode-list readiness.
- If hot-plug begins before active `MS_0001` exists, the initial Boot Camp-style
  INF gate can be falsely skipped. After USB4/link refresh makes `MS_0001`
  active, and the custom Boot Camp-style INF is ready but the 5K60 mode table is
  still degraded, the integrated repair must perform one controlled monitor-INF
  rebind plus USB4/monitor refresh before entering mode-table backoff.
- If `DisplayConfigSetDeviceInfo` rejects HDR state, the tool must report that
  result instead of treating `AdvancedColorEnabled` or WCG as equivalent to HDR.
- If `DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2` reports
  `HighDynamicRangeSupported=False`, do not repeatedly send HDR packets in the
  default path. This is a Windows/driver capability gate; repair EDID, monitor
  binding, reference mode, USB/HID control interfaces, or link topology first.
- If `HighDynamicRangeSupported=False` while `5120x2880@60` is already current
  and enumerated, first confirm the active `MS_0001` binding is the
  Boot Camp-style monitor identity before sending HDR packets. If Windows is
  still on Generic/Digital Flat Panel or Microsoft `monitor.inf`, wait for or
  restore the Boot Camp-style binding; do not let the faster generic fallback
  win the race and become the HDR path.
- The 2026-08-09 known-good hot-plug recovery path is a transaction:
  active `MS_0001`, restore or verify the Boot Camp-style monitor INF from the
  Apple `APPAE3A` EDID, wait for that binding to settle, retrain the Apple
  Studio Display XDR USB4 router, require current 5K plus enumerated 5K60,
  require HDR supported and active, require brightness HID readback, then save
  the launcher `code=0` state as the next diagnostic baseline.
- `Repair-StudioDisplayHdrIdentityRollback.ps1` is the explicit advanced HDR
  identity diagnostic. It may briefly black-screen while Windows rebinds the
  monitor identity, and it must automatically restore the 5K60 fallback if the
  mode table regresses. It is not part of the default hot-plug loop because the
  2026-08-09 test preserved 5K60 but still left
  `HighDynamicRangeSupported=False`.
- A repair launcher may return `0` only after a final independent probe confirms
  5K60 current/enumerated, HDR supported and active, and brightness HID readable.
  WCG/Advanced Color success alone is never HDR success.
- The scheduled auto-repair launcher must preflight the same `code=0` gate
  before disruptive work. If the system is already current 5K, enumerated
  5K60, HDR active, and brightness-readable, it must save the known-good state
  and exit `0` without USB4 retraining or topology flashes.
- Brightness HID writes must remain isolated from HDR/reference-mode state.
  Brightness repair validates and restarts the bridge; it does not write color
  state.
- Brightness worker lifecycle is part of the unified transaction. Before
  starting or restarting `SystemBrightnessMirror` or `BrightnessKeyBridge`, the
  controller must treat stale pid files, no-pid named mutex owners, and
  uniquely identifiable orphan PowerShell workers as one recoverable state:
  adopt the worker when safe, stop it during an explicit restart/full repair,
  and never launch duplicates against a held mutex.
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
- HDR identity rollback to Generic/Digital Flat Panel is source-tree
  diagnostic-only. It must not be installed, shipped in release packages, or
  invoked by the default controller. If it preserves 5K60 but does not reopen
  the HDR gate, the default controller must return to the Boot Camp-style
  identity instead of maintaining two competing hot-plug repair strategies.
- Default tray UI must also avoid standalone external-only/link-refresh buttons.
  Reconnect, resume, topology changes, and manual one-click repair all enter
  the same integrated topology/5K/HDR/brightness transaction.
- Do not ship Discord, game, or app-specific repair helpers in the public
  controller package. Keep game handling generic and diagnostic, and keep local
  experiments outside the release path.
- Automatic repair must be quiet-first. It may use `SetDisplayConfig`, PnP
  rescan, monitor restart, and Apple USB4 router retraining, but it must not
  launch `DisplaySwitch.exe`, Win+P-style projection UI, or the graphics reset
  hotkey unless the user explicitly requests that interactive fallback.
- Manual progress repair must provide non-visual feedback while the Boot
  Camp-style display identity is being established. If the user presses Space,
  the progress host may stop the full HDR rebuild and apply a fast visible
  fallback, but that fallback is an escape hatch only and must not be recorded
  as HDR success.
- If the fast visible fallback is used, the tray controller must surface that
  state and offer a direct rebuild back into the Boot Camp-style 5K60 HDR
  pipeline. Clear the fallback marker only after final probes confirm 5K60
  current/enumerated, HDR active, and brightness HID readable.
- Automatic administrator repair must be bootstrapped through a normal UAC
  prompt or a previously registered highest-privilege scheduled task. The tool
  must not attempt to bypass UAC; after the task is registered once, hot-plug
  automation may run it without prompting again.
- Every reconnect, startup, resume, and topology-change event must create a
  pipeline decision record before repair. The decision must say whether the
  controller skipped because `code=0` is already true, enabled HDR lightly
  because only HDR was inactive, attached to an already-running task, backed off
  a known gate, or entered the Boot Camp-style integrated rebuild.
- Passive observation is not repair. The hot-plug observer may read logs,
  scheduled-task state, 5K mode-table state, HDR state, Apple USB/HID device
  state, brightness worker PIDs, and foreground/user-idle timing, but it must
  not call topology, USB4, HDR, EDID, brightness, or monitor-driver writers.
- The current known post-hot-plug failure class is: Boot Camp-style `MS_0001`
  identity and 5K60 can recover, while HDR remains blocked because
  `VID_05AC&PID_1116` `MI_08`/`MI_09` Apple USB control interfaces remain
  `CM_PROB_FAILED_START`. That state is an HDR capability gate failure, not a
  brightness conflict, and the observer should record it explicitly.
- User activity during topology, USB4, Apple USB/HID, monitor identity, or HDR
  stages is only correlation evidence. It can explain why a run should be
  repeated under quieter conditions, but it must not be treated as proof of
  user-caused failure.

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
