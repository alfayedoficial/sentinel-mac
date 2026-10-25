# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- Nothing yet. Add your line here in your pull request.

### Fixed
- Threat Watch no longer flags Apple's update services, which macOS runs from a temporary staging folder.
- A shell whose command line only mentions miner words is no longer reported unless it is also using heavy CPU.

### Added
- Direct download of a universal `Sentinel.zip` from the releases page, and `scripts/package.sh` to build it.

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
