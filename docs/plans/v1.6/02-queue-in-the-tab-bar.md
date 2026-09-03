# 2 — Queue out of More, into the main tab bar

## The request

> Currently queue is outside the main menu at the bottom. It's not really
> optimal to click on more to manage the queue. Can we move it to the menu
> somehow?

Agreed, and the reason is structural: every other tab is a *place to find
music*, while the queue is what you do with music once found — the one screen
you return to repeatedly during a listening session. It is currently the first
row of More, behind a tab whose other five entries are settings.

## The constraint that decides the design

`ContentView` uses a plain `TabView` with five tabs. **On iPhone, a sixth tab
makes UIKit collapse the last two into its own system "More" tab** — a second,
uncontrollable "More" next to mikMPD's own. So this is not "add a tab"; it is
"spend one".

Three ways to spend it were considered:

| Option | What moves | Verdict |
|---|---|---|
| **A. Browse → a Library chip; Queue takes the tab** | `BrowserView` becomes an eighth `LibTab` ("Files") | **Chosen** |
| B. More → a toolbar gear on Now Playing; Queue takes the tab | Connection, Outputs, Snapcast, Stats, Diagnostics, About | Rejected — buries six settings screens behind an unlabelled glyph, and Now Playing's gutters are already full |
| C. Queue replaces Now Playing, which moves into a mini-player | everything | Rejected outright — far too large for a release whose brief is "don't mess things up" |

**Why A is the right one.** The Library tab is already the app's "browse the
library by some axis" hub: seven chips (Albums, Artists, Recent, Genres,
Playlists, Radio, CD) over one `NavigationStack`. Filesystem browsing is an
eighth axis of exactly that kind — it is the *directory* view of the same
library — and it sits more naturally beside "Albums" and "Genres" than beside
"Search". The chip bar was built to scroll rather than truncate
(`LibraryView.swift:41`), so an eighth chip costs nothing but its own width.
Browse is also the least frequently used of the five tabs for a tagged library,
which is the trade being made explicit: one tap deeper for Browse, three taps
shallower for the queue.

## Changes

### `LibraryView.swift`

- Add `case files = "Files"` to `LibTab`, with `sfSymbol` `"folder"`.
- Place it **last** in `allCases`. Order is the chip order, so appending keeps
  every existing chip at the position users already reach for. (`LibTab` is
  not persisted — `@State private var tab: LibTab = .albums` — so there is no
  stored-value migration.)
- Add `case .files: BrowserView()` to the switch.

### `BrowserView.swift`

- **Remove its own `NavigationStack`.** It becomes a child of `LibraryView`'s
  stack; nesting two would break the toolbar and the back behaviour. This is
  the same shape every other `LibTab` destination already has.
- Its `navigationTitle` currently doubles as the breadcrumb (`"Browse"` at
  root, otherwise the directory name). `LibraryView` sets
  `.navigationTitle("Library")` on the whole stack, and the last `.navigationTitle`
  in the hierarchy wins, so the breadcrumb survives — but this must be checked
  on device, not assumed, and if it does not hold the directory name moves into
  an in-content header row instead.
- Its Up/Home toolbar items stay. They will render in `LibraryView`'s nav bar,
  which is the intended result.

### `ContentView.swift`

- `BrowserView().tabItem { Label("Browse", …) }` becomes
  `QueueView().tabItem { Label("Queue", systemImage: "list.number") }`, in the
  same slot — third, between Library and Search. Keeping the position means
  Search and More do not move.
- `list.number` is the icon `MoreView` already uses for the Queue row, so the
  glyph the user has been tapping is the glyph that moves.

### `MoreView.swift`

- Delete the Queue `NavigationLink` (the first row). More then opens directly
  on Connection, which is what it should have been all along.

### `QueueView.swift`

- Unchanged. It already owns a `NavigationStack`, a title, an `EditButton` and
  the overflow menu — everything a top-level tab needs. This is the whole point
  of choosing a slot for it rather than restructuring it.

## What is deliberately *not* changed

- **The Now Playing queue pane stays exactly as it is.** It is not made
  redundant by the tab: the pane is for glancing at what is next and jumping to
  a track without leaving the artwork; the tab is for reordering, deleting,
  shuffling and clearing. Two entry points to a queue is normal in a player.
- No badge on the Queue tab. A count that is almost always non-zero adds noise
  without adding information.
- No change to any other tab's position, title or icon.

## Risks

1. **Nested `NavigationStack`** — the one real hazard, addressed above by
   removing `BrowserView`'s own. Symptom if missed: a doubled nav bar and a
   toolbar that stops responding.
2. **Muscle memory** — the third tab now shows the queue instead of the
   filesystem. Unavoidable and intended; the release note should say so.
3. **Browse state on tab switch** — `store.browseItems` / `browsePath` live on
   the store, not the view, so the browser keeps its directory when you leave
   the Files chip and come back. That is existing behaviour and it carries over
   unchanged.

## Verification

Nothing here is unit-testable — it is tab and navigation structure. This is a
**`TESTING.md` item**: add a "Files chip and Queue tab" section covering

- Queue tab opens directly on the queue; Edit, reorder, delete, shuffle, clear,
  consume and Add-to-Playlist all still work from the tab.
- Library → Files browses, navigates into directories, Up and Home work, the
  title tracks the directory, swipe-to-add and double-tap-to-play still work.
- More no longer lists Queue and opens on Connection.
- Deep-navigating in Files, switching to another chip, and returning.
- Rotation and iPad, where the tab bar and nav bar lay out differently.

## What actually happened

Built as planned; no design change. Three notes:

**The title question resolved in our favour, and it was worth checking.** The
plan hedged on whether `BrowserView`'s `navigationTitle` would survive being
nested under `LibraryView`'s `.navigationTitle("Library")` — SwiftUI propagates
titles as preferences up the tree, which suggests the parent should win.
On device the **innermost** title wins: the Files chip renders "Browse" with the
Up/Home toolbar items, exactly as the standalone tab did. `CDView` was already
relying on this, which is the evidence the plan should have found first.

**One copy change the plan missed.** `QueueView`'s empty state read "Add songs
from the Library or Browser." — a pointer to a tab that no longer exists. It now
names Library › Files.

**`store.browseItems` empties on disconnect**, so the Files chip shows its
"Empty" placeholder rather than the last directory when the server is away.
Pre-existing and unchanged, but it is what you will see if you test this without
a reachable server, and it looks like a bug in the chip.
