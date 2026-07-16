# Plan: Queue button in Now Playing

## Goal

A small queue button in the Now Playing header (same manner as the add-to-playlist and
lyrics buttons at NowPlayingView.swift:42-51) that shows the queue *inside* the Now Playing
view — like lyrics, which swap into the album-art pane.

## Approach: third pane state (art / lyrics / queue)

The art region is already a two-state toggle (`showLyrics`, NowPlayingView.swift:17,55-65).
Generalize it:

1. **State:** replace `@State private var showLyrics = false` with

   ```swift
   enum NowPlayingPane { case art, lyrics, queue }
   @State private var pane: NowPlayingPane = .art
   ```

   - `lyricsToggle` (NowPlayingView.swift:146) becomes `pane = pane == .lyrics ? .art : .lyrics`.
   - New `queueToggle` button does the same for `.queue`. Icon: `list.bullet` /
     `list.bullet.circle.fill` when active, accent-tinted like the lyrics toggle, with an
     accessibility label ("Show queue"/"Hide queue").
   - Header layout: keep the ZStack; trailing HStack becomes `queueToggle` + `lyricsToggle`
     (add-to-playlist stays alone on the leading side).

2. **Pane switch** (NowPlayingView.swift:55-65): add `case .queue: queuePane` to the
   `Group`. **Move the tap-to-toggle gesture** off the shared container onto `albumArt` and
   `lyricsPane` only — a tap gesture on the container would swallow the queue list's row
   taps and swipes. (Art tap continues to flip art↔lyrics exactly as today.)

3. **`queuePane`** — same visual shell as `lyricsPane` (rounded `systemGray6` fill):

   ```swift
   List {
       ForEach(store.queue) { song in
           QueueRow(song: song, isCurrent: song.pos == store.playlistPos)
               .contentShape(Rectangle())
               .onTapGesture { store.play(at: song.pos) }
               .listRowBackground(...)   // same accent highlight as QueueView.swift:17
       }
       .onDelete { store.delete(at: $0) }
   }
   .listStyle(.plain)
   .scrollContentBackground(.hidden)
   ```

   - Reuse `QueueRow` (QueueView.swift:51) as-is — its artist/album `NavigationLink`s work
     because NowPlayingView already has a `NavigationStack` (NowPlayingView.swift:37).
   - Single tap plays (this is a quick-glance pane; the Queue tab keeps its deliberate
     double-tap + reorder/Edit affordances — no `.onMove` here, reordering in a small
     square pane is fiddly).
   - Wrap in `ScrollViewReader`; on appear and on `.onChange(of: store.playlistPos)`,
     `proxy.scrollTo(currentSong row, anchor: .center)` so the playing track is always
     visible — same pattern as `syncedLyricsView` (NowPlayingView.swift:199-223).
   - Empty queue: compact `ContentUnavailableView("Queue is Empty", systemImage: "list.bullet")`.

## Alternative rejected

Presenting `QueueView` in a sheet — duplicates the Queue tab wholesale (toolbar, clear,
edit mode) and doesn't match "shows the queue in the now playing view"; the lyrics-pane
pattern is already established and liked.

## Verification

Pure UI — no unit tests. Check with `RenderPreview`/simulator:
- Toggling between all three panes (queue button, lyrics button, art tap) never gets stuck.
- Row tap switches tracks; current-row highlight and auto-scroll follow along (poll updates
  `playlistPos` within 1 s).
- Swipe-to-delete works inside the pane; artist/album links push detail views.
- Long queues scroll; empty queue shows the placeholder.
