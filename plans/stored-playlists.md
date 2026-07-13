# Plan: MPD stored-playlists support

Spotify-style playlist management backed by MPD stored playlists
(https://mpd.readthedocs.io/en/stable/protocol.html#stored-playlists).
Playlist browsing lives inside Library; "Add to playlist" is available from Now Playing, album,
queue, and search rows; removal/reorder happens in the playlist detail view.

## MPD protocol commands used

| Command | Purpose |
|---|---|
| `listplaylists` | List playlists (`playlist:` + `Last-Modified:` per record) |
| `listplaylistinfo NAME` | Songs with metadata (`file:` records, **no pos/id fields**) |
| `load NAME` | Append playlist to queue (already wrapped by `MPDStore.loadPlaylist`) |
| `playlistadd NAME URI` | Append URI; creates `NAME.m3u` if missing |
| `playlistdelete NAME SONGPOS` | Remove song at position |
| `playlistmove NAME FROM TO` | Reorder within playlist |
| `rename NAME NEW_NAME` / `rm NAME` | Rename / delete playlist |
| `save NAME` | Save current queue as playlist |

Compatibility: stick to baseline syntax — no `POSITION` arg on `playlistadd`/`load` and no `save`
modes (`append`/`replace`), which require MPD 0.24+. All names/URIs escaped via `.esc` and quoted,
as everywhere else. `parseMPDRecords` already treats `playlist` as a record starter
(MPDSocket.swift:256), so `listplaylists` parses with no socket changes.

## Models (Models.swift)

```swift
struct MPDPlaylist: Identifiable, Equatable {
    var name: String
    var lastModified: String   // raw ISO 8601 from Last-Modified, display-only
    var id: String { name }
}
```

Reuse `MPDSong` for playlist entries. **Gotcha:** `listplaylistinfo` returns no `pos`/`id`, so
every parsed song gets `pos = 0` and `MPDSong.id` (`"\(pos):\(file)"`) collides for duplicate
tracks → broken `ForEach`. When parsing playlist songs in the store, assign `pos = index` from
`enumerated()`.

## Store (MPDStore.swift, new "Stored playlists" section)

Follow the existing pattern: capture state on main, `Q.async` for socket I/O, refresh on main.

- `@Published var playlists: [MPDPlaylist] = []`
- `func loadPlaylists()` — `listplaylists`, sorted by name.
- `func playlistSongs(name:completion:)` — `listplaylistinfo`, assigning `pos = index`
  (mirrors `albumSongs` callback style; detail view keeps songs in `@State`).
- `func addToPlaylist(name: String, uris: [String])` — loop `playlistadd` (same loop style as
  `enqueue`). Creates the playlist implicitly on first add — this is also how "New playlist"
  works, since MPD has no create-empty command. Call `loadPlaylists()` after, so new names appear.
- `func removeFromPlaylist(name: String, at offsets: IndexSet, completion:)` — descending
  positions, `playlistdelete` each (same pattern as `delete(at:)` for the queue).
- `func movePlaylistSong(name: String, from: Int, to: Int, completion:)` — `playlistmove`.
  With SwiftUI `.onMove`, convert destination: `to = dest > from ? dest - 1 : dest`.
- `func renamePlaylist(_ old: String, to new: String)` — `rename`; refresh list.
- `func deletePlaylist(name: String)` — `rm`; refresh list.
- `func saveQueueAsPlaylist(name: String)` — `save`; refresh list.
- Extend existing `loadPlaylist(_:)` (MPDStore.swift:634) with
  `loadPlaylist(_ name: String, replace: Bool = false, play: Bool = false)` —
  optional `clear` before `load`, optional `play 0` after (mirrors `enqueue`). Keep the current
  call sites in BrowserView working (defaults preserve behavior).
- Playing one track *in context* (Spotify tap behavior): `clear` + `load NAME` + `play <index>`
  — add `func playPlaylist(name: String, at index: Int)`.

No idle/subscription support in this app (poll-based); playlist data reloads `onAppear` and after
each mutation, consistent with Library views.

## Views

### 1. Library integration

Add `case playlists = "Playlists"` to `LibTab` (LibraryView.swift:3). The segmented picker then
has 6 items and gets cramped on iPhone — switch the picker to `.menu` style, or shorten labels;
decide at implementation time. `switch tab` gains `case .playlists: PlaylistListView()`.

### 2. PlaylistListView (new file `mikMPD/mikMPD/PlaylistsView.swift`)

Mirrors `AlbumListView`: `List` over `store.playlists`, `.searchable` filter,
`onAppear { store.loadPlaylists() }`.
- Row: `Label(name, systemImage: "music.note.list")`, `NavigationLink` → `PlaylistDetailView`.
- Swipe-to-delete → confirmation dialog → `deletePlaylist` (destructive, so confirm).
- Context menu: Rename (alert with TextField → `renamePlaylist`).
- Toolbar `+`: "Save current queue as playlist" — alert with name field → `saveQueueAsPlaylist`
  (disabled when queue empty).

### 3. PlaylistDetailView

Mirrors `AlbumDetailView` structure:
- Header: `ArtThumb(song: songs.first, size: 90)`, playlist name, "N tracks · total time".
- Buttons: **Play** (`loadPlaylist(name, replace: true, play: true)`) and **Add**
  (`loadPlaylist(name)`), matching Album detail's Play/Add pair.
- Tracks section: rows reuse the `QueueRow` pattern (QueueView.swift:40) — title plus clickable
  artist/album `NavigationLink`s to `ArtistDetailView`/`AlbumDetailView`, duration. Extract a
  shared row view or a `PlaylistSongRow` clone; per-row `ArtThumb(song:, size: 40)` optional.
- Tap row → `playPlaylist(name:at:)` (play in playlist context, Spotify-style).
- Swipe trailing: **Remove from playlist** (`removeFromPlaylist`, then reload songs).
- Swipe leading: **Add to queue** (`store.add(uri:)`).
- `.onMove` (EditButton in toolbar) → `movePlaylistSong`, then reload.
- Row context menu: "Add to playlist…" (other playlist) via the shared sheet below.

### 4. AddToPlaylistSheet (shared, in PlaylistsView.swift)

One reusable sheet: `.sheet` presenting a list of `store.playlists` plus a "New Playlist…" name
field. Takes `uris: [String]`; selection calls `addToPlaylist(name:uris:)` and dismisses.
Validate new names: non-empty after trimming, reject `/` and newline (MPD playlist names are
filenames). Show a brief confirmation (e.g. checkmark) — optional.

Integration points (all pass `song.file` / album URIs):
- **NowPlayingView**: button (`"text.badge.plus"`) alongside the mode buttons row, or a toolbar
  ellipsis menu → current song. Hide/disable when `song.file` is empty or source is radio/CD
  (adding `cdda:` URIs to playlists is not meaningful; http stream URLs are allowed — they work
  in stored playlists — so radio *can* be permitted deliberately).
- **AlbumDetailView**: header context/ellipsis menu → whole album (`songs.map(\.file)`);
  per-song swipe leading or context menu → single song.
- **QueueView** rows: context menu → single song.
- **SearchView** song rows: context menu → single song.

## Edge cases

- Duplicate files in one playlist: handled by index-based `pos` (see Models).
- Deleting the last song leaves an empty `.m3u` — playlist still listed; fine.
- `Last-Modified` display is optional; keep raw string, don't parse dates initially.
- Concurrent external edits (another client): positions may shift between view load and a
  delete/move; reload after every mutation and accept last-write-wins (consistent with the rest
  of the app's poll-based design).
- Large playlists: `listplaylistinfo` fetches everything; acceptable now, `[START:END]` ranges
  exist if it ever becomes slow.

## Tests (mikMPDTests, pure logic)

- `parseMPDRecords` splits `listplaylists` output on `playlist:` keys (starter already exists —
  lock in with a test).
- Index-assignment for playlist songs (duplicate files get distinct ids).
- Playlist-name validation (trim, reject `/`, empty).
- `.onMove` destination-index conversion for `playlistmove`.

## Implementation order

1. Models: `MPDPlaylist` + song index-assignment helper.
2. Store: stored-playlists section (commands above).
3. `PlaylistsView.swift` (write to disk under `mikMPD/mikMPD/` — synchronized group picks it up).
4. `LibTab` integration.
5. `AddToPlaylistSheet` + the four integration points.
6. Tests; update CLAUDE.md conventions (playlist section).
