# Plan: Recently Played as an album grid (Roon/Spotify style) — NOT YET APPROVED

Status: **design only** — the user hasn't decided whether to go this route. Do not
implement without a go-ahead.

## Idea

Replace (or complement) the current track list in `RecentlyPlayedSheet` with a grid of
recently played **albums**: cover art tiles, album title + artist beneath, tap navigates
to the album page — the Roon/Spotify "recently played" shelf.

## Key decision: derive albums, don't record them

Keep `RecentlyPlayedRecorder`, the per-track `RecentlyPlayedEntry` storage, retention, and
per-server persistence exactly as they are. The album view is a **pure derivation** over
the existing track history:

```swift
nonisolated struct RecentAlbum: Identifiable, Equatable {
    var artist: String
    var album: String        // raw tag of the newest entry (detail view self-expands discs)
    var lastPlayed: Date
    var id: String           // artCacheKey(artist:album:) — disc variants collapse for free
}

/// Newest-first album groups from track history. Entries without an album tag
/// (radio streams, loose files) group by file instead so they still get a tile.
nonisolated func recentAlbumGroups(_ entries: [RecentlyPlayedEntry]) -> [RecentAlbum]
```

Why derivation wins:
- **Reversible.** If the grid turns out worse than the list, nothing was lost — the
  track data is untouched. It also allows an Albums/Tracks segmented toggle later.
- Grouping key = `artCacheKey(artist:album:)`, so "X [Disc 1]" and "X [Disc 2]" already
  collapse into one tile with one cover — no new multi-disc handling.
- No migration: existing persisted history just renders the new way.

Grouping rules (all testable):
- Key: `artCacheKey`; empty-album entries key on `file` and display `title` with the
  source-appropriate fallback art (`RadioFallbackArt` for streams via `sourceKind`).
- One tile per key, `lastPlayed` = newest entry's `playedAt`, order newest-first.
- The representative `album`/`artist` come from the newest entry (raw tag — the album
  page strips markers itself).

## UI (RecentlyPlayedSheet, NowPlayingView.swift)

- `ScrollView` + `LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)])`.
- Tile: `ArtThumbByKey(artist:album:size: ~110).cornerRadius(8)`, album line
  (`.subheadline`, 2-line limit), artist line (`.caption`, secondary), relative time
  (`.caption2`).
- **Tile tap = NavigationLink to `AlbumDetailView(album:artist:)`** — the sheet already
  wraps a `NavigationStack`, so the album page (and its artist/wiki links) pushes inside
  the sheet. Disc variants land on the merged multi-disc page automatically.
- Album-less tiles (radio/loose files) aren't albums — tap replays via
  `store.addAndPlay(uri:)` instead of navigating.
- Context menu per tile (with the standard footer hint, per the long-press convention):
  "Play Album" (`albumSongs` → `enqueue(replace:true, playFirst:true)`), "Add Album to
  Queue", "Add Album to Playlist…".
- Keep: Clear button, Done, empty state, `presentationDetents([.medium, .large])` —
  though the grid breathes better opened straight to `.large`.

### Open choice for the user

1. **Albums only** (what was asked): grid replaces the track list entirely. Replaying one
   specific *track* from history is then two taps (tile → track) instead of one.
2. **Albums + Tracks segmented picker** in the sheet: default to Albums, keep the track
   list one tap away. Costs ~10 lines; recommended if losing per-track replay feels bad.

## Tests (mikMPDTests, pure)

- `recentAlbumGroups`: dedupes same album across many tracks (newest `lastPlayed` wins);
  disc variants collapse to one group; distinct artists with the same album title stay
  separate; empty-album entries group by file and preserve title; newest-first ordering;
  empty input.
- `RecentAlbum.id` equals the art cache key (tile art and grouping can't diverge).

## Effort / risk

Small: one pure function + tests, one view restructure; recorder, storage, and store
untouched. Main UX risk is losing one-tap track replay (mitigated by option 2) and tiles
without local/MusicBrainz art showing placeholder covers — same fallback behavior as the
Library, just more visually prominent in a grid.
