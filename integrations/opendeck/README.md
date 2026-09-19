# OpenConnct for OpenDeck and Stream Deck

A plugin for [OpenDeck](https://github.com/nekename/OpenDeck) and the Elgato
Stream Deck, so hardware keys can mute OpenConnct microphones and set their gain
in the middle of a call, without finding the window.

Keys also show what OpenConnct is actually doing. A key turns red while its
microphone is muted, including when it was muted in the app window or from a
script. That is the part a plugin cannot fake: it asks OpenConnct once a second
rather than remembering what it last sent.

It is a sibling of the OpenLens plugin and built the same way: one folder for
both apps, no dependencies, no build step, its own tiny WebSocket client so it
runs on whatever Node the deck app provides.

## Install

1. In OpenConnct, open **OpenConnct ▸ Settings…** (⌘,) and switch on
   **Control from other apps**. The plugin cannot see the app until you do.
2. Run

   ```bash
   ./install.sh
   ```

   It copies the plugin into whichever deck apps are installed:

   - `~/Library/Application Support/opendeck/plugins/`
   - `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`

3. Restart the deck app. The **OpenConnct** category appears in its action list.

Re-run `./install.sh` after any change: both apps read the copy, not the
repository. It is a copy rather than a symlink because OpenDeck does not follow
a symlink out of its plugins directory and fails at it silently.

## Actions

| Action | What a press does | What the key shows |
| --- | --- | --- |
| **Toggle mute** | Mutes or unmutes one microphone | Its name. White while live, red while muted, grey while unplugged |
| **Gain** | Changes one microphone's gain by a fixed step (±1, ±3 or ±6 dB) | The current gain, for example `+3 dB` |

Pick the microphone in the key's settings. The list is filled in live, so you
choose by name. Put one Gain key on **+** and another on **−**.

A key is bound to a microphone by **name**, never by position: the mixer's order
changes when a microphone is plugged in or removed, and a key that quietly moved
to another microphone would mute the wrong one. A key bound to nothing means "the
only microphone" and nothing else; with two or more it refuses and flashes the
alert marker instead of guessing.

A microphone that another channel's **solo** has silenced shows red as well: it is
not muted, but nobody can hear it, and a key saying "live" over a silent
microphone is the worst thing a mute key could say.

## When OpenConnct is not reachable

Keys show `—` in grey and a press flashes the alert marker. The plugin looks
again every second and reads the port and key from the files OpenConnct writes
(`api-port` and `api-token` in `~/Library/Application Support/OpenConnct/`) each
time, so starting the app later, or restarting it onto a different port, brings
the keys back without touching the deck app.

The API is only ever reachable from this Mac (`127.0.0.1`) and every request
carries the key. The key file is readable by your user account only.

## Tests

```bash
npm test
```

Four suites, all offline, with neither deck app nor OpenConnct installed:

- **manifest**: every file it names exists, and it obeys the rules Elgato
  enforces and OpenDeck does not care about.
- **deck-socket**: the WebSocket client against a stand-in server.
- **logic**: which microphone a key means, what it shows, what a press asks for.
- **smoke**: the plugin itself between a stand-in for a deck and a stand-in for
  OpenConnct, including a change made in the app repainting a key, the mixer
  reordering between a poll and a press, the app disappearing and coming back on
  another port, and a refused request.

The smoke test runs a *copy* of the plugin folder with
`--no-experimental-websocket --no-experimental-detect-module`, so it sees what
Stream Deck's older Node would: no global WebSocket, no module detection.

`deck-socket.js` and its test are copied from the OpenLens plugin, where they
were written; keep them in step if the protocol handling ever changes.

## What has not been tested

The Elgato app is not installed on the machine this was written on, and no
physical deck was attached while it was built. The plugin was run against a
stand-in deck and against the real OpenConnct API server, not against a real
Stream Deck.
