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

### Established: the session, and the byte that was missing

The device answers nothing at all — on any channel — until it has been asked
the four opening questions on channel 4, selectors 0 to 3. After that it
answers normally, from an unsigned process of our own, with no other
application running.

This took a while because of one byte. `IOHIDDeviceSetReport` takes the report
identifier as an argument, and Apple's documentation implies that is enough.
It is not: this device wants the identifier **also as the first byte of the
buffer**, with the length counting it. Sent without it, every field arrives one
place out of position and the device refuses the request — which reads exactly
like a permissions or session problem and is not one.

That was not guessed. The manufacturer's application was disassembled around
its call to `IOHIDDeviceSetReport`, which does:

    strb  w21, [x0], #1     ; report id into the first byte
    memcpy                   ; payload after it
    mov   x4, x23            ; length = payload + 1
    bl    _IOHIDDeviceSetReport

and takes a separate path with no prefix when the identifier is zero.

The request's first payload byte selects which property comes back. Asking for
0 returns property 0 and nothing else, so reading the block means asking eight
times. Requests must be paced: asked back to back the device answers about a
quarter of them, spaced by ten milliseconds it answers all of them.

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

### Established: reads are reads, and there is no write

Setting a property was attempted across every write channel the device declares
except the firmware one, at four byte positions, with and without the verb byte
the manufacturer's software uses on its other hardware. Twelve combinations.
The device acknowledged the transport every time and changed nothing, and the
value always read back as it was before.

That is a negative result, so it needs corroborating rather than asserting.
The manufacturer's application was disassembled at every one of the 61 calls to
its own send routine, and the report identifiers it passes as immediates are
1, 2, 3, 4, 5, 7, 9 and 15. **It never writes to 6 or 8**, the two channels
that carry this device's property traffic.

The set-shaped payload does exist in that binary:

    strb w25, [x19]        ; byte 0: which setting
    mov  w8, #0x1
    strb w8,  [x19, #0x1]  ; byte 1: set
    strb w23, [x19, #0x2]  ; byte 2: value
    ... mov w2, #0x9       ; on report 9

but report 9 is not in this device's descriptor, which declares 1 to 8 and
nothing else. That payload is for other hardware from the same manufacturer.

So the conclusion is not "the command was not found". It is that the
manufacturer's own software does not send one either, which agrees with its
interface — it offers no control for these switches — and with the printed
instructions, which describe them only as buttons on the body.

**These switches are readable and not settable.** Treat that as the answer
until someone produces a capture of a device changing state without a finger on
it.

A useful side effect: since writing a value into the request does nothing, the
zero bytes a read request carries are padding, and reading is safe to do
repeatedly.

### Not established

**Three of the properties.** 5 is unused. 3 and 7 sit constant. 4 read `0x5B`
once during a manufacturer session and zero since, so it is probably a
measurement — battery charge would fit 91 — rather than a setting.

Static extraction of the protocol constants failed, and it is worth saying why
that failed while the disassembly of the transport succeeded. The vendor
application is a single 70 MB native binary with its symbol table stripped;
only its RTTI class names and interface strings survive, which is how the
*names* of the settings are known. The constants are plain enumerations and
leave no trace. The transport, by contrast, is code, and code can be read.

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

The original goal was to operate the microphone's switches from the app. That
is not possible, and the section above is the evidence rather than an opinion.
What is possible is the half that turned out to matter more.

**The app can read the device's real state**, with nothing else running and no
special permission. Four settings it currently implements in software — pad,
high-pass filter, high-frequency boost and the safety channel — exist in the
microphone and can be read out.

That fixes a fault that exists today and is silent. The app's high-pass offers
75 Hz and 150 Hz, which are the same two frequencies printed on the device. If
the switch on the body is set and the one on screen is too, the signal is
filtered twice and the voice goes thin, with nothing on screen to explain it.
The same applies to the pad: −20 dB and −20 dB. The app currently warns about
this in words because it could not know; it can now know.

## How it is used in the app

`MicControlChannel` reads the four switches and hands them to `ParameterStore`,
which shows them where they matter: the caution under the pad and filter
controls. That caution used to hedge on every microphone. Now, when the device
can be asked, it names the frequency that is being applied twice — and when the
device says its switches are clear, it says nothing at all.

Three things there were found by running it, not by reasoning about it, and are
worth keeping in mind before changing it.

**Never write from inside a HID callback.** It does not fail, it *times out*,
five seconds at a time, and takes the run loop with it. Adoption and every
request go through a paced outbox on a timer, one per tick, outside any
callback. That also supplies the pacing the device needs.

**Report identifiers alone do not identify this dialect.** An unrelated capture
card declares the same three. The descriptor walk checks the declared payload
lengths as well.

**All-off and never-answered are opposite meanings.** A microphone with every
switch off produces no changes and would never be heard from, which the
interface would read as "cannot be asked". The first complete reading is
announced whether or not anything moved.

Matching is restricted to the vendor-defined usage page, which keeps this away
from keyboards and pointing devices and out of reach of the input monitoring
consent prompt.

Not every microphone with this channel answers. Of the two developed against,
only the one that physically has switches does; the other is never adopted and
stays "cannot be asked", which is the correct answer for a device with no
switches to report.
