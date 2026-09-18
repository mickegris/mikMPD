# v1.7.1 — plan overview

A bug-fix release: reports from living with v1.7, two of which asked for a review
rather than a fix. The reviews are done and are written into the plans as
numbered findings, so each fix can be traced to a line of code.

| # | Item | Plan | Needs a live server / device to verify? |
|---|---|---|---|
| 1 | Queue tab: single tap plays, like the mini-queue | [01-queue-tab-tap-to-play.md](01-queue-tab-tap-to-play.md) | Simulator only |
| 2 | Lock-screen pause felt ignored, once for ten minutes | [02-lock-screen-controls.md](02-lock-screen-controls.md) | **Device** + phone streaming |
| 3 | Transfer never changes consume / ReplayGain / crossfade on **either** partition | [03-transfer-keeps-playback-settings.md](03-transfer-keeps-playback-settings.md) | **Server** with two partitions |
| 4 | Ogg (Opus, FLAC) streaming review: buffering, lost track changes, silent stops, FLAC rates | [04-ogg-streaming-review.md](04-ogg-streaming-review.md) | **Device**; the pure parts are unit-tested |
| 5 | Crash while streaming with the screen locked | [05-background-crash.md](05-background-crash.md) | Unit test for the socket fix; the crash log confirms which cause it was |

## Version and branch

- **Version:** `MARKETING_VERSION` 1.7.0 → **1.7.1**, `CURRENT_PROJECT_VERSION`
  40 → **41**, in the Debug and Release configs of the app target in
  `mikMPD.xcodeproj/project.pbxproj`. A patch bump.
- **Branch:** `v1.7.1` off `main` (this branch), merged back with a
  `Merge v1.7.1 — …` commit.
- The bump lands first as its own commit, then one commit per item.

## The findings, briefly

**Item 1**: the Queue tab only has a double-tap handler, so a single tap falls
through to the row's first `NavigationLink`, the artist. The fix is to use the
mini-queue's `.playableRow`.

**Item 3**: v1.7 explicitly sends the **source's consume** to the target, which
is the direct cause. ReplayGain and crossfade are per partition in MPD and are
never sent. The app, however, reads ReplayGain only on connect, so after
following the music the button shows the source's value. Crossfade shows the
source's value until the next poll. Both *look* like the transfer changed them.
Fix: send none of the three, then snapshot both partitions before and after,
repair any drift and report it.

**Items 2, 4 and 5 are one evening seen three ways.** Yesterday's session had a
crash while locked, then "it just stopped playing" after ten minutes, then a
lock-screen pause held for ten minutes until unlock:

- **Crash (5)**: neither socket suppresses **SIGPIPE**. A write to a connection
  the server or Wi-Fi has reset kills the app instantly, and the background poll
  writes every 2 s while streaming. The fix is `SO_NOSIGPIPE`, two lines per
  socket, and it gets a unit test. The other candidate is the Ogg engine being
  played while iOS has stopped it (4, O4). **The crash log decides**; item 5
  says where to find it on the phone.
- **Silent stop (4)**: the Ogg player does not observe interruptions or engine
  configuration changes, has no underrun handling and no reconnect, and restarts
  the audio engine at every track change. Any of these ends in silence with the
  app still claiming to stream, or streaming switched off at the first network
  blip.
- **Pause held until unlock (2)**: ten minutes cannot be buffering. The press was
  *held*, so the app was not running. iOS suspends a background-audio app that
  has stopped producing audio, and the lock screen kept showing mikMPD because
  `playbackState` follows MPD's state rather than the phone's. The fix is
  detecting the silence (a stall watchdog) and never leaving a "playing" lock
  screen over a dead stream. Separately, a pause that *does* arrive is heard only
  after the phone's buffer runs out (up to 30 s for mp3). That is fixed by
  silencing the phone on pause and rejoining the live stream on play.

**FLAC** is always decoded as 48 kHz stereo. MPD sends the source file's rate,
so 44.1 kHz FLAC plays ~9 % fast, and the rate can change between tracks. The
fix parses `STREAMINFO`; 44.1, 48 and other rates all work.

## Decisions

Settled by you:

1. Queue rows keep their artist/album links, exactly like the mini-queue.
2. **Consume, ReplayGain and crossfade (and MixRamp) belong to the partition.**
   A transfer never changes them on the target or the source, and verifies that
   before and after.
3. FLAC plays at the source's rate (44.1, 48, …), not just 48.

Still in the plans as the default, confirm or overrule:

4. **Repeat / random / single keep travelling with the queue**, as in v1.7, so a
   shuffled playlist stays shuffled after moving. The alternative is to make them
   partition-owned too (item 3, "Open question").
5. Pausing while streaming to the phone silences it immediately; resuming
   rejoins the live stream (about 1–2 s wait).
6. The Ogg player retries a lost stream for about 15 s before giving up with a
   message.

Questions whose answers sharpen the reproduction, not the fix:

- **Item 2:** during the ten-minute wait, was the music coming from the phone,
  or from MPD's own speakers?
- **Item 4:** when it "just stopped" after ten minutes, did the "Listen on
  phone" toggle turn itself off, or stay on over silence?
- **Item 5:** the crash's `.ips` file from the phone.

## Order of work

1 → 3 → 5 → 4 → 2. Item 1 and item 3 are independent. Item 5's socket fix is
tiny and removes a crash from every later device test. Item 4 must come before
item 2, because item 2 relies on the Ogg player's `suspend()`, its played-back
timestamps and its reconnect.

## Out of scope

- Search's "Double-tap to play" footer (noted in item 1 as a follow-up).
- Lock-screen controls when *not* streaming to the phone: iOS shows none for an
  app without an active audio session. This is expected.
- Vorbis, and any codec setting in the app (unchanged from v1.7).
