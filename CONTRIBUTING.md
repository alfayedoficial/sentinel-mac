# Contributing to Sentinel

Thank you for helping! Sentinel is a small, friendly project and every kind of contribution is welcome: bug reports, ideas, documentation, translations, tests and code.

## Ways to help

- **Report a bug** or a false alarm: open an [issue](https://github.com/alfayedoficial/sentinel-mac/issues/new/choose).
- **Suggest a feature:** open an issue with the *Feature request* template, or comment on an existing one in the [roadmap](ROADMAP.md).
- **Pick up an issue:** look for [`good first issue`](https://github.com/alfayedoficial/sentinel-mac/labels/good%20first%20issue) and [`help wanted`](https://github.com/alfayedoficial/sentinel-mac/labels/help%20wanted).
- **Improve the docs:** typos, clearer steps, better screenshots.

## Set up

```bash
git clone https://github.com/<your-username>/sentinel-mac.git   # your fork
cd sentinel-mac
swift test
./build.sh
```

The full guide, including the code layout and how to add a tool or a detection rule, is in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Pull request checklist

- [ ] The change is focused: one idea per pull request.
- [ ] `swift test` passes, and new behavior has tests (and a test for what it must **not** flag).
- [ ] Anything that deletes or changes files shows a list and asks first, and moves items to the Trash through `Trasher`.
- [ ] No work on the main thread that touches the file system, processes or the network.
- [ ] Colors come from `Theme`; no hard-coded values.
- [ ] If the UI changed, the screenshots in `docs/images` were regenerated.
- [ ] `CHANGELOG.md` has a line under *Unreleased*.

## Style

- Swift 5.9, 4-space indentation, `// MARK:` sections, short focused types.
- Match the surrounding code. Comments explain *why*, not *what*.
- Prefer pure functions for decisions so they can be unit-tested.
- User-facing text: plain, short, no jargon, and say what will happen.

## Safety first

Sentinel touches people's files and kills processes. Please be conservative:

- A detection rule that can alarm users needs a false-alarm test.
- Never add a network call, analytics or auto-update without a discussion first.
- Anything involving the privileged helper needs extra care. Read [SECURITY.md](SECURITY.md) and keep `HelperPolicy` strict.

## Questions

Open a [discussion or issue](https://github.com/alfayedoficial/sentinel-mac/issues). By contributing you agree that your work is released under the [MIT license](LICENSE) and that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
