# 5 — Crash while streaming with the screen locked

## The report

> Yesterday I listened with lock screen on and it suddenly just crashed (on wifi).

The phone was streaming Opus, locked and on Wi-Fi, and nothing was being
touched. So the crash came from something the app does unattended in the
background:

| Runs unattended while locked | Where |
|---|---|
| background MPD poll every 2 s | `startBgPollTimer` → `poll()` on `Q` |
| the Ogg pipeline | `OggStreamPlayer` (URLSession → demuxer → converter → engine) |
| the 3 s reconnect after a poll failure | `scheduleReconnect` → `connect()` |
| lock-screen metadata once per poll | `updateNowPlayingInfo` |

## Step 0 — get the crash report

**Update 2026-09-18:** there is no report from that day on the phone, so the
cause cannot be confirmed. C1 and C2 are both fixed in this release anyway. If
the crash recurs on 1.7.1, the report is what to look for, as described below.
(The one report that was found is a CPU resource report from 2026-09-15. It is
not a crash, and item 6 covers it.)

Where to find a report if it recurs:

**Settings → Privacy & Security → Analytics & Improvements → Analytics Data**,
entries starting `mikMPD-` (a crash has no `cpu_resource` in its name). Open one, share it (AirDrop or Mail to
yourself), and drop the `.ips` in the repo root or paste it. Or, with the phone
plugged in: Xcode → Window → Devices and Simulators → the phone → **View Device
Logs**.

What to look for in it:

| In the report | Means |
|---|---|
| `"signal":"SIGPIPE"` / `Terminated due to signal 13` | **C1**, the socket write below |
| `NSInternalInconsistencyException` … `player started when engine not running` / `_engine->IsRunning()` | **C2**, the Ogg engine (item 4, O4) |
| `EXC_BREAKPOINT` in `dispatch_assert_queue` / `swift_task_isCurrentExecutor` | an actor-isolation trap in an SDK callback (the class `PhoneStreamTests` guards) |
| `0x8badf00d` | watchdog: the main thread blocked |
| `jetsam` / an `.ips` of type `JetsamEvent` rather than a crash | memory, and a candidate for item 4 O6 (unbounded buffering) |

## C1 — SIGPIPE from writing to a dead socket (strongest candidate without the log)

Neither socket protects against SIGPIPE. `MPDSocket.send` and
`SnapcastSocket.send` call `Darwin.send(fd, …, 0)`, and nowhere in the project
sets `SO_NOSIGPIPE` or ignores the signal:

```
$ grep -rn "SIGPIPE\|NOSIGPIPE\|MSG_NOSIGNAL" mikMPD/    → nothing
```

On Darwin, `send()` on a TCP connection that the peer has reset delivers
**SIGPIPE**, and its default action is to **terminate the process**, instantly
and with no Swift error. The error path the code is written for, `n <= 0 →
throw MPDError.io`, is never reached.

Why the locked, streaming case is where it happens:

- Only while phone streaming does the app keep its MPD connection open in the
  background (`handleEnteringBackground`), and the background poll writes
  `status` to it every 2 s, unattended, for as long as you listen.
- Anything that resets that connection sets up the kill. Examples: a Wi-Fi power
  save or roam, the router dropping a NAT entry, MPD restarting, MPD's
  `connection_timeout` after a missed poll, or MPD closing a client it thinks is
  stuck. The first `send` after the reset (the next poll, at most 2 s later) is
  fatal.
- The same applies to a lock-screen command (item 2) sent on that socket, and to
  the Snapcast socket while the Snapcast screen is open.

In the foreground this is rarer: the app disconnects on background and
reconnects on resume, so a stale socket is seldom written to. That fits "it
crashes while locked" rather than while in use.

### Fix

In both `openTCP` implementations (MPDSocket.swift ≈159, SnapcastSocket.swift
≈220), next to the timeouts:

```swift
var on: Int32 = 1
setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
```

`send` then fails with `EPIPE`, which the existing `n <= 0` path already turns
into `MPDError.io` → `disconnect()` → the poll's reconnect. It is a two-line
change per socket. A per-socket option is preferred to
`signal(SIGPIPE, SIG_IGN)` process-wide, which would also change behaviour for
every framework in the process.

Also make `send` report `errno` (`"send failed (errno=\(errno))"`), as
`readLine` already does, so the command log can tell `EPIPE` from a timeout.

### Test

This one is unit-testable without MPD. In a test, open a loopback listener on
an ephemeral port, connect an `MPDSocket` to it through a tiny fake that sends
`OK MPD 0.24.0\n`, then have the fake `close()` with `SO_LINGER` 0 (a reset).
Call `command("status")` twice. **Before** the fix the test process dies with
SIGPIPE, which the test runner shows as a crash. That makes it a real
regression test: it cannot pass by accident. **After** the fix it must throw
`MPDError.io` and leave `connected == false`. The same test runs against
`SnapcastSocket`.

## C2 — The Ogg engine played while stopped

`AVAudioPlayerNode.play()` on an engine that iOS has stopped raises an
Objective-C exception that Swift cannot catch. Item 4 (O4) covers why this can
happen: interruptions and engine configuration changes are not observed. It
also covers the fix: the `engine.isRunning` guard before every `play()`, plus
the observers. Locked and on Wi-Fi, the likely triggers are a notification or
Siri interrupting, a Bluetooth or AirPlay change, or iOS reconfiguring the
hardware.

## C3 — Memory (only if the log is a jetsam event)

Item 4 O6: nothing bounds how much decoded audio is scheduled. Each second is
384 KB of Float32 stereo, so a large backlog is plausible after a long stall on
a locked phone. Item 4's `maxFrames` cap fixes it.

## Plan of record

1. No `.ips` from the crash exists, so ship the fixes for the known candidates
   and watch for a recurrence.
2. Land C1 regardless. It is a real crash path even if it was not *this* crash,
   and it costs two lines per socket.
3. C2 and C3 land with item 4.

## Docs

CLAUDE.md → Architecture → MPDSocket: add that sockets set `SO_NOSIGPIPE`, and
why (a reset connection otherwise kills the app on the next write, and the
background poll writes every 2 s while streaming). Mention it in the Snapcast
transport paragraph too.
