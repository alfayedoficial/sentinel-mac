# Security

## Reporting a vulnerability

Please report security problems **privately** through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue for something that could be exploited. You will get a reply as soon as possible, and credit if you want it.

## What Sentinel can do on your Mac

| Component | Runs as | Can do |
|---|---|---|
| Sentinel app | you | Read process information, move files you confirm to the Trash, quit apps and kill processes you confirm. |
| `SentinelHelper` (optional) | root | Exactly one operation: switch off a **third-party** launch item. |

Sentinel makes **no network connections** and has no analytics or auto-update.

## The privileged helper

The helper exists so that switching off a system-wide launch item does not need your password every time. It is installed with Apple's `SMAppService` and needs your one-time approval in System Settings.

Its protections:

1. **Narrow API.** It exposes `version()` and `disableItem(label:plistPath:)` only. It cannot run arbitrary commands.
2. **Strict policy** (`SentinelCommon/HelperPolicy.swift`, unit-tested). The plist must sit **directly inside** `/Library/LaunchAgents` or `/Library/LaunchDaemons`, end in `.plist`, and the label must match `^[A-Za-z0-9._-]+$` and must **not** start with `com.apple.`. Path tricks such as `..` are normalized and refused.
3. **Caller check.** The helper only accepts connections whose code-signing identifier is `com.afapps.sentinel`.
4. **Reversible.** It moves the file to `/Library/SentinelDisabled`; it never deletes it.

To remove the helper: turn **Sentinel** off under *Allow in the Background* in System Settings, then delete the app.

### Known limitation

The app is signed **locally (ad-hoc)** and not with a paid Apple Developer ID. An ad-hoc identifier can be imitated by anyone who can run code as you, so the caller check protects against accidents and casual abuse, not against a determined attacker who already controls your account. On a shared or high-security machine, do not enable the helper; Sentinel then falls back to the standard administrator prompt. A Developer ID build with a team-identifier requirement is on the [roadmap](ROADMAP.md).

## Threat Watch is not antivirus

Threat Watch looks for known patterns (miner names and pool arguments, deleted executables, unsigned heavy programs in temporary folders, launch items that download and run code). It does **not** inspect files, block network traffic or catch every threat. Use it as an extra lookout, not as your only protection.

## Supported versions

Only the latest commit on `main` receives fixes.
