# Plan: Fix the fake default server + first-run setup prompt

## Investigation: what a fresh install does today

1. `@AppStorage("mpd_host") var host = "192.168.1.1"` (MPDStore.swift:64) — a hardcoded
   placeholder address.
2. `loadServersMigratingIfNeeded()` (MPDStore.swift:126-143) sees an empty `mpdServers`
   list and **unconditionally** fabricates a profile from the legacy values. On a genuine
   first install that means a persisted, saved server named "192.168.1.1" that the user
   never created.
3. `connect()` (MPDStore.swift:147) then dials 192.168.1.1:6600 — at best a timeout and a
   cryptic red `connectionError` on Now Playing; at worst it's actually poking whatever
   device (usually the router) answers at that address.
4. Nothing tells the user what to do next; ConnectionView (discovery + add form) is buried
   behind More → Connection.

## Fix 1 — stop inventing a server (MPDStore.swift)

`@AppStorage` defaults are *not persisted*: `UserDefaults.standard.string(forKey:
"mpd_host")` is `nil` unless a previous (pre-multi-server) version actually stored a
value. That cleanly distinguishes "real legacy user" from "fresh install":

- Change the `host` default (MPDStore.swift:64) from `"192.168.1.1"` to `""`.
- In `loadServersMigratingIfNeeded`, gate the migration branch:

  ```swift
  if servers.isEmpty,
     let legacyHost = UserDefaults.standard.string(forKey: "mpd_host"),
     !legacyHost.isEmpty {
      // existing migration, using legacyHost
  }
  ```

  Fresh install → `servers == []`, `activeServerID == ""`, `host == ""`. Legacy upgraders
  (the key exists) migrate exactly as before.
- Users who *already* ran the multi-server version on a fresh device have the bogus
  "192.168.1.1" profile persisted — indistinguishable from a deliberately configured one,
  so leave it; they can swipe-delete it. Note this in the commit message.

## Fix 2 — connect() guard (MPDStore.swift:147)

Bail out before touching the socket when there's nothing to dial:

```swift
guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
    DispatchQueue.main.async { self.isConnected = false; self.connectionError = nil }
    return
}
```

Add `var isConfigured: Bool { !servers.isEmpty && !host.trimmingCharacters(in: .whitespaces).isEmpty }`
for the views. The guard also covers the foreground-resume reconnect in `MPDClientApp` and
the 3 s retry path — no connection spam while unconfigured.

## Fix 3 — the question (ContentView.swift)

First-launch prompt, exactly the asked-for shape:

- In `ContentView`, `@State private var showSetupPrompt/showConnection`; `.onAppear`
  (once per launch): if `!store.isConfigured`, raise an alert —
  **"No MPD Server Configured"** / "mikMPD needs an MPD server to play from. Do you want
  to set one up now?" with buttons **"Set Up Server…"** (presents the existing
  `ConnectionView` as a sheet — it already auto-starts Bonjour discovery on appear and has
  the manual Add Server form) and **"Later"** (cancel role).
- Alert, not a custom onboarding screen: one question, two answers, and all the real work
  (scan/add/edit) already lives in `ConnectionView` — no new flow to maintain.

**Persistent affordance after "Later":** Now Playing's `connectionStatus` banner
(NowPlayingView.swift:99-125) currently shows red "Not connected". When
`!store.isConfigured`, show "No MPD server configured — tap to set up" (neutral styling,
not error-red) and make the banner a button presenting the same `ConnectionView` sheet.
Same text swap in ConnectionView's Status section (SettingsView.swift:89-97), which
otherwise shows a stale/nil error.

## Tests (mikMPDTests)

The migration decision becomes a pure function so the regression is locked:

```swift
nonisolated func shouldMigrateLegacyServer(persistedHost: String?, hasServers: Bool) -> Bool
```

- `(nil, false)` → false (fresh install — the bug this plan fixes)
- `("192.168.1.1", false)` → true (legacy user who really used that address)
- `("myhost", false)` → true; `("", false)` → false; `(_, true)` → false
- Existing `ServerProfileTests` migration tests keep passing unchanged.

`connect()` guarding and the alert are not unit-testable (socket/UI) — verify manually:
delete the app in the simulator, launch → prompt appears, no bogus saved server, no
connection attempts; add a server via the form → connects normally. Then simulate the
legacy-upgrade path by seeding `mpd_host` in UserDefaults before first run of this build.
