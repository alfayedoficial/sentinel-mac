# Architecture

Sentinel is a Swift Package with three targets. There is no Xcode project; everything builds with `swift build`.

```
┌────────────────────────────┐        XPC (Mach service)        ┌────────────────────────┐
│ Sentinel  (menu-bar app)   │ ───────────────────────────────▶ │ SentinelHelper (root)  │
│ SwiftUI, runs as the user  │   disableItem(label, plistPath)  │ launchd daemon         │
└──────────────┬─────────────┘                                  └───────────┬────────────┘
               │ imports                                                    │ imports
               ▼                                                            ▼
                        SentinelCommon  (protocol + HelperPolicy rules)
```

| Target | Type | Role |
|---|---|---|
| `Sentinel` | executable | The whole app: monitoring, scanners, tools, UI. |
| `SentinelHelper` | executable | Tiny root daemon. It only switches off third-party launch items. |
| `SentinelCommon` | library | The XPC protocol and `HelperPolicy`, the rules the helper enforces. Shared so the rules can be unit-tested. |
| `SentinelTests` | tests | 100+ unit tests for rules, scanners, history, updates, similar-photo hashing and the helper policy. |

## Source map (`Sources/Sentinel`)

| File | Responsibility |
|---|---|
| `SentinelApp.swift` | App entry, menu-bar scene, launch wiring. |
| `Monitor.swift` | `Sampler` (background sampling) and `Monitor` (state the UI reads), `IconCache`, `BarState`. |
| `Rules.swift` | `FlagRules`: when does an app look unused? Pure, tested. |
| `ThreatWatch.swift` | `ThreatRules` (pure), `ThreatScanner` (background), `ThreatWatch` (state), the popup and the screen. |
| `CacheCleaner.swift` | Cache roots, age evaluation, report and clean. |
| `Tools.swift` | `Trasher`, disk stats, Uninstaller, big-file finder. |
| `Features.swift` | Startup Manager, Space Lens, Duplicate Finder, `ToolKind`, the shared `Hub`. |
| `More.swift` | History log, Maintenance tasks, weekly reminder. |
| `PrivilegedHelper.swift` | Client side of the helper (registration and XPC calls). |
| `Updater.swift` | `UpdateLogic` (pure, tested: versions, release parsing, checksum, bundle validation, swap), `Updater` (state) and the update banner. |
| `Similar.swift` | Perceptual photo hashing and clustering, similar-file families, thumbnails and both screens. |
| `Views.swift`, `ToolsViews.swift`, `AlertPanel.swift` | SwiftUI screens and the floating popup. |
| `Theme.swift` | Design tokens, logo shapes, shared controls. |
| `Models.swift` | Small value types and formatters. |
| `Demo.swift`, `Snapshot.swift` | Sample data and the screenshot renderer (`--snapshot`). |

## Threading model

The rule is simple: **the main thread only draws and applies results.**

```
Timer (main) ──▶ gather cheap NSWorkspace info ──▶ background queue ──▶ Sampler / ThreatScanner
                                                      (syscalls, file I/O, signing checks)
                                                                   │
main actor ◀──────────────── apply(result), publish only if changed ◀┘
```

- `Sampler` reads processes (`proc_pid_rusage`), windows, power assertions, memory and battery.
- `ThreatScanner` reads every process, its arguments (`sysctl KERN_PROCARGS2`) and, only when needed, its code signature.
- Scans (caches, files, duplicates) run in detached tasks and report progress sparsely.
- Published values are compared with the previous ones and only assigned when they changed, so SwiftUI does not redraw for nothing.
- Polling is 3 s while the window is open and 10 s when it is closed.
- The menu-bar label observes `BarState`, a tiny object with two values, instead of the whole monitor.
- Icons come from `IconCache`; no view touches the file system in `body`.

State that must survive closing the window lives in the shared `Hub`, so reopening is instant.

## Data flow of a clean-up

```
scan (background) ─▶ report (user reviews, can untick) ─▶ confirm card ─▶ Trasher.trash()
                                                                         ├─▶ Trash (recoverable)
                                                                         └─▶ HistoryLog.record()  ─▶ history.json
```

`Trasher.trash` is the single place that moves things to the Trash. It falls back to Finder for items macOS protects and always records the original and Trash locations so **Restore** works.

## Updates and the network

Sentinel makes **one** kind of network request: the update check. It is a `GET` to the GitHub Releases API (and, on request, a download of `Sentinel.zip` and its checksum from GitHub's hosts). The fetch function is injectable, so tests never touch the network.

```
Timer (daily) / "Check now" ──▶ GET /releases/latest ──▶ UpdateLogic.parseRelease ──▶ .available
Update ──▶ download zip ──▶ sha256 == published checksum ──▶ ditto -x ──▶ validateBundle ──▶ swap ──▶ relaunch
```

`UpdateLogic.validateBundle` is the gate: right bundle id, newer version, valid code signature, same signing identity. `UpdateLogic.swap` keeps the old app so a failure restores it. A real-network test runs with `SENTINEL_NETWORK_TESTS=1`.

## The privileged helper

Some launch items live in `/Library/LaunchAgents` and `/Library/LaunchDaemons`, which only root can change. Asking for the administrator password for every change was annoying, so Sentinel registers a helper once through `SMAppService.daemon`; the user approves it once in System Settings.

- The app calls `disableItem(label:plistPath:)` over XPC.
- The helper accepts connections only from a client whose code-signing identifier is `com.afapps.sentinel`.
- `HelperPolicy.validate` refuses anything outside those two folders, non-`.plist` files, Apple (`com.apple.*`) labels, unusual labels, and path tricks such as `..`.
- It stops the job with `launchctl bootout` and **moves** (never deletes) the file to `/Library/SentinelDisabled`.

If the helper is unavailable, the app falls back to the normal macOS administrator prompt. See [SECURITY.md](../SECURITY.md).

## Testing approach

- Rules are **pure functions** (`FlagRules`, `ThreatRules`, `HelperPolicy`), tested without touching the system.
- Scanners take their folders as parameters (`roots:`, `library:`), tested against throw-away temporary folders.
- Threat tests start real harmless look-alike processes (a re-signed copy of `sleep` named `xmrig`, a busy shell with pool text) and check that the real scanner reports them.
- Nothing in the tests writes to your real Trash, history file or home folder.

## Demo mode

`Sentinel --snapshot <folder>` fills every screen with sample data, disables every real scan, renders the SwiftUI views to PNG files and exits. This is how the documentation screenshots are made, and it guarantees they never contain personal information.
