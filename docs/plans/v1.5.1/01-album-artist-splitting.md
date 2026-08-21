# 01 — An album must not split because one track has a different artist

**Symptom:** *Tre amigos* by Just D appears twice. One copy is credited to
"Just D feat. Thåström" and holds a single track; the other is credited to
"Just D" and is missing that track. "Just D feat. Thåström" also appears as its
own row in the Artists list. This works correctly in `../winrmpc`.

## Diagnosis

Confirmed against the live server (10.0.1.3), not inferred.

### The tags are fine

Every track of the album carries the **same** `AlbumArtist`:

```
file: Just D/Tre amigos/d1t03. Just D feat. Thåström - Sug på den.flac
Album:       Tre amigos
AlbumArtist: Just D          ← same on all 15 tracks
Artist:      Just D feat. Thåström   ← differs on this track only
```

So the library is tagged correctly and the album is not ambiguous. The split is
entirely the app's doing.

### The Albums tab is already right; the Artists path is not

| Query | Result |
|---|---|
| `find album "Tre amigos" albumartist "Just D"` | **15** tracks — the whole album |
| `find album "Tre amigos" artist "Just D"` | **14** tracks — track 3 missing |
| `find album "Tre amigos" artist "Just D feat. Thåström"` | **1** track |

The Albums tab uses `list album group albumartist` and passes
`artistTag: "albumartist"` into `AlbumDetailView`, so **it shows the album
correctly**. Everything reached through the *Artists* tab uses the `artist` tag
instead, and that is where all three symptoms come from:

1. **`ArtistListView`** loads `store.listTag("artist")`
   ([LibraryView.swift](../../../mikMPD/LibraryView.swift), `onAppear`), so every
   per-track featuring credit becomes a standalone artist row. → screenshot 1.
2. **`ArtistDetailView.loadAlbums`** sends `list album` filtered on
   `artist`, so "Just D feat. Thåström" owns an album called *Tre amigos*.
3. **`ArtistDetailView`** then pushes `AlbumDetailView(album:artist:)` **without
   an `artistTag`**, which defaults to `"artist"`. That default is what produces
   both broken pages: a 1-track album for the featuring credit → screenshot 2,
   and a 14-track album silently missing track 3 for the main artist →
   screenshot 3 (note the numbering jumps 2 → 4).

The missing track is the worse half of this bug: a duplicate row is visible and
obviously wrong, whereas a quietly incomplete album page is not.

### How winrmpc avoids it

winrmpc uses `AlbumArtist` for the whole artist path, never `Artist`:

- `list_tag("AlbumArtist")` for the artist list (`src/ui/app.rs:3707`, `:3784`)
- `list_tag_filtered("Album", "AlbumArtist", &name)` for an artist's albums
  (`src/ui/app.rs:1104`, `:1165`)

That is the entire difference. mikMPD already has the same discipline in the
Albums tab and simply never applied it to the Artists tab.

## The constraint that makes this non-trivial

**225 songs in this library have an empty `AlbumArtist`.** A naive switch to
`list albumartist` would erase their artists from the Artists tab entirely —
trading a visible duplicate for a silent disappearance, which is worse.

Measured on the live server:

| Query | Values |
|---|---|
| `list artist` | 252 |
| `list albumartist` | 249 |
| artist values that are **not** any albumartist | 8 |

Those 8 are exactly the noise this plan removes: seven featuring credits
(`Alice Cooper feat. Rob Zombie`, `Blue Oyster Cult feat. Robby Krieger`,
`Just D feat. Thåström`, …) plus `Crosby, Stills, Nash And Young`, whose
albumartist is spelled with `&` — its albums stay reachable under that spelling.

So the artist list must be a **union**: every `albumartist`, plus the `artist`
of files that have no albumartist. `MPDSong.groupingArtist` already encodes
exactly this rule for a single song; the list query needs the same thing at
library scale.

## The fix

### A. Artist identity comes from albumartist, with a fallback

Add to `MPDStore`:

```swift
/// Artists for the Artists tab: every `albumartist`, plus the `artist` of files
/// that carry no albumartist at all (225 songs here). Album artist is the album's
/// identity — filtering on `artist` makes every per-track featuring credit its
/// own artist and splits the album it belongs to.
func listArtists(completion: @escaping @MainActor ([String]) -> Void)
```

Two commands on `Q`: `list albumartist`, then
`list artist "(albumartist == \"\")"` for the fallback set, merged
case-insensitively (first-seen spelling wins, as `groupAlbumVariants` already
does) and sorted. Both are bounded, single-shot tag queries — no fan-out.

Verify the filter form against the server before relying on it; if
`list artist "(albumartist == \"\")"` ACKs, fall back to
`find "(albumartist == \"\")"` and collect distinct artists client-side, which
is bounded by the 225 songs.

`ArtistListView.onAppear` calls this instead of `listTag("artist")`.

### B. An artist's albums and tracks are scoped by albumartist

In `ArtistDetailView`:

- `loadAlbums()` → `listTag("album", filter: "albumartist", value: artist)` and
  `listDiscCounts(filter: "albumartist", value: artist)`.
- The `NavigationLink` must pass **`artistTag: "albumartist"`**, matching what
  `AlbumListView` already does. This single omission is what drops track 3.
- Play All / Add All → `enqueueMatching(tag: "albumartist", value: artist)`, so
  playing an artist includes their featuring tracks.

For an artist that only exists as a track artist (the fallback set from A),
albumartist-scoped queries return nothing. Detect the empty result and retry
once on `artist` — those files have no albumartist to scope by, so `artist` is
the correct identity for them, and it cannot reintroduce the split because such
files are never part of an albumartist-tagged album.

### C. Song rows link to the album artist

`SongRow`/`SearchRow`/`QueueRow` build `ArtistDetailView(artist: song.displayArtist)`.
For track 3 that is "Just D feat. Thåström" — an artist page that will now be
empty or fall back oddly. Link artist names to `groupingArtist` instead, so
tapping the artist under a featuring track lands on the album's artist.

Keep **displaying** `displayArtist` — the row should still read
"Just D feat. Thåström", because that is what the file says. Only the navigation
target changes. This is the same display-vs-identity split
[v1.5's item 2](../v1.5/02-artist-identity-fallbacks.md) established.

## Out of scope, and why

**Compilations whose tracks each carry a different albumartist.** Probing the
whole library found only **5 of 820** albums with more than one albumartist:

- `Greatest Hits` (Bob Dylan / Red Hot Chili Peppers) and `Live` (Fleetwood Mac
  / UFO) — genuinely different albums that share a title. Correctly separate.
- `Lateralus` (`TOOL` / `Tool`) — already collapsed, since `groupAlbumVariants`
  lowercases the artist half of its key.
- `Jackie Brown` (14 albumartists) and
  `Legends Of Metal Vol. I` (12) — real compilations that **do** split into one
  row per track-artist in the Albums tab.

The last two are the same family of bug but need a different fix: detecting that
an album is a compilation (a shared parent directory with many albumartists, or
a `Compilation`/`MUSICBRAINZ_ALBUMID` tag) and collapsing it under a single
"Various Artists" identity. That is a design decision with its own failure modes
— wrongly merging two same-titled albums is worse than the current behaviour —
and it should not ride along with a bugfix release. File it as its own item.

## Tests

Offline, pure:

- A merge helper for A: albumartist values plus artist-only values, deduped
  case-insensitively, first-seen spelling preserved; an artist that appears in
  both sets appears once.
- Navigation identity: for a song with `artist = "Just D feat. Thåström"` and
  `albumArtist = "Just D"`, the displayed name is the former and the navigation
  target is the latter.

Live (`mikMPDTests/Local/`, Group C — this is what the fixtures suite is for):

- `find album "Tre amigos" albumartist "Just D"` returns 15 tracks and
  `find album "Tre amigos" artist "Just D"` returns 14, pinning the discrepancy
  this plan exists to remove.
- `list albumartist` does not contain any `feat.` value.
- The union from A contains every `list albumartist` value and does not contain
  `"Just D feat. Thåström"`.
- `list artist "(albumartist == \"\")"` is accepted by the server (the
  capability question in A).

## Manual verification

- [ ] Artists tab no longer lists "Just D feat. Thåström" (nor the six other
      featuring credits)
- [ ] Artists → Just D → Tre amigos shows **15** tracks, numbered 1–15 with no gap
- [ ] Track 3 reads "Just D feat. Thåström" but its artist link opens Just D
- [ ] Albums tab → Tre amigos is unchanged (it was already correct)
- [ ] An artist whose files carry no albumartist still appears and still opens
- [ ] Play All on Just D includes "Sug på den"
- [ ] Crosby, Stills, Nash & Young still reachable under the `&` spelling
