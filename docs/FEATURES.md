# Features in detail

This page explains what each feature does and **how it decides** what to show you.

## Live monitor (Overview)

- **Memory ring:** `app memory + wired + compressed` as a share of installed RAM, plus the system's memory-pressure level (Normal / Warning / Critical).
- **Battery ring:** charge, charging state and time remaining. Shows AC when there is no battery.
- **Disk ring:** free space on the startup volume.
- **Top memory users:** apps ranked by physical footprint, with helper processes (for example browser tabs) added to their parent app.

Sampling runs on a background queue every 3 seconds while the window is open and every 10 seconds when it is closed.

## Idle app detection (Apps tab and popup)

An app is flagged when it is **not the front app**, is **not keeping the Mac awake** (playing audio, downloading, on a call), and one of these is true:

| Rule | Default |
|---|---|
| No visible window, unused for a while, and still holding memory | idle ≥ 20 min and ≥ 300 MB |
| Using CPU in the background | ≥ 15 % averaged over about 30 s, with no window or idle ≥ 5 min |
| High energy use while on battery | ≥ 0.8 W and idle ≥ 5 min |
| The Mac is under memory pressure and the app is idle | idle ≥ 5 min and ≥ 150 MB |

All thresholds can be changed in **Settings**. The rules are a pure function in `Rules.swift` and are unit-tested.

You can **Quit**, **Force quit**, snooze for an hour, or **Never suggest this app**. Apps are asked to quit politely, so they can still save your work. A popup appears at most once every 30 minutes per app.

## Cache cleaner (Clean tab)

Scans these locations for items **whose newest file is older than the range you pick** (1 week to 1 year):

`~/Library/Caches`, `~/Library/Logs`, Xcode *DerivedData* and *iOS DeviceSupport*, `~/.cache`, `~/.npm`, `~/.gradle/caches`, `~/.pub-cache`.

- One recently used file protects the whole folder.
- Caches of apps that are currently running are shown but **not pre-selected**.
- `com.apple.*` caches are shown but not pre-selected.
- The report is grouped and sorted by size. You choose what to clean.
- Items move to the Trash (or are deleted permanently if you switch that on).

## Smart Care

Runs the cache scan (1 month), the big-file scan (500 MB, 3 months), the startup scan and reads the idle-app list. Shows the total that can be freed and a result row for each area with a **Review** button. **Clean junk** cleans only the safe, pre-selected caches after a confirmation.

## Uninstaller

Lists apps from `/Applications` and `~/Applications`. For the selected app it finds leftovers in `~/Library` (Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State, Logs, HTTPStorages, WebKit, LaunchAgents, Cookies) by **bundle identifier** and app name. You see every item before anything moves.

## Big old files

Files above a size you choose (100 MB to 1 GB) that were not modified for the range you choose, in Downloads, Desktop, Movies, Documents, Music and Pictures. `node_modules` is skipped.

## Duplicate finder

1. Groups files by size.
2. Compares a quick hash of the start and end.
3. Confirms with a full SHA-256 hash.

Only byte-identical files are reported. The oldest copy is kept by default; tap any file to choose which copy to keep. Symbolic links and `node_modules` are ignored.

## Similar Photos

Finds pictures that look the same even though the files are different: resized, saved in another format, re-compressed, or lightly edited.

1. Looks at photos (JPEG, PNG, HEIC, TIFF, GIF, BMP, WebP) in Pictures, Downloads, Desktop, Documents and Movies. Photo libraries, `node_modules`, icons (under 300 × 300 pixels) and tiny files are skipped. At most the 15,000 newest photos are examined.
2. Makes a 9 × 8 grayscale miniature of each and builds a 64-bit **difference hash** (is each pixel brighter than its right neighbour?).
3. Groups photos whose hashes differ in only a few bits.

| Setting | Allows | Good for |
|---|---|---|
| Very close (4 bits) | resized or re-saved copies | the safest choice |
| Similar (8 bits) | small edits, crops, other formats | everyday clean-up |
| Loose (12 bits) | burst shots and look-alikes | review carefully |

In each group the photo with the most pixels (then the biggest file) is marked **BEST** and kept. Tap any photo to keep that one instead; the others in the group go to the Trash. Photos are never read beyond a small thumbnail, and nothing leaves your Mac.

## Similar Files

Finds files that look like copies or versions of each other **by name**, without reading their contents. These names belong to the same family:

`Report.pdf` · `Report (1).pdf` · `Report copy.pdf` · `Report - Copy 2.pdf` · `Report-2.pdf` · `Report_final_v3.pdf`

The family key is the name in lower case with trailing copy and version markers removed, plus the extension. Each family shows size, folder and date, with the newest marked **NEWEST**. Because similar is not identical, **nothing is selected for you**; use *Select older versions* or tick files one by one. For byte-identical copies use the Duplicate finder.

## Space Lens

Sizes of the folders and files inside the current folder, shown as bars. Click a folder to go deeper, right-click for *Show in Finder* or *Move to Trash*.

## Startup Manager

Lists login items, user launch agents, system launch agents and system services (Apple's own are hidden). Each item shows whether it is running. Items are flagged:

- **Broken:** the program they start no longer exists (typical after removing an app).
- **Suspicious:** they start something from a temporary or hidden folder, or run a command that downloads and executes code.

*Turn off* stops the item and moves its file to the Trash (user items) or to `/Library/SentinelDisabled` (system items, through the helper).

## Threat Watch

Looks at **every process**, not just apps, every 10 seconds (5 while the window is open). A process is reported when:

| Finding | Risk |
|---|---|
| Name matches a known miner (xmrig, minerd, cpuminer, nicehash, …) | High |
| Its arguments contain mining-pool markers (`stratum+tcp://`, `--donate-level`, …) | High |
| A shell or scripting runtime (`sh`, `zsh`, `python`, `node`, …) has those markers or runs a script named like a miner **and** uses 25 % CPU or more | High |
| It runs from a file that was deleted | High |
| An unidentified program uses ≥ 70 % CPU for 30 s or more | Medium |
| An unsigned program uses CPU from `/tmp`, `/Users/Shared` or an unknown hidden folder | Medium |
| A launch item downloads and runs code (`curl … | sh`, `base64 -d`, …) | Medium |

A shell that only has miner words in its command line while idle (for example, you typing `grep xmrig`) is **not** flagged. Developer tools in trusted places (`/Applications`, Homebrew, `~/.gradle`, Java and Xcode folders) are not flagged for CPU alone. If you keep tools in another hidden folder, trust it with `defaults write com.afapps.sentinel threatKnownHidden -array .mytool`. You can **Stop now**, **Stop & move to Trash**, **Turn off** the launch item that restarts it, or **Always allow** a program. Allowed programs are listed so you can undo that.

The screen also lists the busiest background programs that are not part of an app, with their signature state.

## Maintenance

| Task | What it runs |
|---|---|
| Restart Dock / Finder | `killall Dock` / `killall Finder` |
| Fix "Open With" | rebuilds the Launch Services database for your user |
| Reset Quick Look | `qlmanage -r cache` |
| Clear font cache | `atsutil databases -removeUser` (effective after restart) |
| Flush DNS | `dscacheutil -flushcache` and `killall -HUP mDNSResponder` (asks for your password) |

## History & Restore

Every item moved to the Trash by Sentinel is logged (type, name, size, time, original and Trash location). **Restore** moves it back when it is still in the Trash and the original folder exists. It never overwrites an existing file.

## Automatic updates

Sentinel can update itself from your GitHub Releases:

1. About 8 seconds after launch, then once a day, it requests `https://api.github.com/repos/alfayedoficial/sentinel-mac/releases/latest`.
2. If the release is newer than the running version, the Overview shows **Sentinel x.y.z is available** with **What's new** (the release notes) and **Update**.
3. **Update** downloads `Sentinel.zip` and `Sentinel.zip.sha256` (only over HTTPS from GitHub's own hosts), then checks:
   - the SHA-256 of the zip equals the published checksum;
   - the unpacked app is Sentinel (`com.afapps.sentinel`), is **newer** than the running one, has a valid code signature and the same signing identity.
4. It moves the running app aside (kept in `~/Library/Application Support/Sentinel/previous`), puts the new one in its place and restarts. If anything fails the old app stays untouched.

Prereleases and drafts are ignored. If Sentinel is somewhere it cannot write, it tells you to download the update manually. The check can be switched off in **Settings → Check for updates automatically**.

## Settings

Popup alerts on/off, weekly reminder, automatic update check, open at login, the idle / memory / CPU thresholds, the ignored apps list, and About.
