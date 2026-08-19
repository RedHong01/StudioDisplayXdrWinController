# Changelog

## Unreleased

- Merged the local Studio Display manager worktree with the historical
  `StudioDisplayXdrWinController` GitHub repository without force-pushing or
  discarding release assets, so the cloud repository can carry the latest repair
  logic plus README/docs/release tooling in one history.
- Added `Test-StudioDisplayOfflineMaintenanceGuards.ps1` to verify offline
  maintenance safety: source/installed hashes, PowerShell parser health,
  persisted Apple USB reboot-required HDR-gate handling, brightness workers, and
  latest passive-observer stability.
- Made HDR monitor-identity rollback opt-in. When the controller is already in
  the Apple USB reboot-required gate, automatic repair now preserves the current
  monitor identity and skips driver delete/reinstall churn instead of attempting
  aggressive HDR rollback.
- Cleared stale `StudioDisplayLastFailureState.json` after a real Studio Display
  disconnect/reconnect or sleep-time physical re-enumeration, allowing the next
  automatic pass to perform one fresh conservative repair instead of immediately
  reusing an old Apple USB reboot-required failure as a blocker.
- Added a shared `StudioDisplayPhysicalReenumerationState.json` marker. The tray
  records true disconnect/reconnect/resume evidence, and offline auto-repair
  workers use that newer marker to clear stale HDR physical gates before running
  one fresh conservative pass.
- Extended the Apple USB/HID repair wait and added repair-log quiet settling
  before failure-state classification. This prevents a timed-out USB helper from
  saving `AppleUsbRebootRequired=false` moments before late `pnputil 3010`
  evidence arrives.
- Preserved existing last-failure evidence while the HDR physical re-enumeration
  gate is active, so a preflight-only skip cannot erase the repair log that
  explains why the controller is waiting.
- Installed `HdrScreenshotGuard.ps1` and the offline maintenance guard through
  the release installer so fresh GitHub clones match the local running
  controller component set.
- Recovered brightness worker lifecycle management from stale/no-pid mutex
  states. The tray and integrated repair can now adopt uniquely identifiable
  `SystemBrightnessMirror`/`BrightnessKeyBridge` workers, avoid duplicate
  launches when only a mutex is visible, and reclaim orphaned workers during a
  brightness restart or full 5K/HDR repair transaction.
- Added a hot-plug automation verification tool. `Test-StudioDisplayHotplugAutomation.ps1`
  audits the tray workers, scheduled elevated repair task, Boot Camp-style
  `code=0` recipe, HDR/5K/brightness gates, and can optionally run the scheduled
  task after the launcher preflights and skips disruptive repair when already
  healthy.
- Added a passive hot-plug observer. The tray now starts
  `Watch-StudioDisplayHotplugAutomation.ps1` on reconnect, startup, resume, and
  topology-change events; it records stage/decision snapshots, 5K mode-table
  state, HDR gate state, Apple `VID_05AC&PID_1116` `MI_08`/`MI_09` failed-start
  evidence, brightness worker state, and user-input overlap as correlation-only
  data without intervening in the display pipeline.
- Clamped the HDR-gate retry counter when persisting/restoring backoff state, so
  logs no longer report impossible counts such as `3/2` after a transient 5K
  mode-table repair re-enters the same HDR capability-gate failure.
- Added a post-link Boot Camp-style mode-table rebind. If hot-plug starts before
  active `MS_0001` exists, the integrated repair no longer misses the monitor-INF
  refresh opportunity; once `MS_0001` becomes active and is bound to the custom
  Boot Camp-style INF but Windows still exposes only a low-resolution mode table,
  the repair performs one controlled INF rebind and USB4/monitor refresh before
  giving up on 5K60 enumeration.
- When the manual progress window's `Space` fallback is used, the tray now treats
  that as an explicit temporary-visible state. The main repair entry is relabeled
  to rebuild from fallback back into the Boot Camp-style `5120x2880@60` HDR
  pipeline, and the fallback marker is cleared only after final 5K60/HDR/brightness
  probes pass.
- Retargeted XDR link refresh and external-only repair to the stable
  Boot Camp-style `5120x2880@60` HDR pipeline. `5120x2880@120` remains a
  diagnostic probe, but its absence no longer becomes the deciding target for the
  public repair transaction.
- The integrated repair now rebuilds the Boot Camp-style monitor-INF transaction
  when active `MS_0001` is already bound to the custom INF but Windows still
  exposes no enumerated 5K60 mode table. This targets the "desktop is 5K but
  games still see 1080p/3K" half-restored state directly.
- Collapsed the default hot-plug HDR strategy onto a single Boot Camp-style
  `MS_0001` pipeline. Generic/Digital Flat Panel fallback is now treated as
  diagnostic-only for HDR, while active `MS_0001` sessions must bind to this
  project's Boot Camp-style `oem*.inf` with HDR EDID metadata before HDR packets
  are sent.
- Added a Boot Camp-style identity settle gate before HDR repair. This prevents
  the faster Microsoft `monitor.inf` fallback from winning the hot-plug race and
  leaving Windows at stable 5K60 but `HighDynamicRangeSupported=False`.
- Removed the HDR identity rollback experiment from the installed controller
  and release package. It remains source-tree diagnostic material only, so the
  shipped tool exposes one working recovery pipeline instead of two competing
  monitor-identity strategies.
- Added manual repair audio feedback and a Space-key escape hatch. While the
  Boot Camp-style identity is being rebuilt, the progress window plays periodic
  system sounds; pressing Space stops the full HDR wait and applies a quick
  visible external fallback that can later be replaced by the tray's
  Boot Camp-style 5K60 HDR rebuild.
- Persisted the known-good `code=0` recovery baseline from the auto-repair
  launcher. When final independent probes confirm current 5K, enumerated 5K60,
  HDR supported/active, and readable Studio Display HID brightness, the
  installed controller now writes `StudioDisplayKnownGoodState.json` with the
  exact recovery recipe so future hot-plug debugging and automation use the same
  success gates instead of relying only on transient logs.
- Persisted `StudioDisplayLastFailureState.json` when automatic repair does not
  reach `code=0`. Stable 5K60 plus `HighDynamicRangeSupported=False` is now
  classified separately, and logs that still show Apple `VID_05AC&PID_1116`
  `MI_08`/`MI_09` failed-start interfaces are tagged as a reference-mode USB
  gate instead of causing blind repeated HDR packet attempts.
- Fixed the Boot Camp-style fallback preflight so `monitor.inf` entries under
  `pnputil`'s `Matching Drivers` list no longer count as the active binding when
  the current `Driver Name` is this project's installed `oem*.inf`. This
  prevents a stable 5K `MS_0001` session with full HDR EDID metadata from
  re-running the monitor-INF transaction.
- Stopped default integrated repair from automatically enabling WCG fallback
  when the HDR gate is closed. WCG remains available only through explicit
  `-AllowWcgFallback` diagnostics, so a failed HDR recovery cannot silently
  convert the session into WCG and then be mistaken for HDR.
- Reconnected the Boot Camp-style monitor fallback to the unified repair
  pipeline. If the active `MS_0001` display falls back to Microsoft
  `monitor.inf`, loses the generated monitor driver package, or exposes only a
  128-byte EDID without HDR static metadata, the integrated repair now
  automatically reinstalls the signed monitor INF before USB4 retraining,
  5K60 validation, HDR activation, and brightness validation. The tray also
  bypasses the 5K mode-table backoff for this specific missing-driver state so
  hot-plug automation can recover instead of waiting forever on a stale
  1080p/HDR-gate failure.
- Kept the Boot Camp-style monitor installer from reporting failure when its
  post-install native-mode guard runs before USB4 retraining has refreshed the
  Windows mode table. The installer now logs that transient guard failure as a
  warning and leaves final 5K/HDR validation to the integrated pipeline.
- Added controlled HDR identity rollback tooling for the `MS_0001` monitor path.
  The new script removes only this project's Boot Camp-style monitor INF
  packages, lets Windows rebind through `monitor.inf`, verifies 5K60/HDR, and
  restores the 5K60 fallback if resolution regresses.
- Tightened auto-repair success semantics: the launcher now refuses `code=0`
  unless final independent probes confirm 5K60 current/enumerated, HDR supported
  and active, and Studio Display HID brightness readable. WCG fallback is logged
  as WCG, not HDR. The launcher also has a `-ValidateOnly` mode for
  non-disruptive final-state checks.
- Hardened resolution/HDR output parsing to single-line anchored matches so
  multi-line PowerShell output cannot accidentally satisfy the HDR gate.
- Stopped the default HDR-gate recovery path from switching strategies after a
  Boot Camp-style failure. Historical logs now show Generic/Digital Flat Panel
  can preserve 5K60 while still leaving `HighDynamicRangeSupported=False`; the
  default path therefore keeps the Boot Camp-style `MS_0001` identity as the
  single HDR pipeline and records/backoffs gate failures instead of alternating
  between competing monitor identities.
- Fixed automatic hot-plug repair getting stuck in repeated HDR-gate retries
  after 5K60 was already restored. The tray now classifies stable 5K60 plus
  `HighDynamicRangeSupported=False` as an HDR capability-gate block, backs off
  instead of looping deep USB4/HDR repair, and clears that block on fresh
  Thunderbolt reconnect, power resume, or a successful HDR probe. The backoff
  is persisted locally so restarting/reinstalling the tray does not immediately
  repeat the same failed HDR-gate transaction.
- Coalesced topology/lid-state events that arrive while the elevated integrated
  auto-repair task is already running. The controller now attaches to the
  current transaction instead of resetting `integratedRepairInFlight`, launching
  another topology pass, or submitting another scheduled-task run.
- Removed the remaining split-pipeline tray and hot-plug paths. Direct
  external-only/link-refresh tray buttons are gone, and reconnect/resume/topology
  events now queue the integrated topology/5K/HDR/brightness transaction instead
  of running a standalone topology repair first.
- Removed the Discord microphone helper from the public controller, installer,
  and release list. App-specific helpers stay out of the open-source package;
  game/display issues are documented through generic diagnostics instead.
- Simplified the tray menu information architecture. The primary menu now keeps
  the daily one-click repair visible while grouping brightness service controls,
  HDR/brightness context, permission repair, logs, and diagnostics into focused
  submenus.
- Fixed installer handling for the elevated hot-plug auto-repair task. The
  installer now verifies an existing task before registering, automatically
  launches a UAC registrar when a non-elevated install needs to create or repair
  the task, waits for completion, and validates success through Task Scheduler
  or the registrar log instead of emitting a misleading warning every install.
- Added one-click repair preflight and skip logic. The tray now skips the full
  repair when 5K60, HDR active, brightness workers, and hardware brightness HID
  are already healthy; it only restarts brightness workers when that is the sole
  missing piece; and it asks for UAC immediately before a deep USB4/HDR/HID
  repair is required.
- Extended the same stable-5K60 skip guard to tray startup and hot-plug
  topology repair, so reconnect/startup does not bounce through the 2K safety
  stage when the Studio Display is already the only active 5K60 screen.
- Hardened the progress and integrated repair scripts. The progress window now
  follows the actual repair child process instead of waiting forever for a
  missing final log line, and the integrated repair skips already-satisfied
  external-only/5K/HDR stages to avoid unnecessary black screens.
- Fixed brightness worker false positives caused by orphan mutex holders. The
  brightness mirror and key bridge now return a non-zero duplicate-instance
  exit code, and the tray logs worker startup failures with exit code, pid-file,
  and mutex state so stale hidden workers can be diagnosed instead of silently
  blocking mouse brightness keys.
- Added a 5K mode-table backoff for degraded Thunderbolt sessions. If the
  elevated repair finishes while Windows still exposes only a non-5K/1080p mode
  table, the tray now records a local block state and waits for a fresh
  reconnect, power resume, or successful 5K probe instead of repeatedly
  restarting the Apple USB4 router every repair cycle.
- Hardened brightness worker adoption and installer cleanup. The tray now
  treats an existing mutex owner as an already-running brightness worker instead
  of spawning duplicates, and the installer attempts to stop orphaned
  controller-owned PowerShell workers even when their pid files are missing.

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
- Replaced the earlier "do not refresh Boot Camp-style by default" experiment
  with the current single-pipeline rule: active `MS_0001` repair must converge
  on the Boot Camp-style monitor identity before HDR, while Generic/Digital
  Flat Panel fallback remains diagnostic-only.
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
