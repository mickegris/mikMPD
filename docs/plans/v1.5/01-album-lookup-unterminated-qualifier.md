# 01 — Album art and Wikipedia for `Clutching at Straws [24-bit Remaster`

**Symptom:** Marillion's *Clutching at Straws* and *Misplaced Childhood*, both
tagged as 24-bit remasters, get neither cover art nor a Wikipedia summary.

> **Status: implemented, with a corrected diagnosis.** The real tags are
> `Clutching at Straws [24-bit Remaster CD 1]` and `[… CD 2]` — well-formed,
> with the disc marker *inside* the qualifier bracket. The unterminated string
> in the original report was the app's own output, not the tag: the disc-marker
> regex strips from the space before `CD`, leaving
> `Clutching at Straws [24-bit Remaster`, which is what the UI displayed and
> what the lookups were sent. So the fix went into `albumBaseAndDisc` (re-close
> the bracket the strip broke open) rather than into `albumLookupTitle`, and the
> speculative "tolerate an unterminated bracket in the tag" change below was
> **not** made — there is no evidence such tags exist, and it would widen
> stripping with nothing to justify it. Everything else in this plan stands: the
> keyword gate, the cache-invalidation hazard, and the Diagnostics action all
> landed as written. See the same case in `../winrmpc/CLAUDE.md` § Album
> identity, which documents it as "a marker sitting at the tail of a qualifier
> bracket".

## Diagnosis

Both albums were reported with the qualifier bracket **unterminated** —
`Clutching at Straws [24-bit Remaster`, `Misplaced Childhood [24-bit Remaster`,
with no closing `]`. That detail is almost certainly the whole bug, because the
well-formed spelling already works today.

`albumLookupTitle` ([Models.swift:69](../../../mikMPD/Models.swift)) strips
trailing edition qualifiers with:

```swift
static let trailingBracket = try! NSRegularExpression(
    pattern: #"[(\[{]([^)\]}]*)[)\]}]\s*$"#, options: [])
```

The pattern **requires a closing bracket**. Trace the two spellings:

| Tag | `trailingBracket` matches? | `albumLookupTitle` result | Outcome |
|---|---|---|---|
| `Clutching at Straws [24-bit Remaster]` | yes → content `24-bit Remaster` | `Clutching at Straws` | works today |
| `Clutching at Straws [24-bit Remaster` | **no** | `Clutching at Straws [24-bit Remaster` (unchanged) | Wikipedia and MusicBrainz both miss |

The keyword gate is not the problem: `EditionQualifier.keywords` matches
`remaster` and `\b[0-9]+\s*-?\s*(bit|khz)\b`, so `24-bit Remaster` is
recognised as a qualifier the moment the bracket is parsed at all. Nor is the
disc-marker stage — `DiscMarker.numbered` already tolerates a missing closer
(`[)\]}]?` is optional there), which is precisely the inconsistency to fix.

Downstream, the unstripped title is what fails:

- `WikipediaService.fetchAlbum` ([WikipediaService.swift:54](../../../mikMPD/WikipediaService.swift))
  starts from `albumLookupTitle(rawAlbum)`, so every query it builds carries
  `[24-bit Remaster`, and `albumResultMatches` then requires the extract to
  contain that string outright. Nothing on Wikipedia will.
- `MPDStore.downloadArt` ([MPDStore.swift:1767](../../../mikMPD/MPDStore.swift))
  does the same for MusicBrainz, and `luceneEscape` escapes the stray `[`, so
  the query is well-formed but asks for a release that does not exist.

**Before writing code, confirm the tag.** With the server reachable:

```bash
mpc -h <host> ls | grep -i marillion
```

or `list album albumartist "Marillion"`. If the tags turn out to be properly
closed, this diagnosis is wrong and the investigation restarts from the
"Secondary suspects" list below — do not apply the fix speculatively and
declare victory.

## The fix

Make the qualifier stripper as tolerant of a missing closing bracket as the
disc-marker stripper already is.

In `EditionQualifier`, add a second pattern and try it only when the primary
one fails:

```swift
// An opening bracket with no closer before end-of-string. Real tags get
// truncated by taggers with a field-length limit, and the disc-marker
// regex already tolerates this (its closing bracket is optional).
static let unterminatedBracket = try! NSRegularExpression(
    pattern: #"[(\[{]([^)\]}]*)$"#, options: [])
```

`albumLookupTitle`'s loop then tries `trailingBracket` first and
`unterminatedBracket` second, feeding the captured content through the
*unchanged* `keywords` gate before stripping. Everything else — the loop that
handles stacked qualifiers, the "don't strip to empty" guard, the re-run of
`albumBaseAndDisc` — stays as it is.

Why this is safe:

- The keyword gate is doing the real work. `(What's the Story) Morning Glory?`
  has no trailing open bracket at all; `Peace Sells… but Who's Buying?` has no
  bracket; a hypothetical `Album (Live` would strip — and *should*, since
  `live` is already a qualifier keyword in the closed form.
- The `m.range.location > 0` guard already prevents a tag that is *only* a
  bracketed qualifier from stripping to nothing.
- It cannot affect grouping or art keys: `albumLookupTitle` is lookup-only, by
  design, and is called from exactly two places (`WikipediaService.fetchAlbum`
  and `MPDStore.downloadArt`). `albumBaseAndDisc` and `albumGroupingKey` are
  untouched, so no album row merges or splits as a result of this change.

### Also worth folding in, from `../winrmpc/`

winrmpc's `is_edition_qualifier` (`../winrmpc/CLAUDE.md` § Wikipedia /
MusicBrainz) is a later generation of the same rule and fixes two things
mikMPD's `keywords` regex still gets wrong:

- **Whole tokens, not substrings.** winrmpc records that `lower.contains("bit")`
  also fires on "Rabbit". mikMPD's pattern is already `\b`-anchored for the
  keyword alternation, so this is mostly handled — but check
  `\b[a-z]{2,6}-?[0-9]{3,}\b` (the catalogue-number branch), which is not
  case-insensitive-safe in the same way and can fire on a legitimate title.
- **Short all-caps region/format markers** — `[UK]`, `[US]`, `[EP]`. winrmpc
  added these because this library's entire Depeche Mode discography is tagged
  `… [UK]`. mikMPD's keyword list does not cover them, so those albums have the
  same class of failure as the Marillion ones and are a good second test case.

Take these as a follow-up commit, not bundled with the bracket fix — they widen
what counts as a qualifier, which is a different risk profile from accepting a
missing bracket.

## Cache invalidation

The fix alone will not make the art appear, and this will look like the fix
failing:

- **Art misses persist for 7 days.** `recordMiss(key:)` wrote a zero-byte
  `<key>.miss` file next to the disk cache when the lookup failed, and
  `hasRecentMiss(key:)` suppresses re-fetching until it ages out. The art key
  here is built from the *raw* album tag via `artCacheKey`, which is unchanged
  by this fix — so the same key still resolves to the same stale miss marker.
- **Wikipedia negatives are in-memory only** (`cache[key] = ""`), so those clear
  on app relaunch. The artist-image disk cache is separate and unaffected.

Add a **"Clear album art cache"** action to More → Diagnostics that deletes
`Caches/albumart/` (both images and `.miss` markers) and empties
`albumArtCache`. This is worth having on its own terms — there is currently no
way to force a re-fetch from inside the app — and it is the only practical way
to verify this fix on a device without deleting the app.

## Tests (all offline)

Add to `mikMPDTests/mikMPDTests.swift`, alongside the existing
`AlbumLookupTitleTests`:

```
"Clutching at Straws [24-bit Remaster"    → "Clutching at Straws"
"Misplaced Childhood [24-bit Remaster"    → "Misplaced Childhood"
"Clutching at Straws [24-bit Remaster]"   → "Clutching at Straws"   // regression
"Album (2005 Remaster"                    → "Album"
"(What's the Story) Morning Glory?"       → unchanged                // not trailing
"Album [Part 2"                           → unchanged                // no keyword
"[24-bit Remaster"                        → unchanged                // would empty
"Album [24-bit Remaster] [Disc 1"         → "Album"                  // stacked, loop
```

The last one matters: it crosses the qualifier stripper with the disc-marker
stripper, which is where the loop earns its keep.

## Needs live verification

- **Now, without MPD**: `mikMPDTests/Local/LiveWikipediaTests.swift` runs under
  `WIKI_INTEGRATION=1` and needs only internet. Add a case asserting both
  Marillion albums return a summary whose extract names the album, passing the
  **raw truncated tag** so the test exercises `albumLookupTitle` end to end.
  This verifies the whole external half of the item before the server is back.
- **Later, with MPD**: confirm the real tag spelling; clear the art cache; check
  that both albums show a cover and an About section in `AlbumDetailView`.

## Secondary suspects

If the tags turn out to be well-formed, these are the next candidates, in
order. Two of them are real defects regardless of this item and are covered by
[02-artist-identity-fallbacks.md](02-artist-identity-fallbacks.md):

1. **`representativeFile` filters on the wrong tag.** It sends
   `find album "…" artist "…"` ([MPDStore.swift:1558](../../../mikMPD/MPDStore.swift)),
   but grid tiles and album rows carry an **albumartist**. When the two differ
   the query returns nothing, no MPD-local art is attempted, and the fetch goes
   straight to MusicBrainz — turning a LAN hit into an internet miss.
2. **The art key uses the raw `artist` tag** (`MPDSong.artKey`), while album
   lists key on the albumartist, so one album can occupy two cache entries and
   miss the one that was populated.
3. **A stale `.miss` marker from an earlier failed lookup** — see above; check
   `Caches/albumart/` for `<key>.miss` before concluding anything.
