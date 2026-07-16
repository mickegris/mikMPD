# Plan: Library tab bar that fits small iPhones

## Problem

`LibraryView.swift:10-11` puts all six `LibTab` cases (Albums, Artists, Genres, Playlists,
Radio, CD) into one segmented `Picker`. Six segments in one row:

- On 320–375 pt widths (iPhone SE, mini, any phone in Zoomed display) the segments compress
  until labels truncate ("Playli…") or become unreadably small.
- Segmented controls don't scroll and don't wrap, so larger Dynamic Type sizes make it worse.
- Any future seventh category is impossible.

## Approach: horizontally scrollable chip bar

Replace the segmented control with a horizontal `ScrollView` of capsule chips (icon + label),
the pattern Music/Podcasts use for category filters. It degrades gracefully on any width —
narrow screens scroll instead of truncating — and Dynamic Type just makes chips wider.

Alternatives considered and rejected:

- **Two rows of segments** — no standard control does this; a custom grid of segments reads
  as two unrelated pickers.
- **`Menu`/dropdown picker** — hides the options behind a tap and loses one-tap switching.
- **Apple-Music-style category list** (Library root = list of categories, each pushes) —
  standard, but adds a navigation level and makes Albums↔Artists switching two taps; the
  current one-tap switcher is worth keeping.

## Changes (all in LibraryView.swift)

1. Give `LibTab` an icon (reuse the symbols already associated with each category elsewhere
   in the app):

   ```swift
   var sfSymbol: String {
       switch self {
       case .albums: "square.stack"; case .artists: "person"; case .genres: "tag"
       case .playlists: "music.note.list"; case .radio: "antenna.radiowaves.left.and.right"
       case .cd: "opticaldisc"
       }
   }
   ```

2. New private `LibTabBar` view replacing the `Picker` at `LibraryView.swift:10-11`:

   ```swift
   ScrollView(.horizontal, showsIndicators: false) {
       HStack(spacing: 8) {
           ForEach(LibTab.allCases, id: \.self) { t in
               Button { tab = t } label: {
                   Label(t.rawValue, systemImage: t.sfSymbol)
                       .font(.subheadline)
                       .labelStyle(.titleAndIcon)
               }
               .buttonStyle(t == tab ? AnyPrimitiveButtonStyle(.glassProminent)
                                     : AnyPrimitiveButtonStyle(.glass))
           }
       }
       .padding(.horizontal)
   }
   .padding(.vertical, 8)
   ```

   Notes:
   - Selected chip uses `.glassProminent`, unselected `.glass` (iOS 26 Liquid Glass button
     styles; deployment target is 26.2 so no availability guards). There is no
     `AnyPrimitiveButtonStyle` in SwiftUI — either write a tiny type-erasing wrapper or
     branch on `t == tab` inside `label` with `.glassEffect(.regular.tint(...))`; whichever
     compiles cleaner. Simplest fallback that still looks native:
     `.buttonStyle(.borderedProminent)` vs `.bordered)` with `.buttonBorderShape(.capsule)`.
   - Wrap the `HStack` in `ScrollViewReader` and `withAnimation { proxy.scrollTo(tab) }` in
     an `.onChange(of: tab)` so a chip selected while half-off-screen scrolls into view
     (matters when the app restores to Radio/CD).
   - Keep the existing `Divider()` and `switch tab` body untouched.

3. Optional (only if the chips look sparse): show icon-only chips
   (`.labelStyle(.iconOnly)`) for the *unselected* state on very compact widths — skip
   unless visual check demands it; the scroll already solves the fitting problem.

## Verification

No pure logic to unit-test — this is layout only.

- `RenderPreview` / simulator at iPhone SE (3rd gen, 375 pt) and iPhone 16 Pro Max: all six
  chips reachable, no truncation, selected chip visibly distinct.
- Repeat with `.environment(\.dynamicTypeSize, .accessibility2)` — chips grow and scroll,
  nothing clips vertically.
- Switch to each tab once; confirm the underlying views still swap correctly.
