# Plan: UI polish round 2 (post-v1.2 test feedback)

Five items from manual testing, all view-layer.

## 1. Now Playing header is cramped (4 buttons + title)

`NowPlayingView.swift` header ZStack: "Now Playing" title centered, with
add-to-playlist + history leading and queue + lyrics trailing squeezed around it.

**Recommended: flank the album art.** The art pane is `.aspectRatio(1, .fit)` — on
shorter/wider screens it's height-bound, leaving unused gutters beside it (the user's
observation). Restructure:

```swift
HStack(alignment: .top, spacing: 10) {
    VStack(spacing: 16) { addToPlaylistButton; historyButton }   // left column
    paneGroup                                                    // art/lyrics/queue
    VStack(spacing: 16) { queueToggle; lyricsToggle }            // right column
}
```

- Header row keeps only the "Now Playing" title (or drops the row entirely — the tab bar
  already names the screen; removing it buys vertical space back).
- Trade-off to check on device: on tall narrow phones the art is width-bound, so the
  columns shave ~2×30 pt off the art. If that looks worse than the cramped header,
  fallback plan: drop the title text from the header and spread the four buttons across
  the full width with `Spacer()`s — zero art shrink, one line of change.
- Buttons keep their current icons/tints/accessibility labels; sheets stay attached to
  their buttons.

## 2. Long *song titles* in Now Playing still truncate

The album line got `MarqueeText`; the title (`songInfo`, `.title2.bold`, `lineLimit(2)`)
didn't. Replace with `MarqueeText(text: song.displayTitle, font: .title2.bold(), color: .primary)`
— single line, scrolls when needed, same `.id(text)` reset. (Two wrapped lines → one
marquee line also returns vertical space to the layout, which item 1 appreciates.)

## 3. Library album lists still truncate long album names

`AlbumListView` rows: `Label(...).lineLimit(2)` (LibraryView.swift). Lists should *wrap*,
not marquee (a screenful of marquees is noise). Remove the `lineLimit` so names wrap
fully in: `AlbumListView`, `ArtistDetailView`'s Albums section, `GenreDetailView`, and
SearchView's album rows (`lineLimit(2)` there too). Rows grow; that's fine in a List.
Keep `lineLimit(1)` on *song* rows (title + artist metadata lines) — those have detail
pages.

## 4. Recently Played rows: clickable artist/album links

`RecentlyPlayedSheet` rows show plain title/artist text. Match the `QueueRow` pattern:

- Artist → `NavigationLink(ArtistDetailView(artist:))`, underlined caption.
- Add an album line (entries already carry `album`) → `NavigationLink(AlbumDetailView(album:artist:))`,
  underlined caption. Both push inside the sheet's existing `NavigationStack`.
- `.buttonStyle(.plain)` on the links so the row's tap-to-play doesn't swallow them
  (exactly as QueueView.swift does).
- Keep existing swipes (queue/playlist) unchanged.

## 5. Queue toolbar collides with the title when scrolling

QueueView has four toolbar items (Clear leading; Edit, consume, refresh trailing) and a
default large title — on scroll the collapsing bar renders "Clear Q… Edit". Fix:

- `.navigationBarTitleDisplayMode(.inline)` on the Queue screen.
- Consolidate: keep `EditButton` visible, move Clear (destructive, confirm-free today —
  consider keeping it buried), consume toggle, and refresh into one trailing
  `Menu { … } label: { Image(systemName: "ellipsis.circle") }`. Two trailing items + no
  leading item = nothing left to collide.
- Consume state shown via checkmark/filled icon inside the menu.

## Verification

No unit-testable logic — visual pass per TESTING.md style:
- Now Playing on smallest + largest phone: buttons reachable, art size acceptable, no
  overlap with connection banner; all four sheets/panes still open.
- Titles: long song title marquees; long album name wraps fully in Library lists.
- Recently Played links push artist/album pages inside the sheet.
- Queue: scroll a long queue — title stays inline, toolbar stable; all four actions
  still reachable and functional.
