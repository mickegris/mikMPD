# 02 — Unknown artists: fall back between `artist` and `albumartist`

**Symptom:** artists show as unknown or behave oddly; Blue Öyster Cult given as
the example.

> **Status: implemented.** All three parts landed. Two corrections the live
> library forced. First, `artistFingerprints` must drop non-ASCII from the
> **unfolded** letters: folding first turns `î` into an ASCII `i` that then
> survives the drop, leaving i-vs-o — the exact miss the form exists to fix.
> Second, the contract is tag-vs-*external source*, not tag-vs-tag. This library
> holds four spellings (`Blue Oyster Cult`, `Blue  Oyster Cult` with two spaces,
> `Blue Oyster Cult feat. Robby Krieger`, and the mojibake `Blue Îyster Cult`);
> all four match the canonical accented form MusicBrainz and Wikipedia return,
> but the mojibake and the plain-ASCII spelling do **not** match each other —
> dropping removes the `î` from one side and leaves the `o` on the other.
> Closing that would need fuzzy matching with real false-positive risk, and
> nothing in the app compares one tag to another, so it was left alone.

## Diagnosis

There are three separate defects here that all present as "the artist is
wrong or missing", and they want fixing together because they share a helper.

### A. The fallback only runs one way

`MPDSong` has exactly one fallback, and it is used for grouping only:

```swift
var groupingArtist: String { albumArtist.isEmpty ? artist : albumArtist }
```

There is no mirror. Every place that *displays* a name reads `song.artist`
raw, so a file carrying `AlbumArtist` and no `Artist` — common on rips where
only the album-level tag was written — renders blank or "Unknown Artist":

| Site | Code |
|---|---|
| Now Playing | `Text("Unknown Artist")` ([NowPlayingView.swift:385](../../../mikMPD/NowPlayingView.swift)) |
| Queue rows | `if !song.artist.isEmpty` ([QueueView.swift:84](../../../mikMPD/QueueView.swift)) |
| Album track rows | `if !song.artist.isEmpty` (`SongRow`, LibraryView.swift:870) |
| Search / playlist rows | `if !song.artist.isEmpty` (`SearchRow`, SearchView.swift:289) |

The album *page* for the same file shows the name fine, because it comes from
the grouped `list album group albumartist` query. So the name is present in the
library and absent in the app — which reads as a rendering fault.

winrmpc hit exactly this and fixed it with mirror-image accessors
(`display_artist()` falls back to the album artist, `display_album_artist()` to
the track artist — `../winrmpc/CLAUDE.md` § Album identity). Two details from
that write-up are worth taking verbatim:

- **A present-but-blank tag counts as absent.** A chain that stops at `""`
  renders an empty cell, which looks broken rather than empty.
- **The fallback returns the *original* value, not a trimmed one**, because the
  same accessor feeds the art cache key, and trimming would silently orphan
  cached art for every file with a padded tag.

### B. Identity and lookups use the raw `artist`

Two consequences, both of which also show up as missing album art (and as
suspect #1 in [01](01-album-lookup-unterminated-qualifier.md)):

- **`MPDSong.artKey`** is `artCacheKey(artist: artist, album: album)`. An album
  row built from `list album group albumartist` passes the *albumartist*; a
  song row passes the *artist*. When they differ, one album owns two cache
  entries, and a tile can miss art that the track view already fetched.
- **`representativeFile(album:artist:)`** ([MPDStore.swift:1558](../../../mikMPD/MPDStore.swift))
  sends `find album "…" artist "…"`. Called from `fetchArt` with a grid tile's
  albumartist, that filter matches nothing on any album where the two tags
  differ — every compilation, and every album with per-track guest artists. The
  result is silent: no representative file, so no `readpicture`/`albumart`
  attempt at all, and the fetch falls through to MusicBrainz.

### C. The lookup strings are not normalised enough for real tags

winrmpc's notes name two spellings **found in this library**:

- `"Blue  Oyster Cult"` — two consecutive spaces. `normalizedForLookup`
  ([MPDStore.swift:1848](../../../mikMPD/MPDStore.swift)) folds quotes, dashes
  and ellipsis and moves a sort-order article, but does **not** collapse
  whitespace runs. The doubled space survives into the Wikipedia URL and the
  MusicBrainz Lucene query.
- `"Blue Îyster Cult"` — mojibake of `Blue Öyster Cult`. This is the case that
  motivates the comparison change below.

mikMPD's artist comparisons reduce both sides with `.filter(\.isLetter)`:

```swift
let strippedArtist = artist.lowercased().filter(\.isLetter)          // MPDStore.swift:1778
let strippedMB     = mbArtist.lowercased().filter(\.isLetter)        // MPDStore.swift:1826
```

`Character.isLetter` is **true for `ö` and `î`**, so this strips punctuation
but keeps the very characters that disagree. `blueöystercult` vs
`blueoystercult` fails containment in both directions, and the MusicBrainz
release is rejected even when the search found it. The same weakness is in
`WikipediaService.albumResultMatches`'s `extractLower.filter(\.isLetter)` test.

winrmpc solved this with **two fingerprints, accepting either**: diacritics
folded to ASCII (`Motörhead` ↔ `Motorhead`), and non-ASCII letters **dropped**
entirely — the second exists precisely for mojibake, where the two sides
disagree about *which* accented letter it is: folding gives `i`-vs-`o` and
still misses, while dropping leaves `blueystercult` on both sides. It is
length-guarded (≥6) so short names cannot collide.

## The fix

### Part A — mirror-image accessors (Models.swift)

```swift
/// Non-blank tag or nil. A present-but-blank tag counts as absent: a chain
/// that stops at "" renders an empty cell, which reads as a rendering fault.
/// Returns the *original* value, deliberately untrimmed — `displayArtist`
/// feeds `artKey`, and trimming would orphan cached art for padded tags.
private func tagOr(_ primary: String, _ fallback: String) -> String

/// Artist for display and for external lookups: the track artist, else the
/// album artist. Mirror image of `groupingArtist`, so the two agree on any
/// file carrying only one of the tags.
var displayArtist: String { tagOr(artist, albumArtist) }
```

Keep `groupingArtist` as the album-identity direction and redefine it through
the same helper so the blank-counts-as-absent rule applies to both.

Then replace `song.artist` with `song.displayArtist` at every *display* and
*navigation* site — the four tables above, plus the `ArtistDetailView` /
`AlbumDetailView` navigation targets next to them (a link built from a blank
artist currently pushes an empty page). "Unknown Artist" survives only when
both tags are empty.

### Part B — identity and MPD-local art

- **`MPDSong.artKey` → `artCacheKey(artist: groupingArtist, album: album)`.**
  This changes the key for files that carry an albumartist, which orphans their
  cached art. Accept it and say so: the alternative — read-through to the old
  key on a miss — doubles every cache lookup permanently to save a one-off
  re-fetch. Ship it together with the "Clear album art cache" action from
  [01](01-album-lookup-unterminated-qualifier.md) so there is a deliberate way
  to reset, and note that `.miss` markers under the old key simply become
  unreachable garbage (they age out in 7 days).
- **`representativeFile` retries on `albumartist`.** Send
  `find album "…" artist "…" window 0:1`, and when it comes back empty, retry
  with `albumartist`. Two round trips only in the case that currently returns
  nothing at all. Keep the `window 0:1` bound on both.

### Part C — lookup normalisation (MPDStore.swift, WikipediaService.swift)

1. **Collapse whitespace runs in `normalizedForLookup`** — one
   `replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)`
   plus a trim, applied before the sort-order-article step so `"Beatles,  The"`
   still moves.
2. **Add `artistFingerprints(_:) -> (folded: String, asciiOnly: String)`** to
   Models.swift as a pure `nonisolated` helper: lowercase, drop non-letters,
   then produce (a) the diacritic-folded form via
   `folding(options: .diacriticInsensitive, locale: nil)` and (b) the form with
   all non-ASCII letters removed.
3. **`artistCreditMatches(_:_:) -> Bool`** — true when either fingerprint pair
   contains the other in either direction, with a minimum length of 6 on the
   ASCII-only comparison. Use it in `searchMusicBrainz`'s artist check and in
   `WikipediaService.albumResultMatches`'s `aboutArtist` clause, replacing both
   hand-rolled `.filter(\.isLetter)` expressions.

## Explicitly out of scope

**Merging two spellings of one artist in the Artists list.** If the library
really holds both `Blue Öyster Cult` and the mojibake `Blue Îyster Cult`, they
are two values of the `artist` tag and MPD will keep returning both; folding
them in the UI would mean the row no longer names a filter value that can be
sent back to the server, and every navigation from that row would have to carry
a set of spellings instead of a name. mikMPD's standing discipline — folding is
only ever applied to a *key*, never to a displayed or queried value — says no
here. The right fix is in the tags, and `Diagnostics` could reasonably grow a
"possible duplicate artists" report to surface them; that is a separate item.

## Tests (all offline)

- `displayArtist` / `groupingArtist`: both tags, artist only, albumartist only,
  neither, and **blank-but-present** (`artist = "  "`) in each position.
- `displayArtist` returns the untrimmed original (the art-key invariant).
- `normalizedForLookup("Blue  Oyster Cult") == "Blue Oyster Cult"`, and
  `"Beatles,  The"` still becomes `"The Beatles"`.
- `artistCreditMatches`: `Blue Öyster Cult` ↔ `Blue Oyster Cult` (folding),
  `Blue Îyster Cult` ↔ `Blue Öyster Cult` (ASCII-drop), `AC/DC` ↔ `ACDC`
  (existing behaviour, must not regress), `Motörhead` ↔ `Motorhead`, and a
  **negative**: two different short names must not match through the ASCII-drop
  path (the length guard).
- `artKey` for a song with albumartist `Blue Öyster Cult` and artist
  `Buck Dharma` equals the key an album row builds for that album.

## Needs live verification

- Which spellings this library actually holds: `list artist` and
  `list albumartist`, grepped for `yster`. This decides whether the mojibake
  path is exercised at all, and it is the one fact these plans are guessing at.
- That an albumartist-only album now shows its artist in the queue and in
  search results, and that its art resolves from MPD rather than the internet
  (watch More → Diagnostics → MPD Command Log for a `readpicture` on the
  representative file instead of nothing).
