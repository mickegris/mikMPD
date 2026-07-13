# Plan: Discover MPD servers on the local network

MPD advertises itself over Zeroconf/Bonjour as **`_mpd._tcp`** when built with zeroconf support
and `zeroconf_enabled "yes"` (the default in most distro packages). Browse for that service type
with the Network framework and offer found servers in the Connection screen.

Pairs with [saved-servers.md] — a discovered server should be one tap away from becoming a
saved profile. Implement saved servers first (or together); discovery alone can still just fill
the host/port fields.

## Info.plist (required — silent failure without these)

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>mikMPD browses the local network to find MPD servers.</string>
<key>NSBonjourServices</key>
<array><string>_mpd._tcp</string></array>
```

iOS shows the local-network permission prompt on first browse. If the user denies it, the
browser reports `.waiting(.dns(-65570))`-style states — show "Local network access denied,
enable in Settings" rather than an empty list.

## Discovery service (new file `mikMPD/mikMPD/MPDDiscoveryService.swift`)

`@MainActor final class MPDDiscoveryService: ObservableObject` (matches app's ObservableObject
convention):

- `@Published var servers: [DiscoveredServer] = []` where
  `struct DiscoveredServer: Identifiable, Equatable { let name: String; let host: String; let port: Int }`.
- `start()`: create `NWBrowser(for: .bonjour(type: "_mpd._tcp", domain: nil), using: .tcp)`,
  handle `browseResultsChangedHandler`. Results arrive as unresolved
  `NWEndpoint.service(name:type:domain:interface:)` — the service *name* is immediately
  displayable, but host/port need resolution.
- Resolution per result: open a throwaway `NWConnection(to: endpoint, using: .tcp)`; on
  `.ready`, read `connection.currentPath?.remoteEndpoint`, extract `.hostPort(host, port)`,
  cancel the connection, publish. (This is the modern replacement for `NetService.resolve`.)
  Prefer the IPv4/hostname form for display; strip IPv6 scope suffixes (`%en0`).
- `stop()`: cancel browser and any in-flight resolve connections. Start on view appear, stop on
  disappear — don't browse in the background.
- Browser/connection callbacks arrive on their `DispatchQueue` — hop to main before publishing
  (same discipline as MPDStore).

De-dupe by service name (a server advertising on multiple interfaces yields multiple results).

## UI (ConnectionView in SettingsView.swift)

New "Nearby Servers" section above the manual fields:
- Rows: `Label(name, systemImage: "server.rack")` + resolved `host:port` as caption; a
  `ProgressView` row while browsing with no results yet ("Searching…").
- Tap → fill the `host`/`port` `@State` fields (user still taps Connect, password stays manual —
  discovery can't know it). With saved-servers implemented: tap → pre-filled "Add server" form.
- Section footer: "Servers appear here if MPD has Zeroconf enabled." Manual entry remains the
  fallback.

## Notes

- Simulator caveat: Bonjour browsing from the iOS simulator is unreliable; test on device.
- MPD's advertised service name comes from its `zeroconf_name` config ("Music Player @ %h" by
  default) — names are user-configurable, don't parse them.
- Testability: endpoint→`DiscoveredServer` mapping (host string cleanup, scope stripping) can be
  a pure function with unit tests; the browse/resolve flow is manual-test only.
