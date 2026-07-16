# Plan: Multi-disc albums — art, Wikipedia, and presentation

Example library entry: **Gamma Ray – "Blast from the Past [Disc 1]" / "Blast from the Past
[Disc 2]"**. Two tagging conventions exist in the wild and the app currently handles neither:

- **(a) Disc suffix in the album tag** — `Album [Disc 1]`, `Album (Disc 2)`, `Album CD1`,
  `Album - Disc 1`, `Album [Disk 2]`, … Each disc is a *separate album* to MPD.
- **(b) Proper `disc` tag** — one album tag, per-song `disc: 1/2`. MPD sees one album, but
  the app ignores the tag entirely.

## Investigation: what breaks today and why

**Album art.** MPD-local art (`albumart`/`readpicture`, MPDStore.swift:1148) is per-file and
works fine. The external fallback `downloadArt` (MPDStore.swift:1310) sends the raw album tag
to MusicBrainz: query 1 (`release:"Blast from the Past [Disc 1]"`, exact quoted) never
matches — MusicBrainz stores it as one release named "Blast from the Past" with two mediums;
query 3 (quoted album-only) fails the same way; only query 2 (tokenized) occasionally
rescues it. So fallback art is flaky-to-missing. Worse, each disc has its own
`artCacheKey` (Models.swift:5), so the same cover is fetched and disk-cached once per disc,
and one disc can show art while the other shows the placeholder.

**Wikipedia.** `fetchAlbum` (WikipediaService.swift:35) tries direct titles
`"Blast from the Past [Disc 1] (Gamma Ray album)"` → 404. The search fallback *does* find
"Blast from the Past (Gamma Ray album)", but `albumResultMatches`
(WikipediaService.swift:66) requires title-or-extract to contain the full album string
*including* "[disc 1]" → rejected → blank About section on every disc.

**Presentation.** Convention (a): the discs appear as separate rows in AlbumListView,
ArtistDetailView, GenreDetailView, and SearchView's album grouping; "Play" on the detail
page plays one disc only. Convention (b): `MPDSong` (Models.swift:18) doesn't parse `disc`,
and `albumSongs` (MPDStore.swift:570) sorts by `trackNumber` alone — a 2-disc album
interleaves as 1,1,2,2,3,3,… (both discs restart track numbering).

## Phase 1 — pure helper (Models.swift) + tests

```swift
/// "Blast from the Past [Disc 1]" → ("Blast from the Past", 1); no marker → (album, nil).
nonisolated func albumBaseAndDisc(_ album: String) -> (base: String, disc: Int?)
```

Single case-insensitive regex anchored at the end, with an optional separator before the
marker:

```
[\s]*[-–—:,]?\s*[\(\[]?\s*(disc|disk|cd)\s*\.?\s*(\d{1,3})\s*[\)\]]?\s*$
```

Guards:
- If stripping leaves an empty base (album literally named "Disc 1"), return `(album, nil)`.
- Require the digits — "Live CD" or "Greatest Hits Disc" are not disc markers.
- Trim trailing whitespace/dangling separator from the base.

Out of scope for now (note in code): spelled-out numbers ("Disc One"), disc subtitles
("[Disc 1: The Early Years]" — the subtitle is discarded with the marker only if it's
inside the bracket; first version can simply not match that and leave the tag alone).

**Tests (mikMPDTests, pure):** `[Disc 1]`, `(Disc 2)`, `[Disk 3]`, `(CD 1)`, trailing bare
`CD2` and `Disc 2`, `- Disc 1`, `: disc 12`, no-marker passthrough, "Disc 1" alone →
passthrough, "Live CD" → passthrough, base-trimming (no trailing space/dash).

## Phase 2 — fix art + Wikipedia lookups

1. **Shared cache key:** in `artCacheKey` (Models.swift:5) run the album through
   `albumBaseAndDisc(...).base` before lowercasing. All discs of a set now share one cache
   entry and one fetch, and every consumer (ArtThumb, ArtThumbByKey, NowPlaying lock-screen
   art) agrees automatically. Old disk-cache files under suffixed keys become orphans in
   `Caches/albumart/` — harmless, they just refetch under the new key.
2. **MusicBrainz:** in `downloadArt` (MPDStore.swift:1310), strip the suffix
   (`albumBaseAndDisc(album).base`) before building the three queries.
3. **Wikipedia:** in `fetchAlbum` (WikipediaService.swift:35), strip the suffix right where
   the album is already `normalizedForLookup`-ed (before the cache-key line, so both discs
   share one cache entry too). `albumResultMatches` then compares against the base and the
   existing search fallback starts accepting "Blast from the Past (Gamma Ray album)".

**Tests:** `artCacheKey("gamma ray", "Blast from the Past [Disc 1]")` ==
`artCacheKey("gamma ray", "Blast from the Past (Disc 2)")`; `albumResultMatches` passes for
a suffixed album against the unsuffixed Wikipedia title.

## Phase 3 — presentation

1. **Parse the `disc` tag:** add `disc: String` to `MPDSong` (`r["disc"]`) and
   `discNumber: Int` (same `components(separatedBy:"/")` treatment as `trackNumber`; 0 when
   absent).
2. **Disc-aware sort:** `albumSongs` (MPDStore.swift:570) sorts by
   `(discNumber, trackNumber)`. Fixes convention (b) interleaving. (Leave
   `findSongs`'s album-then-track sort; its album grouping already separates discs.)
3. **Disc sections in AlbumDetailView** (LibraryView.swift:86-95): compute each song's
   *effective disc* — `discNumber` if > 0, else the suffix-derived disc of its own
   `album` tag. When songs span >1 effective disc, render the Tracks section as one section
   per disc with header "Disc N"; otherwise keep the single flat section.
4. **Merge suffixed variants into one album entry.** Do the expansion inside
   `AlbumDetailView` so every entry point (queue/search/now-playing album links that pass a
   raw `song.album`) benefits without touching their call sites:
   - `loadSongs` (LibraryView.swift:102): if `albumBaseAndDisc(album).disc != nil` **or**
     the caller flags a merged group, fetch sibling tags — `store.listTag("album",
     filter: displayArtist.isEmpty ? nil : "artist", value: displayArtist)` filtered to
     tags whose `albumBaseAndDisc().base` matches this one's — then run `albumSongs` per
     tag and concatenate, sorted by effective disc + track. Header/nav title show the base
     name; the track-count line becomes "2 discs · 31 tracks · 2:22:10". Play/Add/playlist
     buttons already operate on `songs`, so they cover the whole set for free.
   - Grouping helper for the list views, pure and testable:
     `nonisolated func groupAlbumVariants(_ albums: [String]) -> [(base: String, variants: [String])]`
     (stable order, single-variant albums pass through). Apply in `AlbumListView`,
     `ArtistDetailView`'s Albums section, `GenreDetailView`, and SearchView's album
     grouping: one row per base, caption "N discs" when `variants.count > 1`, navigating
     to `AlbumDetailView` for the first variant (which then expands per the bullet above).

**Tests:** `groupAlbumVariants` (mixed suffixed/plain input, ordering, no false merges of
albums that merely share a prefix); effective-disc sort of a synthetic 2-disc song list;
`MPDSong` disc parsing ("2", "1/2", absent).

## Risks / notes

- False positives on albums whose real title ends in a disc-like token (e.g. an album
  actually titled "CD 1") merge wrongly — the digit requirement plus end-anchor keeps this
  rare, and the failure mode is cosmetic (merged rows), not data loss.
- `artCacheKey` change invalidates some existing disk-cache entries (refetch, no user
  action needed).
- Phases are independently shippable: 1+2 fix the reported art/wiki problem; 3 is the
  visual polish.
