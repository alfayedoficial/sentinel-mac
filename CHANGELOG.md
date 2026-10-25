# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

## [1.1.1] - 2026-10-25

### Changed
- **Settings → Updates** now always has a **Check for updates** button (it used to disappear while an update was available), shows when it last checked, and has a separate **Update to x.y.z** button.

## [1.1.0] - 2026-10-25

### Added
- **Automatic updates** from GitHub Releases: a daily check, an **Update** banner with release notes, a verified download (HTTPS from GitHub only, SHA-256 checksum, code-signature and identity check, newer-version check), a safe swap that keeps the previous version, and a restart. Can be switched off in Settings. `--install-update` does it from a script.
- **Similar Photos**: perceptual hashing finds resized, re-saved or lightly edited copies, marks the sharpest as *Best*, with Very close / Similar / Loose sensitivity.
- **Similar Files**: finds copies and old versions by name (`Report (1).pdf`, `Budget-v2.xlsx`), with nothing pre-selected.
- Direct download of a universal `Sentinel.zip` from the releases page, and `scripts/package.sh` to build it.
- 30+ new tests (100+ in total), including real signed and tampered look-alike apps for the update checks.

### Changed
- The app now makes one network request: the optional update check. The documentation, website and security policy say so.
- The privileged helper only registers itself when Sentinel runs from an Applications folder, so a copy in `/tmp` or a build folder never adds a background item.

### Fixed
- Threat Watch no longer flags Apple's update services, which macOS runs from a temporary staging folder.
- A shell whose command line only mentions miner words is no longer reported unless it is also using heavy CPU.
- Website: install cards no longer overflow and code blocks no longer hide under the Copy button.

## [1.0.0] - 2026-10-25

First public release.

### Added
- Live monitor for memory, battery and disk, with an animated menu-bar icon.
- Idle app detection with an animated popup, reasons, and one-click quit.
- Cache cleaner with 1-week to 1-year ranges, a report and a confirmation step.
- Smart Care: one scan across caches, Trash, big files, startup items and idle apps.
- Uninstaller that removes an app together with its caches, preferences and containers.
- Big old files finder, duplicate finder (SHA-256) and Space Lens.
- Startup Manager that flags broken and suspicious launch items.
- Threat Watch for crypto miners and hidden background programs.
- Maintenance tasks and a History log with Restore.
- Optional weekly reminder and open-at-login.
- Privileged helper (optional) so system launch items can be switched off without repeated password prompts.
- Dark and light appearance, About screen, app icon.
- 72 unit tests, project documentation and website.
