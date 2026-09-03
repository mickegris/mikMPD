# 1 — Server picker in Now Playing

## The request

> MPD server picker (if more than one server are configured) in the now playing
> view. Somewhere at the upper part of the view. Dropdown or similar.

## Where it goes

`NowPlayingView.connectionStatus` — the banner already at the top of the view
(`NowPlayingView.swift:179`). It is the right anchor for three reasons: it is
already the "which server am I talking to" element, it already has three states
(unconfigured / connected / not connected) that the picker must not disturb,
and it is already at the top of the screen, so nothing moves.

There are currently three affordances of this shape in the view, and they are
**not** consistent with each other by accident:

| Affordance | Control | Why |
|---|---|---|
| `outputsButton` | `confirmationDialog` | 30 pt icon in a side gutter — nothing for a menu to anchor to |
| `partitionButton` | `confirmationDialog` | same |
| **server picker (new)** | `Menu` | anchors to a wide banner; a menu pops *at* the banner, which reads as a dropdown |

The request says "dropdown or similar", and a `Menu` attached to a full-width
banner is the dropdown. Keep the two icon buttons on `confirmationDialog`.

## Behaviour

- **`store.servers.count <= 1`** — the banner renders **exactly as it does
  today**, byte for byte. No chevron, no menu, no tap target. This is the
  common case and it must not change.
- **`store.servers.count > 1`** — the banner becomes the label of a `Menu`:
  - Line 1: the active profile's `name`, followed by a small
    `chevron.up.chevron.down` so it reads as a control. Falls back to
    `host:port` when the profile name is blank (the form does not force a name).
  - Line 2 (connected only): `host:port · Partition: <name>` — the host moves
    down here rather than being dropped, since a named profile is the more
    useful headline but the address is still what you check when something is
    wrong.
  - Menu contents: one button per profile, `✓`-prefixed for the active one
    (matching `partitionButton`'s existing convention), then a divider and
    **Manage Servers…** presenting the existing `ConnectionView` sheet.
  - Selecting the active profile is a no-op. `switchToServer` already guards
    this (`guard force || profile.id.uuidString != activeServerID`), but the
    button should also not be styled as an action that does something.
- The connected/disconnected colouring, the red "Not connected" state and the
  red-tinted background all stay as they are, in both branches.

## Store change

One read-only computed property on `MPDStore`, next to `isConfigured`:

```swift
/// The profile matching `activeServerID`, if it still exists.
var activeServer: MPDServerProfile? { servers.first { $0.id.uuidString == activeServerID } }
```

`ConnectionView` and the picker both need this and both would otherwise
re-derive it inline. Nothing else changes in the store: **the switch itself is
`store.switchToServer(profile)`, unchanged.**

## What makes this safe

`switchToServer` is not new code, and it is not simple code — it saves the
outgoing partition, stops phone streaming, disconnects, clears
`partitionToRestore`, swaps host/port/stream URL, resets per-server published
state, reloads history and playback context, and reconnects. The plan adds a
*caller*, not a variant. The failure mode to watch for is therefore not logic
but **frequency**: the picker puts a full reconnect one tap from the main
screen, where it used to be four (More → Connection → row → select).

Mitigations, in order of how much they matter:

1. **No confirmation prompt.** Considered and rejected — a switch is
   recoverable in one further tap, and a prompt on every switch would make the
   feature worse than the path it replaces. The `✓` on the active row and the
   no-op guard are enough.
2. **The menu is hidden entirely at one server**, so the single-server user
   cannot reach it at all.
3. **Phone streaming**: `switchToServer` already calls `stopPhoneStream()`
   before disconnecting, because the stream URL belongs to the old profile.
   Verify this during QA rather than assuming — it is the one path where a
   mis-ordered teardown leaves the audio session held (see CLAUDE.md,
   "Nothing runs on termination").

## Verification

Unit-testable: nothing meaningful. This is view composition over existing
state; `activeServer` is a one-line lookup. **No new tests** — adding a test
for `first(where:)` would be noise.

Manual, against two real profiles (this needs the LAN):

1. One server configured → banner identical to today, not tappable.
2. Add a second → banner gains the name and chevron.
3. Switch → queue, art, history and "Playing from …" all belong to the new
   server within a second or two; no stale flash from the old one.
4. Switch **while phone streaming** → the stream stops, audio session is
   released, and other apps can play.
5. Switch **while the old server is unreachable** → picker still opens, switch
   still completes, banner turns red for the unreachable one only.
6. Delete the active profile from `ConnectionView` → picker follows the
   automatic switch to the next profile, or disappears when one is left.
7. A profile with a blank name → shows `host:port`, not an empty line.

## What actually happened

The design held — a `Menu` on the banner, hidden at one server, `switchToServer`
called and not modified. Three things only a real screen showed, and two latent
defects found on the way.

### Three fixes the plan did not anticipate

1. **A dangling "Partition:" with nothing after it.** `currentPartition` is
   empty until the first poll lands after a connect, and the banner rendered the
   label anyway. `bannerDetail` now returns nil instead of an empty-valued
   label. This was a pre-existing wart on the single-server banner too; promoting
   the line to carry the address as well is what made it obvious.
2. **The headline needed a line limit.** Profile names are free text and the
   Bonjour-discovered ones are long — this network advertises
   `Music Player @ miknuc[1836667]`. Unbounded, a long name pushes the chevron
   off the banner.
3. **Re-picking the active server had to stop being a pure no-op.** See below —
   this is the interesting one.

### Two latent defects found — both fixed in a follow-up

*(Recorded here as found; the fixes landed after the rest of v1.6, in their own
commit. `shouldRetryConnect` and `shouldAdoptLegacyPassword` are the pure
predicates, both unit-tested, following `shouldMigrateLegacyServer`'s shape.)* here

**`connect()`'s failure path schedules no retry.** The 3-second reconnect loop
lives *only* in `poll()`'s catch. `startTimers()` runs on connect **success**, so
after a failed `connect()` no poll timer exists, no poll ever fails, and nothing
retries. The connection stays down until something else calls `connect()` — a
foreground transition, or an explicit action. Observed directly: switching to an
unreachable profile and back left the app at "not connected" indefinitely.

The picker makes this much easier to reach, so it carries the mitigation the
plan did not foresee: **selecting the active profile while disconnected forces a
reconnect** (`switchToServer(profile, force: true)`), instead of the no-op the
plan specified. The banner is where a broken connection is reported, so it has to
be what you tap to retry. Fixing `connect()` itself is the real repair, and it was done
in a follow-up commit: its catch now schedules a retry through a shared
`scheduleReconnect()`, with `reconnectGeneration` so an explicit connect
supersedes a retry in flight, and `cancelPendingReconnect()` in `disconnect()`
so a retry cannot reopen a socket closed on purpose by backgrounding. A wrong
password and a non-MPD port are excluded — retrying either produces the same
failure forever, and in the first case a failed authentication against someone's
server every three seconds.

Verified end to end against a stub MPD on localhost, which is the only way to
observe it: switch to a host with nothing listening (banner red), start the
server, and the app connects itself within one retry without being touched.
Before the fix it stayed red indefinitely. The reverse — kill the server
mid-session, restart it — recovers too, which exercises the refactored
`poll()` path.

**`loadServersMigratingIfNeeded` has an asymmetric password migration.** The
`servers.isEmpty` branch copies the legacy `mpd_password` Keychain entry to
`mpd_password_<uuid>` when it fabricates the first profile. The
`else if activeServerID.isEmpty` branch below it adopts the first existing
profile as active and does **not**. A profile reached by that second path has no
per-profile password, and MPD's response — ACK on every command — surfaces as
"This server requires a password". Suspected, not proven, as the cause of what
was seen in the simulator; recorded because reading the two branches side by side
is enough to see the gap.

Fixed by moving the adoption **out** of both branches, to the end of
`loadServersMigratingIfNeeded`, where it runs against the active profile
whatever path produced it. That placement is the point: an install already in
the broken state has `activeServerID` set and so takes neither branch ever
again, and a fix inside either one would never reach the people who have the
bug. The legacy entry is deleted once adopted, so it cannot resurrect a password
the user later clears on purpose.

### On the verification that could not be completed

The manual list below was run as far as the environment allowed. The live server
currently refuses unauthenticated commands, and the app's stored password for it
was not available in the simulator, so **switching between two *connected*
servers was not observed end to end** — the switch itself, the banner in both
states, the ✓, the retry and the layout were. The same permission wall fails all
31 tests in the gitignored `mikMPDTests/Local/` suites (`MPD_TEST_PASSWORD`
unset); every one of the 387 tracked tests passes. Items 3, 4 and 5 of the list
still want a pass on a device that can authenticate.
