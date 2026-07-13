# Plan: Reorder songs in the queue

**Status check: not implemented.** `QueueView` has `.onDelete` only; `MPDStore` has no `move`
command wrapper. This is a small, self-contained change.

## MPD protocol

`move {FROM} {TO}` — moves the song at position FROM to position TO in the current queue.
(`moveid` exists too, but position-based `move` matches how the rest of the queue code works,
e.g. `delete(at:)` and `play(at:)`.)

## Store (MPDStore.swift, queue-management section)

```swift
func move(from: Int, to: Int) {
    Q.async { [weak self] in
        _ = try? self?.socket.command("move \(from) \(to)")
        DispatchQueue.main.async { self?.loadQueue() }
    }
}
```

Plus a thin `moveRow(from offsets: IndexSet, to destination: Int)` adapter for SwiftUI:
`.onMove` reports the destination index in the *pre-removal* array, while MPD's TO is the index
in the resulting list — convert with `to = destination > from ? destination - 1 : destination`.
Single-item moves only (`offsets.first`), which is all `List.onMove` produces in practice.

**Optimistic update:** apply `queue.move(fromOffsets:toOffset:)` locally on main *before*
dispatching the command, so the row doesn't snap back while waiting for `loadQueue()`/next poll.
Same philosophy as the seek/state locks. The subsequent `loadQueue()` is the ground-truth
correction.

## View (QueueView.swift)

- Add `.onMove { store.moveRow(from: $0, to: $1) }` to the `ForEach` (next to `.onDelete`).
- Add `EditButton()` to the toolbar so reorder handles appear (plain-style `List` needs edit
  mode for `.onMove`).

## Notes / edge cases

- Moving the currently playing song is fine — MPD keeps playing it and updates `song` pos;
  the 1 s poll refreshes `playlistPos`, so the highlight follows automatically.
- Positions can shift under us if another client edits the queue between render and drop;
  `loadQueue()` after the command self-heals, accept last-write-wins (consistent with app design).
- `.onMove`-conversion logic is pure — add a unit test for the destination-index adjustment
  (shared with the same conversion needed by the stored-playlists plan's `playlistmove`).
