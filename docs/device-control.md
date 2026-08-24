# Reaching a microphone's own controls

What this app can and cannot change *inside* a microphone, what was measured to
establish that, and what is still unknown. Written down because most of it was
found by experiment rather than from documentation, and an experiment nobody
recorded has to be repeated.

No vendor is named here. Devices are identified by their USB numbers, which is
what the code matches on anyway.

## Two separate routes into a device

A USB microphone of this kind enumerates as a composite device: several audio
interfaces, plus one more interface that has nothing to do with audio. Those are
separate services with separate drivers, and they can be used at the same time
by different processes without conflict.

| Route | What it is | What it reaches |
|---|---|---|
| USB Audio Class | Public, documented, class-compliant. Surfaces as ordinary CoreAudio device properties. | Input gain, mute, direct monitoring. |
| Vendor control channel | A HID interface on a vendor-defined usage page. Undocumented. | Everything else the device can do. |

### What the audio-class route gives, measured

Every device-level control published to CoreAudio was enumerated across all
scopes and elements on both microphones. The complete list is: **volume, mute,
direct monitoring.** Nothing else exists there.

That is why the app drives gain this way. It is public, it cannot brick
anything, and it works on any class-compliant microphone rather than one
vendor's. `CoreAudioInputGain` does exactly this.

It is also why the app's own high-pass and pad are marked as running in the app:
not because microphones lack such stages, but because they are **not reachable
by this route**. Several microphones have a filter and a pad switched by buttons
on the body, applied before the signal ever reaches the computer, reporting
nothing about it. A microphone cutting at 75 Hz feeding an app also cutting at
75 Hz gives a thin voice and no clue why — which is what
`ChannelProcessingMap.bodySwitchNote` warns about.

Writing the gain property was measured at a median of 1.7 ms but a **worst case
of 1007 ms** on one device. That is why it never runs on the main thread.

## The vendor control channel

### Established by measurement

Both microphones expose a HID interface on usage page `0xFF00` alongside their
audio interfaces.

| Device | USB id |
|---|---|
| Shotgun microphone in USB mode | `19F7:001A` |
| Small USB condenser | `19F7:0015` |

- **Both devices return byte-identical 78-byte report descriptors.** Published
  descriptor dumps claim 26 bytes; those dumps were taken by a tool that could
  not read the descriptor and reported the wrong length. Read it from the device.
- **No entitlement is required.** An unsigned command-line binary enumerates and
  opens both. The vendor's own application is signed with exactly one
  entitlement — microphone access — and none for USB or HID. Apple reserves the
  keyboard and consumer-control usage pages; `0xFF00` is not reserved.
- **The vendor application uses the same public API this app would**:
  `IOHIDDeviceSetReport` and `IOHIDDeviceRegisterInputReportCallback`. No kernel
  extension, no privileged helper, no driver.
- Opening the HID interface does not disturb the audio interfaces, and the
  device can be driven while it is streaming.

### Channel layout, from the descriptor

Four request/response pairs. Each reply channel is an Input report; each request
channel is the Output report that follows it.

| Reply (device → host) | Request (host → device) | Payload bytes |
|---|---|---|
| 1 | 2 | 9 |
| 3 | 4 | 28 |
| 5 | 6 | 14 |
| 7 | 8 | 27 |

### Framing, from captured traffic

    reply:  <report id> <selector> <status> <value ...>

`status` is `0x41` (`A`, accepted) or `0x4E` (`N`, refused). `selector` echoes
the request. On channel 1 the selector is an ASCII letter; on channel 7 it is a
small integer.

Observed behaviour:

- The device sends **nothing unprompted**. Twenty-five seconds of listening with
  no writes produced no reports at all.
- Any write to channel 8 produces a dump of six properties on channel 7,
  numbered 0, 1, 2, 3, 6 and 7.
- Selector `0x02` on channel 8 is refused, with the refusal arriving on
  channel 1.
- Selector `0x06` on channel 8 answers on channel 5 with several bytes of data.

### Established: what the properties mean

Worked out on 24 August 2026 by moving one control at a time on the shotgun
microphone and watching which number moved, then checking the sequence against
the manufacturer's own printed description of the buttons. It matches, which is
what turns this from a plausible reading into a confirmed one.

| Property | Control | Values |
|---|---|---|
| 0 | −20 dB pad | 0 off, 1 on |
| 1 | High-pass filter | 0 off, 1 = 75 Hz, 2 = 150 Hz |
| 2 | High-frequency boost | 0 off, 1 on |
| 6 | Safety channel | 0 off, 1 on |
| 3 | unidentified, constant `01` | — |
| 7 | unidentified, constant `0` | — |
| 4 | unidentified, seen as `0x5B` = 91 during a manufacturer session; absent from our own polls | — |

The confirmation worth recording: the device has one button that cycles pad and
safety channel together, in four steps — pad on, pad off and safety on, both on,
both off. The captured sequence was exactly

    0 = 1
    0 = 0, 6 = 1
    0 = 1, 6 = 1
    0 = 0, 6 = 0

Two independent properties producing that pattern from single presses of one
button is not something that happens by coincidence.

Property 1 is a three-state value, which is the shape of the high-pass filter
and of nothing else on the device. Property 2 changed only on a long press of
the filter button, which is the high-frequency boost.

`tools/deviceprobe --window` is the tool that produced this and is the tool to
use for the remaining ones: it shows each property live, lights up the row that
changed, and has a field to name it.

### Not established

**The session.** The device answers nothing until the manufacturer's
application has been started. With that application running, our own polls are
answered normally, from a separate unsigned process, so this is not exclusivity
or ownership — the device simply ignores everyone until someone says the right
thing to it. Quit that application and the device goes silent again within
seconds.

The opening move is on channel 4: the application asks selectors 0, 1, 2 and 3
there at startup and gets long structured replies on channel 3, and only
afterwards does anything else answer. Asking those same four selectors cold,
with a zero payload, gets the first one **refused** and the rest ignored. So the
selectors are right and the payload is not.

That last step cannot be read off the wire with an input-report callback, which
only sees what the device sends and never what another process wrote. Finishing
it needs either a USB-level capture or a small number of payload variants tried
deliberately.

**How to set a property.** Not attempted. Reading is solved; writing is not.
There is no point guessing at it before the session is understood, because a
write will be ignored for the same reason a read is.

Static extraction was tried and failed. The vendor application is a single
70 MB native binary, not a script bundle. Its C++ symbols are not stripped and
its interface strings are readable — which is how the *names* of the settings
are known — but the protocol constants are plain enumerations and leave no
trace in the binary's strings.

## The part that can destroy a device

On a sibling product from the same vendor, the firmware update path runs over
**channel 1** as single ASCII letters: one puts the device into update mode,
another triggers the flash. There is no signature check on the image.

These microphones almost certainly do not use the same path — they have no bulk
endpoint to carry a firmware image, and the vendor application sends those same
letters to them routinely during normal operation, so on these devices the
letters mean something else. "Almost certainly" is not a safety property.

`tools/deviceprobe` therefore holds its permitted write channels in a constant
and checks every write against it. Channel 2 is not in the set, so the tool
cannot address channel 1's request side at all, whatever it is asked to do. Any
code that later gains the ability to write settings should keep that constraint.

Channel 4 was added to the permitted set once it was clear the device ignores
everything until it is asked something there. That is a different channel from
the dangerous one, and the reason for adding it is written down beside the
constant so that nobody widens the set again without a reason of the same kind.

## What this now means for the app

Reading the device's real state is solved, and it is worth being precise about
what that is worth on its own. Four of the settings the app currently
implements in software — pad, high-pass filter, high-frequency boost and the
safety channel — exist in the microphone, are switched by its buttons, and can
be read out. So the app can at minimum stop guessing: it can show what the
device is actually doing, and it can stop applying its own high-pass on top of
one the microphone is already applying.

Writing still needs the session, and until then nothing changes on screen.

## Why this is not in the app yet

The transport is fully understood; the meaning is not. Shipping a control that
writes bytes whose effect is unverified would be worse than the honest badge
that currently says the app is doing the work itself. The seam is already in
place — `ChannelProcessingMap.resolve` decides per control whether it runs in
the device or in the app, so when a control gains a device-backed
implementation, the interface follows on its own.
