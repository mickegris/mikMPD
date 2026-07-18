# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Open `mikMPD.xcodeproj` and build the `mikMPD` scheme. No external dependencies — pure SwiftUI + Foundation + AVFoundation + MediaPlayer + Darwin.

Deployment target: iOS 26.2+. Swift 6 language mode with default actor isolation set to `MainActor` in build settings — data-race violations are compile errors. `MPDSocket` is `nonisolated` and `@unchecked Sendable` under the invariant that all access after init happens on the store's serial queue `Q`; pure value types and helpers are `nonisolated`; completion callbacks that cross the socket queue are `@MainActor`.

## Tests

Unit tests use the Swift Testing framework (`mikMPDTests` target). Run via **Product → Test** (Cmd+U) in Xcode.

Tests cover pure logic that doesn't need an MPD server: model init/computed properties, `formatTime`, `String.esc`, `Double.clamped`, `parseMPDRecords` (MPD protocol record parsing), `SavedStation`/`MPDServerProfile` Codable roundtrips, `parseStreamURL` validation, `artCacheKey`, `sourceKind` detection, `mpdMoveTarget` (onMove index conversion), `ackMessage` (ACK prefix stripping), playlist name validation and position assignment, discovery host formatting, Wikipedia album-match validation, and multi-disc handling (`albumBaseAndDisc` marker parsing, `groupAlbumVariants`, `sortedByDiscAndTrack`). One integration-style regression test (`PhoneStreamTests`) starts a phone stream and pumps the run loop to catch actor-isolation traps in SDK callbacks.

`parseMPDRecords` is an internal free function extracted from `MPDSocket` specifically for testability.

## Architecture

This is an MPD (Music Player Daemon) client for iOS/iPadOS.

### Layers

**MPDSocket** — Raw TCP socket using Darwin POSIX APIs. Sends text commands, reads lines until `OK` or `ACK`. Parses responses into `[[String: String]]` records by splitting on `:` and flushing on record-starter keys (`file`, `directory`, `playlist`, `outputid`, `partition`).

**MPDStore** — Single `@Observable` store that owns the socket and all published state. Views never talk to the socket directly. All socket I/O runs on a dedicated `DispatchQueue` (`.userInteractive`); all `@Published` properties update on main thread.

**Views** — SwiftUI views consume `MPDStore` via `@EnvironmentObject`. They are purely reactive — no view-local state for MPD data, only for transient UI concerns (drag state, search text).

**Models** — Lightweight value types (`MPDSong`, `MPDOutput`, `MPDBrowseItem`, `MPDPlaylist`, `MPDServerProfile`) initialized from parsed MPD records or persisted as JSON.

**MPDDiscoveryService** — Bonjour browser (`NWBrowser`, `_mpd._tcp`) that resolves advertised MPD servers to host:port via throwaway `NWConnection`s. Scans stop after a 10 s timeout; the Connection screen offers rescan. Requires `NSBonjourServices` + `NSLocalNetworkUsageDescription` in Info.plist.

### Dual-timer design

- **Poll timer (1s)**: fetches ground truth from MPD (`status`, `currentsong`, `outputs`).
- **Display timer (0.1s)**: smoothly advances `elapsed` during playback without waiting for the next poll.

### Optimistic UI with locking

- **Seek lock (2s)**: after a seek, `elapsed` is locked from poll updates to prevent snap-back while MPD processes.
- **State lock (0.5s)**: after `togglePlay()`, `isPlaying`/`isPaused` are locked from poll to avoid flickering.
- State is captured on main thread *before* dispatching commands to the background queue to avoid races.

### Partition & output model

MPD supports multiple partitions (independent playback zones). The store tracks `outputNameToPartition` by name (not ID, since IDs can shift). Outputs can be moved between partitions; partitions can be created and deleted from OutputsView (delete requires the partition to be empty — MPD's ACK error is surfaced in an alert, cleaned via `ackMessage`). MPD leaves a `plugin=dummy` placeholder in the source partition after `moveoutput`; these are filtered out of the outputs list and the partition-probing map. A "remember partitions" setting restores the last-used partition on reconnect (per server profile).

### Saved servers

Multiple server profiles (`MPDServerProfile`: name, host, port, stream URL, last partition) are stored as JSON in UserDefaults (`mpdServers` + `activeServerID`, both `@Published` with didSet persistence). Passwords are **not** in the JSON — each profile's password lives in the Keychain under `mpd_password_<uuid>`. `host`/`portStr`/`password`/`httpStreamURL` on the store remain the *live* values, loaded from the active profile on `switchToServer`, which also saves the outgoing profile's partition, stops phone streaming, and resets all server-specific published state. A one-time migration in init converts pre-multi-server settings into the first profile — gated by `shouldMigrateLegacyServer`: it only runs when a legacy `mpd_host` was actually *persisted* (`@AppStorage` defaults are never written to UserDefaults), so fresh installs start with no servers instead of a fabricated one. `host` defaults to empty and `connect()` bails when it's blank; `store.isConfigured` drives the first-launch "No MPD Server Configured" alert in ContentView and the "tap to set up" banner in Now Playing (both open ConnectionView). After connecting, a `status` probe detects password-required servers (MPD accepts unauthenticated connections and ACKs every command with a permission error, which would otherwise cause a reconnect loop).

### Stored playlists

`PlaylistListView`/`PlaylistDetailView` live in the Library tab (PlaylistsView.swift). Tapping a track plays it in playlist context (`clear` + `load` + `play <index>`). Reorder uses `playlistmove` with the same optimistic local reorder as the queue's `moveRow`. The shared `AddToPlaylistSheet` is reachable from Now Playing, album detail, queue rows, search rows, and playlist detail rows.

### Phone streaming (listen on phone)

`AVPlayer` plays an MPD httpd output URL on the device. The stream URL is per server profile (edited in the server form) and mirrored into the live `@AppStorage("httpStreamURL")` on switch. A toggle in Now Playing starts/stops the stream.

- **AVAudioSession**: `.playback` category enables background audio (requires `UIBackgroundModes = [audio]` in Info.plist).
- **Lock screen metadata**: `MPNowPlayingInfoCenter` displays title, artist, album, artwork, and elapsed time. Updated every 1s poll cycle (not the 10Hz display timer) — the system extrapolates elapsed time via `playbackRate`.
- **Lock screen controls**: `MPRemoteCommandCenter` routes play/pause/next/previous to MPD commands via the socket queue. Closures capture `Q` and `socket` (both `Sendable`) to avoid `MainActor` isolation issues.
- **Background polling**: A `DispatchSourceTimer` on `Q` polls MPD every 2s while streaming, since `RunLoop`-based timers suspend when the app backgrounds.
- **`parseStreamURL`**: validates http/https scheme and non-empty host. Lives on `MPDStore` as a static for testability.

### Recently played

MPD has no history command, so history is client-side: `RecentlyPlayedRecorder` (Models.swift, pure) is ticked from the poll's main-thread block and commits a song after ~30 s of accumulated wall-clock play (half-duration for short tracks; per-tick delta capped at 5 s so suspended-app gaps don't count; pause freezes the clock; a file change resets, so skips never register; repeat-one logs once per continuous play). One list per server — deliberately partition-agnostic, since the poll only observes the currently tuned partition. Stored in UserDefaults under `recentlyPlayed_<serverID>`, pruned via `prunedRecentHistory` (30 days / 100 entries) on insert and load, reloaded on `switchToServer` (which also resets the recorder), and deleted with the profile. UI: `RecentlyPlayedSheet` (NowPlayingView.swift) from the clock button in the Now Playing header.

### Connection lifecycle

Disconnects on background, reconnects on foreground resume — **unless phone streaming is active** (`isPhoneStreaming` guards the disconnect in `MPDClientApp`). Partition is restored automatically. 3-second retry on connection loss, guarded by `isReconnecting` to prevent stacking.

## Conventions

- MPD command arguments are escaped via `String.esc` (backslash + quote escaping) and wrapped in quotes to prevent injection.
- Password stored in Keychain via `KeychainHelper`; legacy migration from UserDefaults runs on init.
- Album art keyed by `artist|album` (lowercased) with an LRU cache (100 items). Fetch order: MPD-local (`albumart`/`readpicture` binary commands) → MusicBrainz/CoverArtArchive. Both in-memory and disk-cached (`Caches/albumart/`).
- **Multi-disc albums**: `albumBaseAndDisc` (Models.swift) strips trailing disc markers (`[Disc 1]`, `(CD 2)`, `Disk 3`, bare `CD2`; a delimiter must precede the keyword so titles like "ABCD2" survive). Applied in `artCacheKey` (disc variants share one cover), MusicBrainz queries, and `WikipediaService.fetchAlbum`. `MPDSong` parses the `disc` tag; `effectiveDisc` falls back to the album-suffix disc; album tracks sort via `sortedByDiscAndTrack`. Album lists (Library/Artist/Genre/Search) collapse variants into one row via `groupAlbumVariants` ("N discs" caption); `AlbumDetailView.loadSongs` re-expands to sibling variants (one `listTag` probe) and renders "Disc N" sections when tracks span multiple discs. The stripped base title is shown only when variants actually merged.
- Artist/album names are clickable `NavigationLink`s across NowPlaying, Queue, Search, and Library detail views.
- No command batching — each MPD operation is a separate `send`/`receive` cycle ("No command_list, no dual sockets").
- **SDK callbacks that run off-main must be explicitly `@Sendable`.** With default MainActor isolation, closure literals passed to non-`@Sendable` SDK parameters are inferred `@MainActor` and trap at runtime (`dispatch_assert_queue`) if the framework invokes them on another queue. Known cases handled: `MPMediaItemArtwork(boundsSize:requestHandler:)` (MediaPlayer calls it on its internal queue), `DispatchSourceTimer.setEventHandler`, and `MPRemoteCommand.addTarget`. `DispatchQueue.async` is already `@Sendable` in the SDK, so `Q.async` closures are unaffected. The `PhoneStreamTests` regression test guards this class of bug.
- Stored playlists: `listplaylistinfo` returns no pos/id, so positions are assigned from the record index (`songsAssigningPositions`) to keep duplicate files uniquely identifiable. Names are validated via `validatePlaylistName` (no slashes/newlines). Only pre-0.24 command syntax is used (no `playlistadd` POSITION arg, no `save` modes). The shared `AddToPlaylistSheet` (PlaylistsView.swift) is presented via `.sheet(item:)` with an `AddToPlaylistRequest`.
- `WikipediaService` is a Swift actor with in-memory and disk caches (`Caches/artistart/` for artist images). Uses music-aware disambiguation: artist lookups try Wikipedia suffix pages `(band)`, `(musician)`, etc. before falling back to exact title with music-keyword validation. Album lookups clean the tag via `albumLookupTitle` (disc markers + bracketed edition qualifiers like "[24-bit remaster]" — lookups only, never grouping/art keys), then try naming patterns, the plain exact title (music+artist validated), and search over the top 3 hits. A hit whose *title* names the album (`titleMatchesAlbum`: exact or ≥2/3 token overlap) wins immediately; extract-only matches are fallback — a sequel's article cites the album by name in its extract ("Live at Carnegie Hall…" vs the Vienna Opera House album). Disambiguation pages and unrelated results are rejected (blank wiki shown instead).
- `MarqueeText` (NowPlayingView.swift) renders one-line text that ping-pongs (scroll–dwell–scroll back) when it overflows; used for Now Playing's title and album lines. Driven by a trigger-less `PhaseAnimator` — `.animation(value:)` + `repeatForever` gets cancelled by the 10 Hz elapsed re-renders and froze. State resets via `.id(text)`. `AlbumDetailView` keeps its (truncating) inline bar title; the in-page header carries the full name with `fixedSize(horizontal: false, vertical: true)` to guarantee wrapping.
- Now Playing's square region is a three-state pane (`Pane`: art/lyrics/queue); the four small buttons (playlist, history, queue, lyrics) sit in fixed-width columns flanking the pane, not in a header row. Art↔lyrics also toggles by tapping the pane. The tap gesture lives on the art/lyrics panes themselves, **not** the shared container — a container gesture would swallow the queue list's row taps/swipes. The queue pane reuses `QueueRow` (single tap plays; reorder stays in the Queue tab) and auto-centers the current track via `ScrollViewReader` on `playlistPos` changes.
- Album *names* in list rows wrap (no lineLimit); song rows keep `lineLimit(1)`. Now Playing's title and album lines use `MarqueeText`.
- `titleTokensMatch` (Models.swift) is the shared word-level title check for external lookups (Wikipedia article titles **and** MusicBrainz release titles): stopwords dropped, whole-word matching, ≥2/3 overlap with a two-token minimum. In `albumResultMatches`, token overlap counts only toward the title; extracts require exact containment.
- `dedupedAlbumTracks` collapses duplicate library copies (same disc/track/title) on the album page only.
- Every long-press (`.contextMenu`) action has a section-footer hint ("Long press … Swipe …", OutputsView copy style) and a swipe-action equivalent, so long press is never the sole path to an action. Playlist rename is the exception (context menu + hint only).
- Launch screen: `UILaunchScreen` dict in Info.plist (`LaunchLogo` imageset + `LaunchBackground` colorset); `INFOPLIST_KEY_UILaunchScreen_Generation = NO` in both configs — a generated launch screen and the plist dict conflict. Launch images render at intrinsic point size (never scaled), hence the dedicated 180 pt 1x/2x/3x renditions; the logo PNG is opaque white, so the background is fixed white in both appearances. iOS caches launch screens aggressively — delete the app between iterations when changing it.
