# HDR Gate Forensics - 2026-08-09

This note captures why Studio Display XDR HDR worked in earlier repair runs but
does not currently come back after Thunderbolt hot-plug.

## Current State

- Resolution is healthy: `5120x2880@60Hz` is current and present in the Windows
  mode table.
- Advanced color is partially healthy: Windows is in WCG/10bpc mode.
- HDR is blocked: `HighDynamicRangeSupported=False`,
  `HighDynamicRangeUserEnabled=False`, and dxdiag reports `HdrSupport=Not
  Supported`.
- After the controlled identity rollback, the active display identity is
  `MS_0001` through Microsoft's standard `monitor.inf` path, shown by dxdiag as
  `Digital Flat Panel (640x480 60Hz)`.
- The effective EDID still contains HDR metadata, including BT.2020 and ST
  2084/PQ, so this is not a simple missing-EDID-metadata issue.

## Why Earlier Runs Worked

Successful runs on 2026-08-07 and 2026-08-08 followed this pattern:

- The reconnect initially had an unstable mode table, often exposing only
  `1920x1080@60Hz` even while the desktop was already rendering at 5K.
- The USB4/router refresh restored the `5120x2880@60Hz` mode table.
- After that refresh, Windows already reported HDR active:
  `RawFlags=0x000000f3`, `HighDynamicRangeSupported=True`,
  `HighDynamicRangeUserEnabled=True`, and `ActiveColorMode=HDR`.
- Because HDR was already active, the external-mode repair guard skipped
  topology and display-mode rewrites.

In other words, the earlier success was mostly preservation of a good
Windows/driver HDR target state after USB4 retraining, not a proof that the
tool can always force HDR back from a closed HDR capability gate.

## Why Current Runs Fail

The first stable failure on 2026-08-09 differed at the HDR gate:

- USB4 retraining still restored the 5K60 mode table.
- HDR did not re-open after the same retraining.
- Windows reported `RawFlags=0x000000c7`, `AdvancedColorEnabled=True`,
  `WideColorUserEnabled=True`, `ActiveColorMode=WCG`, but
  `HighDynamicRangeSupported=False`.
- Since Windows reports the active target path as not HDR-capable,
  `SET_HDR_STATE` must not be spammed; it will be rejected or skipped.

Later Boot Camp-style monitor INF re-enumeration did not reopen HDR. A
controlled rollback from the custom Boot Camp-style INF to generic
`monitor.inf`, including a stronger `DISPLAY\MS_0001` remove/rescan test, also
did not reopen HDR. It preserved `5120x2880@60Hz`, but Windows still reported
`RawFlags=0x000000c7`, `ActiveColorMode=WCG`, and
`HighDynamicRangeSupported=False`. A forced `SET_HDR_STATE` packet returned
`ERROR_NOT_SUPPORTED (50)`. That shows the monitor-INF fallback is useful for
5K60 mode-table recovery, but neither the custom INF nor generic monitor
identity is currently sufficient to restore HDR on this Windows/Intel path.

## Ruled Out

- Not a 5K60 mode-table problem anymore: 5K60 is currently enumerated.
- Not a brightness conflict: Apple HID brightness reads still work, and the HDR
  gate fails before brightness writes matter.
- Not only a missing HDR EDID block: dxdiag still sees HDR monitor capabilities.
- Not solely the failed Apple HID `MI_08`/`MI_09` interfaces: those failures
  were present in successful HDR runs too.

## Repair Rule

Default hot-plug repair must not refresh the Boot Camp-style `MS_0001` monitor
INF just because `HighDynamicRangeSupported=False`. That fallback remains an
explicit advanced option for mode-table recovery, but the default path should
avoid pinning the active session back to a WCG-only monitor identity.

The next meaningful HDR experiments are:

- Install or repair Apple Windows support software from the official Boot Camp
  route where available, because Apple's documented path relies on current
  Apple Windows support updates rather than only a monitor INF.
- Compare Intel graphics driver behavior, because the active Studio Display
  path is routed through Intel graphics and the HDR gate is exposed by the
  graphics stack.

## Automation Rule Added

The automated repair path must refuse `code=0` unless final probes verify all
of the following:

- `5120x2880@60Hz` is the current display mode and is present in the mode table.
- `GET_ADVANCED_COLOR_INFO_2` reports `HighDynamicRangeSupported=True`.
- The final active color mode is HDR, not merely WCG/Advanced Color.
- Studio Display HID brightness is readable after the brightness workers are
  restored.

If WCG fallback succeeds but HDR remains blocked, the correct result is a
non-zero pending/blocked exit code with logs, not a successful hot-plug repair.
