# 1 — Songs: every track A–Z in the Library

[Issue #14](https://github.com/mickegris/mikMPD/issues/14). Requested:

- a **Songs** section alongside Albums, Artists, Recent, Genres …
- every track sorted A–Z by title (owner: **default A–Z, switchable to Z–A**)
- the usual song actions: tap to play, Add Next, Add to Queue, Add to Playlist
- works on older MPD, specifically **0.21.11** (Chord Poly)
- owner: **must not crash or wedge the app on a large library**; chip placed
  **directly right of Recent**; no artwork; pre-0.21 gets a message only

## What can go wrong on a large library, concretely

Each of these has bitten this app before, in a different view:

| Risk | Mechanism | How this plan avoids it |
|---|---|---|
| MPD drops the connection | One response larger than MPD's `max_output_buffer_size` (**8 MiB default**, same in 0.21.11 — `ClientGlobal.cxx`) makes MPD close the client. The app sees an I/O error, disconnects, and the 3 s reconnect re-issues the query: a loop. `listallinfo` is exactly this, and the protocol docs say of it: *"It will break with large databases."* | Paged `find … window`, 1000 songs per page (~350 KiB) |
| Poll / controls starve | A long loop inside one `Q.async` block holds the socket queue; this is what "Play All" on a large artist did before `findadd` | **One `Q.async` per page**, so the 1 s poll and user commands interleave between pages |
| Main-thread hang / energy | Sorting or filtering in `body` re-runs on every store change (the v1.7.1 CPU report: 57 % CPU regrouping albums at 10 Hz) | Sort once, off-main, on load; filter on input change only; list state in its own `ObservableObject`, not `@Published` on the store |
| Memory | Holding the whole DB client-side | Bounded: ~10.5 k songs here; hard cap (below) with a clear message beyond it |

## Measured on the live server (0.24, 10,488 songs)

Read-only probes over a plain TCP socket:

| Query | Result |
|---|---|
| `count "(file != '')"` | 10,488 songs, 5 ms |
| `find "(file != '')" window a:a+1000`, all 11 pages | **10,488 files, all unique, 3.8 MiB, 85 ms total** (worst page 9 ms) |
| same with `sort Title` | complete and unique too, but 168 ms total — MPD sorts the whole DB for every page |
| `count "(title == '')"` | 9 untitled songs |
| `find … sort Title` order | **byte order** — lowercase and non-ASCII initials after Z (see overview) |

So the whole library fits in one short burst of small pages, and a
server-side sort buys nothing because its order is unusable anyway.

## MPD 0.21.11 compatibility, checked against its source

- `find` with a filter expression — 0.21 (NEWS: *"new filter syntax for
  find/search etc. with negation"*). `(file != '')` parses: `Filter.cxx` at tag
  `v0.21.11` accepts `!=` and routes `file` to `UriSongFilter`.
- `window START:END` on `find` — 0.20 (NEWS: *"search/find have a window
  parameter"*); present in `DatabaseCommands.cxx` at `v0.21.11`.
- `count FILTER` — long-standing; filter-expression form is 0.21.
- **Not used**: `TitleSort` (0.24), `list … window` (unreleased), `sort` at all.

**Page order without `sort`.** The docs call it "undefined"; in practice it is
the database traversal order, which is what `findadd`'s "Play All" ordering
already relies on (CLAUDE.md, "Bulk enqueue"). The app does not *trust* it: it
dedupes by URI and checks the total against `count` (below).

### Why one syntax path, not "newer syntax when available"

Asked by the owner. Every newer feature that touches this view was checked, and
none earns a second code path:

| Newer feature | Version | Why it doesn't help |
|---|---|---|
| `find … sort Title` | 0.21 | Byte order, **also on 0.24** (measured) — unusable for A–Z |
| `TitleSort` tag | 0.24 | Falls back to Title and sorts with the same byte comparison |
| `list title … window` | 0.25, **unreleased** | Returns titles only, no file URIs — rows could not be played |
| `stringnormalization` | 0.25, unreleased | Affects filter matching, not sorting |
| `tagtypes clear` / `enable` to shrink pages | **already in 0.21.11** (`ClientCommands.cxx`) | Not version-gated at all. Measured: 3.81 → 2.90 MiB, **24 % smaller**, 102 → 69 ms. But tag visibility is per *connection*, and the poll's `currentsong` shares the socket between pages, so each page would need `clear`/`enable`/`find`/`all` in one Q block, and a failure between them hides tags from everything else until reconnect. Not worth 0.9 MiB. |

A version-switched path also has a cost of its own, learned from Recently
Added: the live server is 0.24 and would always take the new path, so the 0.21
path — the one the reporter runs — would only ever execute on someone else's
server. One path that works on 0.21 means the path tested here is the path the
Chord Poly runs. Revisit if a future MPD adds a collation-aware sort.

**Older than 0.21** (filter expressions ACK): show "The Songs view needs MPD
0.21 or newer" — the same stance as Recently Added. No legacy fallback; nothing
in the issue asks for pre-0.21.

## Design

### Loading (`MPDStore`, Q-side)

`loadSongCatalog()`:

1. `count "(file != '')"` → `total`. Over the cap → stop with the too-large
   message (no pages fetched).
2. Page `find "(file != '')" window N:N+1000`, **each page its own `Q.async`**,
   re-dispatched from the previous one's completion. Parse to `MPDSong`,
   drop empty `file`, dedupe by URI. Publish progress (`loaded`/`total`) to the
   catalog object on main after each page.
3. A page that returns fewer rows than asked ends the walk. If the unique count
   ≠ `total` (library updated mid-walk), **restart once**; if it still
   disagrees, keep what arrived — a song or two off is not worth a loop.
4. Off-main (still on `Q`, it is one-shot work): compute each row's sort key
   and sort **once**. Hand the sorted array to main.

Guards, following `loadRecentlyAdded`: an in-flight flag so reappearing does not
start a second walk; a **generation** stamped at start and checked per page, bumped
by `connect()`, `disconnect()` and `switchToServer`, so a walk against the old
server can never land in the new one's list. Stops early if `socket.connected`
turns false (an ACK is not the only failure mode).

**Cap:** `songCatalogLimit = 100_000`. That is ~35 MiB of transfer at the
measured ~350 B/song; beyond it the view says the library is too large for the
Songs list and points to Search. Named constant, one place to change.

### Where the data lives

A new `SongCatalog: ObservableObject` owned by the store (`store.songCatalog`,
same pattern as `PlaybackClock`), holding `state` (`.idle / .loading(loaded,
total) / .loaded([CatalogSong]) / .tooLarge(Int) / .unsupported / .failed`).
Why not `@Published` on `MPDStore`: progress changes ~11 times per load and the
store's single `objectWillChange` would re-render every view observing it —
the exact v1.7.1 energy lesson. Only `SongListView` observes the catalog.

Why cache at all: `LibraryView` rebuilds the chip's view on every chip switch,
so view-local `@State` would re-download 3.8 MiB each time the user glances at
Albums and back.

**Changed during implementation:** the cache is keyed on server **and**
`stats`' `db_update`, not on the connection. `connect()` runs on every
foreground resume, so a per-connection cache would re-download the library
after every unlock. Each visit sends one `stats` (a few lines); an unchanged
`db_update` means the list in memory is current — which also catches scans by
other clients or while the app was backgrounded, which watching `isUpdatingDB`
would miss. The list is dropped on a server switch (`SongCatalog.reset()`) and
on a memory warning while Songs is not on screen. A walk in flight is abandoned
when `connect()`/`disconnect()` bump a Q-only walk ID. It reloads lazily on the
next appearance, never proactively.

### Sorting and sections (pure, Models.swift, unit-tested)

- `songTitleSortKey(_:)` — `displayTitle` (so the 9 untitled songs sort by
  filename, not all at one end) with **leading non-alphanumerics stripped**:
  `“Heroes”` files under H, `...And the Mouse Police` and `…and Justice for All`
  under A, `(Don't Fear) The Reaper` under D. Leading "The" is **kept** — the
  Artists list does not strip it either, and "The Wait" under W would surprise
  more people than it helps.
- Comparator: `localizedStandardCompare` on the precomputed keys (case- and
  locale-aware; in a Swedish locale Å Ä Ö come after Z as they should; also
  orders "Track 2" before "Track 10"). Ties broken by artist, then URI, so the
  order is total and stable across reloads.
- Keys are computed once per row, never inside the comparator.
- **Z–A is the reversed array**, not a second sort.
- Sections: first character of the sort key, uppercased; anything that is not a
  letter → `#`. Sections are built by **walking the sorted array and starting a
  new section when the label changes**, so section order always agrees with the
  comparator whatever the locale does with Æ or 荒 — derived, not assumed.
  (A label that recurs non-adjacently gets a unique id; tests pin this.)

### The view (`SongListView`, LibraryView.swift)

- `LibTab` gains `case songs = "Songs"`, symbol `music.note`, **inserted
  directly after `.recentlyAdded`** as the owner asked (Albums, Artists, Recent,
  Songs, Genres, …). This deliberately breaks the
  CLAUDE.md rule "new tabs append rather than insert"; inserting is safe
  because the selected chip is plain `@State`, never persisted by index or raw
  value. CLAUDE.md's LibraryView paragraph is updated to say so (owner approved changing the rule).
- Loading: a `ProgressView(value: loaded, total: total)` with "Loading 4,000 of
  10,488 songs…". Header when loaded: "10,488 songs".
- `List` with one `Section` per letter and an **A–Z section index** for fast
  scrolling: iOS 26's `sectionIndexLabel` / `listSectionIndexVisibility`
  (verify the exact API when implementing; fallback is a letter menu in the
  toolbar driving a `ScrollViewReader`). With 10 k rows the index is what makes
  the view usable rather than merely correct.
- Sort menu in the toolbar (`arrow.up.arrow.down`), same look as Artists:
  A–Z / Z–A, persisted in `@AppStorage("librarySortSongs")`, a `SongSort` enum in
  Models.swift (convention: cycled enums live there with their labels).
- `.searchable` filter ("Filter songs…") over title, artist and album —
  in memory, recomputed on input change with a short debounce, never in `body`.
- Row: title, then `artist · album` on the second line, duration on the right,
  `NowPlayingMarker` via `isCurrentTrack` (by URI). **No artwork**: 10 k
  thumbnails would each resolve a track and hit the art pipeline while
  scrolling; the energy cost is not worth it in a text index. `SongRow` gets a
  `showsTrackNumber`/subtitle option rather than a second row type.
- Actions, copied from `AlbumDetailView.trackRows` so every song list behaves
  alike:
  - **tap** → `.playableRow { store.addAndPlay(uri:) }`
  - swipe trailing → Add (green), Add Next (orange)
  - swipe leading → Playlist (indigo) → `AddToPlaylistSheet`
  - context menu → Add Next, Add to Queue, Add to Playlist…, **Go to Album**,
    **Go to Artist** (the last two have no swipe equivalent, but are also
    reachable from Now Playing once the song plays — same exemption logic as
    Search)
  - hint text (convention): "Tap to play. Long press or swipe to add to the
    queue, play next, or add to a playlist." — shown **above** the list, since a
    footer after 10 k rows is never seen.

### Added after first review: filter scopes

Owner request: a filter row choosing the field: a segmented **All / Title /
Artist / Album** row at the top of the Songs list (`SongFilterScope` in
Models.swift; not persisted). Artist matches either the track artist or the
album artist. It first shipped as `.searchScopes`; see below for why it moved.

### Added after device testing: filter fields across the Library

A screen recording showed the filter field vanishing from every chip after
Songs (search active) → Recent → Albums. Reproduced in the simulator, and it
needs no search at all: visiting any chip without a filter (Recent, Radio, CD,
Files) collapsed the navigation-bar search drawer for good. Fixes, all in
`librarySearchable` / `LibraryView`: pin the drawer with `displayMode: .always`;
end an active search before switching chips; attach the field outside loading
branches (Artists, Genres and Playlists had none on first visit); and move the
Songs scope row into the list, because a hidden `.searchScopes` bar in a pinned
drawer swallowed taps on the chip bar. Tried and rejected: `.id(tab)` on the
stack root (no effect) and on the `NavigationStack` (resets the `TabView`).

## Energy (acceptance criterion)

- **Idle cost: zero.** Nothing is fetched until the Songs chip is opened; no
  timer, no polling, no background refresh.
- **Per open:** one walk per connection — here 11 small requests, 3.8 MiB,
  < 0.2 s of server time — then the cache serves every later visit until the
  database or server changes.
- **No per-render work:** sort once on `Q`; filter on input change; catalog
  progress on its own `ObservableObject`, so the ~11 progress ticks re-render
  only the Songs view.
- **No artwork fetches** from this list.
- Verify on device with a Release build: open Songs, scroll top to bottom via
  the index, filter; the CPU gauge should return to idle once scrolling stops.

## Tests

Unit (Swift Testing, no server):

- `songTitleSortKey`: quotes, ellipsis, parentheses, brackets, leading digits,
  empty title → filename, "The" kept.
- Ordering with the real titles from this library that MPD gets wrong (lowercase
  Metallica, `Älska mej Bill`, `Ænema`, `“Heroes”`, `荒城の月`), under `en` and
  `sv` locales; ties broken by artist then URI.
- Section building: labels in comparator order, `#` bucket, non-adjacent
  recurrence gets unique ids, Z–A reverses sections too.
- Page-walk logic as a pure function with injected `run`/`stillConnected`
  closures (the `firstAcceptedRecentlyAdded` pattern): short last page ends the
  walk; duplicate URIs across pages deduped; count mismatch restarts once and
  then accepts; ACK on the first page → `.unsupported`; socket drop → stops.

Live (`mikMPDTests/Local/`, Group A–C read-only):

- The walk returns exactly `count "(file != '')"` unique URIs.
- No page response exceeds 1 MiB.

**0.21 verification.** The live server is 0.24. Before release, run the
read-only probes and the live suite against a real 0.21: Debian *buster*
packages MPD 0.21.5 (`docker run debian:buster` + `apt install mpd`, pointed at
a copy of a few albums). That checks `(file != '')`, `window` without `sort`, and
`count` on the reporter's major version. Optionally offer the reporter a
TestFlight build.

## Docs (part of done)

- CLAUDE.md: LibraryView paragraph (Songs chip, chip order no longer
  append-only), a "Songs catalog" note under Conventions (paged, unsorted
  `window`, client sort because MPD's is byte order, cache invalidation, cap).
- README: feature list.
- TESTING.md: a Songs section — first load with progress, index scrubbing,
  A–Z/Z–A, filter, each action, reload after a DB update, reconnect mid-load.

## Out of scope

- Sorting by artist/album/duration inside Songs (the issue asks for A–Z).
- Multi-select (Search has it; add later if asked).
- Stripping leading articles ("The", "A").
- MPD older than 0.21.
