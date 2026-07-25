# Bit-perfect / USB-DAC passthrough — feasibility assessment

**Date:** 2026-07-25
**Status:** ❌ Not implementable on iOS as commonly understood. **Ship the honest
version** (see "What we *can* do") and say so publicly at launch.
**Driver:** ranked #6 in the [niche research](../../README.md) — an audiophile
dealbreaker, repeatedly asked for in r/audiophile ("Best iOS FLAC players with
DAC support… bit-perfect audio from my FLAC files").

---

## The question

Can Aria deliver bit-perfect output to a USB DAC — the source file's samples,
at the file's native rate, unmixed and unresampled?

## The answer: no, and not because of Aria

iOS routes **every** app's audio through a **fixed-rate system mixer** and does
not expose the Hardware Abstraction Layer (AUHAL) APIs macOS uses to negotiate
a device's native rate. Consequences, verified against Apple's own docs and
independent testing:

- **Output is capped at 44.1 or 48 kHz** to any USB DAC, regardless of what the
  DAC supports or what the file contains. A 192 kHz FLAC is resampled by the OS
  before it ever reaches the DAC.
- **`AVAudioSession.setPreferredSampleRate(_:)` is a hint, not a command.**
  Apple's documentation states preferred values "may be different once the
  AVAudioSession has been activated"; requesting 192 kHz returns no error and
  leaves `session.sampleRate` at 44.1/48 kHz.
- This is **stable across iOS 13 → 18** with no sign of change — it is a
  deliberate architectural choice, not an oversight.
- **No iOS app has solved it.** Neutron Music Player — the most
  audiophile-focused player on the platform — states plainly in its FAQ: "On
  iOS, normally Apple devices support only 2 frequencies: 44100 and 48000 Hz,
  so you can achieve Bit-Perfect output with these frequencies only." Apps
  marketing "bit-perfect" on iOS are subject to the same mixer.

**Therefore:** any claim we made about true hi-res bit-perfect passthrough would
be false, and the audiophile audience is precisely the audience that would
catch it. That reputational risk is far larger than the feature's upside.

## What we *can* honestly do (and mostly already do)

Within the 44.1/48 kHz ceiling, "bit-perfect" means **we don't touch the
samples**. Aria's current path is already clean:

1. **No EQ tap is attached unless EQ is on.** `AVPlayerPath.attachEQ()` runs
   only when `eq.isEnabled`; with EQ off there is no `MTAudioProcessingTap` in
   the graph at all — the decoded samples go straight to the output. (When EQ
   *is* on but bypassed, the tap exists and passes audio through unmodified.)
2. **No format conversion, resampling, or normalization** of our own anywhere in
   the playback path.
3. **Lossless files stay lossless end-to-end** — FLAC/ALAC are decoded once by
   AVFoundation and played; the quality badge (shipped) tells the user exactly
   what they're playing.

The one thing we do **not** currently do, and should:

4. **Match the session sample rate to the file** — request 44.1 kHz for 44.1 kHz
   content and 48 kHz for 48 kHz content via `setPreferredSampleRate`, instead
   of letting whatever the previous route negotiated stand. Within the two rates
   iOS honors, this removes an unnecessary OS resample (e.g. a 44.1 kHz album
   played while the session sits at 48 kHz). **This is a real, deliverable
   quality win** — it is what "bit-perfect on iOS" actually means in practice.

## Recommendation

1. **Do not ship a "bit-perfect" toggle or claim.** ❌
2. **Ship "Sample-rate matching" instead** (item 4 above) — small, honest, and
   genuinely the best iOS allows. Suggested placement: More → Advanced, with
   copy that states the platform limit plainly.
3. **Say it out loud at launch.** This is a credibility asset, not a weakness:

   > **On bit-perfect output:** iOS routes all audio through a fixed-rate system
   > mixer and caps USB DACs at 44.1/48 kHz — no iOS app can bypass this
   > (Neutron's FAQ says the same). Aria doesn't pretend otherwise. What it does
   > do: never touch your samples (no EQ tap in the graph when EQ is off, no
   > resampling of our own), and match the output rate to the file so the OS
   > doesn't resample unnecessarily. If Apple ever exposes HAL-style device
   > access on iOS, we'll be first in line.

   Posting this in r/audiophile earns more trust than any feature bullet — it
   answers a question the community asks constantly and is usually
   mis-answered by marketing copy.

## Sources

- Apple, [`setPreferredSampleRate(_:)`](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredsamplerate(_:)) — preferred values are hints
- [Why iOS Caps External USB DACs at 48 kHz](https://benefic.com/blog/why-ios-caps-usb-dacs-at-48khz) — fixed-rate mixer, no AUHAL on iOS, behavior stable iOS 13–18
- Neutron Music Player FAQ (quoted above) — 44.1/48 kHz only on iOS
- Community corroboration: Audiophile Style, Roon Labs forum, Steve Hoffman forums

## Implemented alongside this doc

`Services/OutputSampleRate.swift` + a hook in `AVPlayerPath.play(url:)`:
on item load, read the asset's sample rate and request the matching honored
rate. Family selection is **not** nearest-distance — a source keeps its family
when it's a clean integer multiple *or divisor* of that base (22.05/88.2/176.4
→ 44.1; 24/96/192 → 48), because those are clean ratio conversions. A rate in
neither family (e.g. 32 kHz, where 48/32 = 1.5) falls back to the nearer base.

Best-effort by design: `setPreferredSampleRate` can be refused (another app owns
the route, hardware disagrees) and playback simply continues — never a failure
path. Covered by `Tests/OutputSampleRateTests.swift`, including a real-file
format read.

**Not device-verifiable here:** whether the session actually lands on the
requested rate depends on hardware and route. Worth one check on a real device
with a USB DAC (Console: `OutputSampleRate` category logs the requested vs
resulting rate).
