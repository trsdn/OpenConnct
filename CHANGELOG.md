# Changelog

All notable changes to OpenConnct. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Release notes are taken
from the entry for the version being released.

## [Unreleased]

### Changed

- **Control from other apps** moved out of the diagnostics panel into a proper
  Settings window (**OpenConnct ▸ Settings…**, ⌘,), where a setting can be found.

## [0.3.0] - 2026-09-19

### Added

- **Control from other apps.** OpenConnct can now be muted, have its gain set and
  be read from a script or a Stream Deck over a small local web API. It is off
  until you switch on **Control from other apps** in *Technical details*, listens
  on this Mac only, and every request needs a secret key that only your user
  account can read. See the README, "Controlling it from other apps".
- **OpenDeck and Stream Deck plugin** (`integrations/opendeck`). Keys mute a
  microphone and step its gain, and turn red while a microphone is muted or
  silenced by another channel's solo, including when that was done in the app.
- **In-app updates.** OpenConnct checks GitHub once a day for a newer version and
  offers **Install and Restart**; nothing installs without that click.
- **A gain that finds itself.** Say a sentence and OpenConnct proposes a gain from
  your measured voice instead of asking you to guess.
- **The noise gate sets its threshold from your room.**
- **New devices arrive muted**, so a headset that connects itself never joins a
  call unannounced. The strip says why it is muted.
- **The switches on a microphone's own body** (pad, high-pass filter) are read
  where the microphone allows it, so the same filter is not applied twice.
  OpenConnct never asks for the permission this needs.
- The controls now show whether they run on the microphone or in the app, and gain
  is taken from the microphone's own stage where one exists.
- A project website: https://trsdn.github.io/OpenConnct/

### Changed

- Mute and solo are a speaker and headphones instead of the letters M and S.
- The level meter shows one quantity instead of three, and channel strips show the
  part of a name that identifies the microphone.
- A muted channel is now not processed at all, and the window says so.
- The gate, compressor and bass stage no longer compute a logarithm per sample,
  which lowers CPU use.

### Fixed

- The wide level meters no longer trust what they drew last time, which left stale
  marks, and no longer draw a hold mark when there is nothing to hold.
- The meter's target band is drawn in a neutral colour rather than the level colour.
