# 2 — Lock-screen play/pause

## The report

> Not completely sure play/pause etc on lock screen work as it should. Yesterday
> I pressed pause, nothing happened, then I unlocked the screen and it paused.

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

### F1 — The phone keeps playing its buffer after MPD pauses (most likely cause)

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

## Changes

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
- [ ] pause for 5 minutes on the lock screen, then play → resumes; the stream was
      not torn down by `handleEnteringBackground`.

## Docs

CLAUDE.md → "Phone streaming": update the lock-screen-controls bullet. The
closures no longer capture `Q`/`socket`; they hop to the store. Add a paragraph
on the pause/resume-follows-MPD rule and why it reconnects rather than
un-pausing.
