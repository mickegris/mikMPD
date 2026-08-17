# v1.5 — plan overview

Six items, from the v1.5 request. Each has its own document; this page records
what they have in common, what order they want to be done in, and what can and
cannot be verified right now.

| # | Item | Plan | Live MPD server needed to verify? |
|---|---|---|---|
| 1 | Album art + Wikipedia for `… [24-bit Remaster` | [01-album-lookup-unterminated-qualifier.md](01-album-lookup-unterminated-qualifier.md) | **No** for the fix and its tests; yes for the end-to-end check |
| 2 | Unknown artists (Blue Öyster Cult), albumartist fallback | [02-artist-identity-fallbacks.md](02-artist-identity-fallbacks.md) | No for the logic; yes to confirm which tags this library actually holds |
| 3 | Search should also search playlists | [03-search-playlists.md](03-search-playlists.md) | **Yes** — needs a `searchplaylist` capability probe |
| 4 | Highlight the playing song in every view it appears in | [04-current-song-highlighting.md](04-current-song-highlighting.md) | No for the match rules; yes for the visual pass |
| 5 | Toggle between synced and freely scrollable lyrics | [05-lyrics-sync-scroll-toggle.md](05-lyrics-sync-scroll-toggle.md) | No (LRCLIB is internet-only) |
| 6 | "Playing from <playlist>" after shuffling a playlist | [06-playlist-context-shuffle.md](06-playlist-context-shuffle.md) | **Yes** — the obvious cause is already ruled out by code reading |

## Prior art in `../winrmpc/`

Four of the six are already solved, wholly or partly, in the sibling Rust
client. Where that is so, the plan says which winrmpc source or document to
port from, and — as important — which of its decisions **not** to copy.

- **Item 1/2** — `../winrmpc/CLAUDE.md` § "Wikipedia / MusicBrainz" documents a
  round of real-library lookup fixes that were themselves ported *from* mikMPD
  and then extended: whole-token edition-qualifier matching, whitespace-run
  collapsing, diacritic folding, and a two-fingerprint artist comparison. That
  library is this library — winrmpc's notes name `"Blue  Oyster Cult"` (two
  spaces) and `"Blue Îyster Cult"` (mojibake of `Blue Öyster Cult`) as tags it
  actually found, which is direct evidence for item 2.
- **Item 2** — `../winrmpc/CLAUDE.md` § "Album identity" documents
  `display_artist()`/`display_album_artist()` as mirror-image fallbacks, and why
  a present-but-blank tag must count as absent.
- **Item 4** — `../winrmpc/docs/plans/current-song-highlighting.md` is a
  complete, already-executed plan for this exact feature, including the
  position-vs-URI trap and the album-level follow-up.
- **Item 5** — `../winrmpc/CLAUDE.md` § "Lyrics" records that unconditional
  autoscroll made the pane unreadable, that a Sync/Scroll switch fixed it, and
  that auto-detecting a manual scroll instead does **not** work.

## Shared groundwork

Items 1, 2 and 4 all want the same thing in different places: **one pure,
testable helper per rule, in `Models.swift`, rather than the rule re-expressed
at each call site.** mikMPD already works this way for `albumBaseAndDisc`,
`albumGroupingKey` and `titleTokensMatch`; these three items each add or widen
one such helper. Doing them in the order 2 → 1 → 4 avoids rework, because item
2 touches the artist string that item 1's lookups consume and item 4's album
matching keys on.

## Two standing cache hazards

Both bite every item that changes a lookup or a key, and both are easy to
mistake for "the fix didn't work":

1. **Album-art misses are remembered for 7 days.** A failed fetch writes a
   zero-byte `<key>.miss` marker beside the disk cache (`recordMiss` /
   `hasRecentMiss` in `MPDStore.swift`). After fixing a lookup, the albums that
   previously failed will *still* show no art until the marker expires. Any fix
   in items 1 or 2 needs a way to clear it — see item 1's "Cache invalidation".
2. **Changing a cache key orphans the cache.** `artCacheKey` is deliberately
   *not* punctuation-folded for this reason (CLAUDE.md records it). Item 2
   proposes changing it for one narrow class of file; that plan states the cost
   explicitly rather than hiding it.

## Verification without a server

There is no MPD connection available while these plans are being written, and
that shapes what "done" can mean per item. Three tiers:

- **Pure logic** — `albumLookupTitle`, artist fallbacks, the highlight match
  rules, the active-lyric-line search. All unit-testable in `mikMPDTests`
  offline. Every plan below puts its acceptance criteria here where it can.
- **Internet-only** — Wikipedia, MusicBrainz/CoverArtArchive and LRCLIB need
  no MPD server. `mikMPDTests/Local/LiveWikipediaTests.swift` already runs
  under the `WIKI_INTEGRATION=1` gate with no MPD server involved, so item 1's
  external half **can** be verified now.
- **Needs the server** — anything issuing MPD commands: item 3's capability
  probe, item 6's reproduction, and every visual pass. These are called out
  per plan under "Needs live verification" so they can be batched into one
  session once the server is reachable.

## Suggested order

1. **Item 2** (artist identity) — widest blast radius, feeds items 1 and 4.
2. **Item 1** (lookup title) — small, and its Wikipedia half is verifiable now.
3. **Item 5** (lyrics toggle) — self-contained, no dependency on the others.
4. **Item 4** (highlighting) — mostly mechanical once its helper exists.
5. **Item 6** (playlist context) — starts with diagnosis, not a code change.
6. **Item 3** (playlist search) — blocked on the server for the probe.
