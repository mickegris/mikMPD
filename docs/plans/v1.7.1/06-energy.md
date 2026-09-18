# 6 — Energy: the whole app redraws ten times a second

## The evidence

`mikMPD.cpu_resource-2026-09-15-223125.ips` (iCloud Drive). This is not a crash
report. It is iOS's **CPU resource report** (`bug_type 202`, "Action taken:
none"):

```
CPU:     90 seconds cpu time over 158 seconds (57% cpu average),
         exceeding limit of 50% cpu over 180 seconds
Energy:  93.77 mWh     Power Source: 35 samples on Battery
Primary state: 35 samples Frontmost App … Thread QoS User Interactive
Num threads: 1         (all of it on the main thread)
```

The build was 1.7.0 (40) **Debug**. The matching `mikMPD.debug.dylib` (UUID
`30D40497-…`) was still in DerivedData, so the report symbolicates exactly:

| Samples (of 35) | Frame |
|---|---|
| 35 | SwiftUI update cycle on the main run loop |
| 7 | `AlbumListView.body` → `AlbumListView.groups.getter` (LibraryView.swift:87–102) |
| ~20 | under it: `groupAlbumVariants`, `albumGroupingKey` (Models.swift:131–139, eight `replacingOccurrences` each), `albumBaseAndDisc` (two regex matches), `collapsingCompilations`, `AlbumGroup.groupingKey` |
| several | `AlbumGroupRow.isPlaying` → `isCurrentAlbum` → `albumGroupingKey` for the row **and** for the current song, per row, per render |
| several | `NowPlayingView.body` / `connectionStatus` |

The phone spent 2.5 minutes, on battery, recomputing the entire album grouping
(all ~820 albums: regexes, eight string replacements each, a sort) inside
`body`, many times a second.

## Why it re-renders that often

1. **`elapsed` is `@Published` on `MPDStore`, and the display timer sets it at
   10 Hz** (`tickElapsed`). `ObservableObject` has one `objectWillChange` for the
   whole object, so every one of the **29 views holding `@EnvironmentObject var
   store`** is invalidated ten times a second. That includes every visible
   `AlbumGroupRow`, and `AlbumListView`, whose body rebuilds `groups` from
   scratch. Only the seek bar, the time labels and the lyrics pane actually read
   `elapsed`.
2. **`bitrate` changes on almost every poll** (VBR), so even with (1) fixed, the
   whole app would still re-render at 1 Hz while playing.
3. **`groups` is a computed property evaluated in `body`**, so each invalidation
   pays for the full grouping, not just a diff.
4. **`isCurrentAlbum` re-derives both grouping keys per row per render.** The
   current song's key is the same for every row and changes once per track.
5. **The display timer keeps running in the background** while phone streaming
   keeps the app alive. `setDisplayTimerActive(isPlaying)` looks only at MPD's
   state, so a locked phone publishes `elapsed` ten times a second to a UI no
   one can see. The lock screen does not need it, because the system
   extrapolates from `playbackRate`.
6. **`updateNowPlayingInfo()` rebuilds the whole dictionary every poll**,
   including a new `MPMediaItemArtwork`. That means once a second in the
   foreground and every 2 s in the background. The system only needs it when the
   song, the state or the position (a seek) changes.

The report came from a Debug (`-Onone`) build, which exaggerates the cost per
evaluation several times over. The *number* of evaluations is the same in
Release, though. The waste is real, only smaller.

## Changes

### E1 — Take the fast-changing values out of `MPDStore`'s change stream

A small `@MainActor final class PlaybackClock: ObservableObject` owns
`@Published elapsed`, `bitrate` and `audioFmt`, plus the 10 Hz display timer.
`MPDStore` holds it as `let clock` and injects it with
`.environmentObject(store.clock)`. Only the views that show these values observe
it: the seek bar and time labels, the lyrics pane (`activeLyricLine`), and the
audio-format line. **`MPDStore.elapsed` stays as a forwarding property** for
reads from store code (seek, transfer capture, now-playing info), so call sites
outside those views do not change.

The seek lock, the poll's "only assign on change" rule and `tickElapsed` move
with it unchanged. This is a mechanical move, not a redesign.

*Why not migrate `MPDStore` to `@Observable`, which would give per-property
tracking everywhere?* It would, and it is the right long-term fix. It touches
all 29 environment-object sites, every `$store.x` binding and the `didSet`
persistence, which is too much for a patch release. It is noted as the follow-up
plan. E1 removes the 10 Hz and 1 Hz sources today, with a small diff.

### E2 — The display timer runs only when someone can see it

`PlaybackClock` ticks only when **all** of these hold: MPD is playing, the scene
is `.active`, and at least one clock-observing view is on screen. That last one
is a reference count bumped in `onAppear`/`onDisappear` of the seek bar and the
lyrics pane. In the background, or on the Library tab, the timer is off and
`elapsed` is updated by the poll alone. When the Now Playing tab reappears, the
seek bar resumes from the last polled value and ticks on. That is the same as
after a pause today.

### E3 — Grouping is computed when its inputs change, not in `body`

`AlbumListView`: `groups` becomes `@State private var groups: [AlbumGroup]`,
recomputed by one `recomputeGroups()` called from `.onChange` of `albums`,
`filter`, `albumSort`, `discMap` and `compilations` (and after load). `body`
only reads it. Filter typing still recomputes once per keystroke, which is fine.

Audit and apply the same to every view that builds groups or sorts inside
`body`: `GenreDetailView`, `RecentlyAddedView` (`AddedAlbum` derivation),
`ArtistListView` (sort), the Search album collapsing, and `RecentlyPlayedSheet`
(`recentAlbumGroups`). A grep for computed `var …: [` in view files is the
starting point. `AlbumListView.groups`/`shown` and `PlaylistListView.shown` are
the known ones.

### E4 — Grouping keys are computed once

- `AlbumGroup` stores `groupingKey` at construction (`let`, set in
  `groupAlbumVariants`, which already computes it as part of its map key)
  instead of a computed property that re-runs the regexes on every access.
- `MPDStore` publishes `currentAlbumKey` (and `currentGroupingArtist`),
  recomputed in the poll **only when `songid` changes**, which is where
  `currentsong` is already refetched.
- A new `isCurrentAlbum(rowKey:rowArtist:compilationBase:currentKey:current:)`
  overload compares precomputed keys. The existing functions stay and delegate
  to it, so their tests keep pinning the semantics. Rows (`AlbumGroupRow`, grid
  tiles, Recently Added/Played, Search) pass `group.groupingKey` and
  `store.currentAlbumKey`.
- `albumGroupingKey`'s eight `replacingOccurrences` passes become one pass over
  the unicode scalars with a small switch. It is a pure function with existing
  tests, so the rewrite is pinned. Worth doing only because it runs ~820 times
  per recompute.

### E5 — Lock-screen info is set on change, not every poll

`updateNowPlayingInfo()` is called when the song, the play state, the duration
or the artwork changes, or after a seek. It is no longer called from every poll.
The `MPMediaItemArtwork` is built once per song and cached. Elapsed stays
correct between calls because the system extrapolates from
`MPNowPlayingInfoPropertyPlaybackRate`, which is how the API is meant to be
used.

## Energy rules for the rest of v1.7.1

The user asked that none of this release's fixes cost battery. The other plans
are held to these rules, and each plan names how it complies:

1. **No new timers.** Anything periodic rides on a timer that already exists.
   Item 2's stall check uses the existing 2 s background poll. Item 3's
   before/after check is a handful of commands per *transfer*, not per poll.
2. **Event-driven over polling.** Interruptions, route changes and engine
   configuration changes are notifications. Remote commands are callbacks.
3. **Bounded retries.** Item 4's reconnect is four attempts over ~15 s, then it
   stops. Item 2's reconnect-then-send is one attempt per user press. No retry
   loop runs unattended in the background.
4. **Stop the radio when there is nothing to hear.** Today a paused MPD makes
   httpd send encoded silence, and the phone receives, decodes and plays it
   indefinitely, keeping Wi-Fi and the audio hardware busy. Item 2's `suspend()`
   closes the stream while MPD is paused, so a paused phone uses **no** network
   or audio power. This is the largest single energy win in the release for
   phone-streaming users.
5. **Fewer, larger audio buffers.** Item 4 coalesces decoded Opus packets into
   ~100 ms buffers before scheduling them. Today every 20 ms packet is its own
   `scheduleBuffer` plus a completion dispatch: 50 wakes a second, which drops
   to 10.
6. **Nothing runs at 10 Hz in the background** (E2).
7. **Diagnostics stay free when off.** Any new logging (items 2, 3) goes through
   `MPDCommandLog`, whose disabled path is a single flag check.

## Tests

- `PlaybackClock` tick gating as a pure function:
  `displayTimerShouldRun(isPlaying:sceneActive:observers:)`, which is false in
  the background, false with no observers, and true only with all three.
- `AlbumGroup.groupingKey` stored equals `albumGroupingKey(base)` for the
  existing fixtures, including the en-dash Beatles case and the disc-marker cases.
- `isCurrentAlbum` precomputed-key overload agrees with the existing function
  across all existing `isCurrentAlbum` test cases (table-driven: run both, assert
  equal).
- `albumGroupingKey` single-pass rewrite: the existing tests unchanged, plus one
  per folded character.
- A performance test (`measure`-style, via `ContinuousClock` in Swift Testing):
  grouping 1,000 synthetic album pairs stays under a generous bound. It is not
  there to benchmark, only to catch an accidental return to per-render cost.

## Verification

On a device, **Release build** (Product → Scheme → Edit Scheme → Run → Build
Configuration → Release, or an archive):

- [ ] Xcode → Debug Navigator → **CPU**, Albums tab open while music plays: idle
      CPU near 0–2 %, not a sawtooth at 10 Hz. Compare against v1.7.0 on the
      same screen.
- [ ] **Energy Impact** gauge: "Low" on the Albums tab while playing, and on Now
      Playing with lyrics open.
- [ ] Instruments → **SwiftUI** template, 10 s on the Albums tab while playing:
      `AlbumListView.body` is evaluated only on data changes, not ~100 times.
- [ ] Locked and phone streaming (Opus), 10 minutes: Xcode's Energy report
      shows no 10 Hz main-thread activity; lock-screen elapsed still advances
      smoothly.
- [ ] MPD paused with phone streaming on: network activity drops to the 2 s poll
      only (no stream bytes).
- [ ] Seek bar and synced lyrics are exactly as smooth as before on Now Playing.

## Docs

CLAUDE.md → "Dual-timer design": the display timer now lives in `PlaybackClock`,
is observed only by the views that show time, and runs only while
foreground-visible. State the reason: a 10 Hz `@Published` on the store
re-rendered all 29 observing views, and a CPU resource report caught the Albums
list recomputing its grouping at that rate. Add a Conventions bullet: **no
derived collections computed in `body`**; compute them into `@State` on input
change.

## Follow-up (not in this release)

Migrate `MPDStore` to `@Observable`, for per-property invalidation everywhere.
It gets its own plan and a minor version.
