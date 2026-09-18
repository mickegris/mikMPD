# 1 — Queue tab: single tap plays

## The report

> When tapping a song in the queue (main bar queue at the bottom) you come to the
> album or artist view when it instead should play the song, like it does with
> the other mini queue view. It should work like Spotify.

## Cause

Both queues render the same `QueueRow` (`QueueView.swift:72`), and that row holds
two `NavigationLink`s: the artist credit and the album name. What differs is the
gesture attached to each:

| | Modifier | Single tap on the row |
|---|---|---|
| Now Playing mini-queue (`NowPlayingView.swift:384`) | `.playableRow { store.play(at:) }` | plays |
| Queue tab (`QueueView.swift:15-17`) | `.contentShape` + `.onTapGesture(count: 2)` | **opens the artist page** |

The Queue tab has no single-tap handler, so a single tap falls through to the
`List`, which gives the row's first `NavigationLink` to the tap: the artist
link. That is why it "goes to the album or artist view". It is almost always the
artist, because that link comes first. The double-tap handler also makes SwiftUI
delay every single tap while it waits for a possible second one.

## Change

`QueueView.swift`, the row inside `ForEach(store.queue)`:

```swift
QueueRow(song: song, isCurrent: …)
    .playableRow { store.play(at: song.pos) }      // was .contentShape + .onTapGesture(count: 2)
    .nowPlayingRow(…)
    .swipeActions … .contextMenu …                 // unchanged
```

`.playableRow` is the project convention for rows that start playback (CLAUDE.md
→ Conventions). It brings the content shape, the haptic and the 350 ms accent
flash, so the tab gives the same feedback as the mini-queue, radio, CD and
library rows.

### Edit mode

The Queue tab has an `EditButton`, and the mini-queue does not. In edit mode a
tap must not start playback, because you are reordering or deleting there. Add
an `isEnabled` parameter to `playableRow`, defaulting to `true` so no other
caller changes:

```swift
func playableRow(isEnabled: Bool = true, action: @escaping () -> Void) -> some View
```

When disabled, the modifier applies neither the tap gesture nor the flash. In
`QueueView`, read `@Environment(\.editMode)` and pass
`isEnabled: editMode?.wrappedValue.isEditing != true`.

The environment value has to be read *inside* the `NavigationStack`, where the
`EditButton` sets it. Put it in a small `QueueList` subview, or it will read the
outer, never-editing value.

### Footer and docs

- Footer: "Double-tap to play. Long press or swipe to add to a playlist." →
  **"Tap to play. Long press or swipe to add to a playlist."**
- README.md:25: "Double-tap to jump to a song" → "Tap a song to play it".
- TESTING.md:76 and :80: "double-tap-to-play" / "double-tap play" → tap-to-play,
  plus one new line: *tapping the underlined artist/album still navigates;
  tapping elsewhere on the row plays; in Edit mode a tap does nothing.*
- CLAUDE.md: no architecture change. `QueueView` is described nowhere that
  mentions double-tap, so nothing needs updating there.

## Links stay (decision)

Spotify's queue rows carry no inline links. Navigation lives in the "…" menu.
This plan **keeps** the underlined artist/album links, because:

- the mini-queue already works this way, and the report holds it up as the
  behaviour to copy;
- the links are reachable elsewhere only through Now Playing, which shows the
  *current* song, not an arbitrary queue row.

**Alternative, if the Spotify version is preferred:** render the credit and album
as plain `Text` in `QueueRow`, and add "Go to Artist" / "Go to Album" to the
context menu. Programmatic navigation needs a `navigationDestination`, because a
`contextMenu` button cannot host a `NavigationLink` push directly. That changes
both queues, since the row is shared. The long-press rule would then want a
swipe equivalent or a footer mention.

## Verification

Simulator, Queue tab, with a queue of at least 5 songs:

- [ ] tap on the title, the track number or the duration → the song plays, and
      the row flashes;
- [ ] no noticeable delay before playback, now that the double-tap wait is gone;
- [ ] tap on the underlined artist → artist page; on the underlined album →
      album page;
- [ ] Edit → tap a row → nothing plays; drag-reorder and delete still work;
- [ ] swipe leading → Playlist; long press → Add to Playlist… (unchanged);
- [ ] the mini-queue in Now Playing behaves exactly as before.

No unit test: this is gesture wiring with no logic to extract.

## Follow-up (not in this release)

`SearchView.swift:250` also says "Double-tap to play." The same Spotify argument
applies, but it was not reported, so it is left for a later release.
