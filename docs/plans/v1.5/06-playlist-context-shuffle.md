# 06 — "Playing from <playlist>" after shuffling a playlist

**Request:** "Make sure it shows which playlist it plays from if you have
shuffled the playlist (by pressing the shuffle button in playlist view). It
only works if you press play in the playlist view."

> **Status: implemented.** All three parts (persist, verify, "Add" to an empty
> queue) landed, plus the playlist-list marker. Hypothesis 1 was not confirmed
> against the server — it could not be, without one — but the fix makes the
> symptom impossible under any of the four hypotheses, which is why it was worth
> doing rather than waiting for a reproduction.

## Start here: the obvious fix is already in the code

The natural assumption is that `shufflePlayPlaylist` forgot to set the context.
It does not. All three playlist entry points set it identically:

| Action | Function | Sets context |
|---|---|---|
| Play button | `loadPlaylist(name, replace: true, play: true)` | `playbackContext = name` (MPDStore.swift:1046) |
| Shuffle toolbar button | `shufflePlayPlaylist(name)` | `playbackContext = name` (MPDStore.swift:1062) |
| Tapping a track | `playPlaylist(name:at:)` | `playbackContext = name` (MPDStore.swift:1272) |

`git log -S` shows the assignment has been in `shufflePlayPlaylist` since the
function was added (c9bbe08, "Add shuffle play and shuffle queue"), so this is
not a stale build either. Nothing in `poll()`, `loadQueue()` or `play(at:)`
clears `playbackContext`; the only places that nil it are `switchToServer`,
`clearQueue`, `add`, `addAndPlay`, `playCD`, and the `replace` branches of
`enqueue`/`enqueueMatching`.

**So do not open with a code change.** Reproduce first — otherwise the "fix"
will be a line that was already there.

## Ranked hypotheses

### 1. The context is transient and the app was relaunched (most likely)

`playbackContext` is a plain `@Published var` with no persistence. It is lost
on app relaunch — including the silent relaunch after iOS reclaims a
backgrounded app — and reset by `switchToServer`. Reconnecting after a dropped
connection keeps it, but a cold start does not.

This fits the report well. Shuffling a playlist is a "set it going and leave it"
action, so the label is most often looked at *later*, after the app has been
away — whereas pressing Play is usually followed by looking at Now Playing
immediately, while the state is still alive.

**Distinguishing test:** shuffle a playlist, then check Now Playing without
leaving the app. If the label is there, this is the cause.

### 2. The **Add** button was pressed, not Play

`loadPlaylist(name)` with its defaults (`replace: false, play: false`) sets
`playbackContext = nil` explicitly. Pressing **Add** and then starting playback
some other way leaves no context at all — correctly, by the current rule, but
surprisingly when the queue was empty and now holds exactly that playlist.

### 3. The Queue tab's "Shuffle Queue" was used

`shuffleQueue()` reorders the queue in place and is reached from the Queue tab
menu, not the playlist view. It does not clear the context — so it would only
explain the report in combination with (1) or (2).

### 4. A genuine ordering defect

Least likely, and ruled out by reading, but the cheapest to confirm: in
`shufflePlayPlaylist` the inner `self.poll()` enqueues its main-thread block
*before* the outer `DispatchQueue.main.async` that assigns the context, so the
assignment lands last and cannot be overwritten. Enable More → Diagnostics and
check the command log ordering if hypotheses 1–3 are all excluded.

## The durable fix

Whichever hypothesis holds, the label is fragile for the same underlying
reason: it is remembered rather than derived, so anything that costs us the
memory costs us the label, silently and permanently — there is no path back to
"playing from X" short of starting the playlist again.

Three changes, in increasing order of cost:

### A. Persist it per server

Store `playbackContext` in UserDefaults under `playbackContext_<serverID>`,
alongside the existing per-server `recentlyPlayed_<serverID>`, with the same
didSet-persistence shape the store already uses for `servers`/`activeServerID`.
Reload it in `switchToServer`, clear it with the profile on delete. This alone
fixes hypothesis 1.

### B. Validate it against the queue

A remembered name can go stale — the queue may have been replaced from another
client entirely. On reconnect (and on the first poll after a cold start),
confirm the context still describes the queue before showing it:

- Fetch `listplaylist <name>` (URIs only — cheaper than `listplaylistinfo`).
- Compare as a **set** against the current queue's files, not as a sequence:
  after `shuffle` the order deliberately differs, which is exactly the case in
  the request. Require the queue to be a subset of the playlist (a superset
  means tracks were added afterwards; treat that as context lost).
- On mismatch, clear it.

Do this once per connection, not per poll — it is two commands, and the queue
does not silently change identity between polls.

### C. Make "Add to an empty queue" set the context

When `loadPlaylist(name)` runs with `replace: false` against an **empty** queue,
the resulting queue is exactly that playlist, so the label is accurate and
should be shown. Check `playlistLength()` — already available and cheap — before
deciding. This closes hypothesis 2 rather than leaving it as a papercut.

### Related, and worth doing with it

[04](04-current-song-highlighting.md) deliberately leaves "which playlist is
playing" out of the playlist *list*. Once the context is persisted and
validated, marking that row in `PlaylistListView` is two lines and completes the
same thought: the app knows what it is playing from, so every view that lists
playlists should say so.

## Tests

Offline, on the pure parts:

- Queue-vs-playlist validation: identical sets in a different order → still
  valid (**the shuffle case**); a strict subset → valid; an extra track in the
  queue → invalid; disjoint → invalid; empty playlist → invalid.
- Persistence roundtrip per server ID, and that deleting a profile removes it.

## Needs live verification

Everything above the pure helpers, and the reproduction itself:

1. Shuffle a playlist → check Now Playing **immediately** (isolates hypothesis 1).
2. Force-quit and relaunch → check again (confirms hypothesis 1).
3. Press **Add**, then play from the queue → check (confirms hypothesis 2).
4. After the fix: shuffle, background the app for several minutes, return — the
   label survives; then replace the queue from another client — the label goes.
