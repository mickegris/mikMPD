# Plan: Saved MPD servers with quick switching

Today the app has exactly one server: `@AppStorage("mpd_host")`/`("mpd_port")` +
Keychain `mpd_password` + `@AppStorage("httpStreamURL")` (MPDStore.swift:62-70). Turn that into
a list of named server profiles with one active, switchable from the Connection screen.

Pairs with [server-discovery.md] — discovered servers feed the "add profile" flow.

## Model (Models.swift)

```swift
struct MPDServerProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String          // display name, e.g. "Living room"
    var host: String
    var port: Int = 6600
    var streamURL: String = ""   // httpd output URL — server-specific, moves into the profile
    var lastPartition: String = "" // per-server "remember partitions" value
}
```

**Password is not in the struct** (it's JSON in UserDefaults) — store per-profile in Keychain
under `"mpd_password_\(id.uuidString)"` via the existing `KeychainHelper`.

## Persistence & migration (MPDStore)

- `@AppStorage("mpdServers")` `Data` holding `[MPDServerProfile]` JSON (same pattern as
  `SavedStation` in RadioView), plus `@AppStorage("activeServerID")` `String`.
- One-time migration in `init()` (alongside the existing legacy-password migration): if
  `mpdServers` is empty and `mpd_host` is set, create a profile from `mpd_host`/`mpd_port`/
  `httpStreamURL`/`lastUsedPartitionName`, copy Keychain `mpd_password` to the per-profile key,
  mark it active.

## Store changes — keep churn minimal

Keep `host`/`portStr`/`password`/`httpStreamURL` as the *live* connection values exactly as they
are (every call site keeps working). Profiles are the source they're loaded from:

- `var servers: [MPDServerProfile]` (computed decode/encode over the @AppStorage Data, or
  `@Published` mirror refreshed on mutation — decide at implementation; RadioView precedent is
  computed).
- `func switchToServer(_ p: MPDServerProfile)`:
  1. Save current partition into the *old* active profile's `lastPartition`.
  2. `disconnect()`.
  3. Copy `p.host`/`p.port`/`p.streamURL` into the live fields; point `password` at the
     per-profile Keychain key; set `activeServerID`; seed `lastUsedPartitionName` from
     `p.lastPartition`.
  4. Reset server-specific state so stale data doesn't flash: `queue`, `currentSong`, `outputs`,
     `partitions`, `searchResults`, `browseItems`, `playlists` (once stored-playlists lands).
     `albumArtCache` can stay — keys are artist|album, art is server-independent.
  5. If phone streaming is active, `stopPhoneStream()` first (the stream URL belongs to the old
     server).
  6. `connect()`.
- `addServer`, `updateServer`, `deleteServer(id:)` — delete also removes the per-profile
  Keychain entry; deleting the active profile switches to the first remaining one (or
  disconnects if none).

The simplest way to keep `password` working: change its computed accessor to key off
`activeServerID` (fall back to legacy `"mpd_password"` when unset, preserving pre-migration
behavior).

## UI (rework ConnectionView in SettingsView.swift)

- **"Servers" section**: one row per profile — name, `host:port` caption, checkmark on the
  active one. Tap → `switchToServer` (with the green/red status dot reflecting the result).
  Swipe-delete with confirmation. `NavigationLink` (or Edit swipe action) → detail form.
- **Server detail form**: name / host / port / password / stream URL — the current form fields,
  scoped to one profile. Saving the *active* profile re-applies live values (and reconnects if
  host/port/password changed).
- **Add**: toolbar `+` → same form, blank (or pre-filled from a discovered server, see
  server-discovery plan).
- Keep the Status section as is.

## Edge cases

- Deleting the last profile → app returns to "not connected" state with an empty list; the add
  form is the empty-state CTA.
- Two profiles for the same host:port — allowed, harmless (different partitions/passwords are a
  legitimate use).
- `lastUsedPartitionName`/`rememberPartitions` become per-profile via `lastPartition`; the
  global `rememberPartitions` toggle stays global.
- Art disk cache is shared across servers (keyed by artist|album) — acceptable; wrong-art risk
  only if two servers tag the same album differently, same as today.

## Tests

- `MPDServerProfile` Codable roundtrip (mirrors existing `SavedStation` test).
- Migration logic: legacy single-server settings → one active profile (extract as a pure
  function taking the old values and returning `[MPDServerProfile]` + active id so it's testable
  without UserDefaults).
