# 2 — Ogg phone streaming (Opus, and what else falls out)

## The request

> Opus decoder for http phone streaming. Currently only mp3 works.
> […] Phone streaming needs to work seamless regardless of codec configured in MPD.
> […] if it's not documented by Apple, it doesn't exist. They might remove that in
> the future. So go ahead and write a solid ogg demuxer.

`startPhoneStream` hands the httpd URL to `AVPlayer`, which plays mp3 and AAC and
has never supported Ogg. Point it at an httpd output encoding Opus and the toggle
produces silence.

**The requirement is seamlessness, not Opus.** The codec is chosen on the MPD
server and the app has no business knowing or caring which one is configured:

- **No app-side setting, ever.** No codec picker, no per-server format field. The
  stream URL stays the only thing configured.
- **Nothing about the codec is persisted.** It is detected at each stream start,
  so changing the server's encoder needs no action in the app and no relaunch.
- **The toggle behaves identically either way.** A user should not be able to
  tell from the app which encoder their server runs.

Nothing here encodes anything. The app decodes; MPD encodes.

## The line: our container, Apple's codec

An earlier draft leaned on the fact that `AudioFileStream` *does* parse Ogg on
iOS 26 — verified, 151/151 packets, even with no type hint. That is now
deliberately unused: `AudioFile.h` declares no Ogg type constant, so it is
behaviour Apple has never promised and can withdraw in a point release. **If it
is not documented, it does not exist.**

That rule cuts precisely one thing, and it is worth being exact about where it
falls, because the rest of the stack is fully supported API:

| Piece | Status | Decision |
|---|---|---|
| Ogg container parsing | **undocumented** on iOS | **we write it** |
| `kAudioFormatOpus`, `kAudioFormatFLAC` | declared in the public `CoreAudioBaseTypes.h` | use them |
| `AudioConverter` decode | documented public API | use it |
| `AVAudioEngine` playback | documented public API | use it |

One more undocumented thing was found and then designed out. Apple's Opus *magic
cookie* is a 28-byte binary blob with no published layout (big-endian words:
sample rate, frames-per-packet, a negative pre-skip, channel count). Building one
by hand would have smuggled an undocumented format back in through the side door.
**It turns out not to be needed:** decoding the same 151 packets with **no magic
cookie at all**, driven only by a fully specified `AudioStreamBasicDescription`,
produced byte-identical output — 144,840 frames, peak 0.407. Every field of that
ASBD is documented.

So the final dependency list is: our demuxer, plus public AudioToolbox. Nothing
third-party, and nothing undocumented.

## What we can and cannot decode

Authoritative source is `kAudioFormatProperty_DecodeFormatIDs` on the device:

```
.mp3 aac aace aacf aacg aach aacl aacp ac-3 alac alaw apac dvi8 ec+3 ec-3
flac ilbc ima4 lpcm ms ms ms 1 opus ulaw usac
```

| MPD httpd `encoder` | Container | Decoder | Result |
|---|---|---|---|
| `lame` (mp3) | raw mp3 | AVPlayer | works today, untouched |
| `opus` | Ogg | `kAudioFormatOpus` | **the feature** |
| `flac` | Ogg | `kAudioFormatFLAC` | **works for free** once the demuxer exists |
| `vorbis` | Ogg | *none exists on iOS* | identified, then refused with a reason |
| `wave` | raw wav | AVPlayer | works today |

FLAC is a genuine bonus: the demuxer is codec-agnostic, `flac` is in the
decodable list, and `kAudioFormatFLAC` is a documented constant. It costs a
branch on the codec identified in the Ogg headers, so it is in scope.

**Vorbis is out of scope and stays out.** iOS has no Vorbis decoder — `vorb` is
absent from the list above, and the string "Vorbis" appears nowhere in the
CoreAudioTypes, AudioToolbox or AVFAudio headers of the iOS 26.5 SDK. Decoding
it would mean vendoring libvorbis, ending the no-dependencies invariant for a
codec Opus supersedes at every bitrate. The demuxer will still *identify* it
from the Ogg headers, because the alternative is silence: the user gets a message
naming the codec and telling them what to switch to.

## Telling the user which codecs work

Two places, so the answer is available before *and* after something goes wrong:

- **In the server form**, under the Stream URL field, where the URL is entered
  and where someone setting this up is already looking. The existing footer gains
  the supported list — mp3, Opus and FLAC — so it is answerable without
  experiment.
- **In the failure message**, when a stream turns out to be something else.
  Naming the codec that arrived and the ones that work ("This stream is Ogg
  Vorbis. mikMPD can play mp3, Opus and FLAC — change the httpd output's encoder
  to `opus`.") turns a dead toggle into a one-line fix.

The list is a fact about the app, not configuration: no setting, no picker,
nothing to keep in sync with mpd.conf.

## The demuxer

A new file, pure Swift, no Foundation networking and no AudioToolbox — it takes
bytes in and yields packets out, which is what makes it testable.

```swift
struct OggDemuxer {
    mutating func push(_ bytes: UnsafeRawBufferPointer)   // arbitrary chunk sizes
    mutating func nextPacket() -> OggPacket?              // nil when it needs more bytes
}
```

**Page structure** (RFC 3533): capture pattern `OggS`, version 0, header-type
flags (0x01 continued, 0x02 beginning-of-stream, 0x04 end-of-stream), 8-byte
granule position, 4-byte serial, 4-byte sequence, 4-byte CRC, segment count, then
the segment table. Packets are laced across segments: a value of 255 continues,
anything less terminates. A packet can span pages, which is what the continued
flag marks.

The parts that are easy to get wrong, and are the reason to write tests before
wiring any audio:

- **We join a live stream mid-page.** MPD's httpd starts sending at the moment
  you connect, so the first bytes are almost never a page boundary. The demuxer
  must scan for the capture pattern rather than assume alignment.
- **`OggS` occurs inside packet data.** Scanning alone will resync onto garbage.
  **Validate the CRC** — poly `0x04c11db7`, init 0, no reflection, no final xor,
  computed with the CRC field zeroed — and treat a mismatch as "keep scanning".
  This is the difference between a demuxer that works and one that works until
  the network hiccups.
- **Chained streams are normal here, not exotic.** An encoder may end one logical
  bitstream and begin another at a track boundary — a fresh BOS with a **new
  serial number**. Handling it is what stops "plays the first track then stops".
  On a new BOS: re-read the codec headers and reconfigure the converter, and the
  engine too if the sample rate changed. (Opus is always 48 kHz; FLAC is not.)
- **Multiplexed streams**: track packets by serial and ignore serials that are
  not the audio stream, rather than interleaving them into one packet stream.
- **Backpressure and bounds.** Fed from the network, so the internal buffer needs
  a ceiling and a defined behaviour when a page claims a length that never
  arrives.

**Codec identification** comes from the first packet of the logical bitstream:
`OpusHead` (19 bytes: version, channels, pre-skip, input rate, output gain,
mapping family), `\x7fFLAC`, or `\x01vorbis`. The second packet is comment data
(`OpusTags` / `\x03vorbis`) and is skipped. **Pre-skip must be honoured** —
discard that many samples from the front of the decoded output, per RFC 7845;
this is our job now rather than the container parser's, and getting it wrong
produces a click at the start of every stream.

## Pipeline

```
URLSession (streaming delegate)
   → OggDemuxer          ours: pages → packets, resync, chaining
   → AudioConverter      opus/flac → PCM float32          [documented]
   → AVAudioEngine + AVAudioPlayerNode
```

Selection stays automatic, per stream start: probe `Content-Type` —
`audio/mpeg` → the existing `AVPlayer` path untouched; `audio/ogg` or
`application/ogg` → this pipeline; anything else or absent → try `AVPlayer`,
fall back. `streamPlayerKind(forContentType:)` is a pure function and a unit test.

### Why not one pipeline for everything

`AVPlayer` currently does buffering, stall recovery, interruption handling and
route changes for free, all of which become ours to write and get wrong.
Replacing a working mp3 path is regression risk with no user-visible gain.
**Add a path; do not swap one out.**

## Integration points that will break if missed

Each already has a hard-won reason recorded in CLAUDE.md:

- **`handleEnteringBackground` inspects `streamPlayer?.timeControlStatus`.** That
  check exists because a dead stream left `isPhoneStreaming` true forever,
  holding the audio session open so other apps were never told they could resume.
  The new player needs an equivalent "is this actually playing" signal, or that
  bug returns for Ogg users only — the worst kind, since it was hard enough to
  find once.
- **`stopPhoneStream` must tear down whichever player is running**, and
  `startPhoneStream` must keep tearing down *before* touching the audio session.
- **Nothing runs on termination.** No `deinit` may be relied on to stop the
  engine or deactivate the session; `AVAudioEngine` holds a render thread and a
  force-quit is a SIGKILL.
- **Interruptions and route changes.** `AVPlayer` absorbed phone calls and
  unplugged headphones; `AVAudioEngine` does not. Explicit
  `AVAudioSession.interruptionNotification` and `routeChangeNotification`
  handling is new work and the likeliest source of "it stopped and never came
  back".
- **Underrun.** No `automaticallyWaitsToMinimizeStalling` here. The player needs
  its own target buffer depth and a defined dry behaviour — and httpd is an
  endless live stream, so there is no duration and no seeking to lean on.
- **Off-main callbacks must be `@Sendable`.** CoreAudio invokes the converter
  input callback and render path on its own threads; MainActor inference traps
  there. `PhoneStreamTests` guards this class of bug and should be extended.

## Nothing to configure, on either side

The httpd `encoder` is MPD's own configuration and outside this plan. The only
release-note detail: Opus runs at 48 kHz, so an Opus httpd output is best given
`format "48000:16:2"` to stop MPD resampling twice. Advice about their server,
not a requirement the app imposes.

## Verification

**The demuxer is pure, so it carries the test weight** — and unlike most of this
app's logic, it can be tested exhaustively without a server:

- Page splitting at every offset; packets spanning 2 and 3+ pages; a 255-byte
  lacing run; a zero-length packet
- Byte-at-a-time feeding must produce the same packets as one-shot feeding —
  the property that catches most incremental-parser bugs
- Joining mid-page (every possible start offset into a known stream) recovers
  and yields all subsequent packets
- A corrupted page is skipped via CRC and the stream resyncs
- `OggS` embedded in packet payload does not cause a false resync
- Chained stream: two logical bitstreams, second with a different serial, both
  fully delivered and the boundary reported
- Truncated final page yields nothing rather than a partial packet
- Header parsing: `OpusHead` fields and `\x7fFLAC` identified and configured;
  `\x01vorbis` identified and refused with the supported-codec message

The existing hand-built Ogg Opus fixture (see appendix) is a good seed; a
generator that emits pathological pagings is better and cheap.

Device, in order:

1. Opus stream plays, and keeps playing >10 minutes without drift or dropout
2. Track changes are seamless — the chained-stream case
3. FLAC stream plays
4. Vorbis stream shows the explanatory message naming the supported codecs,
   not silence
5. mp3 stream still works — the regression that matters most
6. **Switch the server's encoder between mp3 and Opus and restart the stream from
   the same URL, with no app change** — the actual requirement
7. Lock screen metadata and transport controls still drive MPD
8. Backgrounded playback survives; a dead stream still stops cleanly
9. Phone call interrupts and recovers; headphones out pauses
10. Switching servers mid-stream stops the stream

## Appendix: building an Ogg test fixture

macOS has an Opus **encoder**; iOS only the decoder. `afconvert -f Oggf` fails
(`ExtAudioFileWrite failed ('pck?')`) — the Ogg *writer* is broken even where the
reader works — so the fixture is assembled by hand:

1. `python3` a 3 s 48 kHz stereo WAV tone.
2. `afconvert -f caff -d opus -b 96000 tone.wav tone.caf`.
3. Dump bare packets with `AudioFileReadPacketData`.
4. Wrap in Ogg pages in Python: `OpusHead` (19 bytes, family 0), `OpusTags`, then
   ~20 packets per page, granule += 960 per packet, CRC-32 as described above.
   `afinfo` should then report `Oggf`, 2 ch, 48000 Hz, opus.

This fixture belongs in the test target rather than a scratch directory, since
the demuxer tests need it permanently.
