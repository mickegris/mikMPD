# v1.7 — plan overview

Two features and the release chores. They share nothing technically — one is a
sequence of MPD commands, the other an audio pipeline — so they can be done in
either order, by different hands, without conflict.

| # | Item | Plan | Live MPD server needed to verify? |
|---|---|---|---|
| 1 | Transfer the queue between partitions (Roon-style) | [01-transfer-queue-between-partitions.md](01-transfer-queue-between-partitions.md) | **Yes** — two partitions with outputs, and it moves real playback |
| 2 | Ogg phone streaming (Opus, FLAC) | [02-opus-phone-streaming.md](02-opus-phone-streaming.md) | Demuxer: **no** — pure and fully unit-testable. Playback: yes, plus a **real device** |

## Version and branch

- **Version:** `MARKETING_VERSION` 1.6.0 → **1.7.0**, `CURRENT_PROJECT_VERSION`
  → **40**, both Debug and Release configs in `mikMPD.xcodeproj/project.pbxproj`.
  Two user-facing features, no breaking change: a minor bump, as v1.6 was.
- **Branch:** `v1.7` off `main`, then a `Merge v1.7 — …` commit, matching
  v1.5 through v1.6.
- The bump lands first as its own commit, so the feature commits read alone.

## What the probes settled before any code was written

Item 2 looked like it needed an Ogg demuxer *and* libopus, ending the "no
external dependencies" invariant that has held since v1.0. Probing the iOS 26.2
simulator settled where the real line falls:

1. **iOS has a native Opus decoder, and it is documented.** `kAudioFormatOpus`
   and `kAudioFormatFLAC` are declared in the public `CoreAudioBaseTypes.h`, and
   both appear in `kAudioFormatProperty_DecodeFormatIDs`.
2. **It decodes real packets correctly** — 151 bare Opus packets → 144,840
   frames (3.02 s @ 48 kHz), peak 0.407, matching the encoded tone.
3. **No magic cookie is required.** Apple's Opus cookie is a 28-byte blob with
   no published layout; decoding with **no cookie at all**, driven only by a
   fully specified ASBD, gives byte-identical output. Every ASBD field is
   documented — so the undocumented cookie is designed out, not depended on.
4. **iOS does parse Ogg itself** — `AudioFileStream` extracted 151/151 packets,
   even with no type hint — but `AudioFile.h` declares no Ogg type, so this is
   unpromised behaviour. **Deliberately unused.** If it is not documented, it
   does not exist; Apple can withdraw it in a point release.
5. **There is no Vorbis decoder, at all** — `vorb` is absent from the decodable
   list and "Vorbis" appears nowhere in the iOS 26.5 SDK headers — which is why
   it is out of scope rather than pending.

So the demuxer is ours and the codec is Apple's, with nothing third-party and
nothing undocumented in the path. **FLAC falls out for free** — same container,
documented decoder. Supported codecs end up being mp3, Opus and FLAC, and the
app says so rather than leaving it to be discovered.

The fixture-building recipe is in
[02](02-opus-phone-streaming.md#appendix-building-an-ogg-test-fixture); the
scratch files are session-local and will not survive.

## Decisions taken

- **Transfer is a move, as in Roon** — the source partition ends empty and
  stopped. No copy variant; "transfer" means the music is in one place
  afterwards, and offering both would make the common case a choice.
- **Its entry point is Now Playing**, in the partition dialog, and it stays one
  confirmed tap. Outputs & Partitions gets a secondary entry, not the primary.
- **Phone streaming exposes no codec setting.** The encoder is MPD's
  configuration; the app detects and adapts at each stream start and persists
  nothing about it. Changing the server's encoder must need no action in the app.
- **The Ogg container is parsed by our own demuxer**, not by the undocumented
  system parser — a deliberate rejection of working-but-unpromised behaviour.
  The decoder stays Apple's, because that part *is* documented.
- **Vorbis is out of scope.** No iOS decoder exists and vendoring libvorbis is
  not worth it for a codec Opus supersedes. It is identified and refused with a
  message naming what does work.
- **The supported codecs are stated in the app** — in the server form beside the
  Stream URL, and again in the failure message — so the answer is available
  before and after something goes wrong.
- **The transfer's stored playlist is ephemeral** — uniquely named per transfer,
  removed on every exit path, swept on connect if orphaned, and never shown in
  the Playlists list.

## What the two items have in common

Very little, which is the useful part — they touch disjoint code:

| | Item 1 | Item 2 |
|---|---|---|
| Store surface | queue/partition commands on `Q` | phone-streaming section |
| New files | none | `OggDemuxer.swift` + a stream player |
| Risk | server-side state in **two** partitions | audio session, background playback |
| Existing hazard to respect | `plans/move-active-output-hang.md` | "Nothing runs on termination" |

Neither touches views the other does: item 1 lands in `OutputsView` and Now
Playing's partition dialog, item 2 behind the existing "Listen on phone" toggle.

## Out of scope

- Transferring between *servers* (item 1 is partitions on one MPD instance;
  cross-server would mean re-resolving every URI against a different database).
- Ogg Vorbis playback, and the libvorbis dependency it would require. It is
  demuxed and identified so the user gets a reason rather than silence, but not
  decoded. (Ogg **FLAC** *is* in scope: same container, documented decoder.)
- Replacing `AVPlayer` for mp3. It works, it handles stalls and buffering, and
  swapping it out for a pipeline we maintain is a regression risk with no user
  benefit — see item 2's "Why not one pipeline for everything".
- Any app-side control over the stream's codec, bitrate or format. That is
  mpd.conf's job; the app's job is to play whatever comes down the wire.
