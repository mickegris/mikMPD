# 2 — Lock-screen play/pause

## The report

> Not completely sure play/pause etc on lock screen work as it should. Yesterday
> I pressed pause, nothing happened, then I unlocked the screen and it paused.

Clarified, with a second occurrence:

> When I was done listening I tapped pause on the lock screen and waited for like
> 10 minutes (opus stream) and nothing happened. Directly when I unlocked the
> screen it paused.

That same day: the app crashed while locked (item 5), and after the restart
"I listened for about ten minutes and then it just stopped playing" (item 4).

## What the 10-minute case rules in and out

- **It is not buffering (F1 below).** No player holds ten minutes of a live
  stream. F1 is real, and it explains a pause that takes seconds to be heard. It
  cannot explain this one.
- **"Directly when I unlocked" means the command was *held*, not lost.** A
  command lost to a dead socket (F2) would never pause MPD, not even on unlock.
  Nothing in `refreshOnForeground` sends a pause. The pause therefore ran at
  unlock, which means **the handler did not run until the app was running
  again**.
- **The app was suspended (F6).** iOS keeps a background-audio app running only
  while it is *actually producing audio*. The Ogg player can stop producing
  audio while the app still believes it is streaming: the engine is stopped by
  an interruption or a configuration change (item 4 O4), or the stream has died.
  iOS then suspends the app. The lock screen keeps showing mikMPD, because
  `nowPlayingInfo` and `playbackState = .playing` are still set. A press on that
  stale widget is held by the system and delivered when the app next runs,
  which is at unlock. That fits every detail, including "it just stopped
  playing" earlier the same day, which is the same silent death seen from the
  other side.

  **A caveat on this theory.** iOS normally *does* wake a suspended app that
  owns the lock screen's Now Playing slot, in order to deliver a remote command.
  That is how a paused Spotify resumes from the lock screen. So "suspended"
  alone would not hold a press for ten minutes. Suspension combined with what
  the app finds on waking fits better. By then MPD has closed the idle
  connection (`connection_timeout`), the handler's `pause 1` fails silently
  (F2), or the write hits the reset socket and dies of SIGPIPE (item 5). At
  unlock, a fresh connection and poll then show a state that makes it *look*
  as if the pause landed at that moment. Either way, the fixes are the same:
  detect the silence (0), reconnect-then-send (2), `SO_NOSIGPIPE` (item 5), and
  log it so the next occurrence explains itself (4).

  **This matters for the new pause behaviour too.** Once pausing closes the
  stream (change 3), a paused app *will* be suspended by iOS, correctly and
  by design, and every lock-screen "play" will arrive on a woken app with a
  dead MPD socket. Reconnect-then-send is therefore a requirement, not a
  nicety, and must be verified on a device after at least 2 minutes paused and
  locked.

  **To confirm (question for you):** during those ten minutes, was the music
  coming **from the phone** (headphones or speaker) or from MPD's own speakers?
  If it was audibly from the phone, the app cannot have been suspended, and the
  next suspect is `Q` being blocked. Socket I/O is bounded at 5 s, so that would
  be a new bug.

## Scope

Lock-screen, Control Center and headphone controls exist **only while streaming
to the phone**. `setupRemoteCommands()` is called from `startPhoneStream()` and
torn down in `stopPhoneStream()`. iOS shows these controls only for an app that
holds an active audio session, and without phone streaming this app holds none.
The report must therefore have come from a phone-streaming session. Everything
below is about that path.

## Review findings

Code: `MPDStore.swift`, `setupRemoteCommands()` (≈2502) and
`updateNowPlayingInfo()` (≈2569).

### F1 — The phone keeps playing its buffer after MPD pauses (the first report: seconds, not minutes)

A remote pause sends `pause 1` to MPD, and MPD pauses. The phone is a *listener*
on MPD's httpd output, though, and its player holds audio that MPD has already
sent:

- mp3 (AVPlayer): `item.preferredForwardBufferDuration = 30`. AVPlayer can hold
  many seconds of a live stream, up to 30.
- Ogg: every scheduled buffer plays out (see item 4 for why that can grow).

So you press pause, MPD pauses, and the music carries on from the phone's
buffer. That is "nothing happened". While paused, MPD's httpd output keeps
clients connected by sending encoded silence, so the phone eventually drains its
buffer and goes quiet. That is "then it paused". The unlock is very likely just
when the buffer happened to run out. **Resume has the mirror problem**: the
phone plays out stale buffered audio (or silence) before it reaches the live
point.

The in-app pause button has the same latency. It is less noticeable there
because the UI flips immediately.

### F2 — Commands fail silently and report success

```swift
center.pauseCommand.addTarget { @Sendable _ in
    q.async { _ = try? sock.command("pause 1") }
    return .success
}
```

If the socket is down (a background poll hit an I/O error, and the 3 s reconnect
has not landed yet), `command` throws `notConnected`, `try?` swallows it, and
iOS was already told `.success`. Nothing retries. This is a secondary cause of
"nothing happened", and nothing records it, so it cannot be told apart from F1
afterwards.

### F3 — The handlers bypass the store

They talk to the socket directly, so there is no optimistic state, no
`stateLockUntil` and no `updateNowPlayingInfo()`. The lock-screen glyph and
`playbackState` stay wrong until the next background poll (2 s), and until
then a second press sends the same command again.

### F4 — Toggle is state-blind

`togglePlayPauseCommand` sends a bare `pause`, which MPD ignores when the player
is *stopped*. A headphone button press on a stopped queue does nothing.

### F5 — No record of remote commands

`MPDCommandLog` records the MPD command but not that it came from the lock
screen. The next "nothing happened" will be just as undiagnosable as this one.

### F6 — A silent stream leaves a live-looking lock screen, and the app gets suspended (the 10-minute report)

`updateNowPlayingInfo()` publishes `playbackState` from **MPD's** state
(`isPlaying`), not from whether the phone is producing sound. When the Ogg
player dies silently (item 4 O4/O5), the lock screen goes on saying "playing".
iOS stops running the app because no audio is being produced, and every
lock-screen press waits until you unlock. Nothing in the app notices that the
phone has gone quiet.

## Changes

### 0. Never present a dead stream as playing (F6)

Most of this lands with item 4. Listed here because it is what fixes the
10-minute report:

- **Detect silence, don't infer it.** `OggStreamPlayer` records when it last had
  a buffer *played back* (the `.dataPlayedBack` completion from item 4 A). A
  pure `oggStreamStalled(lastPlayedBack:now:state:)` is true when the state
  claims `.playing` but nothing has been played back for more than 3 s. The
  background poll (every 2 s, on `Q`) asks the player, and a stall is handled as
  a transient failure: item 4's bounded reconnect (D), then `.failed` → stop
  phone streaming. The same check makes `isStreamActuallyRendering` truthful.
- **Stop claiming playback when there is none.** When phone streaming ends for
  any reason, `tearDownRemoteCommands()` already sets `.stopped` and clears the
  info. The fix is to make sure a dead stream actually *reaches*
  `stopPhoneStream()`, which the stall check does. While reconnecting, publish
  `playbackState = .interrupted`, so the lock screen does not show a confident
  "playing".
- Engine stops from interruptions and configuration changes are observed
  (item 4 C), so the common causes of a silent death go away as well as being
  detected.

The result: the app is either producing audio, and therefore running, so
lock-screen presses act immediately; or it has stopped streaming and cleared the
lock screen, so there is no stale widget to press.

### 1. Route remote commands through the store, on main

```swift
center.pauseCommand.addTarget { @Sendable [weak self] _ in
    guard let self else { return .commandFailed }
    DispatchQueue.main.async { self.handleRemote(.pause) }
    return .success
}
```

`MPDStore` is MainActor-isolated and therefore `Sendable`, so a weak capture in
a `@Sendable` closure compiles under Swift 6. MediaPlayer calls these handlers
on the main thread in practice, but the `@Sendable` + hop pattern stays
(CLAUDE.md → "SDK callbacks that run off-main"). It costs nothing, and a trap
here would be a crash on the lock screen.

`handleRemote(_:)` maps each command to the same store method the in-app button
calls, so both paths share one implementation:

| Remote command | Store call |
|---|---|
| play | `play()`, a new explicit method (not the toggle) |
| pause | `pause()`, new, explicit |
| togglePlayPause | `togglePlay()`, which is state-aware: stopped → `play` (fixes F4) |
| next / previous | `next()` / `previous()` |

The explicit `play()`/`pause()` matter because a lock-screen "pause" must never
become a resume just because local state was stale. Each sets the optimistic
state and the 0.5 s state lock exactly as `togglePlay()` does, then calls
`updateNowPlayingInfo()` at once (fixes F3).

`togglePlay()`'s stopped case: today it sends `pause` whenever `!playing`. It
needs to send `play` when neither `isPlaying` nor `isPaused` is set.

### 2. Reconnect-then-send (F2)

A small Q-side helper, `sendEnsuringConnection(_ cmd:)`: if
`!socket.connected`, attempt one synchronous `socket.connect(host:port:password:)`
with the values captured on main, then send the command. It runs on Q, so it
cannot race the poll. If it still fails, hop to main and call the existing
`scheduleReconnect()` rather than stacking a new retry loop. Only remote
commands use it; the in-app buttons keep today's behaviour. The value of this is
on the lock screen, where the user cannot see the red banner.

The partition must be restored after such a reconnect, so run the helper through
the existing partition-restore logic. **Do not** duplicate `connect()` here: call
the Q-side body that `connect()` uses, if it can be factored out cleanly. Decide
this during implementation. If factoring is messy, fall back to
`scheduleReconnect()` plus return `.commandFailed`, which at least stops
reporting false success.

### 3. The phone follows MPD's play state immediately (F1)

A new store method, `phoneStreamFollow(playing: Bool)`, is called:

- directly from `play()`/`pause()`/`togglePlay()`/`stop()` while
  `isPhoneStreaming`, so it happens at press time, not a poll later;
- from the poll when it observes a play→pause/stop or pause→play transition made
  by *another client*, detected by comparing with the previous state.

Behaviour:

| Transition | AVPlayer (mp3) | OggStreamPlayer |
|---|---|---|
| → paused/stopped | `pause()`, then `replaceCurrentItem(with: nil)`, which drops the buffer | `suspend()`: stop the node and drop scheduled buffers, keep the phone stream "on" (item 4 adds this) |
| → playing | new `AVPlayerItem` for the stream URL, then `play()`: joins at the live point | `start(url:)` again: joins at the live point |

`isPhoneStreaming` stays **true** throughout. The toggle means "the phone is a
speaker for this server", not "audio is coming out right now". The session stays
active while paused. That is correct: iOS keeps an audio app that is paused
from its lock screen as the Now Playing app. `handleEnteringBackground()` must
therefore treat *suspended because MPD is paused* as a legitimate state and not
stop the stream. Add a `phoneStreamSuspended` flag that `isStreamActuallyRendering`
treats as rendering.

Why reconnect rather than un-pause: a paused live stream resumes behind the live
point by the length of the pause. For an httpd listener that is never what you
want, since MPD is the clock.

The cost: resume takes as long as a fresh stream start (AVPlayer about 1–2 s on
a LAN, Ogg the start threshold). That is the same wait as pressing the toggle
today, and far better than 30 s of the wrong audio.

### 4. Log remote commands (F5)

When the diagnostics log is enabled, record `remote: pause` (etc.) in
`MPDCommandLog` before dispatching, with an outcome of `socket down →
reconnecting` when that path is taken. It is cheap, and the next report comes
with evidence.

## Tests (unit, no device)

- `remoteCommandAction(for:isPlaying:isPaused:)`, a pure function in Models.swift
  returning the MPD command. Pins: toggle when stopped → `play`, toggle when
  playing → `pause 1`, toggle when paused → `pause 0`, pause when already paused
  → `pause 1` (idempotent, never resumes).
- `phoneStreamTransition(from:to:)`, pure: returns `.suspend` / `.resume` /
  `.none` for each MPD state pair; pause→stop is `.none`, stop→play is
  `.resume`.
- Extend `PhoneStreamTests` so the new `addTarget` closures are invoked on a
  background queue, as the existing regression test already does for the old
  ones. They must not trap.

## Device verification (TESTING.md additions)

Streaming mp3, then Opus:

- [ ] lock the phone, press pause → silence within ~0.5 s, and the lock-screen
      glyph flips at once;
- [ ] press play → music within ~2 s, at MPD's current position (compare with
      another client), not where the phone stopped;
- [ ] pause from another client (e.g. `mpc pause`) → the phone goes silent
      within one background poll (~2 s);
- [ ] stop MPD from another client, then press the headphone button → playback
      starts (F4);
- [ ] Wi-Fi off for 10 s while locked, back on, press pause → it works, and the
      diagnostics log shows the reconnect;
- [ ] pause for 5 minutes on the lock screen, then play → resumes. By then iOS has
      suspended the app and MPD has dropped the idle socket, so this exercises
      the wake + reconnect-then-send path end to end, and it must not crash
      (item 5);
- [ ] energy: while paused and locked, no stream bytes are received (Xcode's Network
      gauge stays flat, because the app is suspended).
- [ ] F6: Opus streaming, locked; kill the stream from the server side without
      closing the socket cleanly (disable the httpd output, or pull the MPD
      host's network cable) → within ~15 s the lock screen either recovers or
      clears. It never keeps showing "playing" over silence, and a press on it
      is never held until unlock.

## Docs

CLAUDE.md → "Phone streaming": update the lock-screen-controls bullet. The
closures no longer capture `Q`/`socket`; they hop to the store. Add a paragraph
on the pause/resume-follows-MPD rule and why it reconnects rather than
un-pausing.
