# Security policy

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/trsdn/OpenConnct/security/advisories/new).
**Do not open a public issue.**

Please include the macOS version, the hardware architecture, the OpenConnct
version (`Contents/Info.plist` → `CFBundleShortVersionString`), and the smallest
reproduction you can manage. You should get an acknowledgement within seven days
and an assessment within thirty.

## What is in scope

OpenConnct has a much larger blast radius than an ordinary desktop app, because
part of it does not run in the app at all.

| Component | Runs in | Privilege |
|---|---|---|
| `OpenConnct.driver` (HAL plug-in) | **`coreaudiod`**, a system daemon | Loaded from a root-owned directory; a crash here takes down *all* audio on the machine |
| `Contents/Resources/install-driver.sh` | A one-shot `osascript` prompt, run by `/bin/bash` | **Root**, for the duration of one copy |
| `OpenConnct.app` | The logged-in user | Hardened runtime, microphone entitlement only |

The following are in scope and taken seriously:

- Anything that makes the plug-in crash, hang, or corrupt memory inside
  `coreaudiod`, including malformed property requests and IO cycles.
- Anything that lets an unprivileged process influence what the plug-in
  publishes or what it writes into the shared ring buffer.
- A path that escalates privilege during driver installation or uninstallation
  — for example a writable intermediate directory, a symlink that is followed,
  or an unquoted path in a script that runs as root.
- Loss of audio isolation: a way for a third-party application to read what is
  on the input ring buffer without being able to open the device.
- Signature or entitlement weaknesses that would let a substituted bundle
  inherit the microphone grant.

## What is out of scope

- The fact that "OpenConnct Mic" is a system-wide input device that any
  application may open. That is the entire purpose of the software; macOS
  microphone privacy controls apply to the *consuming* application.
- Requiring an administrator password to install into
  `/Library/Audio/Plug-Ins/HAL`. That directory is root-owned by design.
- Denial of service that requires an administrator to have already installed a
  modified plug-in.
- Reports produced by an automated scanner with no demonstrated impact.

## Design decisions that exist for security reasons

Please do not "fix" these without reading the reasoning first.

- **The plug-in is a dumb loopback.** All DSP lives in the app. The resident
  code in `coreaudiod` is one dependency-free C file with a lock-free ring
  buffer: no allocation, no locks, no logging, no Objective-C or Swift runtime.
  This is deliberate and is the single largest reliability and safety lever in
  the project.
- **There is no IPC on the audio path.** No XPC service, no Mach service, no
  privileged helper daemon, no `AudioServerPlugIn_MachServices` entry. The app
  writes to a hidden output device using ordinary CoreAudio. Every one of those
  mechanisms would be new attack surface for a problem the architecture already
  removed.
- **The sink device is hidden.** It cannot be selected as a system output, which
  structurally prevents a feedback loop rather than warning about one.
- **The app is signed with a Developer ID and uses the hardened runtime**, with
  exactly one entitlement (`com.apple.security.device.audio-input`). Ad-hoc
  signing is not supported, because it would require disabling System Integrity
  Protection.

### The in-app driver installer

The app can install its own driver, which means it can run code as root. That is
the most sensitive thing it does, so the reasoning is set out here in full.

- **A one-shot prompt, not a privileged helper.** The Apple-sanctioned route for
  privileged work is `SMAppService` with a helper daemon and XPC. That is right
  for an app that needs privilege repeatedly or unattended. This one needs it
  twice in its life, always with the user watching. A permanent root daemon that
  exists to be asked to write into a system directory is a worse trade than a
  prompt that leaves nothing behind.
  (`AuthorizationExecuteWithPrivileges` is not an option — deprecated since 10.7
  and absent on Apple silicon.)
- **The privileged script takes no arguments.** Everything it touches is derived
  from its own location inside the bundle, or is a hard-coded constant. A
  privileged script that accepts a path is one that can be asked to install
  something else.
- **The script's path never enters the AppleScript source text.** It is passed
  through the environment and read back with `system attribute`, so there is no
  string to escape and nothing to inject into. The value is shell-quoted,
  because it still lands in a shell.
- **The script is not marked executable, and the interpreter is named.** The copy
  inside the bundle is mode `644`, and the app runs it as `/bin/bash <path>`.
  A shell script in a bundle is a sealed resource, not signed code, so an
  executable bit on it buys nothing and costs something: every downstream check
  — notarisation preflight included — has to account for an executable file that
  is not a declared Mach-O. Naming the interpreter also means it is not read from
  a shebang line in a file on disk.
- **The app validates its own signature, sealed resources included, before
  prompting.** This is load-bearing rather than decorative: macOS checks the main
  executable at launch, but altering a *resource* does not stop an already-trusted
  app from starting, so without this check a rewritten installer script would
  simply run as root on the next click. Verified with `SecStaticCodeCheckValidity`
  rather than by shelling out to `codesign`, which could be shadowed on `PATH`.
- **That check narrows the exposure; it does not eliminate it.** The app verifies
  the bundle and then hands `osascript` a *path*, which root opens afresh.
  Anything able to rewrite the script in between chooses what root runs, and the
  check cannot be moved to the privileged side — a swapped script would omit it.
  **Run the app from `/Applications`.** There it takes an administrator to modify,
  and an administrator is already on the other side of the prompt. Run from
  `~/Downloads` or removable media, code running as the ordinary user only has to
  win a race. We would rather state this plainly than claim the check closes it.
- **Root re-checks the driver before copying it**, with `codesign --verify
  --strict`, and requires that the driver's team identifier matches the app's.
  Validation performed by the unprivileged side proves nothing about what the
  privileged side then does.
- **The replacement is staged, not done in place.** The new copy is assembled and
  verified beside the existing driver, and only a rename swaps them. The obvious
  ordering — delete, then copy — turns any failure in the copy into a machine
  with no audio driver at all, which is worse than the state the user started in.
- **The privileged script pins its own `PATH`** rather than trusting the caller's,
  since it uses `codesign` to decide what is safe to install.

## Supported versions

The most recent release on `main` is supported. There are no maintained release
branches.
