# Plan: Snapcast control view (More section) — device volume focus

Control snapclients (multiroom endpoints) from the app: per-device volume sliders first,
mute second, everything else later.

## Protocol

snapserver exposes JSON-RPC 2.0 over **raw TCP on port 1705**, newline-delimited — the
same transport shape as MPD, so `MPDSocket`'s conventions carry over directly.

- `Server.GetStatus` → whole tree: `server.groups[]` (id, name, muted, stream_id,
  `clients[]`) and `server.streams[]`. Clients carry `id`, `connected`,
  `host.name`, `config.name`, `config.volume.{percent, muted}`, `config.latency`.
- `Client.SetVolume` `{id, volume: {percent, muted}}` — the focus feature.
- `Group.SetMute` `{id, mute}`.
- Notifications (`Client.OnVolumeChanged`, `Server.OnUpdate`, …) arrive interleaved with
  responses on the same connection — phase 1/2 may ignore them, but the socket's
  read-until-response loop must *skip* lines whose JSON has no matching `id` rather than
  choke on them.

## Architecture (mirror the MPD layers + Swift 6 posture)

- **`SnapcastSocket`** — `nonisolated`, `@unchecked Sendable` POSIX TCP socket like
  `MPDSocket`, under the same invariant: all access after init happens on the owning
  store's serial queue. `request(method:params:) throws -> JSON` writes one JSON-RPC line
  (incrementing `id`) and reads lines until the response with that `id` (skipping
  notifications). Newline-delimited `JSONSerialization` — no Codable on the wire needed
  for requests.
- **`SnapcastStore`** — separate `ObservableObject`, MainActor, own `DispatchQueue`
  (don't entangle with `MPDStore`; snapcast may be down while MPD is fine). Published:
  `groups: [SnapGroup]`, `isConnected`, `connectionError`. Connects when the view
  appears, disconnects on disappear (view-scoped lifecycle — no app-wide reconnect
  machinery), polls `Server.GetStatus` every 2 s while visible.
- **Models** (Models.swift or a new SnapcastModels.swift, `nonisolated`, Codable,
  fixture-testable): `SnapVolume {percent, muted}`, `SnapClient {id, connected, hostName,
  name, volume, displayName}` (`displayName` = config name, falling back to host name),
  `SnapGroup {id, name, muted, streamID, clients}`. Decoded from the `Server.GetStatus`
  result via `JSONDecoder` with a fixture test using a real captured response.

## Configuration (per server profile)

`MPDServerProfile` gains `snapcastHost: String` (empty ⇒ use the MPD host — the common
deployment) and `snapcastPort: Int` (default 1705). **Codable back-compat:** existing
persisted profiles lack the keys, so decode via `decodeIfPresent` with defaults (custom
`init(from:)`) — lock with a test that decodes legacy profile JSON without the new keys.
Edited in `ServerFormView` under a "Snapcast" section (host placeholder "same as MPD").

## UI

- **MoreView row** "Snapcast" (icon `hifispeaker.2.fill`, same row style as Outputs) →
  `SnapcastView` (new file SnapcastView.swift).
- One section per group — header: group name (or stream id when unnamed) + a group mute
  toggle. Rows per client:
  - `displayName`, connected dot (green/gray); disconnected rows dimmed, controls disabled.
  - **Volume slider** — the focus. Same pattern as Now Playing's `volumeSlider`: local
    `@State` copy per row synced from the store, committed via `Client.SetVolume` on
    `onEditingChanged(false)`; the poll refresh skips rows being dragged (per-row drag
    flag), mirroring the seek-lock idea.
  - Mute speaker button toggling `volume.muted` (optimistic, then SetVolume).
- Footer: "Snapcast server at host:port" + error state
  `ContentUnavailableView("Snapcast Unreachable", …)` with a hint to check the server
  form. If no snapcast is configured/reachable the More row still shows — the view
  itself explains, keeping discovery simple.

## Phases

1. **Read-only**: socket + models + `Server.GetStatus` rendered (groups, clients,
   volumes, connection states). Proves transport + parsing.
2. **Control**: `Client.SetVolume` slider commit + client mute + `Group.SetMute`,
   optimistic with poll-skip-while-dragging.
3. **Later (out of scope)**: notification-driven live updates, client rename,
   latency adjustment, moving clients between groups, stream assignment.

## Tests (pure, no server)

- Status JSON fixture → models: groups/clients/volumes, `displayName` fallback,
  disconnected client parsing.
- JSON-RPC request encoding: `Client.SetVolume` payload shape, incrementing ids.
- Response/notification discrimination: given interleaved lines, the matcher picks the
  response with the right id and ignores notifications (pure function over `[String]`).
- Profile Codable: legacy JSON without snapcast keys decodes with defaults; roundtrip
  with them set.
- Volume percent clamping (0…100).

## Risks / notes

- Response/notification interleaving is the only protocol subtlety — covered by the
  line-matcher being a pure, tested function.
- Snapcast group volume semantics: the official clients compute a "group volume" that
  scales member volumes proportionally. **Not** in scope; per-client sliders only
  (matches "volume on devices is focus").
- Port 1705 must be reachable from the phone (LAN); no TLS/auth exists in the snapcast
  control protocol — nothing to store in the Keychain.
