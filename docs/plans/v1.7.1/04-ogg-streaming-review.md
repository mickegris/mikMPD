# 4 — Ogg (Opus) phone streaming: review and fixes

## The report

> Code review on Opus streaming. Feels a bit buggy compared to mp3 streaming.
> Worse buffering, once it crashed the app, it has failed to play next song
> sometimes, one time it just stopped playing. It works but can work better.

Clarified: it crashed while listening with the screen locked, on Wi-Fi (item 5
has the crash analysis). After the restart, "I listened for about ten minutes and
then it just stopped playing." A lock-screen pause was then held for ten minutes
until unlock (item 2, F6). That is the same silent death, seen from the lock
screen.

**Question for you:** when it "just stopped" after ten minutes, did the "Listen
on phone" toggle turn itself **off** (maybe with a message), or did it stay
**on** over silence? Off points to O5: the connection ended and the app gave up
at once. On points to O4: the engine was stopped under it and nothing noticed.
The plan fixes both, but the answer tells us which one to reproduce first on the
device.

## Context

`OggStreamPlayer` (OggStreamPlayer.swift) replaced nothing. It sits beside
AVPlayer, which keeps mp3. The v1.7 plan
([../v1.7/02-opus-phone-streaming.md](../v1.7/02-opus-phone-streaming.md),
"Risks") listed **interruptions**, **route changes** and **underrun** as work
that AVPlayer did for free and that would become ours. Route changes got a
partial handler in v1.7. **Interruptions and underrun were not implemented.**
They account for three of the four symptoms. The demuxer and decoder are sound:
they have exhaustive tests and nothing in this review implicates them.

## Findings, ranked, mapped to symptoms

### O1 — Underrun is never handled → "worse buffering"

`schedule(_:)` starts the node once, when 0.5 s is queued, and never looks again.
After that:

- if the network stalls, the scheduled buffers run dry and `AVAudioPlayerNode`
  plays **silence while staying `isPlaying`**. The state stays `.playing`;
- when data returns, each packet (~20 ms) plays **the moment it arrives**, with
  no cushion. So one stall becomes a stretch of stutter until the network is
  ahead again, and there is no mechanism by which it ever gets ahead.

AVPlayer, by contrast, pauses, rebuffers to a healthy depth and resumes, which
is why mp3 feels better. The start threshold is also small: 0.5 s against
AVPlayer's multi-second buffering.

### O2 — The buffer counter is wrong

- The start check multiplies `scheduledBuffers * Int(buffer.frameLength)`, the
  count times *this* buffer's length. Opus packets vary (2.5–120 ms), and the
  first buffer after pre-skip is short. Track **frames**, not buffers.
- `startEngineIfNeeded` sets `scheduledBuffers = 0` right after `node.stop()`,
  but `stop()` fires the completion handler of every buffer still scheduled.
  Each one dispatches `scheduledBuffers -= 1` onto `queue` **after** the reset,
  so the counter goes negative by the number of buffers that were pending. The
  next start then needs roughly twice the threshold. It is bounded, but wrong,
  and it lands exactly at track changes (O3).

### O3 — Every track change restarts the engine → "failed to play next song"

MPD's Opus encoder ends a logical bitstream and begins a new one (new serial,
fresh `OpusHead`/`OpusTags`) when the tags change, which means every song. The
v1.7 plan called chained streams "normal here, not exotic". On each BOS,
`beginBitstream` → `startEngineIfNeeded` does
`node.stop(); engine.stop(); engine.detach(node)`, then reattaches and
restarts. That:

1. **discards everything scheduled**, so the last ~0.5 s+ of the outgoing song
   is cut;
2. leaves the node not playing, so the new song must re-reach the (inflated,
   O2) threshold before it is heard: a gap at every track change;
3. restarts the engine at a moment when the session or route may not allow it.
   If `engine.start()` throws, `fail(…)` ends phone streaming, and that is "failed
   to play the next song".

The engine only needs reconfiguring when the **output format** changes (channel
count; the rate is always 48 kHz for Opus). The decoder must be replaced on a new
bitstream, because its pre-skip belongs to the new header. The engine does not
need to be touched.

### O4 — Interruptions and engine configuration changes are unobserved → the crash, and "just stopped playing"

Nothing observes `AVAudioSession.interruptionNotification` or
`AVAudioEngineConfigurationChange`. When a phone call, Siri, an alarm or another
app's audio interrupts, or when the hardware configuration changes (a Bluetooth
codec switch, AirPlay, a sample-rate change), **iOS stops the engine**, and:

- `started` stays `true`, the node still holds its old state, and the state is
  still `.playing`. The app believes it is streaming over silence. That is "just
  stopped playing", and `isStreamActuallyRendering` then *keeps the session
  open* in the background: the v1.7 bug, back again for Ogg;
- the next `node.play()` on a stopped engine raises the Objective-C exception
  *"player started when engine not running"*. That is **an uncatchable
  crash**, and one of the two candidates for "once it crashed the app". The
  other is SIGPIPE on the MPD socket (item 5), which fits "locked, on Wi-Fi"
  slightly better; the crash log decides. It can be reached from `schedule(_:)` after an underrun, or after O3's re-attach, if
  the start threshold is crossed while the engine is down.

`.newDeviceAvailable` already restarts the stream (v1.7). Everything else that
stops the engine does not.

### O5 — A closed connection ends phone streaming; there is no reconnect → "just stopped playing"

`didCompleteWithError(nil)` → `.idle` → `endsPhoneStream` → `stopPhoneStream()`.
Any network error (Wi-Fi roam, the 30 s inactivity timeout, a brief AP drop)
goes `.failed` → stop. The same happens when MPD closes httpd clients, which it
does when an output is closed: stop, some queue replacements, daemon restart.
AVPlayer rides out short gaps through its buffer and stall recovery. The Ogg
player gives up at the first one.

v1.7 made `.idle` end the stream deliberately, so that the toggle never showed
"Streaming" over silence. That rule stays, but it applies **after a bounded
reconnect budget**, not on the first event.

### O6 — Latency grows without bound

Nothing caps how much is scheduled. After a stall, TCP delivers the backlog in a
burst, everything is scheduled, and the phone now lags MPD by the stall length.
It never catches up for the rest of the session. This compounds item 2's
pause/resume lag.

### O7 — Smaller issues

- **FLAC assumes 48 kHz stereo; it must play 44.1 and 48 (and anything else
  MPD sends).** FLAC itself handles any rate up to 655 kHz; 44.1 and 48 are
  simply the common ones. `STREAMINFO` is not parsed, and the decoder is always
  built for 48 kHz stereo. MPD's FLAC encoder sends the **source file's** format
  unless the httpd output sets `format`. A CD rip (44.1 kHz) would therefore play
  about 9 % fast and high-pitched, and a 96 kHz file twice as fast. Because the
  rate follows the file, **it can change at a track boundary**: a new chained
  bitstream with a new `STREAMINFO`.

  Fix: parse `STREAMINFO` from the first packet. The Ogg FLAC mapping is
  `0x7F "FLAC"`, a version, a header count, then `"fLaC"` and the 34-byte
  STREAMINFO block. In that block the sample rate is 20 bits, channels 3 bits
  (+1) and bits per sample 5 bits (+1), all big-endian from byte 10 of the
  block. `OggCodec.flac` becomes `.flac(FLACStreamInfo)`, like
  `.opus(OpusHead)`, and `OggPacketDecoder` builds both the source ASBD and the
  output `AVAudioFormat` at that rate and channel count. Fix B (engine
  reconfigured only when the format changes) then handles a 44.1 → 48 track
  change: the engine is reconfigured *only* at that boundary, and the playback
  hardware resamples as usual. Opus is unaffected: it always decodes at 48 kHz
  whatever the source was.

  The server-form copy ("mikMPD can play MP3, Opus and FLAC") stays true, and
  becomes so for real.
- **Opus `mFramesPerPacket = 960` is hard-coded.** It is correct for MPD's
  default 20 ms frames. A packet whose TOC says otherwise is decoded by the
  converter per its own TOC, and the output buffer is sized for the 120 ms
  maximum, so this is safe. Leave it, with a comment saying why it is safe.
- **The completion handler on `scheduleBuffer`** uses the plain completion form.
  Use `scheduleBuffer(_:completionCallbackType: .dataPlayedBack)` so the
  frame accounting (O2) counts what was *heard*, not what was consumed.

## Design of the fixes

The fixes fit together, so they are designed as one change to the player's
lifecycle, not seven patches.

### A. A jitter buffer with a pure policy (O1, O2, O6)

A new pure type in OggStreamPlayer.swift:

```swift
nonisolated struct OggBufferPolicy {
    var startFrames   = 48_000 * 2      // 2.0 s before first play and after underrun
    var lowFrames     = 48_000 / 4      // 0.25 s → declare underrun, pause, rebuffer
    var maxFrames     = 48_000 * 6      // 6 s → drop incoming packets until back under
    func action(bufferedFrames: Int, isPlaying: Bool) -> OggBufferAction  // .play / .pause / .drop / .none
}
```

- `bufferedFrames` is maintained on `queue`: add at schedule time, and subtract
  in the `.dataPlayedBack` completion. Reset to 0 only together with an
  invalidated **generation token**: each completion captures the generation
  current when its buffer was scheduled, and ignores itself if the generation
  has moved on. That fixes O2's negative counter by construction.
- Underrun: below `lowFrames` while playing → `node.pause()`, state
  `.buffering`, and resume once back at `startFrames`. A stall becomes one clean
  gap, as with AVPlayer, instead of a stretch of stutter.
- Over `maxFrames` → drop decoded buffers (not packets: the decoder state must
  keep advancing) until back under `startFrames`. This bounds latency (O6).
- `.buffering` ↔ `.playing` transitions reach the store, so the UI can show
  "Buffering…" under the toggle. The toggle itself does not change.

The numbers are a starting point for device tuning. 2 s matches what AVPlayer
feels like on a LAN.

### B. The engine is configured once per format, not per bitstream (O3)

`beginBitstream`: always replace the decoder. Call `configureEngine(format:)`
only if `format != currentEngineFormat`. For a chained Opus stream with the same
channel count this means no stop, no detach and no flush: the next song's
buffers queue directly behind the last song's, and the transition is gapless.

### C. Engine health is checked, never assumed (O4)

- Before every `node.play()`: `guard engine.isRunning`. If it is not, attempt
  `try engine.start()`. If that throws, go to `.buffering` and let the recovery
  below handle it. **Never** call `play()` on a stopped engine. This single
  guard removes the crash regardless of which path got there.
- Observe `AVAudioEngineConfigurationChange` (object: the engine). On it,
  rebuild: re-attach the node, reconnect with the current format, restart, and
  reschedule nothing (the live stream carries on). The observer is registered
  in `start` and removed in teardown, and it hops onto `queue`.
- Observe `AVAudioSession.interruptionNotification`. **This is the store's
  job**, next to `observeAudioRoute`, because it applies to AVPlayer too (which
  pauses itself on interruption and never resumes). On `.began`, mark the phone
  stream suspended. On `.ended` with `.shouldResume`, restart the stream at the
  live edge. Without `.shouldResume`, stay suspended: the user resumes from the
  lock screen, and item 2's play path reconnects. Add a pure
  `phoneStreamInterruptionAction(type:options:)` so it is testable, beside
  `phoneStreamRouteAction`.
- `isRendering` must be false while the engine is not running. The state
  machine handles this, because every such path goes to `.buffering`, then to
  `.failed`/reconnect.

### D. Bounded reconnect (O5)

Inside `OggStreamPlayer`, on `.idle` (server closed) or a transient `URLError`
(`timedOut`, `networkConnectionLost`, `notConnectedToInternet`,
`cannotConnectToHost`): reconnect at 1, 2, 4, 8 s, **four tries, ~15 s total**,
in state `.reconnecting(attempt:)`. A successful reconnect goes back through
`.buffering`. After the budget, emit `.failed("Lost the stream from <host>…")`.
`endsPhoneStream` then fires exactly as in v1.7. The v1.7 rule, that the toggle
never shows "Streaming" over silence indefinitely, still holds, with a ceiling
of ~15 s.

Pure `oggReconnectDelay(attempt:) -> TimeInterval?` (nil = give up), and the
`URLError` classification as a pure function, are both unit-tested.

A token per connection (as the store already does per player) ensures a late
callback from connection N cannot act on connection N+1.

### E. `suspend()` / resume for item 2

`suspend()` stops the node, bumps the generation (dropping all scheduled
audio), cancels the data task and sets state `.suspended`. **It does not end
phone streaming** (`endsPhoneStream` is false for it). Resume is a normal
`start(url:)`. Item 2 uses this when MPD pauses.

### State machine after the change

```
idle ─start→ buffering ─≥startFrames→ playing ─<lowFrames→ buffering
                 ↑                        │
                 └──── reconnecting ←─ closed / transient error
                         │ budget spent
                         ↓
                       failed ─→ (store stops phone streaming)
any ─suspend→ suspended ─start→ buffering
```

`OggStreamState` gains `.reconnecting(Int)` and `.suspended`.
`endsPhoneStream` is true only for `.failed` and for `.idle` *after* an explicit
`stop()`. `isRendering` covers `.playing`, `.buffering` and `.reconnecting`,
plus `.suspended` for the background check in item 2.

## Tests (unit, no device)

- `OggBufferPolicy.action`: the start threshold, the underrun trigger, recovery
  back to the start threshold (not just above low; hysteresis), and the drop
  above the maximum.
- A frame-accounting test: schedule, complete, bump the generation, then deliver
  stale completions → `bufferedFrames` never goes negative.
- Chained stream through the player's `consume` path with a fake engine sink, or
  `configureEngine` extracted behind a small protocol: two bitstreams with the
  same channel count → exactly **one** engine configuration; mono then stereo →
  two.
- `oggReconnectDelay`: 1, 2, 4, 8, then nil.
- `URLError` classification: transient vs fatal (`badURL`,
  `unsupportedURL` and HTTP 404 are fatal and never retried).
- `phoneStreamInterruptionAction`: began → suspend; ended + shouldResume →
  resume; ended without it → stay.
- FLAC `STREAMINFO` parse: 44.1 k/stereo, 48 k/stereo and 96 k/mono fixtures,
  built with the recipe in the v1.7 plan's appendix.
- FLAC decode at 44.1 kHz, like `OggPacketDecoderTests`' Opus tone: a 1 kHz tone
  encoded at 44.1 k decodes to a 44.1 k buffer, and the zero-crossing count over
  one second is ~2000, not ~2180 (the "9 % fast" bug).
- A FLAC chained stream 44.1 k → 48 k → exactly two engine configurations.
- `oggStreamStalled(lastPlayedBack:now:state:)` (item 2 F6): `.playing` with no
  playback for more than 3 s → stalled; `.buffering`/`.reconnecting` → never
  stalled (they are already handling it).
- The existing `OggPacketDecoderTests` stay green untouched. They are the proof
  that the decode path still produces audio.

## Device verification (TESTING.md §21 additions)

Opus stream, iPhone, on Wi-Fi:

- [ ] 20 track changes in a row (skip through the queue) → every song starts,
      with no cut-off tail and no gap longer than the encoder's own;
- [ ] let 3 songs play through naturally → gapless;
- [ ] walk to the edge of Wi-Fi until it stutters → one clean rebuffer gap
      ("Buffering…"), not stutter; recovers by itself;
- [ ] Wi-Fi off 5 s then on → "Reconnecting…" → plays again; Wi-Fi off 30 s →
      stops with the message, and the toggle is off;
- [ ] receive a phone call and decline it → streaming resumes; take the call,
      hang up → resumes, or waits for lock-screen play (per `shouldResume`);
- [ ] Siri, and an alarm, mid-stream → no crash, recovers;
- [ ] AirPods in/out, AirPlay to a speaker and back → no crash;
- [ ] restart MPD mid-stream → reconnects within the budget;
- [ ] FLAC at 44.1 kHz and at 48 kHz → correct pitch for both, including across
      a track change from one rate to the other;
- [ ] a 30-minute locked session on Wi-Fi → no crash, no silent stop (the
      combined reproduction of yesterday's three reports);
- [ ] mp3: all of the above that apply → unchanged from v1.7.

## Docs

CLAUDE.md → "Phone streaming": replace "A server closing the stream ends phone
streaming" with the reconnect-budget rule. Add the jitter buffer, the
"engine is configured per format, not per bitstream" rule (with the reason:
MPD chains a new bitstream every song), and the `engine.isRunning` guard (with
the reason: the uncatchable exception). Fix the FLAC claim once `STREAMINFO` is
parsed.
