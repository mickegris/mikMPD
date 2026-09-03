# v1.6 — plan overview

Two UI items plus the release chores. Both items touch the two screens the app
is actually used from, so the guiding constraint is the one the request states
outright: **the app works well; nothing that works today may regress.**

| # | Item | Plan | Live MPD server needed to verify? |
|---|---|---|---|
| 1 | Server picker in Now Playing (only when >1 server) | [01-now-playing-server-picker.md](01-now-playing-server-picker.md) | **Yes** — two profiles, and switching is a disconnect/reconnect |
| 2 | Queue out of More, into the main tab bar | [02-queue-in-the-tab-bar.md](02-queue-in-the-tab-bar.md) | No for the structure; yes for the QA pass |

> **Status: both implemented on branch `v1.6` (build 39).** Each plan carries
> its own note on where it was wrong. In short: item 2's one named risk — the
> title-as-breadcrumb surviving the un-nesting — resolved in our favour and was
> confirmed on device; item 1 was correct as designed but needed three fixes
> that only a real screen surfaced, and turned up two latent defects in
> connection handling that are *not* this release's to fix (recorded in
> [01](01-now-playing-server-picker.md)).

## Version and branch

- **Version:** `MARKETING_VERSION` 1.5.2 → **1.6.0**, `CURRENT_PROJECT_VERSION`
  → **39**, both configs (Debug and Release) in `mikMPD.xcodeproj/project.pbxproj`.
  A feature release, not a bugfix one — item 2 moves a top-level tab, which is
  the most visible change since the Library chip bar.
  The working tree already carries an uncommitted 37 → 38 bump; that becomes
  part of the same commit rather than a separate one.
- **Branch:** `v1.6` off `main`, matching how v1.5 / v1.5.1 / v1.5.2 were done
  (feature branch, then a `Merge v1.6 — …` commit onto main).
- Version bump lands **first**, as its own commit, so the two feature commits
  are readable on their own.

## What the two items have in common

Both are pure presentation changes over state the store already publishes
(`servers` / `activeServerID`, and `queue`). **No new MPD commands, no socket
work, no changes on `Q`.** That is deliberate: it keeps the blast radius inside
`NowPlayingView.swift`, `ContentView.swift`, `LibraryView.swift` and
`MoreView.swift`, and it means neither item can affect polling, partitions, or
phone streaming.

The one store change in either plan is a two-line read-only computed property
(`MPDStore.activeServer`), which several call sites already re-derive by hand.

## Prior art in `../winrmpc/`

- **Item 1** — `../winrmpc/CLAUDE.md` § "Server switching" describes the same
  operation from the desktop side: `SwitchServer(name)` rebuilds the client,
  reconnects, restores that server's partition, and **clears the previous
  server's per-server state before the new load lands** so stale history can't
  flash. mikMPD's `switchToServer` already does all of this
  (`resetServerState` + `loadRecentlyPlayed` + `loadPlaybackContext`), so item 1
  is only ever a new *entry point* to an existing, working operation — the plan
  adds no switching logic of its own. winrmpc also notes the Snapcast trap
  (a client built against server A silently keeps controlling A after a switch);
  mikMPD's `SnapcastStore` is view-scoped `@StateObject`, so it is rebuilt on
  view entry and the trap does not apply here.
- **Item 2** — no prior art. winrmpc is a desktop sidebar app with the queue
  always visible next to Now Playing; it has no tab-bar budget to spend and
  nothing to port.

## Out of scope

- Reordering or renaming any other tab.
- A queue-count badge on the new tab (noise on a tab that is usually non-empty;
  reconsider separately if the tab proves easy to lose track of).
- Any change to the Now Playing **queue pane** — the in-place pane and the
  Queue tab keep their current division of labour: the pane is for glancing and
  jumping, the tab is for editing and reordering.
- Editing server profiles from the picker beyond an escape hatch into the
  existing `ConnectionView`.
