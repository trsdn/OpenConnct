# Agent instructions

Read this before changing anything in this repository.

## What this repository is

OpenConnct is a native macOS app that runs several USB microphones as one
system-wide input: independent channel strips, a software mixer, a per-channel
DSP chain (gate, compressor, EQ), and a CoreAudio virtual device (an
AudioServerPlugIn / HAL driver) that other apps (Teams, Zoom, OBS, System
Settings) select as their microphone. A large part of the value is the
drift-correction loop that keeps independently-clocked USB devices in sync —
get that wrong and the output clicks or drops out. The driver runs inside
`coreaudiod`, a system process, so a bad driver build can affect audio
system-wide until it's uninstalled or the machine restarts.

## What this repository is not

Not a recorder, soundboard, podcast/multitrack tool, or headphone monitor. It
is the mixing and processing stage only, sitting between USB microphones and
whatever app consumes the resulting virtual device.

## Layout

| Path | Purpose |
|---|---|
| `Core/` | Swift package: DSP core (C ABI, tested via `swift test`), engine, drift correction |
| `App/OpenConnctApp/` | The SwiftUI macOS app (mixer UI, persistence, update manager) |
| `App/OpenConnctDriver/` | The CoreAudio AudioServerPlugIn (HAL virtual device) |
| `Update/` | SwiftPM wrapper around the `AppUpdater` dependency for in-app updates |
| `scripts/` | Build, packaging, signing, notarization, install/uninstall shell scripts |
| `tools/` | Standalone diagnostic binaries (bench, probe, driver harness) — not shipped |
| `docs/` | Verification runbooks and design docs |
| `integrations/opendeck/` | The OpenDeck / Stream Deck plugin (plain Node, no dependencies). `npm test` there runs its four suites; `./install.sh` copies it into the deck apps |
| `site/` | The GitHub Pages landing page: static HTML/CSS, no scripts, no third-party requests. `scripts/build_site.sh` fills in the build date; `.github/workflows/pages.yml` deploys it |
| `.github/workflows/` | CI (build, test, naming guard) and the Pages deploy. There is no release workflow: releases come only from the notarization broker (see `README.md`, "Releasing") |

Generated, never hand-edit:
- `dist/` — build output, recreated by `make build`/`make driver`
- `_site/` — the built landing page, recreated by `scripts/build_site.sh`
- `Core/.build/`, `Update/.build/`, `tools/*/build/` — SwiftPM/clang build caches, removed by `make clean`

## For the Apple HIG reviewer

Windowed app, one `WindowGroup` plus a `Settings` scene (`App/OpenConnctApp/App/OpenConnctApp.swift`);
not a menu-bar app (`LSUIElement` is not set). User data it handles: microphone audio
(processed in memory, never written to disk or sent anywhere), and, only when the
local API is switched on, a bearer token file and loopback HTTP requests (see
`README.md`, "Local API"). There is no screen-rendering command; review from source
and say so.

## Setup

```sh
xcode-select --install   # Xcode command-line tools, once per machine
```

Swift 6 toolchain is required for `make test`. `make build` resolves the
`Update/` package's `AppUpdater` dependency via SwiftPM on first run, which
needs network access; subsequent runs are cached.

## Run

```sh
make run     # builds (native arch) and launches OpenConnct.app
```

Installing the driver for real (`make install-driver`) needs `sudo` and
restarts `coreaudiod` — see "Do not do these" below.

## Validate before proposing a change

This is the single command that must succeed:

```sh
make test-all
```

It runs `make test` (DSP core unit tests, `Core/Tests/OpenConnctDSPTests`, via
`swift test`) followed by `make test-driver` (the offline driver harness:
property dispatch and IO round trip through the real AudioServerPlugIn vtable
via `dlopen`, no install needed). Verified 2026-09-17: 185 + 384 assertions,
0 failures, from this checkout.

`make test-driver` is the only automated check of driver *behavior* — installing
it for real needs `sudo` and a `coreaudiod` restart, which no CI or agent
sandbox should do (see "Do not do these"). If you touched `integrations/opendeck/`, run `npm test` there. If you touched the app or driver
target rather than `Core/`, also run `make build UNIVERSAL=1` — this compiles
both architectures and is what would first catch a break `test-all` alone
cannot, matching what `.github/workflows/ci.yml` does for the `build` job.

## Conventions

- The DSP core (`Core/Sources/OpenConnctDSP`) is C-ABI and tested independently
  of the Swift app layer; keep new DSP logic there, not inlined in the app or
  driver targets.
- Anything that still says "OpenConnect" (no `t`) is intentional legacy
  handling for installs that predate the current name: the old driver and the
  old Application Support directory, in `AppSupport.swift` and the driver
  install/uninstall scripts. Do not "fix" these to say "OpenConnct"; that would
  break upgrades for existing installs. The CI naming guard lists the files
  where this is allowed.

## Do not do these

- Do not rewrite history, force push, or delete branches.
- Do not commit secrets, tokens, credentials, or personal data. Signing and
  notarization credentials never enter this repository; the notarization
  broker holds them (see `README.md`, "Releasing").
- Do not deploy, publish a release, create or move tags, or change repository
  settings (topics, branch protection, security settings, Pages) without being
  asked. Releases are cut only through the notarization broker.
- Do not run `make install-driver` / `make uninstall-driver` or any script
  under `scripts/` that calls `sudo` unless explicitly asked to test on real
  hardware — they install a HAL plug-in into a running `coreaudiod` and can
  affect the system's audio outside this repository.
- Do not hand-edit `dist/`, `Core/.build/`, `Update/.build/`, or `tools/*/build/`
  — regenerate them with `make build` / `make clean` instead.
- Do not add SwiftPM dependencies without discussing it first; the driver and
  DSP core are deliberately dependency-free C ABI for signing/entitlement
  reasons.

## Attribution

Agent-authored changes are identified by the `Co-Authored-By` / session
trailers their tool adds to commit messages, and are reviewed the same as any
other change before merging to `main`.
