# 04 — Highlight the playing song in every view it appears in

**Request:** "Current playing song should be highlighted in all views the song
exists in."

> **Status: implemented.** Parts A–D all landed, including album-level marking,
> which winrmpc had deferred. The plan's read was right: the position-vs-URI
> rule was already correct in all eight views that highlighted, so the visible
> problem was presentation, not matching — only the Queue tinted its row, and
> five row types drew their own marker at different sizes. Search's album rows
> were added beyond the plan's list, since they show albums too.

`../winrmpc/docs/plans/current-song-highlighting.md` is this feature, already
designed and shipped there. This plan follows it, adjusted for what mikMPD
already has — which is more than winrmpc had at the same point.

## What already works

| View | Rule used | Where |
|---|---|---|
| Queue tab | queue **position** | QueueView.swift:16, row tint at :19 |
| Now Playing queue pane | queue **position** | NowPlayingView.swift (`queuePane`) |
| Album detail | `file` | LibraryView.swift:292 |
| Playlist detail | `file` | PlaylistsView.swift:161 |
| Search (songs) | `file` | SearchView.swift:117 |
| Browser (files) | `path` | BrowserView.swift:10 |
| Radio | `station.url == currentSong.file` | LibraryView.swift:604 |
| Recently played (tracks) | `file` | NowPlayingView.swift:674 |

So the position-vs-URI distinction is, by luck or by care, already correct
everywhere. What is missing is the *rule being written down*, consistency of
presentation, and the album-level case.

## Gaps

1. **No shared helper.** Three row types (`QueueRow`, `SongRow`, `SearchRow`)
   plus `BrowserRow` each hand-roll `speaker.wave.2.fill` with a different
   font, a different position in the row (leading in the queue, trailing
   elsewhere), and only the queue tints the row background. Nothing stops the
   next view from comparing the wrong field.
2. **`pos` is a live trap.** In `PlaylistDetailView` the row's `pos` is the
   *playlist* index, unrelated to `store.playlistPos`. It happens to compare
   `file` today; winrmpc asserts this exact bug in a test
   (`a_playlist_row_at_the_playing_queue_position_does_not_match_by_position`)
   because it is the failure mode that produces **wrong** highlighting rather
   than missing highlighting.
3. **No empty-file guard.** With nothing loaded, `store.currentSong.file` is
   `""`. No library row has an empty path today, so this is latent rather than
   live — but the guard belongs in the helper, not in each caller's head.
4. **No album-level highlighting.** Albums list and grid, Artist detail, Genre
   detail, Recently Added, and Recently Played (Albums mode) never mark the
   album the playing track belongs to.
5. **CD view** rows are plain `Track N` labels with no row state, while Radio
   has it. `cdda:///N` URIs compare fine — this is just unfinished.

## The fix

### A. One helper, in `Models.swift`, pure and `nonisolated`

```swift
/// A library-listing row matches the playing track by **URI**.
/// Never by position: outside the queue, a row's `pos` is either absent or
/// means something else entirely — in a stored playlist it is the playlist
/// index, unrelated to `status.song`. Matching on position there lights up an
/// arbitrary unrelated row.
nonisolated func isCurrentTrack(file: String, currentFile: String) -> Bool {
    !file.isEmpty && file == currentFile
}

/// A **queue** row matches by position: a queue can legitimately hold the same
/// file twice, and only the position distinguishes the two entries.
nonisolated func isCurrentQueueRow(pos: Int, playlistPos: Int) -> Bool {
    pos >= 0 && pos == playlistPos
}
```

Put the doc comment on the helper, not in a plan — that is what makes the rule
discoverable from a call site.

### B. One presentation

A `NowPlayingIndicator` view (or a `.nowPlayingRow(_:)` modifier) owning the
glyph, its tint and its size, used by all four row types. Keep the two existing
placements — the queue replaces the track number with the glyph, everything
else puts it before the duration — but let one place decide what the glyph *is*.

Add the row-background tint (`Color.accentColor.opacity(0.12)`) to the other
lists too; today only the queue has it, and in a long album the trailing glyph
alone is easy to miss.

### C. Album-level highlighting

The interesting half, and the reason winrmpc landed it as a second pass.

The comparison is **not** `album == album`. A row on screen shows the
disc-collapsed base name, so a playing *Disc 2* track must light up the single
collapsed row:

```swift
/// True when `current` is a track from this album row. Compares the
/// disc-collapsed, artist-scoped grouping key, so a playing "X [Disc 2]"
/// marks the single collapsed "X" row. False when either side has no album,
/// which is what stops a radio stream (no album tag) marking every
/// untagged album at once.
nonisolated func isCurrentAlbum(rowArtist: String, rowAlbum: String,
                                current: MPDSong) -> Bool
```

Key it exactly as the lists already group — `albumGroupingKey` for the album
half, lowercased artist for the other — because CLAUDE.md's standing rule is
that every site using `albumGroupingKey` must agree or a row will not find its
own data. Use the song's `groupingArtist` (and, after
[02](02-artist-identity-fallbacks.md), the same fallback the rows display) so a
compilation track matches its albumartist row.

Apply to: `AlbumGroupRow` and the grid tile in `AlbumListView`, `ArtistDetailView`,
`GenreDetailView`, `RecentlyAddedView`, and `RecentlyPlayedSheet`'s album tiles.
On a grid tile the title alone is too subtle at that density — give the cover an
accent border as well.

### D. CD view

`CDView`'s rows compare `track.path` (a `cdda:///N` URI) to
`store.currentSong.file` through the same helper.

## Deliberately not doing

- **Auto-scrolling lists to the playing track.** The Now Playing queue pane
  already centres itself, and that is enough. Unconditional autoscroll is
  exactly what makes the lyrics pane unreadable — see
  [05](05-lyrics-sync-scroll-toggle.md), which is about undoing one. If a jump
  is wanted later, make it a button, as winrmpc did with `JumpToCurrent`.
- **Marking which stored playlist is playing** in the playlist *list*. That is
  playback context, not track identity — see
  [06](06-playlist-context-shuffle.md).

## Accepted consequences

- **The same file twice in one album or playlist highlights both rows.** Correct
  under a URI rule, rare, and not worth complicating the rule for. Assert it in
  a test so it stays a decision rather than becoming a surprise.
- **A stopped player still highlights.** MPD keeps a current song when stopped
  and the queue already behaves this way; the transport controls communicate
  play/pause/stop. Consistency with the existing view beats the distinction.

## Tests (all offline)

- `isCurrentTrack`: match, non-match, and **both files empty → false**.
- `isCurrentQueueRow`: match; and the trap — a playlist row whose `pos` equals
  `playlistPos` but whose `file` differs must **not** match by URI.
- The same file at two queue positions is distinguished by position.
- `isCurrentAlbum`: a playing `X [Disc 2]` matches a row for `X`; the same album
  title under a different artist does **not**; a song with an empty album
  matches nothing; punctuation variants (`1967-1970` vs `1967–1970`) match,
  proving it goes through `albumGroupingKey`.

## Needs live verification

Play a track, then open the album, the playlist containing it, a search that
returns it, and the browser folder holding it — the same row marked in all
four, and no other row anywhere. Then check the Albums grid marks exactly one
tile, and that playing a radio stream marks none.
