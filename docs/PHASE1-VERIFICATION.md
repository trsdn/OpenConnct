# Phase 1 manual verification runbook

This is the end-to-end test that cannot be automated. It needs physical microphones, an
administrator password, and a CoreAudio restart.

**Nothing in this document has been performed yet.** The driver compiles, signs, and passes 384
offline assertions through the real `AudioServerPlugIn` vtable, but it has never been loaded by
`coreaudiod` and no audio has ever passed through the complete pipeline.

> **If you are reading this because audio is broken right now, skip to
> [Section 7: Rollback](#7-rollback-getting-your-audio-back).** It is written to be followed on
> its own, out of order, without reading anything above it.

---

## Before you start

**What this will do to your Mac.** Installing the driver copies a bundle into
`/Library/Audio/Plug-Ins/HAL/` and then runs `sudo killall -9 coreaudiod`. That command **kills the
audio service for the entire system, not just this app**. Every running audio application — music,
browser tabs, a call you are on, screen recording — loses audio for roughly one to five seconds
while macOS restarts the service automatically. Some applications recover instantly; some need to
be restarted; a few need their audio device re-selected.

**So, before you begin:**

- [ ] Leave any call, meeting, or live stream.
- [ ] Stop any recording. This step can and will interrupt a recording in progress.
- [ ] Quit or pause music, video, and anything else playing audio.
- [ ] Have this document open somewhere you can still read it if audio breaks — it is text only, so
      a second device or a printout is fine, but not required.

**Time required:** about 15 minutes.

**Paths.** Commands in Sections 1–6 assume the repository is at `/Volumes/big/dev/OpenConnect`. If
yours is elsewhere, substitute your own path. **Section 7 is deliberately path-independent** — the
rollback must work even if the repository has been moved or deleted, so it never depends on a
checkout.

**You will need:** the RØDE NT-USB Mini, the RØDE VideoMic NTG with a USB cable, and your
administrator password.

**Do not plug both microphones in yet.** Steps 3 and 4 deliberately test them one at a time. Testing
them individually first is the whole point — see the note in Step 4.

---

## 1. Build

No password needed for this step, and it changes nothing outside the project folder.

```bash
cd /Volumes/big/dev/OpenConnect
make clean
make embed-driver UNIVERSAL=1
```

Then run the automated checks. These must pass before you install anything; if they do not, stop and
report the output rather than installing.

```bash
make test          # DSP suite: expect "Executed 56 tests, with 0 failures"
make test-driver   # driver vtable harness: expect "SUMMARY 384 passed, 0 failed"
```

**Known good:** both commands exit 0, with the counts above.

**Stop here if:** either command fails. Nothing has been installed yet, so there is nothing to undo
— your system is untouched.

---

## 2. Install the driver

This is the step that needs your password and interrupts system audio.

```bash
make install-driver
```

You will be prompted for your administrator password. Depending on how recently you last used
`sudo`, you may be prompted once or not at all. **There is no "are you sure?" confirmation — the
script proceeds immediately**, rebuilding and code-signing the driver before installing it.

The script copies the bundle to `/Library/Audio/Plug-Ins/HAL/OpenConnect.driver`, sets root
ownership, then restarts CoreAudio with `sudo killall -9 coreaudiod`. **Expect your audio to drop
out briefly here. That is this step working, not failing.**

If it stops with `No Developer ID Application signing identity found`, nothing was installed and
your system is untouched — the driver must be signed to load.

### Confirm the device actually appeared

Two independent checks. Do both — the first is authoritative, the second is what you will actually
use day to day.

**a. From the terminal:**

```bash
system_profiler SPAudioDataType | grep -A6 "OpenConnect"
```

**Known good** — an entry like this, reporting 2 input channels at 48 kHz on the Virtual transport:

```
        OpenConnect Mic:

          Input Channels: 2
          Manufacturer: OpenConnect
          Current SampleRate: 48000
          Transport: Virtual
```

You should see **`OpenConnect Mic`**. You should **not** see `OpenConnect Sink` — it is deliberately
hidden so that it cannot be selected as an output device and create a feedback loop. Its absence is
correct behaviour.

**b. From the GUI:** open **System Settings → Sound → Input**. `OpenConnect Mic` should be listed.

### If the device did not appear

The driver was rejected by `coreaudiod`. This is the single most likely failure in the whole
project, and it is normally silent. Diagnose in this order:

1. Confirm the bundle is actually on disk and owned by root:

   ```bash
   ls -l@ /Library/Audio/Plug-Ins/HAL/OpenConnect.driver/Contents/MacOS/OpenConnect
   ```

2. Confirm the signature survived the copy:

   ```bash
   codesign --verify --strict --verbose=2 /Library/Audio/Plug-Ins/HAL/OpenConnect.driver
   ```

3. Read the actual rejection reason. Open **Console.app**, put `coreaudiod` in the search box, then
   in a terminal run `sudo killall -9 coreaudiod` and watch the messages that appear. Look for
   anything naming OpenConnect, a code-signature failure, or a plug-in load error.

4. If Console shows nothing at all, force a fully supported reload by **rebooting**.
   `launchctl kickstart -k system/com.apple.audio.coreaudiod` was deprecated in macOS 14.4, so a
   reboot is the only officially supported way to reload a HAL plug-in.

If it still does not appear after a reboot, go to [Section 7: Rollback](#7-rollback-getting-your-audio-back)
to remove it cleanly, and report what Console showed.

---

## 3. NT-USB Mini alone

Plug in **only** the NT-USB Mini. Leave the VideoMic NTG unplugged.

```bash
open /Volumes/big/dev/OpenConnect/dist/OpenConnect.app
```

macOS will ask for microphone access the first time. **You must allow it.** If you dismiss the
prompt the app will run but capture silence, which looks identical to a broken driver. If you
dismissed it by accident, re-enable under System Settings → Privacy & Security → Microphone.

> **How to tell this apart from a driver fault.** A denied microphone is silent in the log, not
> loud: the engine never starts at all, so the app window opens normally and nothing is obviously
> wrong. Check it directly — the following prints nothing at all when permission is missing, and
> many lines when the engine is running:
>
> ```bash
> log show --last 2m --predicate 'process == "OpenConnect"' --style compact | grep -c AUHAL
> ```
>
> If that prints `0`, it is permission, not the driver. Reset the app's own entry and relaunch to
> get a fresh prompt (this touches only this app):
>
> ```bash
> tccutil reset Microphone audio.openconnect.app
> ```
>
> The build signs the app with a Developer ID so the grant survives rebuilds. If `make` warned
> `no Developer ID Application identity`, the app is ad-hoc signed instead and macOS will re-ask
> after **every** rebuild, orphaning the previous grant — that is expected in that case, not a bug.

### Record the native format

We need to know exactly what the device presents, because the app deliberately captures at each
microphone's **native** rate rather than letting macOS resample — hiding the drift would defeat the
purpose of the project.

```bash
system_profiler SPAudioDataType | grep -A6 "NT-USB Mini"
```

That gives you channel count and sample rate, but **not** bit depth. For the complete format, open
**Audio MIDI Setup** (in `/Applications/Utilities/`), select the microphone, and read the Format
line — it looks like `2 ch 24-bit Integer 48.0 kHz`.

Write down all three:

| | NT-USB Mini |
|---|---|
| Sample rate | |
| Channel count | |
| Bit depth | |

### Check it works

- The channel strip for the NT-USB Mini appears in the app.
- Speaking into it moves the input level meter.
- The engine indicator reads **Engine running** (green), not **Engine stopped** (red).
- The status bar shows a **ppm** figure for the channel. A small non-zero number is correct and
  expected — that is the drift controller doing its job. It is displayed in amber beyond ±100 ppm.
- **No XRun or OVR badge appears.** These only show up when the count is above zero.

Now confirm the audio actually reaches other applications. Open **QuickTime Player → File → New
Audio Recording**, click the chevron next to the record button, and choose **OpenConnect Mic**. Its
level meter should move when you speak. This proves the whole path end to end: microphone → app →
DSP → sink → ring buffer → virtual device → another application.

**Known good:** clean speech, meters moving in both the app and QuickTime, no badges.

**Failure symptoms and what they mean:**

| Symptom | Most likely cause |
|---|---|
| App meter moves, QuickTime meter does not | The loopback inside the driver is not working — the app is rendering into the sink but the mic device is not reading it back |
| Neither meter moves | Microphone permission was denied, or the wrong input device is selected in the app |
| Steady crackling or clicking | Drift compensation problem. Note the ppm reading and whether the XRun count is climbing |
| XRun count climbing steadily | The ring is starved — the input is not keeping up |
| Engine indicator red | The engine failed to start; the sink device is probably missing. Check `OpenConnect Sink` exists internally by re-running the install |

---

## 4. VideoMic NTG alone

Unplug the NT-USB Mini. Plug in **only** the VideoMic NTG, in USB mode.

> **Why one at a time.** This is risk **R5**: the VideoMic NTG may present an unexpected native
> format — a sample rate other than 48 kHz, or a channel count we did not anticipate. If it does, we
> want to discover that with one microphone, where the cause is unambiguous, rather than with both
> running, where a format problem and a drift problem look identical.

Repeat the whole of Step 3 for this microphone and record its format:

| | VideoMic NTG |
|---|---|
| Sample rate | |
| Channel count | |
| Bit depth | |

**Flag it immediately if** the sample rate is anything other than 48000, or the channel count is
anything other than 1 or 2. Both cases are handled in principle — the app resamples from the native
rate, and downmixes multi-channel input by averaging — but neither has been exercised against real
hardware, and a surprise here changes what Step 5 means.

---

## 5. Both microphones together

Plug in both. This is the actual thing RØDE Connect does badly, and the reason this project exists.

Confirm:

- Two channel strips appear, one per microphone.
- Each meter responds to **its own** microphone only.
- Mute silences one channel and leaves the other alone.
- Solo silences everything except the soloed channel. The muted channels' buttons show a dim amber
  "silenced by solo" state rather than the red user-muted state.
- Both faders work independently.

Then **let it run for at least fifteen minutes** while speaking into both microphones periodically.
Drift is cumulative, and the ring fill level only moves in whole 512-frame hardware blocks, so at
realistic crystal offsets one microphone gains a full block only every nine minutes or so. Until
then both channels will legitimately report *identical* numbers. This has been confirmed on the
development machine: the two channels stayed byte-identical until roughly t=600 s and then diverged.
A thirty-second test proves nothing, and a five-minute test proves almost nothing.

Watch the status bar for the whole period:

- **ppm per channel** — should settle to a small steady value per microphone and stay there. Two
  different microphones showing two different ppm values is exactly right; they have different
  crystals.
- **XRun / OVR badges** — should never appear. In the offline simulation the controller held
  ±200 ppm for a simulated two hours with zero underruns and zero overruns, so any xrun on real
  hardware is a genuine finding worth reporting.

**Known good:** clean audio from both microphones, no clicks or crackles, stable ppm, no badges,
after fifteen-plus minutes.

For reference, measured on the development machine with both microphones live, sampling the ring
continuously rather than once per interval:

```
t=60s   under=0 over=0 dropped=0
        [RØDE NT-USB Mini  fill 1535/1535.9/1537  ppm -3.9/-0.5/+3.6]
        [RØDE VideoMic NTG fill 1535/1535.9/1537  ppm -3.9/-0.5/+3.6]
```

Fill is min/mean/max against a target of 1536 frames. Staying within a couple of frames of target,
with ppm inside single digits and no underruns, is what healthy looks like.

**Failure symptoms:**

| Symptom | What it points to |
|---|---|
| Periodic click, roughly regular interval | Ring wrap or xrun. Check whether XRun/OVR is incrementing |
| One channel gradually distorts or drops out | That channel's drift controller is not holding |
| ppm climbing without settling | The controller is not converging — record the value over time |
| Both channels crackle together | Output-side problem, not per-channel drift |

Note that the ring fill level is tracked internally but is **not** currently shown in the interface;
the ppm readout and the xrun badges are the diagnostics available to you.

### If you want the detailed numbers

Two environment variables exist for diagnosis. Both are off or defaulted in normal use, and neither
changes what the audio path does:

```bash
# Log accumulated min/mean/max fill and ppm every 60 seconds. Quit the app first.
OPENCONNECT_SOAK_LOG=60 /Applications/OpenConnect.app/Contents/MacOS/OpenConnect 2>&1 | grep -a SOAK
```

```bash
# Meter refresh rate in Hz; default 20, and 0 disables the meters entirely.
# With meters off the whole app measures 0.5% of one core with both mics live,
# which is how we established that the CPU cost is drawing, not audio.
OPENCONNECT_METER_HZ=0 /Applications/OpenConnect.app/Contents/MacOS/OpenConnect
```

Running the binary directly like this puts its log on your terminal. Launching the app normally from
Finder does **not** show these messages anywhere.

---

## 6. Hot-plug

Microphones get unplugged constantly, so this must not require restarting the app.

**Please treat this section as the least-tested part of the system.** Every other step above has
been exercised on the development machine; a physical unplug of a live microphone has not, because
it needs a hand on the cable. If something is going to be wrong, it is most likely to be here.

With both running, unplug one microphone. Expect:

- Its channel strip disappears.
- The other channel keeps working **without a gap or a click**. Watch its XRun badge across the
  unplug — a single xrun at the moment of removal is plausible; a rising count afterwards is not.
- The engine stays green rather than dropping to a stopped or error state.

Now plug it back in. Expect the strip to return **with its previous settings intact** — gain,
effects, fader position — because settings are persisted per device UID, not per slot.

There is one specific thing worth listening for on replug. When a channel's ring runs dry the
engine re-primes it rather than free-running, which briefly re-establishes the buffer before audio
flows. On replug you may hear the channel come back a fraction of a second late. That is expected.
What is *not* expected is repeated dropouts, a channel that comes back permanently distorted, or
ppm that never settles again.

Finally, quit the app, relaunch it, and confirm your settings survived.

---

## 7. Rollback: getting your audio back

**Read this section first if something is wrong. It does not depend on anything above, and it does
not depend on the project folder still existing.**

### Remove the driver — works from anywhere

These two commands are the entire uninstall. They work from **any** directory, on any machine, even
if the project folder has been moved or deleted. Nothing else is written anywhere on your system.

```bash
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/OpenConnect.driver"
sudo killall -9 coreaudiod
```

Audio will drop out briefly as CoreAudio restarts. That is expected. Wait about five seconds —
macOS relaunches the service by itself.

Then confirm it is gone:

```bash
system_profiler SPAudioDataType | grep -c "OpenConnect"   # expect 0
```

That is the whole rollback. Everything below is optional.

### Convenience alternative, if you still have the repo

If the project folder is present, this does the same thing and additionally verifies the device
really disappeared:

```bash
cd /Volumes/big/dev/OpenConnect
make uninstall-driver
```

Prefer the two raw commands above if you are in a hurry or unsure the folder still exists — the
`make` target only works from a checkout, and it is not needed to fix your audio.

### If the Mac has no working audio at all

Do not panic, and do not reinstall anything. **A HAL plug-in cannot permanently break audio.** It
runs in userspace inside `coreaudiod`, not in the kernel. Removing the bundle and restarting the
service always restores the previous state, and macOS restarts `coreaudiod` automatically if it
crashes.

Work through these in order:

1. **Remove the driver** with the two commands at the top of this section
   (`sudo rm -rf …/OpenConnect.driver` then `sudo killall -9 coreaudiod`). This alone fixes almost
   every case, and it needs nothing but a terminal.

2. **Restart CoreAudio again**, in case it came back before the file was gone:

   ```bash
   sudo killall -9 coreaudiod
   ```

   Wait about five seconds. macOS relaunches it for you.

3. **Re-select your output and input** in System Settings → Sound. When a device disappears, macOS
   sometimes leaves the selection pointing at something that no longer exists. Pick your speakers
   and microphone explicitly rather than assuming the default is right.

4. **Quit the applications that lost audio.** Many apps grab an audio device at launch and never
   re-check it. Zoom, Teams, OBS and browsers commonly need a restart after a CoreAudio restart —
   this is normal behaviour with any virtual audio device, not damage.

5. **Reboot.** This resolves any remaining stale state, and it is the only officially supported way
   to reload HAL plug-ins.

6. **If audio is still broken after a reboot with the driver removed**, then the cause is not
   OpenConnect — the bundle is gone and nothing of ours is loaded. Check System Settings → Sound for
   a sensible output device, and look for a stuck app holding the device exclusively.

### Confirming you are fully clean

```bash
ls /Library/Audio/Plug-Ins/HAL/                            # no OpenConnect.driver
system_profiler SPAudioDataType | grep -c "OpenConnect"    # 0
```

The app itself is a normal application in `dist/` and can simply be quit or deleted. It installs
nothing outside its bundle except a settings file at
`~/Library/Application Support/OpenConnect/`, which is safe to delete.

---

## 8. What to report back

Please include, whether it worked or not:

1. Whether `OpenConnect Mic` appeared, and what `system_profiler` printed for it.
2. The native format table for **each** microphone from Steps 3 and 4 — sample rate, channels, bit
   depth. This is the R5 evidence and is useful even on a completely successful run.
3. Final ppm reading per channel, and the XRun / OVR counts after the ten-minute run in Step 5.
4. Any audible artefacts, with what you were doing at the time.
5. If it failed: the relevant `coreaudiod` lines from Console.app.
