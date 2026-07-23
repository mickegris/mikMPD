# Energy optimization plan

## Goal

Reduce battery drain without degrading UX. All changes are invisible to the user.

## Identified waste (pre-optimization)

| Source | Rate | When | Issue |
|--------|------|------|-------|
| Display timer | 0.1 s (10 Hz) | Always while connected | Woke CPU 10×/s even when paused; `tickElapsed()` guarded `isPlaying` but timer still fired |
| Poll timer | 1 s | Always while connected | Sent 2 MPD commands/s regardless of play state |
| `currentsong` command | every poll | Always | Fetched full song metadata every second even when song hadn't changed |
| `elapsed` @Published | every poll | Always | Assigned even when value was identical (spurious SwiftUI re-renders when paused) |

## Items implemented (2026-07-23, commit TBD)

### 1 — Stop display timer when not playing ✅

`setDisplayTimerActive(_ active: Bool)` invalidates/recreates the 0.1 s `Timer`.  
Called from `poll()`'s main-thread block each cycle: `setDisplayTimerActive(self.isPlaying)`.

- **Playing**: timer runs at 10 Hz (unchanged)
- **Paused/stopped**: timer is nil — zero CPU wakes from display updates

The display timer starts running on connect (first poll ≤1 s away corrects it immediately if
not playing). On resume from pause the timer is recreated within one poll cycle (≤3 s in paused
mode, ≤1 s if play was detected by the poll).

### 2 — Throttle poll timer when paused/stopped ✅

`setPollingInterval(_ interval: TimeInterval)` tears down and re-creates the poll `Timer` only when
the target rate changes. Called each poll cycle: `setPollingInterval(isPlaying ? 1.0 : 3.0)`.

- **Playing**: 1 s (unchanged)
- **Paused/stopped**: 3 s — 67 % fewer MPD connections and main-thread dispatches

UX impact: if someone presses play on another MPD client while this app is paused, the app catches
up within ≤3 s. Acceptable; this is the same window as the reconnect delay.

### 3 — Skip `currentsong` when song ID unchanged ✅

`poll()` now parses `songid` from the `status` response first. If `sid == lastSongID`, it reuses
the cached `lastSong` (`nonisolated(unsafe)`, only touched on Q) instead of sending a second
command.

- **Song changes**: still fetches `currentsong` and updates `lastSong` + `lastSongID`
- **No song change**: saves one MPD round-trip per poll — during normal playback this is every
  single poll (songs last minutes, polls are every second)

### 3b — Guard `elapsed` from spurious @Published updates ✅

Changed `self.elapsed = elapsed` → `if self.elapsed != elapsed { self.elapsed = elapsed }`.  
When paused, MPD always returns the same elapsed value; the old code assigned it unconditionally,
triggering unnecessary SwiftUI diffing every poll cycle.

## Items ruled out (no action needed)

- **TCP socket**: kept open between polls — cheaper than reconnecting
- **BG poll timer (2 s)**: already only runs during active phone streaming
- **Snapcast poll (2 s)**: only runs while SnapcastView is visible
- **Network caches**: album art, Wikipedia, LRCLIB all already cached aggressively
- **Lock screen updates**: 1 s cadence with system interpolation via `playbackRate` — correct

## Items deferred (potential future work)

- **Per-tab poll pause**: when the user hasn't touched the app in N minutes, could drop to 5 s even while playing (for background lock-screen-only usage). Adds complexity; deferred.
- **MPD idle command**: instead of polling, use MPD's `idle` command to receive push events. Eliminates all polling overhead but requires a second connection and significant architecture change.
