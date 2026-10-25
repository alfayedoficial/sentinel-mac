# Development guide

## Get the code

```bash
git clone https://github.com/alfayedoficial/sentinel-mac.git
cd sentinel-mac
```

Requirements: macOS 14+, Xcode 15+ or a Swift 5.9+ toolchain. No other dependencies.

## Build, run, test

```bash
swift build                 # debug build
swift test                  # run all unit tests
./build.sh                  # release build, local signing, installs ~/Applications/Sentinel.app
open ~/Applications/Sentinel.app
```

You can open the package in Xcode (`xed .`) and run the `Sentinel` scheme. When running from Xcode the privileged helper is not registered, so system launch items use the normal administrator prompt.

Useful while developing:

```bash
swift test --filter ThreatRulesTests          # one test class
swift test --filter testRestoreMovesTheFileBack
log stream --predicate 'process == "Sentinel"' # live logs
```

## Make a change (the workflow)

1. **Fork** the repository and create a branch: `git checkout -b feature/short-name`.
2. Make a focused change. Add or update **tests** in `Tests/SentinelTests`.
3. Run `swift test` and `./build.sh`; try the feature in the real app.
4. If the UI changed, [regenerate the screenshots](#regenerating-the-screenshots).
5. Commit with a clear message (see below) and push your branch.
6. Open a **pull request** and describe what changed and why. The template will guide you.

### Commit messages

Use the imperative mood and explain the *why*:

```
Fix history losing items when many are cleaned at once

Records were appended to the published copy of the list, which updates
asynchronously, so rapid writes overwrote each other. Keep a locked
source-of-truth array and publish a copy.
```

## How to add a new tool

Tools are the cards in the **Tools** tab. Adding one touches four places.

1. **Engine** (`Sources/Sentinel/`): create an `ObservableObject` that does the work on a background task and publishes results. Take folders as parameters so it can be tested.
2. **Register it** in `Features.swift`:
   - add a case to `ToolKind` and fill in `title`, `blurb`, `icon` and `style`;
   - add the object to `Hub` if it must keep its state between opens.
3. **Screen**: create a SwiftUI view and add it to the `switch` in `ToolsTab` (`ToolsViews.swift`). Use `Theme` colors, `Card`, `ConfirmCard` and the existing row styles.
4. **Tests**: add a test file. Use `Sandbox` from `TestSupport.swift` for temporary files.

Rules for anything that deletes or changes things:

- Show a list and require a confirmation (`ConfirmCard`).
- Move to the Trash through `Trasher.trash(_:size:kind:)` so it is logged and restorable.
- Never block the main thread.

## How to add a detection rule

Detection logic is pure and lives in two places:

- **Idle apps:** `FlagRules.reasons(for:memoryPressure:battery:)` in `Rules.swift`.
- **Threats:** `ThreatRules.evaluate(_:)` and `ThreatRules.suspiciousLaunchItem(...)` in `ThreatWatch.swift`.

Add the rule, then add tests for **both** directions: the thing it should catch **and** a similar harmless thing it must leave alone. False alarms erode trust, so a new rule needs at least one negative test (see `testAnIdleShellMentioningMinerWordsIsNotFlagged`).

## Changing the look

All colors, radii and gradients come from `Theme.swift`. Do not hard-code colors in views. See [DESIGN.md](DESIGN.md) for the palette and principles.

## Regenerating the screenshots

```bash
swift build -c release
.build/release/Sentinel --snapshot docs/images
```

The app fills itself with sample data (`Demo.swift`), writes one PNG per screen in dark and light mode, and quits. Review the images before committing. If you add a screen, add it to the list in `Snapshot.swift`.

## Project website

The website is a static page in `docs/index.html`, published with GitHub Pages from the `docs` folder of the `main` branch. Edit the HTML and CSS directly; no build step is needed.

## Releasing

Automatic updates read your GitHub Releases, so a release must follow a few rules or installed apps will ignore or refuse it.

1. **Bump the version** in `Info.plist` (`CFBundleShortVersionString`, and `CFBundleVersion` by one). The tag must match: `v1.2.0` for `1.2.0`. Update `CHANGELOG.md`.
2. Run `swift test`.
3. Build the universal download and its checksum:
   ```bash
   ./scripts/package.sh        # creates build/Sentinel.zip and build/Sentinel.zip.sha256
   ```
4. Publish. The asset names **must be exactly** `Sentinel.zip` and `Sentinel.zip.sha256`; the updater and the website link depend on them:
   ```bash
   git tag -a v1.2.0 -m "Sentinel 1.2.0" && git push --tags
   gh release create v1.2.0 build/Sentinel.zip build/Sentinel.zip.sha256 --title "Sentinel 1.2.0" --notes-file notes.md
   ```
   The release notes are shown to users under **What's new**. Do not mark it as a draft or prerelease: those are ignored.
5. Put the SHA-256 in the release notes.

### Testing the update path

- Unit tests (`UpdaterTests.swift`) cover version comparison, release parsing, the checksum, signed, unsigned and tampered look-alike apps, and the swap with roll-back.
- Against the real release: `SENTINEL_NETWORK_TESTS=1 swift test --filter testRealLatestRelease`.
- End to end: build a copy with a lower version in `Info.plist` into a temporary folder and run `Sentinel.app/Contents/MacOS/Sentinel --install-update`. It checks GitHub, installs the newer release over itself and restarts. Copies outside an Applications folder never register the background helper.

Signed and notarized downloads are on the [roadmap](../ROADMAP.md); today the app is signed locally.

## Troubleshooting

| Problem | Fix |
|---|---|
| `swift build` cannot find a module | Make sure Xcode command line tools are selected: `xcode-select -p`. |
| The helper never asks for approval | Open System Settings → Login Items & Extensions and allow **Sentinel** under *Allow in the Background*. |
| macOS says the app is from an unidentified developer | Right-click the app → **Open**, or build it yourself with `./build.sh`, which avoids the download quarantine. |
| Screenshots come out blank | Run the command from a normal logged-in session, not over SSH. |
