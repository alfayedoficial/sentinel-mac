# Roadmap

Ideas for making Sentinel better. Each item links to an issue where you can discuss it or claim it. Order is a rough priority, not a promise.

## Done recently

- Automatic updates from GitHub Releases (1.1.0).
- Similar Photos and Similar Files (1.1.0).

## Next

- **Signed and notarized releases** ([#1](https://github.com/alfayedoficial/sentinel-mac/issues/1)). Developer ID signing, notarization, a downloadable `.dmg` and a Homebrew cask. Also lets the helper verify its caller with a team identifier.
- **Arabic and English with right-to-left layout** ([#2](https://github.com/alfayedoficial/sentinel-mac/issues/2)). Move strings to a localization table and mirror the layout.
- **Accessibility** ([#3](https://github.com/alfayedoficial/sentinel-mac/issues/3)). Labels on every icon-only button, Reduce Motion support, full keyboard navigation (`⌘1…5` for tabs).
- **Scheduled automatic cleaning** ([#4](https://github.com/alfayedoficial/sentinel-mac/issues/4)). Rules such as "clean caches older than 3 months every Sunday", with a notification and History entry.

## Later

- **Network-level blocking** ([#5](https://github.com/alfayedoficial/sentinel-mac/issues/5)) for suspicious programs (a Network Extension or `pf` rules), so Threat Watch can cut a miner's connection and not only stop the process.
- **Right-click menu on the menu-bar icon** ([#7](https://github.com/alfayedoficial/sentinel-mac/issues/7)) with Quick Clean, Empty Trash and Quit.
- **Similar videos and Live Photos**, using the same hashing idea on key frames.
- **Update safety upgrades.** Pin a Developer ID team identifier for updates, add a *Restore previous version* button, and show update progress.
- **Per-app history.** See how much memory and CPU an app used over the last days.
- **More detection rules** ([#8](https://github.com/alfayedoficial/sentinel-mac/issues/8)) for Threat Watch, with a shared, reviewable list of known miner names and pools.
- **Universal build in CI** (Apple Silicon and Intel) with downloadable artifacts.

## Ideas welcome

Open an issue with the *Feature request* template. Small, well-explained ideas that fit the "safe by default" principle are the easiest to accept. See [CONTRIBUTING.md](CONTRIBUTING.md).
