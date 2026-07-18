# Plan: Artist-aware album identity (+ safe duplicate-copy dedupe)

Follow-up to the `dedupedAlbumTracks` revert. The dedupe wasn't the root problem — album
identity is *name-only* on several paths, and the dedupe just made that destructive.

## Audit: who passes an artist to AlbumDetailView?

| Entry point | Artist? |
|---|---|
| Library → Albums (`AlbumListView`) | ❌ nil |
| Genre detail | ❌ nil |
| Artist detail | ✅ |
| Search albums section | ✅ |
| Queue / Search / Now Playing / Recently Played song links | ✅ (song.artist) |

With `artist == nil`, `AlbumDetailView.loadSongs` does two name-only things:

1. **Sibling-variant probe** — `listTag("album")` unfiltered, merging any tag whose
   `albumBaseAndDisc` base matches: "X [Disc 1]" by artist A merges with "X" by artist B
   (v1.2 regression).
2. **`find album "X"`** with no artist filter — returns songs from *every* artist owning
   an album named X (pre-existing since v1.0). The header then shows the first song's
   artist and fetches wiki/art for that possibly-wrong pairing.

The list rows are ambiguous by construction too: `list album` returns unique *names*, so
three artists' "Greatest Hits" is one row. The reverted dedupe key
(disc|track|title) deleted same-titled tracks across those artists — hence the revert.

## Protocol fix: `list album group albumartist`

MPD 0.21+ (already required — `albumart` is 0.21+) supports grouping:

```
list album group albumartist          → AlbumArtist: Gamma Ray
                                        Album: Blast from the Past [Disc 1]
                                        Album: Blast from the Past [Disc 2]
                                        AlbumArtist: The Doors
                                        Album: The Best of the Doors
list album genre "Rock" group albumartist   (filtered variant)
```

Neither existing parser can read this: `listValues` filters a single key, and
`parseMPDRecords` collapses it (neither line is a record-starter). Needs a small pure
line parser.

## Steps

1. **MPDSocket**: extract `rawLines(_ cmd:) -> [String]` from `listValues`'s body
   (send → readUntilOK → ACK check); `listValues` becomes a wrapper. New pure function
   (Models.swift or MPDSocket.swift, `nonisolated`, tested):
   `parseGroupedValues(_ lines: [String], groupKey: String, valueKey: String) -> [(group: String, value: String)]`
   — tracks the current group as lines stream by; values before any group key get `""`.
2. **MPDStore**: `listAlbumsByArtist(filter: String? = nil, value: String? = nil,
   completion: @MainActor ([(artist: String, album: String)]) -> Void)` sending
   `list album [FILTER] group albumartist`. On ACK (very old server), fall back to plain
   `listTag("album")` with empty artists — UI degrades to today's behavior.
3. **Models**: parse `albumartist` into `MPDSong` (`albumArtist` +
   `groupingArtist { albumArtist.isEmpty ? artist : albumArtist }`). Artist-aware
   grouping overload: `groupAlbumVariants(_ pairs: [(artist, album)]) ->
   [(artist: String, base: String, variants: [String])]`, keyed `(artist.lowercased, base)`
   — the existing name-only overload stays for ArtistDetailView (already single-artist).
4. **AlbumListView / GenreDetailView**: rows from the grouped pairs — base title with an
   artist caption underneath; "N discs" as today. Same-named albums by different artists
   become separate rows. Filter field matches against title *and* artist. Pass the artist
   into the detail view with `artistTag: "albumartist"`.
5. **AlbumDetailView**: new `var artistTag: String = "artist"`; both the sibling probe
   (`listTag("album", filter: artistTag, …)`) and `albumSongs` (`find album X <artistTag> Y`)
   use it (store methods take the tag through). When `artist == nil` (songs with empty
   artist tags), **skip sibling merging** — the safe default; plain `find` behavior stays.
6. **Reintroduce the dedupe, artist-scoped**: `dedupedAlbumTracks` keyed
   `(groupingArtist.lowercased, effectiveDisc, trackNumber, displayTitle.lowercased)`,
   applied on the album page only. Regression tests: two artists + same album name +
   same track titles → nothing collapses (the revert case); one artist + duplicate file
   paths → collapses (Fear of a Blank Planet case).

## Notes / risks

- `albumartist` vs `artist`: grouping uses albumartist so compilations stay one row per
  set; files without an albumartist land in the `""` group → row without artist caption →
  detail gets `artist: nil` → current behavior (no merge, no dedupe). Graceful.
- Artist detail still filters by `artist` (its albums came from the artist tag) — that's
  why `artistTag` is a parameter, not a constant.
- The header's `displayArtist` should prefer the passed-in artist (it already does) and
  fall back to the first song's `groupingArtist`.

## Verification

- Two artists sharing an album name: two rows in Albums (each captioned), each page shows
  only its artist's tracks, wiki/art match the right artist.
- Multi-disc merging still works per artist ("Blast from the Past", "101 [Disc A/B]").
- Fear of a Blank Planet lists each track once again; TESTING.md §5 regression pass.
