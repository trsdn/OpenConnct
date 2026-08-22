# Contributing

Thanks for your interest. Part of this project runs inside `coreaudiod`, a
system daemon, so a defect there breaks audio for the whole machine rather than
just this app. Changes are reviewed with that in mind.

## Before you start

- Open an issue first for anything that changes the DSP, the audio engine, or
  the HAL plug-in. Documentation fixes can go straight to a pull request.
- Do **not** report vulnerabilities in a public issue. Follow
  [SECURITY.md](SECURITY.md#reporting-a-vulnerability).
- Read the "Design decisions that exist for security reasons" section of
  [SECURITY.md](SECURITY.md) before proposing a new IPC mechanism or moving
  processing into the plug-in. Both have already been considered and rejected
  for stated reasons.

## Local validation

From the repository root:

```bash
make test          # DSP primitives, offline, against known signals
make test-driver   # plug-in property dispatch and ring buffer, no sudo needed
make build         # universal app, signed if a Developer ID is present
```

`make test-driver` `dlopen`s the plug-in and exercises its vtable in-process, so
driver behaviour is regression-tested without installing anything. CI runs the
same targets.

The `Makefile` globs its sources, so a new Swift or C++ file needs no project
registration.

## Rules that are not style preferences

**Realtime safety.** Nothing reachable from an audio callback may allocate, take
a lock, log, call into the Objective-C or Swift runtime, or do unbounded work.
Pre-allocate in the setup path. Communicate with the UI through lock-free SPSC
queues and atomics only. `Core/Tests` contains an allocation detector that will
catch a regression, but the reviewer will catch it first.

**DSP primitives stay dependency-free.** Everything in
`Core/Sources/OpenConnctDSP` is plain C++17 plus Accelerate, testable offline
with no audio hardware. If a change cannot be asserted against a generated
signal, it probably belongs in the app rather than the core.

**Persisted settings need a hand-written decoder.** `ChannelSettings` must never
fall back to synthesised `Codable`. The whole settings file is decoded in one
`try?`, so a single unknown or missing key would silently discard *every*
microphone's settings, not just one. Add a coding key and a default for each new
field.

**Talking to a microphone is slow, and never happens on a UI or audio thread.**
Setting a device's own gain was measured at a median of 46 ms on one device and
up to **1007 ms** on another. `CoreAudioInputGain` therefore runs every read and
write on a dedicated serial queue and coalesces requests, keeping only the newest
target. Its threading is stated in a comment at the top of the file: the
capability tables belong to the main thread, the pending queue belongs to the
serial queue, and nothing is shared — the slow path captures the `AudioObjectID`
it needs by value rather than looking it up. Preserve that split.

**Gain compensation reads the device, never the request.** Because of that
latency, deriving the DSP half from what the device was *asked* for would leave
the level wrong for up to a second at a time. `HardwareGainSplitter.compensate`
takes the reported value for that reason, and it is also what makes an external
change to the gain inaudible. Do not "simplify" it to use the requested value.

**The level meters are AppKit on purpose.** A SwiftUI implementation measured
22 % of a CPU core; the AppKit one measures under 6 % and, unlike the SwiftUI
version, does not scale with window size. Read the header comment in
`MeterNSView.swift` before changing anything there.

## Measurements, not assertions

This project has repeatedly found that the instrument was wrong rather than the
system. If you claim a performance or audio-quality improvement, include the
numbers and say how they were produced — debug and release builds differ by
roughly an order of magnitude here, so state which one you measured.

Drift in particular is not observable in a short run: ring fill is quantised to
the hardware period, so at realistic crystal offsets a soak shorter than about
fifteen minutes measures nothing at all.

## Pull requests

1. Branch from `main`.
2. Keep the change focused; unrelated cleanups belong in their own pull request.
3. Add or update tests for any behaviour change in `Core/`.
4. Update `README.md` when behaviour, setup, or a measured figure changes.
5. Fill in the pull request template, including the realtime-safety section.
