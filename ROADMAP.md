# Roadmap

Ideas for making Sentinel better. Each item links to an issue where you can discuss it or claim it. Order is a rough priority, not a promise.

## Next

- **Signed and notarized releases.** Developer ID signing, notarization, a downloadable `.dmg` and a Homebrew cask. Also lets the helper verify its caller with a team identifier.
- **Arabic and English with right-to-left layout.** Move strings to a localization table and mirror the layout.
- **Accessibility.** Labels on every icon-only button, Reduce Motion support, full keyboard navigation (`⌘1…5` for tabs).
- **Scheduled automatic cleaning.** Rules such as "clean caches older than 3 months every Sunday", with a notification and History entry.

## Later

- **Network-level blocking** for suspicious programs (a Network Extension or `pf` rules), so Threat Watch can cut a miner's connection and not only stop the process.
- **Similar photos.** Perceptual hashing to find near-duplicate images, not just identical files.
- **Right-click menu on the menu-bar icon** with Quick Clean, Empty Trash and Quit.
- **Per-app history.** See how much memory and CPU an app used over the last days.
- **More detection rules** for Threat Watch, with a shared, reviewable list of known miner names and pools.
- **Universal build in CI** (Apple Silicon and Intel) with downloadable artifacts.

## Ideas welcome

Open an issue with the *Feature request* template. Small, well-explained ideas that fit the "safe by default" principle are the easiest to accept. See [CONTRIBUTING.md](CONTRIBUTING.md).
