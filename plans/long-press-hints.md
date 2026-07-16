# Plan: Hint text wherever long press changes something

## Inventory of long-press interactions (all `.contextMenu`)

| Site | Long-press action | Hint today | Only path? |
|---|---|---|---|
| OutputsView.swift:36 (output row) | Move output to another partition | ✅ footer: "…Long press to move between partitions." | yes |
| PlaylistsView.swift:37 (playlist row) | **Rename playlist** | ❌ none | **yes** |
| SettingsView.swift:37 (server row) | Edit server | footer mentions swipe only | no (swipe Edit exists) |
| QueueView.swift:19 (queue row) | Add to Playlist… | ❌ none | yes |
| SearchView.swift:132 (song row) | Add to Playlist… | ❌ none | yes |
| PlaylistsView.swift:163 (detail song row) | Add to Playlist… | ❌ none | yes |

The worst offender is playlist **rename** — a value change reachable *only* by long press,
with nothing anywhere suggesting it exists.

## Approach: standardize on the OutputsView footer pattern

The app already ships the right idiom twice: static section-footer copy
("Toggle to enable/disable. Long press to move between partitions.",
"Tap a server to connect. Swipe for edit and delete."). Extend that same pattern to every
site above — always-visible, zero new dependencies, and the copy style is already
established ("Long press to …").

**Alternative rejected — TipKit** (`.popoverTip`): Apple's actual tooltip framework, but
tips show once and vanish, so the affordance is invisible to anyone who dismissed it,
second-device users, and UI tests; heavier machinery for six lines of caption text. Static
footers match what the app already does.

### Edits

1. **PlaylistListView** (PlaylistsView.swift:28-45): the `List` is plain with no sections —
   wrap the rows in a `Section` with footer
   **"Long press a playlist to rename it. Swipe to delete."**
   (Section footers render fine in `.plain` style.)

2. **ConnectionView servers footer** (SettingsView.swift:48-50): extend to
   **"Tap a server to connect. Long press or swipe to edit. Swipe to delete."**

3. **SearchView songs section** (header "Songs (n)", SearchView.swift:138): add footer
   **"Long press a song to add it to a playlist."**

4. **PlaylistDetailView** (PlaylistsView.swift:150-175): wrap the track `ForEach` in a
   `Section` with footer **"Long press a track to add it to another playlist."**
   (Keep `onDelete`/`onMove` on the `ForEach`, unaffected by the wrapping.)

5. **QueueView** (QueueView.swift:12-27): plain list, no sections; a bottom footer on a
   long queue is invisible until scrolled. Two-part fix:
   - Wrap rows in a `Section` whose footer reads
     **"Double-tap to play. Long press to add to a playlist."** (also documents the
     currently-unhinted double-tap).
   - **Swipe parity** so long press stops being the only path: add the same leading
     swipe action AlbumDetailView rows already have (LibraryView.swift:92) —
     `Button { addRequest = … } label: { Label("Playlist", systemImage: "music.note.list") }.tint(.indigo)`
     — to queue rows, search rows, and playlist-detail rows. Three copies of an existing
     one-liner, and it makes the hint text *confirmable* by swipe for users who never
     long-press.

6. **OutputsView** — already correct; leave as the reference copy.

### Copy rules (keep future hints consistent)

- Start with the primary tap gesture if it's non-obvious, then the long press:
  "Double-tap to play. Long press to …".
- Always "Long press" (two words, no hyphen — matches the existing OutputsView string).
- Name the *outcome*, not the menu: "to rename it", "to add it to a playlist" — never
  "to open the menu".

## Verification

No unit-testable logic (static strings + one repeated swipe action). Visual pass in the
simulator: each of the five updated screens shows its footer; footers don't collide with
the delete-confirmation alerts; VoiceOver still announces rows normally (context-menu
actions are already exposed via the actions rotor — no extra `accessibilityHint` needed,
but spot-check the new swipe actions are announced).
