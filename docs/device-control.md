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

### Not established

**What the six properties mean, and how to set one.** All six currently read
zero and none of them moves when the audio-class gain is changed, so none of
them is gain. Mapping them needs a ground-truth event: change exactly one thing
on the device and see which number moves.

`tools/deviceprobe` exists for that:

    tools/deviceprobe/build_deviceprobe.sh
    tools/deviceprobe/build/OCDeviceProbe --watch --pid 0x001A

Then move one switch on the microphone. The line that appears is that switch.

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

## Why this is not in the app yet

The transport is fully understood; the meaning is not. Shipping a control that
writes bytes whose effect is unverified would be worse than the honest badge
that currently says the app is doing the work itself. The seam is already in
place — `ChannelProcessingMap.resolve` decides per control whether it runs in
the device or in the app, so when a control gains a device-backed
implementation, the interface follows on its own.
