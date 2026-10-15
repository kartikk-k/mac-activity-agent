# Activity Agent

A local native macOS monitor built with SwiftUI, AppKit, libproc and IOKit. No account, telemetry, remote backend, or third-party dependencies.

## Build and run

Requires Xcode Beta at `/Applications/Xcode-beta.app` (the installed macOS 27 SDK). The deployment target is macOS 14; Liquid Glass uses macOS 26+ with a native-material fallback.

```sh
./scripts/build.sh
open "build/Activity Agent.app"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

The generated app is locally ad-hoc signed, not notarized. Use the built bundle directly; startup registration is optional in Settings. Closing the window keeps the menu-bar monitor running. Quit exits the app.

## Implemented

- Real applications grouped with nested and reparented helpers; validated ancestry connects CLI children. Named runtime chains are distinct command groups, never fake app bundles. Independent servers with the same working directory stay separate.
- Expandable process rows, memory/CPU sorting, search, real icons, actual listening TCP ports, explicit quit/force-quit, and pause/resume. Actions revalidate PID, birth time and executable path before signalling; no automatic termination.
- Native translucent window, Liquid Glass status control on supported macOS, neutral navigation icons, original app icon, soft filled trend charts, dotted memory graphics, and image export.
- System CPU, physical memory composition, swap usage, interface traffic, disk I/O, battery, uptime, thermal state, and optional GPU driver telemetry.
- Menu-bar CPU/memory/network reading and top applications.
- CLI agent sessions, process descendants, project paths and aggregate memory/CPU. Installed provider app icons are reused. Activity labels reflect measured CPU, not guessed task state.
- Timestamped local Codex usage/limit observations and explicitly partial Claude token counts. Credentials are not read or transmitted. These are not live account balances.
- Local Docker container CPU, memory, network and disk statistics. Docker is never started automatically; only the local socket is queried.
- Local per-app history, one sample/minute for 24 hours then hourly, retained for 30/90/180/365 days. These are sampled snapshots, not interval averages.
- Sustained CPU, memory growth, disk and machine-wide network alerts; optional macOS notifications.
- Conservative closing suggestions: at least one hour running plus 15 minutes observed below 0.5% CPU with no disk-counter changes. Foreground applications and Keep running exclusions are protected. A quiet process may still be necessary; suggestions never trigger actions.
- Read-only MCP executable for system, applications, processes and listening ports.

## Memory and process controls

macOS decides when to compress memory or swap it to disk. There is no supported safe command to clear one process's swap while preserving it. **Pause** sends SIGSTOP and retains allocated memory; its servers stop responding. **Resume** sends SIGCONT. **Quit** asks processes to terminate (SIGTERM); **Force Quit** uses SIGKILL. Both may lose unsaved work. Actual stopped state comes from the kernel, so Resume remains available after relaunch. “Reclaim memory” opens the closing suggestions; it does not promise to shrink the swap file.

## Efficiency

The visible active app defaults to a balanced 6-second refresh (3/6/10 seconds selectable); background defaults to 15 seconds (configurable 10–60). Timers coalesce, samplers run on one utility queue, process metadata is cached by PID/birth, graphs use brief eased updates only in the active scene and respect Reduce Motion. Live values crossfade instead of repeatedly rasterizing rolling digits. There is no continuous animation loop, and sleep suspends sampling. Port enumeration is cached for 30 seconds and only requested for relevant visible sections. Docker runs only while its view is selected. History writes are batched and skipped when unchanged.

Measure the actual running app, excluding startup and interaction, using:

```sh
swift scripts/measure-app.swift <pid> --seconds 45
.build/release/ActivityMCP --benchmark --seconds 30 --interval 3
```

On the development MacBook Air, the final balanced build measured 1.70% CPU over a 30-second fully foreground run and about 58 MB physical footprint. The same final build measured 0.26% CPU over a 30-second fully hidden run. The responsive three-second mode measured 2.90% over 45 seconds. These are short steady-state observations, not upper bounds. Local screenshots, raw process measurements, logs, and build artifacts are intentionally excluded from this repository.

CPU percentages use one full core as 100%. The MCP benchmark includes the native backend but excludes the UI. Measurements vary with process count, current tab, rendering, and hardware. No hard CPU cap is enforced.

## MCP

Build creates `.build/release/ActivityMCP`. Add its absolute path as a stdio MCP server in your chosen client. The executable supports `initialize`, `ping`, `tools/list`, and `tools/call`. Tools are `system_snapshot`, `list_applications`, `list_processes`, `list_ports`; there are no destructive tools and it only samples on request. Working directories and executable paths are local data that your MCP client may receive.

## Current limits

This is not full feature parity with every commercial system monitor. Per-app network/energy attribution, Neural Engine statistics, temperature/fan controls, per-app volume, Bluetooth batteries, automatic multi-account provider quotas, full-day/week token accounting, multiple independently arranged menu-bar items, and comprehensive appearance customization are not implemented. GPU registry telemetry is optional and driver-specific. No privileged helper is installed.

A process may hide metrics from your user; inaccessible processes or counters cannot be attributed exactly. Physical footprint falls back to RSS, so memory totals are not a direct reconciliation with system used memory. Interface traffic may double-count VPN/tunnel transport. Low CPU and disk activity do not prove no requests or user activity. No input-event surveillance is used. History starts when the app runs and cannot reconstruct earlier activity.
