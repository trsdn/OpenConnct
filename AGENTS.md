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
| `.github/workflows/` | CI (build + test) and release (signed DMG/PKG + notarization) |

Generated, never hand-edit:
- `dist/` — build output, recreated by `make build`/`make driver`
- `Core/.build/`, `Update/.build/`, `tools/*/build/` — SwiftPM/clang build caches, removed by `make clean`

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

```sh
make test           # DSP core unit tests (Core/Tests/OpenConnctDSPTests), via swift test
make test-driver     # offline driver harness: property dispatch and IO round trip via dlopen, no install needed
make build UNIVERSAL=1   # confirms the app and driver actually compile universal, matching CI
```

These three together are what `.github/workflows/ci.yml` runs. `make test`
catches DSP regressions; `make test-driver` is the only automated check of
driver *behavior* since installing it for real needs `sudo` and a `coreaudiod`
restart, which CI cannot do; the build step catches compile breaks the Core
package alone wouldn't.

## Conventions

- The DSP core (`Core/Sources/OpenConnctDSP`) is C-ABI and tested independently
  of the Swift app layer; keep new DSP logic there, not inlined in the app or
  driver targets.
- Anything that touches the old project name ("OpenConnect", no `t`) is
  intentional legacy/migration handling (old driver name, old Application
  Support directory, upgrade docs) — see `README.md`'s "Upgrading from
  OpenConnect" section. Do not "fix" these to say "OpenConnct"; that would
  break migration for existing installs.

## Do not do these

- Do not rewrite history, force push, or delete branches.
- Do not commit secrets, tokens, credentials, or personal data. Signing/
  notarization secrets live only in GitHub Actions secrets, consumed by
  `.github/workflows/release.yml`.
- Do not deploy, publish a release, create or move tags, or change repository
  settings (topics, branch protection, security settings) without being asked.
  Releases are cut by pushing a `v*` tag or running `release.yml` manually.
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
