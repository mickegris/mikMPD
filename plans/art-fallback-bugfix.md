# Plan: Fix art cache key mismatch in SearchView (follow-up to 802ef11)

Commit 802ef11 ("Add source-specific fallback artwork") introduced `artCacheKey(artist:album:)`
(trims whitespace, returns `""` when both fields are empty) and switched `MPDSong.artKey`,
`ArtThumbByKey`, and `ArtThumb` to it. **`SearchView.AlbumArtThumb` was missed.**

## Bug

`mikMPD/SearchView.swift:267-269` — `AlbumArtThumb.artKey` still uses the old formula:

```swift
var artKey: String { "\(artist)|\(album)".lowercased() }
```

The store now caches art under the *trimmed* key (`MPDSong.artKey` → `artCacheKey`), so for any
song whose artist/album tags carry leading/trailing whitespace, search results look up a key that
is never populated: the thumbnail stays a placeholder forever even though the art is cached and
shown correctly everywhere else. For songs with empty artist+album it looks up `"|"`, which is
also never populated anymore.

Secondary inconsistency: `AlbumArtThumb` still shows the old `square.stack` SF Symbol placeholder
instead of the new `MikMPDLogo` fallback used by every other thumbnail.

## Fix

`AlbumArtThumb` (SearchView.swift:261-293) is functionally identical to `ArtThumbByKey`
(LibraryView.swift:407-421), differing only in placeholder styling.

1. Delete `AlbumArtThumb` and replace its call site(s) in SearchView with `ArtThumbByKey`
   (pass the same `size`; keep any corner radius applied at the call site).
2. If keeping it for styling reasons instead: change `artKey` to
   `artCacheKey(artist: artist, album: album)` and swap the placeholder to
   `Image("MikMPDLogo").resizable().scaledToFit().padding(size * 0.18)`.

Option 1 preferred — removes duplication.

## Tests (optional, pure logic, fits mikMPDTests)

- `artCacheKey`: trimming (`" A " / " B "` → `"a|b"`), both-empty → `""`, one-empty keeps `|`.
- `MPDSong.sourceKind`: `cdda://1` → `.cd`, `https://…` → `.radio`, `Artist/Album/01 Track.mp3`
  → `.library`.

## Reviewed and deemed OK (no action)

- The `!key.isEmpty` guard in `MPDStore.fetchArt` was dead code before this commit (old keys
  always contained `|`) and is now the effective empty-key guard — correct.
- Old disk-cache files under untrimmed keys (incl. `%7C.jpg` from the former `"|"` key) are
  orphaned in `Caches/albumart/` — harmless; iOS purges Caches. Optional one-time cleanup only.
- Fallback PNGs are 1024×1024 @1x, ~0.4–1 MB each (~2.3 MB total). Consider downsizing to 512px
  or HEIC to trim app size — cosmetic, not a bug.
- `updateNowPlayingInfo` resolves the fallback via `UIImage(named:)` every 1 s poll — fine,
  system-cached.
- `sourceKind` doesn't recognize `mms:`/`rtsp:` schemes (falls back to library logo) — acceptable.
