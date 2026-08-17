# 05 — Toggle between synced and freely scrollable lyrics

**Request:** "Add possibility to toggle synced/scrollable lyrics."

## Diagnosis

`syncedLyricsView` ([NowPlayingView.swift:349](../../../mikMPD/NowPlayingView.swift))
scrolls to the active line unconditionally:

```swift
.onChange(of: active) { _, newValue in
    guard let newValue else { return }
    withAnimation(.easeInOut(duration: 0.3)) {
        proxy.scrollTo(newValue, anchor: .center)
    }
}
```

So scrolling back to read an earlier verse survives only until the song reaches
the next lyric line — a few seconds — and is then yanked back to centre. The
pane is effectively unreadable anywhere except at the current line.

winrmpc reached the same conclusion and fixed it with a **Sync / Scroll**
switch (`../winrmpc/CLAUDE.md` § Lyrics). Two of its findings save a wrong
turn here:

- **Do not auto-detect a manual scroll.** The obvious design — notice the user
  scrolled and stop following — feeds back on itself, because the scroll
  observer fires for our own programmatic scroll too, so it switches itself off
  immediately. It has to be an explicit control.
- **Show the switch only when synced lyrics exist.** On plain lyrics there is no
  autoscroll to disable, so the button would do nothing.

mikMPD's version of the bug is milder than winrmpc's was: the scroll fires on
`active` *changing*, not on every poll tick, so a manual scroll survives until
the next line rather than for half a second. Milder, same defect.

## The fix

### State

```swift
@State private var lyricsFollow = true
```

View-local `@State`, **not** `@AppStorage`. This is "how I want to read *this*
track", not a durable preference — winrmpc reached the same conclusion — and
mikMPD's convention is that view-local state is for transient UI concerns
exactly like this one. Reset to `true` when the song changes
(`.onChange(of: store.currentSongID)`), so the next track starts following
again.

### Gate the autoscroll

`.onChange(of: active)` runs only `if lyricsFollow`. Toggling back to Sync
snaps to the active line **immediately** rather than waiting for the next line
change — otherwise re-enabling appears to do nothing for several seconds.

**The highlight stays in both modes.** While scrolled away it is the only
indication of where the song actually is.

### The control

CLAUDE.md says the pane's tap gesture lives on the art/lyrics panes themselves,
so a control inside `lyricsPane` would sit under a tap-to-flip gesture. **That
is stale** — the gesture was since removed ("No tap-to-toggle on the panes:
accidental art taps kept flipping to lyrics. The flanking buttons are the only
toggles"), so a button in the pane is unobstructed. CLAUDE.md needs correcting.

- Put the button in an `.overlay` on the lyrics pane with its own `Button`.
- Size it like the existing pane-flanking buttons and label it with
  `arrow.up.arrow.down.circle` / `arrow.up.arrow.down.circle.fill` (or
  `text.aligncenter` vs `arrow.down.circle`), tinted accent when following —
  matching how `lyricsToggle` signals its state at NowPlayingView.swift:251.
- Accessibility label: "Follow lyrics" / "Scroll freely".

### Extract the active-line search

`let active = lines.lastIndex { $0.secs <= t }` with
`t = store.elapsed - LyricsService.syncOffset` is currently one expression
feeding both the highlight and the scroll target, so mikMPD does not have the
drift problem winrmpc had. Extract it anyway:

```swift
nonisolated func activeLyricLine(_ lines: [LyricLine], elapsed: Double) -> Int?
```

It makes the `syncOffset` **sign** testable, which is the part worth pinning: a
flipped sign makes the highlight lead the song instead of trailing it and still
looks plausible. Real tracks routinely open with 20–30 s of intro, so "no line
active yet" is the normal opening state, not an edge case.

## Tests (offline)

- `activeLyricLine`: before the first timestamp → `nil`; exactly on a
  timestamp; between two; past the last → the last index; empty input → `nil`.
- The offset **delays** the advance: a line at `t = 10.0` is not yet active at
  `elapsed = 10.2` when `syncOffset` is 0.5, and is active at `elapsed = 10.6`.

## Needs live verification

None that requires MPD — LRCLIB is internet-only, and `LiveWikipediaTests`'
sibling gate pattern would suit a synced-lyrics fetch test. What does need a
device: that the toggle button is reachable without flipping the pane, and that
Sync-after-Scroll snaps back as expected.
