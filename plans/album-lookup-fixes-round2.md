# Plan: Album art/Wikipedia fixes round 2 (post-v1.2 test feedback)

Six real-library failures. Diagnoses against current code:

| Tag | Symptom | Root cause |
|---|---|---|
| Best of the Doors | debut album's art **and** wiki | token matcher: `{best, the, doors}` vs "The Doors (album)" = 2/3 hit — "the" is a stopword and matching is substring-based; MusicBrainz has **no** title validation at all |
| Black Rain (Original 8869…) | no wiki, art suspect | "(Original 8869…)" isn't recognized as a qualifier (no keyword, `(19\|20)\d{2}` doesn't match 5-digit catalog numbers) |
| Blood of Emeralds – The Very Best of Gary Moore Part 2 | right art, wrong wiki | probably has no Wikipedia article; the extract-only fallback promotes whatever related article mentions enough words — correct answer is *blank* |
| Clutching at Straws [24-bit…] | no wiki | cleaning + plain-title lookup *should* work; suspect the per-session wiki cache from before the fix — **verify after force-quit before coding** |
| Helldorado {Japan, VICP…} | no wiki (art OK) | **curly braces** — disc-marker and qualifier regexes only know `()`/`[]` |
| Fear of a Blank Planet | every track listed twice (1,1,2,2,…) | duplicate copies of the files in the library; `find album` returns both |

## 1. Word-level token matching with stopwords (WikipediaService.swift)

Rework `tokensMostlyPresent`:
- Tokenize **both** sides (needle and haystack) into word sets — no substring matching
  ("the" can no longer hit "theatre").
- Drop stopwords `{"the", "and"}` and tokens < 3 chars from the needle.
- Require ≥ 2/3 overlap **and ≥ 2 matching tokens** (single-token names like "101" are
  covered by exact containment, never by tokens).

Checks: "Best of the Doors" → `{best, doors}` vs "The Doors (album)" → 1 hit → reject ✓.
"Beacon Theatre. Live from..." → `{beacon, theatre, live, from}` vs "Live from the Beacon
Theatre" → 4/4 ✓ (existing tests must keep passing).

## 2. Demote the extract-only fallback to exact containment only

In `albumResultMatches`: `aboutAlbum = titleMatchesAlbum(title, album) || extract contains
album (exact, normalized)`. Token overlap counts **only** toward the title
(`titleMatchesAlbum`), never toward the extract — a sequel/related article freely
mentions enough of the album's words. Blood of Emeralds then matches nothing → blank
wiki, which is correct. (Also re-run the Doors search: the compilation's real article
"The Best of the Doors" title-matches by containment → right article, right-side up.)

## 3. Curly braces + more qualifier signals (Models.swift)

- Add `{}` to the bracket classes in `DiscMarker.numbered/.lettered` and
  `EditionQualifier.trailingBracket` (and the closing classes).
- Extend `EditionQualifier.keywords` with: `original`, `recording`, `version`, `japan`,
  `import`, `promo`, `limited`, plus two catalog-number patterns:
  `\b[0-9]{4,}\b` (bare "88697…" runs) and `\b[a-z]{2,6}-?[0-9]{3,}\b` ("VICP-60852").
- Bracket content with ellipses ("8869…") needs no special casing — the digit/keyword
  patterns match inside whatever's there.

Tests: "Black Rain (Original 88697…)" → "Black Rain"; "Helldorado {Japan, VICP-60852}" →
"Helldorado"; "{Disc 1}" curly disc marker; guard rails — "Album (Part 2)" and
"Live (1993)"-style *titles*… note "(1993)" already strips (year rule, pre-existing);
"(Part 2)" must NOT strip (no keyword) — add a test locking that, since Blood of
Emeralds ends in "Part 2" unbracketed and must keep it.

## 4. Validate MusicBrainz release titles (MPDStore.swift)

`searchMusicBrainz` filters candidates by artist only — "Best of the Doors" happily
returns the debut album (same artist). Add title validation: accept a release only if
`release["title"]` passes the same word-level token/containment check as Wikipedia titles.
Move the token helper to Models.swift as a shared `nonisolated` function
(`titleTokensMatch(candidate:query:)` used by both `WikipediaService.titleMatchesAlbum`
and `searchMusicBrainz`) so the two ends can't drift. Tests move/extend accordingly.

## 5. Dedupe duplicate files in album detail (LibraryView.swift + Models.swift)

```swift
/// Collapse duplicate library copies: same disc, track, and title (case-insensitive).
/// First occurrence wins. Album-detail display only — queue/search show real files.
nonisolated func dedupedAlbumTracks(_ songs: [MPDSong]) -> [MPDSong]
```

Key: `(effectiveDisc, trackNumber, displayTitle.lowercased())`. Applied in
`AlbumDetailView`'s `loadSongs(tags:)` finish, after `sortedByDiscAndTrack`. Deliberately
not keyed on duration (rips differ by a second) and deliberately display-only. Note the
track-count line then reflects deduped count — desired. Tests: exact dupes collapse,
different discs/tracks/titles don't, first file path wins.

## 6. Clutching at Straws — verify before coding

Cleaning "[24-bit remaster]" and the plain-title lookup are already covered by passing
tests; the reported failure predates… or survives… the session cache. Steps: force-quit,
reopen, check again. If still blank, capture the **exact** album tag (Browse → folder, or
`mpc list album | grep -i clutch`) and add it verbatim as a test case for
`albumLookupTitle` + the query path.

## Order & verification

1 + 2 together (they reshape the same function; keep all existing AlbumTokenMatch/
WikipediaAlbumMatch tests green), then 3, 4, 5 — each with tests. On-device recheck per
TESTING.md §5 plus the six tags above (restart the app between wiki checks). Expected
end state: Doors/Black Rain/Helldorado correct, Blood of Emeralds blank, Fear of a Blank
Planet single track listing.
