# Plan: Recently Played (Spotify/Roon-style)

## Constraint: MPD has no playback history

The MPD protocol (through 0.24) exposes only current state (`status`/`currentsong`) — no
history command. So history must be recorded **client-side** from the existing 1 s poll
(and the 2 s background poll while phone-streaming, which runs the same `poll()` path), and
it only captures what plays while the app is connected. That matches how other MPD clients
do it; note the limitation in the UI copy if desired.

## Recording: pure, testable reducer + store hook

**Reducer (Models.swift, `nonisolated`, unit-testable without a server):**

```swift
nonisolated struct RecentlyPlayedEntry: Codable, Identifiable, Equatable {
    var file, title, artist, album: String
    var playedAt: Date
    var id: String { "\(file)|\(playedAt.timeIntervalSince1970)" }
}

/// Commits a song to history once it has played ~30s continuously
/// (or half its duration for very short tracks), Spotify-style.
nonisolated struct RecentlyPlayedRecorder {
    private var file = ""; private var accumulated: TimeInterval = 0
    private var lastTick: Date?; private var committed = false
    mutating func tick(song: MPDSong, isPlaying: Bool, now: Date) -> RecentlyPlayedEntry?
}
```

Rules:
- Accumulate **wall-clock deltas between ticks** while `isPlaying` and the file is
  unchanged (poll cadence differs 1 s / 2 s, so counting ticks would be wrong; cap a single
  delta at ~5 s to survive suspended-app gaps).
- Commit once per continuous play when `accumulated >= min(30, max(5, duration/2))` —
  short jingles still register, skipped-after-5-seconds tracks don't.
- File change resets everything (an uncommitted song was skipped — drop it). Pause stops
  accumulation but keeps progress. Empty `file` (stopped) resets.
- Radio streams keep one file for hours → exactly one commit per listening session, which
  is right. Repeat-one commits each replay — accurate history, leave it.

**Store hook (MPDStore.swift):** in the poll's main-thread block, next to the existing
`songChanged` handling at MPDStore.swift:420, call
`if let e = recorder.tick(song: song, isPlaying: isPlaying, now: Date()) { pushRecent(e) }`.
`pushRecent` prepends, prunes (see Retention), and persists.

**Partitions: deliberately ignored.** One history list per server, no per-partition keys.
This falls out of the design for free: the poll's `status`/`currentsong` only ever reflect
the partition the app is currently tuned to, so history simply records "what I saw
playing" regardless of which partition it came from — which is the point ("nice to see
what you played recently"). Switching partitions mid-song reads as a file change and
resets the recorder (the interrupted song just doesn't commit unless it already had its
30 s). Inherent limitation, worth knowing but not fixing: playback in a partition the app
is *not* viewing is invisible to the poll and never recorded.

**Retention:** keep it recent, don't archive forever. A pure helper applied on every
insert *and* on load-from-disk (so stale lists shrink at startup too):

```swift
nonisolated func prunedRecentHistory(_ entries: [RecentlyPlayedEntry], now: Date,
                                     maxAge: TimeInterval = 30 * 86_400,
                                     cap: Int = 100) -> [RecentlyPlayedEntry]
```

- Drop entries older than 30 days, then trim to the 100 newest — whichever bites first.
- Constants live in one place; no settings UI for this (sane defaults over knobs) unless
  asked later.

**Persistence — per server profile**, since history is meaningless across servers: JSON in
UserDefaults under `recentlyPlayed_<activeServerID>` (same didSet-persist pattern as
`mpdServers`). `@Published var recentlyPlayed: [RecentlyPlayedEntry]`. Load in `init` and
in `switchToServer` (which already resets server-specific state); delete the key when a
profile is deleted (alongside its Keychain password cleanup); reset the recorder on
switch/disconnect so a half-accumulated song can't leak across servers.

## UI: header button + sheet

Now Playing's control stack (songInfo → phoneStreamToggle, NowPlayingView.swift:69-77) has
no vertical room left on small phones, so an inline horizontal strip is out. Follow the
add-to-playlist pattern instead:

- **Button** in the Now Playing header (NowPlayingView.swift:42-51), leading side next to
  `addToPlaylistButton`: icon `clock.arrow.circlepath`, presents a sheet.
- **`RecentlyPlayedSheet`** (new view in NowPlayingView.swift), `presentationDetents([.medium, .large])`:
  - `List` of `store.recentlyPlayed`: `ArtThumbByKey(artist:album:size: 44)` +
    title/artist + relative timestamp (`Text(entry.playedAt, style: .relative)` reads
    "3 min ago"-ish and self-updates).
  - Tap → `store.addAndPlay(uri: entry.file)` (works for library files, streams, and cdda
    URIs alike). Trailing swipe → `store.add(uri:)` ("Add", green, matching album detail's
    swipe). Leading swipe → Add to Playlist via `AddToPlaylistRequest` (skip for
    `sourceKind == .cd`, same rule as NowPlayingView.swift:89).
  - Toolbar: "Clear" (destructive) empties the current server's history.
  - Empty state: `ContentUnavailableView("Nothing Played Yet", systemImage: "clock.arrow.circlepath")`.

Rows show what was in the tags at play time (no re-query of the server), so entries whose
files have since vanished still render; `addAndPlay` on one just yields an MPD ACK that's
already swallowed like other playback commands.

## Alternatives rejected

- Inline "Recently played" carousel under the transport controls (closest to Spotify's
  home) — no vertical space; Now Playing already overflows small screens.
- Putting history in the Library tab — user asked for it in Now Playing; can be linked
  from Library later since the sheet is a standalone view.
- MPD stickers for server-side history — write-heavy, only works on servers with sticker
  DB enabled, and other clients' plays still wouldn't be captured anyway.

## Tests (mikMPDTests, pure)

- Recorder: commits at 30 s of accumulated play; half-duration rule for a 20 s track;
  no second commit while the same file keeps playing; skip-before-threshold then file
  change → no commit; pause freezes accumulation; large tick gap is capped; empty file
  resets; stop→play of the same file commits again.
- `RecentlyPlayedEntry` Codable roundtrip (matches existing `SavedStation`/profile tests).
- `prunedRecentHistory`: newest first; trims to 100; drops >30-day-old entries; both
  limits together; empty input.
