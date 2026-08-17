# 03 — Search should also search playlists

**Request:** "Make sure search also searches in playlists."

## What the request covers

Two different matches, both reasonable, with very different costs:

1. **Playlist names** that contain the query — "rock" finds the *Rock 2024*
   playlist. Cheap: `listplaylists` is one command and the app already loads it
   for the Library tab.
2. **Playlist contents** — "Marillion" finds every stored playlist containing a
   Marillion track. This is the expensive one, and the one MPD gives us a
   command for.

Build both. (1) alone would be a thin reading of the request, and (2) alone
would miss the obvious case where the playlist is *named* after what you typed.

## What SearchView does today

`performSearch` ([SearchView.swift:200](../../../mikMPD/SearchView.swift)) runs
three things against one debounced, cancellable `Task`:

- `store.search(field: "any", …)` → `store.searchResults` (songs)
- `store.listTag("artist")`, filtered client-side → `artists`
- `store.listTag("album")` + a per-artist `listTag("album", filter:)` fan-out,
  joined by a `DispatchGroup` → `albums`

Playlists are absent from all three. The sections render from `@State` arrays,
so a fourth section is a mechanical addition; the work is in the query.

## MPD support

Verified against the protocol reference (MPD 0.24 is what this server runs):

```
searchplaylist {NAME} {FILTER} [window {START:END}]
listplaylistinfo {NAME} [{START:END}]        # range since 0.24
```

`searchplaylist` takes a **filter expression**, not a `tag value` pair, so the
query is `searchplaylist "Rock 2024" "(any contains \"marillion\")"`. mikMPD
already sends filter expressions (`loadRecentlyAdded` uses
`find "(modified-since …)"`), so `String.esc` quoting covers it — but note the
nesting: the inner `"` around the value must be escaped inside the outer
quoted argument.

**It must be probed, not assumed.** CLAUDE.md records that some builds close
the TCP connection outright on an *unknown* command, which surfaces as a
non-ACK I/O error and a disconnect. So:

- Add `playlistSearchAvailable: Bool?` to `MPDStore` (nil = not yet probed).
- Probe lazily on the first playlist search, against a real playlist name, and
  **check `socket.connected` before retrying** — the caveat comment in
  `MPDSocket.command` is the model.
- On ACK or disconnect, set `false` and use the fallback below permanently for
  that connection; reset to nil on `switchToServer`.

**Fallback** for servers without it: `listplaylistinfo <name>` per playlist and
filter client-side on title/artist/album. Same number of round trips, much
larger payloads — acceptable as a fallback, wrong as the primary path.

## Design

### Store

```swift
struct PlaylistMatch: Identifiable {
    let name: String
    let nameMatched: Bool      // the query appears in the playlist's name
    let trackCount: Int        // matching tracks (0 when only the name matched)
    var id: String { name }
}

func searchPlaylists(query: String, limit: Int = 20,
                     completion: @escaping @MainActor ([PlaylistMatch]) -> Void)
```

Sequenced on `Q` like every other store query, with results handed back on the
main actor. Inside:

1. `listplaylists` → names. Mark name matches with `localizedCaseInsensitiveContains`.
2. For each playlist, up to `limit`, issue `searchplaylist <name> "(any contains
   "<query>")" window 0:50` (or the `listplaylistinfo` fallback) and count rows.
3. Return every playlist that matched by name or has ≥1 matching track, in the
   server's playlist order.

Three bounds, all of which matter and each of which mirrors an existing
mikMPD rule:

- **Cap the playlists scanned** (`limit`, default 20) — a library with 200
  playlists would otherwise send 200 sequential commands on the socket queue,
  which is exactly the "Play All sent thousands of commands and starved the
  poll" failure CLAUDE.md already records for `enqueueMatching`.
- **`window 0:50` per playlist** — the count is for a caption; nobody needs
  every row. Unbounded queries outrunning the 5 s socket read timeout is a
  documented hazard (`loadRecentlyAdded`).
- **An in-flight guard**, so a fast typist cannot stack N×M commands. The
  existing 300 ms debounce plus `searchTask?.cancel()` handles the common case,
  but `Task.isCancelled` is not checked inside the store's `Q.async` work — see
  below.

### Cancellation

This is the part most likely to go wrong. `performSearch`'s `searchTask` cancel
only stops the Swift `Task`; the store's `Q.async` blocks are already queued
and will run to completion regardless. Adding a per-playlist fan-out multiplies
that. Give `searchPlaylists` a generation counter on the store (bump on each new
call, drop results whose generation is stale) — cheaper and more reliable than
threading `Task` cancellation into the socket queue, and it matches how
`fetchLyrics` already guards with `lyricsToken`.

### View

A fourth section in `searchResults`, between Albums and Songs — playlists are
closer to albums than to tracks in how they get used:

```
Playlists
  ♫  Rock 2024                    12 tracks
  ♫  Marillion Live               name match
```

Each row is a `NavigationLink` to `PlaylistDetailView(name:)`. Caption reads
"N matching tracks", or nothing when only the name matched. Reuse the
`music.note.list` symbol the app already uses for playlists.

Add the section to the empty-state check at
[SearchView.swift:28](../../../mikMPD/SearchView.swift) — it currently reads
`store.searchResults.isEmpty && artists.isEmpty && albums.isEmpty`, so a
query matching *only* a playlist would show "no results" above the results.

Long-press / swipe parity per the standing convention: swipe to play the
playlist (`loadPlaylist(name, replace: true, play: true)`), context menu for
Play / Shuffle / Add, and a section footer hint.

## Tests (offline)

The query building and result shaping are pure; the round trips are not.

- Filter-expression construction: a query containing `"` and `\` produces a
  correctly nested, escaped `searchplaylist` command string. Extract the
  builder as a `nonisolated` free function so it is testable without a socket —
  the same reason `parseMPDRecords` was extracted.
- `PlaylistMatch` ordering and the name-match-only case (`trackCount == 0`).
- The generation counter drops stale results.

## Needs live verification

- **Whether `searchplaylist` exists on this server.** Everything else is
  designed around not knowing. Add it to
  `mikMPDTests/Local/LiveMPDCapabilityTests.swift` (Group B) — that suite exists
  to answer exactly this kind of question and prints a capability report.
- Behaviour on a playlist name containing a quote or a slash.
- That a search which matches many playlists does not visibly stall the poll —
  watch the MPD Command Log for the fan-out's timings.
