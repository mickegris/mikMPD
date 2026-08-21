# 02 — Detect compilation albums without breaking anything

> **Status: implemented in 1.5.2 and verified in the simulator against the live
> server.** Jackie Brown is one row, "Various Artists", 17 tracks, with cover
> art; Greatest Hits and Live still show two rows each. Two things the plan did
> not foresee. First, merging the rows made `discCountFromVariants` report
> "14 discs" — the variants are one album tag repeated per track artist, so they
> must be uniqued by name. Second, the art key and the art *lookup* have to
> diverge: keying on the directory is right, but sending that path to
> MusicBrainz matches nothing, and these files have no embedded art at all, so
> the lookup sends an empty artist and searches by album alone.
> The Wikipedia summary resolves to the *film* rather than the soundtrack, which
> was accepted as good enough.

**Problem:** an album whose tracks are each by a different artist fragments into
one row per artist. `Jackie Brown` shows as 14 albums, `Legends Of Metal Vol. I`
as 12. Deferred out of
[01](01-album-artist-splitting.md) because the fix is a change to *album
identity*, and getting it wrong merges two unrelated albums — which is worse
than the split it cures.

## Why the v1.5.1 fix does not cover these

01 made the artist path use `albumartist`. That works when a compilation is
tagged with one — but these files **carry no AlbumArtist at all**:

```
file: itunes/Compilations/Jackie Brown/01 Across 110th Street.m4a
Artist: Bobby Womack
Album:  Jackie Brown
Genre:  Soundtrack
        (no AlbumArtist, no MUSICBRAINZ_ALBUMID)
```

**MPD substitutes `Artist` for a missing `AlbumArtist`.** That is why
`list albumartist` reports 14 values for this one album, and why
`count "(albumartist == \"\")"` finds only fully untagged files. So every
albumartist-keyed path — `listAlbumsByArtist`, `AlbumGroup`, `artCacheKey`,
`isCurrentAlbum` — sees 14 distinct albums that happen to share a title.

## The whole library, measured

Only **5 of 820** albums carry more than one albumartist. Probing each one's
files makes the picture unambiguous:

| Album | Files | Artists | Explicit albumartists | **Directories** | Truth |
|---|---|---|---|---|---|
| Jackie Brown | 17 | 14 | 0 | **1** | one compilation |
| Legends Of Metal Vol. I | 12 | 12 | 0 | **1** | one compilation |
| Greatest Hits | 28 | 2 | 0 | **2** | Dylan *and* RHCP — two albums |
| Live | 25 | 2 | 2 | **2** | Fleetwood Mac *and* UFO — two albums |
| Lateralus | 26 | 2 | 1 | **2** | two rips of one album |

**The directory is the disambiguator, and it does exactly the work the artist
tag cannot.** The two real compilations live in a single directory each. The two
genuine title collisions live in two directories, one per album:

```
Jackie Brown      → itunes/Compilations/Jackie Brown          (all 17 files)
Greatest Hits     → Bob Dylan/Greatest Hits
                    Red Hot Chili Peppers - Discography …/(2003) … Greatest Hits
```

That is the signal to build on: it says "yes" to both cases we want merged and
"no" to both we must not touch, on real data rather than by construction.

## Detection

**An album is a compilation when its tracks share a common directory but not a
common artist.**

Implement as `compilationIdentity(files:) -> String?` in Models.swift, pure and
testable: return the longest common directory prefix of the URIs, or nil when it
is empty (i.e. the tracks only share the library root).

- `itunes/Compilations/Jackie Brown/…` ×17 → `itunes/Compilations/Jackie Brown`
- `Bob Dylan/Greatest Hits/…` + `Red Hot Chili …/…` → `""` → nil, no merge
- A multi-disc set at `X/CD1`, `X/CD2` → `X` → merges, which is correct

Deliberately **not** used as signals:

- **A `Compilation` tag.** MPD does not know it — `count "(Compilation == …)"`
  ACKs with `Unknown filter type`. It cannot be queried even where the file has it.
- **`MUSICBRAINZ_ALBUMID`.** A valid MPD filter (it returns 0 rather than ACKing)
  but absent from every file in these albums, so it would detect nothing here.
  Worth adding later as a *confirming* signal, never as the only one.
- **The literal path segment `Compilations`.** True for this library because
  iTunes made it so; useless for anyone else's.
- **Genre `Soundtrack`.** Present on Jackie Brown, absent from Legends Of Metal.

## Cost

Detection needs the file list of a candidate album, which is a `find` per album —
far too expensive across 820 albums. It is cheap because **only albums with more
than one albumartist are candidates**, and `list album group albumartist` (already
issued by `listAlbumsByArtist`) names them for free. Five probes here, each
`find album "…"` bounded by a `window`, and only when the Albums tab loads.

Cache the result per album key for the session; it changes only on a database update.

## The fix

### A. One extra grouping pass, not a new identity scheme

Keep `AlbumGroup` and its artist-scoped key exactly as they are — CLAUDE.md's
standing rule is that every site using `albumGroupingKey` must agree, and this
plan must not put that at risk. Add a pass *after* `groupAlbumVariants`:

1. Find base names owned by more than one artist in the current list.
2. For each, probe its files and compute `compilationIdentity`.
3. When non-nil, replace those N groups with **one** `AlbumGroup` whose artist is
   `"Various Artists"` and which carries the directory so detail queries can use it.

`AlbumGroup` gains `var compilationBase: String?`. Nil for every ordinary album,
so nothing else changes shape.

### B. Detail, art and playback follow the directory, not the artist

`AlbumDetailView` needs a compilation branch, since no artist filter can select
these tracks. MPD's `base` filter does it, verified against the server:

```
count "((album == \"Jackie Brown\") AND (base \"itunes/Compilations/Jackie Brown\"))"
→ songs: 17
```

So `albumSongs` gains a `base:` variant. Track rows must show each track's own
artist (they already use `displayArtist`), and the header shows "Various Artists".

### C. The five places that will otherwise disagree

This is where "without breaking anything" actually lives. Each of these keys on
artist today and will mismatch a compilation row unless it is updated in step:

1. **`artCacheKey`** — a row keyed `various artists|jackie brown` will not find
   art fetched under `bobby womack|jackie brown`. Key compilations on the
   directory instead, and ship with the Clear Album Art Cache action from
   v1.5's item 1, since existing entries become unreachable.
2. **`isCurrentAlbum`** — a playing Jackie Brown track has `groupingArtist`
   "Bobby Womack" while the row says "Various Artists", so the now-playing
   marker silently stops working. It needs the compilation identity too.
3. **`RecentlyAddedView`** and **`recentAlbumGroups`** derive albums from songs'
   `groupingArtist` and will keep splitting them.
4. **Wikipedia** — `fetchAlbum(album:artist:)` with "Various Artists" is a
   guaranteed miss at best and a wrong article at worst. Pass no artist for a
   compilation and let the existing title-only validation decide.
5. **`enqueueMatching`** — Play All on a compilation must use the `base` filter,
   not `findadd albumartist "Various Artists"`, which matches nothing.

If any of these cannot be done in the same change, **do not ship the grouping
pass**: a merged row whose art, marker and Play All are all broken is worse than
today's honest split.

## Risks, and what bounds them

- **Two different albums sharing one directory** would merge — a messy dump
  folder holding two albums of the same name. No instance in this library; the
  merge is visible and reversible, unlike a silent track loss.
- **An album split across sibling directories** (`X/CD1`, `X/CD2`) merges, which
  is correct, but so would `Various/Disc 1` and `Various/Disc 2` of *different*
  sets sharing a parent. Requiring the album *tag* to match as well — which the
  pass already does, since it only ever considers one base name — contains this.
- **"Various Artists" is not localised** and will look odd next to Swedish
  library content. Use the directory's last path component as the caption if
  that reads better; decide with the screenshot, not in the plan.

## Tests

Offline, pure — `compilationIdentity` is where the judgement lives:

- 17 URIs under one directory → that directory.
- Dylan's and RHCP's `Greatest Hits` → nil. **This is the regression test that
  matters**; assert it by name so a future loosening cannot quietly merge them.
- `X/CD1/…` + `X/CD2/…` → `X`.
- A single file → its directory; an empty list → nil.
- URIs at the library root → nil, not `""` treated as a match.

Live (Group C), each pinning a number this plan was written from:

- `Jackie Brown`: 17 files, 1 directory, 0 explicit albumartists.
- `Greatest Hits`: 2 directories → stays two albums.
- `find "((album == …) AND (base …))"` returns the full track list.
- The count of albums with >1 albumartist is still small (a jump means the
  library changed shape and the cost assumption needs rechecking).

## Manual verification

- [ ] Jackie Brown is one row captioned "Various Artists", opening to 17 tracks
      each showing its own artist
- [ ] Legends Of Metal Vol. I likewise, 12 tracks
- [ ] **Greatest Hits still shows two rows** — Bob Dylan and Red Hot Chili Peppers
- [ ] **Live still shows two rows** — Fleetwood Mac and UFO
- [ ] Cover art appears on the merged rows (after clearing the art cache)
- [ ] Playing a compilation track marks its album row, and only that one
- [ ] Play All on a compilation queues all its tracks in track order
- [ ] The About section is absent or correct — never another album's
- [ ] Recently Added and Recently Played show the compilation as one tile
