# v1.7.1 — plan overview

A bug-fix release: four reports from living with v1.7, two of which asked for a
review rather than a fix. The reviews are done and are written into the plans as
numbered findings, so each fix can be traced to a line of code.

| # | Item | Plan | Needs a live server / device to verify? |
|---|---|---|---|
| 1 | Queue tab: single tap plays (Spotify-style) | [01-queue-tab-tap-to-play.md](01-queue-tab-tap-to-play.md) | Simulator only |
| 2 | Lock-screen play/pause felt ignored | [02-lock-screen-controls.md](02-lock-screen-controls.md) | **Device** + phone streaming |
| 3 | Queue transfer must not change consume / ReplayGain / crossfade | [03-transfer-keeps-playback-settings.md](03-transfer-keeps-playback-settings.md) | **Server** with two partitions |
| 4 | Ogg (Opus) phone streaming review — buffering, a crash, lost track changes | [04-ogg-streaming-review.md](04-ogg-streaming-review.md) | **Device**; the pure parts are unit-tested |

## Version and branch

- **Version:** `MARKETING_VERSION` 1.7.0 → **1.7.1**, `CURRENT_PROJECT_VERSION`
  40 → **41**, in the Debug and Release configs of the app target in
  `mikMPD.xcodeproj/project.pbxproj`. No new features, so this is a patch bump.
- **Branch:** `v1.7.1` off `main` (this branch), merged back with a
  `Merge v1.7.1 — …` commit, as for v1.5 to v1.7.
- The bump lands first as its own commit, then one commit per item.

## What the reviews found, in one paragraph each

**Item 2** is probably not a dropped command. A remote pause reaches MPD, but
the phone still holds whatever its player has buffered. For mp3,
`preferredForwardBufferDuration = 30` lets AVPlayer hold up to 30 s. MPD pauses,
and the phone keeps playing until that buffer runs out, which reads as "nothing
happened". Two real defects make it worse. The handlers fire and forget with
`try?`, and they return `.success` even when the socket is down. They also
bypass the store, so the lock-screen glyph stays wrong until the next 2 s poll.

**Item 3**: crossfade and ReplayGain mode are **per-partition** in MPD, and the
transfer carries neither. After the app follows the music to the target, you
hear and see the *target's* settings. It looks intermittent because it only
shows when the two partitions differ. On top of that, the app reads ReplayGain
mode once per connection, so after a transfer or a partition switch the
ReplayGain button shows a value that no longer applies. `single oneshot` (and
0.24's `consume oneshot`) collapse to "off" in transit.

**Item 4**: the Ogg player has **no underrun handling**. It buffers 0.5 s once,
at start, and never again, so every network hiccup after that is a hard dropout
instead of a rebuffer. It **tears down and restarts the audio engine at every
track boundary**, because MPD's Opus encoder starts a new chained bitstream per
song. That throws away buffered audio and makes the next song start from zero,
which is the "failed to play next song". It also corrupts the buffer counter.
The **crash** is most likely `AVAudioPlayerNode.play()` on an engine that iOS
has stopped: interruptions and configuration changes stop the engine, and
nothing observes either.

## Decisions taken in the plans (confirm or overrule)

1. **Queue tab rows keep their artist/album links**, exactly as the Now Playing
   mini-queue does. A tap on the row plays; a tap on the underlined text still
   navigates. The alternative, Spotify's plain rows with navigation only in the
   context menu, is described in item 1 and is a one-line change if preferred.
2. **"Must not change" means what you heard before the transfer is what you hear
   after.** Consume, ReplayGain and crossfade (plus repeat/random/single and
   MixRamp) are copied from the source to the target, and the source is left as
   it was. The other reading, "never touch the target's settings", would make a
   transfer *change* what you hear whenever the partitions differ. That is the
   symptom being reported.
3. **Pausing while streaming to the phone silences the phone immediately**, and
   resuming reconnects to the live stream rather than playing out a stale
   buffer. The lock screen and the in-app buttons get the same fix, because the
   latency is the same.
4. **The Ogg player reconnects on its own** (bounded, with backoff) when the
   server closes the stream or the network blips, instead of ending phone
   streaming at the first `.idle`. It gives up with a message after the retry
   budget. That keeps v1.7's rule that the toggle never shows "Streaming" over
   silence indefinitely.

## Shared ground

Items 2 and 4 both touch the phone-streaming section of `MPDStore` and
`OggStreamPlayer`. Do **4 before 2**: item 2's "flush on pause, reconnect on
play" needs the Ogg player to have a pause/flush entry point, and item 4 is
where that player's lifecycle gets rewritten. Items 1 and 3 are independent of
everything else.

## Out of scope

- Search's "Double-tap to play" footer. The same Spotify argument applies, but
  it was not reported, and Search rows carry more actions. It is noted in item 1
  as a follow-up.
- Lock-screen controls when *not* streaming to the phone. iOS shows controls only
  for an app that holds an active audio session, so without phone streaming
  there is nothing to show. This is expected, not a bug.
- Vorbis, and any codec setting in the app (unchanged from v1.7).
