# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Open `mikMPD.xcodeproj` and build the `mikMPD` scheme. No external dependencies — pure SwiftUI + Foundation + AVFoundation + MediaPlayer + Darwin.

Deployment target: iOS 26.2+. Swift 6 language mode with default actor isolation set to `MainActor` in build settings — data-race violations are compile errors. `MPDSocket` is `nonisolated` and `@unchecked Sendable` under the invariant that all access after init happens on the store's serial queue `Q`; pure value types and helpers are `nonisolated`; completion callbacks that cross the socket queue are `@MainActor`.

**Adding source files**: `mikMPD/mikMPD/` is an Xcode synchronized group — write `.swift` files directly to that directory on disk and Xcode picks them up automatically. Do not use `XcodeWrite` or manually add file references in the project navigator.

`mikMPD` is the only scheme; targets are `mikMPD` and `mikMPDTests`. From the command line (useful for a non-interactive compile check):

```bash
xcodebuild build -project mikMPD.xcodeproj -scheme mikMPD -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Tests

Unit tests use the Swift Testing framework (`mikMPDTests` target), driven by `mikMPD.xctestplan` (single configuration, `parallelizable: false`).

- **Run all**: **Product → Test** (Cmd+U)
- **Run a single test**: click the diamond button in the gutter next to the test function, or right-click it in the Test Navigator and choose **Run**.
- **From the CLI**: build and test in two steps so a rebuild isn't repeated per run —

```bash
xcodebuild build-for-testing -project mikMPD.xcodeproj -scheme mikMPD -destination 'platform=iOS Simulator,name=iPhone 17'
```

```bash
xcodebuild test-without-building -project mikMPD.xcodeproj -scheme mikMPD -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:mikMPDTests/AlbumDiscTests
```

Tests cover pure logic that doesn't need an MPD server: MPD protocol parsing (`parseMPDRecords`, `parseGroupedValues`), all model helpers and computed properties, Codable roundtrips, album/disc grouping, Snapcast model decoding and wire helpers, Wikipedia/MusicBrainz match logic, recently-played derivation, and Bonjour host formatting. One integration-style regression test (`PhoneStreamTests`) pumps the run loop to catch actor-isolation traps in SDK callbacks.

`parseMPDRecords` is an internal free function extracted from `MPDSocket` specifically for testability.

### Live integration tests (local only)

`mikMPDTests/Local/` holds suites that talk to a real MPD server, and it is **gitignored** — a fresh clone has no live tests at all. `LocalTestSupport.swift` defines the host/port constants and `withSocket`, which runs each test body on a dedicated serial queue to honour `MPDSocket`'s `@unchecked Sendable` invariant. Suite gates, in ascending order of risk:

- **Groups A–C (read-only: connection, capability probe, library fixtures)** — gated on `integrationEnabled`, which is a *reachability probe* (a real `connect()` at load time), deliberately **not** an env var. Off-LAN runs therefore skip rather than fail.
- **Group D (mutating)** — `MPD_INTEGRATION_MUTATE=1`. Every test captures a `ServerSnapshot` (state, position, elapsed, volume, all modes, queue) and restores it in `defer`.
- **Group E (dangerous: partition lifecycle, daemon-hang repro)** — double-gated on `MPD_INTEGRATION_DANGEROUS=1` *and* a `private let iAcceptDaemonHangRisk` literal that must be flipped in the file and never committed as `true`.
- **Group W (Wikipedia, real HTTP)** — `WIKI_INTEGRATION=1`.

**Pass these on the command line with a `TEST_RUNNER_` prefix.** The tests run in a separate process inside the simulator, which does **not** inherit the invoking shell's environment — `MPD_TEST_PASSWORD=… xcodebuild test-without-building` silently does nothing and every live test fails with `ACK [4@0] … you don't have permission`, which reads like a server misconfiguration rather than a missing variable. `xcodebuild` forwards `TEST_RUNNER_<VAR>` to the runner as `<VAR>`:

```bash
TEST_RUNNER_MPD_TEST_PASSWORD='…' xcodebuild test-without-building -project mikMPD.xcodeproj -scheme mikMPD -destination 'platform=iOS Simulator,name=iPhone 17'
```

**Never put these env vars in `mikMPD.xctestplan`.** It is the only place Xcode can store scheme env vars once a test plan is in use, and it is *tracked* — committing `MPD_INTEGRATION=1` there turned the gate on for every clone and had to be reverted twice. That history is why the read-only gate became a reachability probe instead.

## Repo layout notes

`plans/` (design/review notes, one per feature) and `mikMPDTests/Local/` are both gitignored, so the `plans/…` cross-references throughout this file resolve only on a machine that has them. `docs/plans/` is tracked. `TESTING.md` is a manual QA checklist (launch screen, first-run setup, multi-disc, marquee, queue pane, recently played, swipe/long-press parity) — work through it for release-shaped changes; the first two sections need a fresh install.

## References

**MPD protocol**: https://mpd.readthedocs.io/en/stable/protocol.html#command-reference  
Full command reference for all MPD text commands. Consult before adding new MPD operations — covers filters, tags, binary commands (`albumart`, `readpicture`), partition commands, stickers, channels, and more.

### Verified server behavior (checked against MPD 0.24.0)

Facts confirmed by querying a real server, each of which cost debugging time to learn:

- **Filter values are case-sensitive.** `list disc album "Live at Leeds"` returns nothing;
  `list disc album "Live At Leeds"` returns all four discs. When an exact-name query comes back
  empty, suspect capitalisation before concluding the tag is missing or differently shaped —
  a mis-cased probe was once misdiagnosed as "the album uses disc markers in its name".
  Prefer scoping by artist/albumartist and matching case-insensitively in Swift.
- **`xfade` is omitted from `status` when crossfade is 0** (not reported as `xfade: 0`).
  `poll()` handles this with `Int(s["xfade"] ?? "0") ?? 0`; any new status field may be absent
  when it holds its default.
- **ReplayGain mode is per partition and is not in `status`** — only
  `replay_gain_status` reports it, so the poll never sees it change. Refresh it
  explicitly whenever the connection's partition changes. Crossfade and MixRamp
  are per partition too, but do appear in `status`.
- **ACK does not always keep the connection alive.** A bad *argument* on a *known* command
  ACKs and leaves the socket usable (`setvol 9999`). Some builds close the TCP connection
  outright for an *unknown* command, which surfaces as a non-ACK I/O error and disconnects.
  Capability probes that fall back on failure must check `socket.connected` before retrying —
  see the caveat comment in `MPDSocket.command`.
- **Multiple `group` keys are supported**: `list disc group albumartist group album` works and
  interleaves `Album:` / `AlbumArtist:` / `Disc:` lines (empty `Disc:` for untagged albums).
  `listDiscCounts` currently uses the single-key form plus a base-name-uniqueness guard;
  the two-key form would make disc counts artist-aware and remove that limitation, but needs a
  two-key variant of `parseGroupedValues`.
- **Only the `default` partition's queue survives a daemon restart.** Other partitions' queues
  are runtime state and come back empty; partitions created with `newpartition` vanish; outputs
  return to their mpd.conf partitions. Learned when 0.24.0 aborted mid-test — so a live test that
  touches partitions must back up **every** partition's queue, not only the ones it uses
  (`ServerSnapshot` covers the current partition alone).
- **0.24.0 can abort** (SIGABRT, uncaught `std::system_error`: "Invalid argument"). Seen once,
  during a queue transfer whose target played into an httpd output that `moveoutput` had moved
  into a runtime-created partition, while the source's httpd output had been enabled seconds
  earlier. **The transfer sequence itself does not reproduce it**: with fifo and httpd outputs,
  either side playing, both partitions playing at once, HTTP clients attached to both httpd
  outputs, and ten back-to-back transfers at app speed, the daemon survived every command. The
  two conditions never retested — a moved output in a runtime partition, and an output enabled
  mid-run — are the remaining suspects; see `docs/plans/v1.7/01-transfer-queue-between-partitions.md`.

### MPD stickers (v1.5 candidate)

Per-song metadata stored by MPD clients on the server. `<type>` is always `"song"` in practice.

| Command | Purpose |
|---|---|
| `sticker get song <uri> <name>` | Read one sticker value |
| `sticker set song <uri> <name> <value>` | Write one sticker value |
| `sticker delete song <uri> <name>` | Remove a sticker |
| `sticker list song <uri>` | List all stickers on a song |
| `sticker find song <base> <name>` | Find all songs under a path with a given sticker |

**Planned use**: star ratings (1–5) stored as sticker name `rating`. Requires `sticker_file` set in mpd.conf — probe availability on connect with `sticker list song ""` and check for non-ACK (set `stickersAvailable: Bool` on `MPDStore`).

**Not planned**: MPD channels (`subscribe`/`sendmessage`/`readmessages`) — low value for a single-client setup; document only.

## Architecture

This is an MPD (Music Player Daemon) client for iOS/iPadOS.

### Layers

**MPDSocket** — Raw TCP socket using Darwin POSIX APIs. Sends text commands, reads lines until `OK` or `ACK`. Parses responses into `[[String: String]]` records by splitting on `:` and flushing on record-starter keys (`file`, `directory`, `playlist`, `outputid`, `partition`). **Every socket sets `SO_NOSIGPIPE`** (MPDSocket and SnapcastSocket alike): without it the first `send()` after the peer resets the connection raises SIGPIPE, which kills the app with no Swift error to catch — verified, exit 141. The background poll writes every 2 s while phone streaming, so a Wi-Fi blip or an MPD restart on a locked phone was enough. `SocketResetTests` pins it with a loopback server that resets; without the option that test takes the whole test run down, so it cannot pass by accident.

**MPDStore** — `final class MPDStore: ObservableObject`. Single store that owns the socket and all `@Published` state. Views never talk to the socket directly. All socket I/O runs on a dedicated `DispatchQueue` (`.userInteractive`); all `@Published` properties update on main thread.

**Views** — SwiftUI views consume `MPDStore` via `@EnvironmentObject`. They are purely reactive — no view-local state for MPD data, only for transient UI concerns (drag state, search text). Tab structure (ContentView.swift): Now Playing, Library, Queue, Search, More. **Five is the ceiling, not a preference** — a sixth tab makes UIKit collapse the last two into its own system "More" beside mikMPD's, so adding a top-level destination means taking the slot from another (v1.6 spent Browse's on the queue).

**BrowserView** — Filesystem-style MPD library browser, reached from the Library tab's **Files** chip (it had its own tab until v1.6). Single tap navigates directories; double-tap adds and plays a file or loads a playlist. Swipe actions: add to queue (green) or play immediately (blue, files only). Toolbar shows current directory name with Up and Home buttons. Uses `store.browse(_:)`, `store.browseUp()`, `store.browseItems`, `store.isAtRoot`, `store.browsePath`. It has **no `NavigationStack` of its own** — it is a destination inside `LibraryView`'s, and nesting two breaks the toolbar. Its `navigationTitle` still doubles as the breadcrumb: the innermost title wins over `LibraryView`'s "Library" (`CDView` already relied on this).

**SearchView** — Searches songs (`store.searchResults`), artists, albums, and stored playlists simultaneously via a cancellable `Task`. Shows four result sections (Artists → NavigationLink to artist albums; Albums → AlbumGroup rows; Playlists; Songs → SongRow with context menus). `AddToPlaylistSheet` reachable from song rows. Playlist search (`store.searchPlaylists`) matches both the playlist *name* and its *contents*: contents go through MPD 0.24's `searchplaylist`, probed lazily per connection (`playlistSearchAvailable`, Q-only) because an unknown command can drop the socket rather than ACK, with a `listplaylistinfo` + client-side-filter fallback. Bounded three ways — at most 20 playlists per search, `window 0:50` per playlist, and a generation counter so a superseded fan-out's results are discarded.

**LibraryView** — One file (LibraryView.swift, the largest view file) holding the whole Library tab: a scrolling chip bar over `LibTab` (Albums, Artists, Recent, Genres, Playlists, Radio, CD, Files — `allCases` order *is* the chip order, so new tabs append rather than insert), plus `AlbumListView`, `ArtistListView`, `GenreListView`/`GenreDetailView`, `AlbumDetailView`, `RecentlyAddedView`, `RadioView`, `CDView`, `BrowserView`, and the shared row/grid helpers. Albums and Recently Added share a list/grid toggle persisted in `@AppStorage("libraryAlbumLayout")` (`LazyVGrid` with `GridItem(.adaptive(minimum: 130))`); sort order persists in `librarySortAlbums`/`librarySortArtists`. `RecentlyAddedView` derives `AddedAlbum`s from the bounded `loadRecentlyAdded` query and records per album whether *any* track carried an `albumartist`, since that decides the `artistTag` handed to `AlbumDetailView`.

**Models** — Lightweight value types (`MPDSong`, `MPDOutput`, `MPDBrowseItem`, `MPDPlaylist`, `MPDServerProfile`) initialized from parsed MPD records or persisted as JSON.

**MPDDiscoveryService** — Bonjour browser (`NWBrowser`, `_mpd._tcp`) that resolves advertised MPD servers to host:port via throwaway `NWConnection`s. Scans stop after a 10 s timeout; the Connection screen offers rescan. Requires `NSBonjourServices` + `NSLocalNetworkUsageDescription` in Info.plist.

### Dual-timer design

- **Poll timer**: fetches ground truth from MPD (`status`, `outputs`, and `currentsong` only when `songid` changed). Runs at 1s while playing, throttled to 3s while paused/stopped (`setPollingInterval`) to cut connections and main-thread dispatches.
- **Display timer (0.1s)**: smoothly advances `elapsed` during playback without waiting for the next poll. It runs only when `displayTimerShouldRun` — MPD playing, the scene `.active`, **and** at least one on-screen view displaying time (`PlaybackClock.observers`, counted by `.observesPlaybackClock`) — so it never ticks in the background, on the Library tab, or while paused.
- **`elapsed` lives on `PlaybackClock`, not on the store** (`store.clock`, injected as its own environment object; `store.elapsed` forwards to it). An `ObservableObject` has one `objectWillChange`, so a 10 Hz `@Published` on the store re-rendered all ~30 views observing it — an iOS CPU resource report caught the Albums list regrouping ~820 albums ten times a second (57 % CPU for minutes, on battery). Only `NowPlayingSeekBar` and `SyncedLyricsView` observe the clock. Bitrate was dropped from the UI for the same reason (it changed on nearly every poll); the audio format, which changes per song, stays on the store and is shown readably via `formatAudioFormat`.
- **Lock-screen info is sent on change, not per poll** (`nowPlayingInfoNeedsUpdate`): the song, play state or artwork changing, or the position jumping more than 2 s from where the system's own extrapolation would put it. The `MPMediaItemArtwork` is built once per song.
- `elapsed` is only reassigned on poll when the value actually changed, and `currentsong` is skipped when `songid` is unchanged from `lastSongID` (cached in `lastSong`) — both avoid redundant `@Published` churn during steady-state playback/pause.

### Optimistic UI with locking

- **Seek lock (2s)**: after a seek, `elapsed` is locked from poll updates to prevent snap-back while MPD processes.
- **State lock (0.5s)**: after `togglePlay()`, `isPlaying`/`isPaused` are locked from poll to avoid flickering.
- State is captured on main thread *before* dispatching commands to the background queue to avoid races.

### Partition & output model

MPD supports multiple partitions (independent playback zones). The store tracks `outputNameToPartition` by name (not ID, since IDs can shift). Outputs can be moved between partitions; partitions can be created and deleted from OutputsView (delete requires the partition to be empty — MPD's ACK error is surfaced in an alert, cleaned via `ackMessage`). MPD leaves a `plugin=dummy` placeholder in the source partition after `moveoutput`; these are filtered out of the outputs list and the partition-probing map. A "remember partitions" setting restores the last-used partition on reconnect (per server profile).

### Saved servers

Multiple server profiles (`MPDServerProfile`: name, host, port, stream URL, last partition) are stored as JSON in UserDefaults (`mpdServers` + `activeServerID`, both `@Published` with didSet persistence). Passwords are **not** in the JSON — each profile's password lives in the Keychain under `mpd_password_<uuid>`. `host`/`portStr`/`password`/`httpStreamURL` on the store remain the *live* values, loaded from the active profile on `switchToServer`, which also saves the outgoing profile's partition, stops phone streaming, and resets all server-specific published state. A one-time migration in init converts pre-multi-server settings into the first profile — gated by `shouldMigrateLegacyServer`: it only runs when a legacy `mpd_host` was actually *persisted* (`@AppStorage` defaults are never written to UserDefaults), so fresh installs start with no servers instead of a fabricated one. `host` defaults to empty and `connect()` bails when it's blank; `store.isConfigured` drives the first-launch "No MPD Server Configured" alert in ContentView and the "tap to set up" banner in Now Playing (both open ConnectionView). After connecting, a `status` probe detects password-required servers (MPD accepts unauthenticated connections and ACKs every command with a permission error, which would otherwise cause a reconnect loop).

**The legacy password is adopted, not just migrated.** `loadServersMigratingIfNeeded` ends by calling `adoptLegacyPassword(for:)` on the active profile, gated by `shouldAdoptLegacyPassword`, which moves a pre-multi-server `mpd_password` Keychain entry to `mpd_password_<uuid>` and then deletes the legacy one so it can happen only once (otherwise deliberately clearing a profile's password would resurrect the old one next launch). It runs *outside* both migration branches on purpose: the branch that merely **adopts** an existing profile as active used to leave the password behind — unlike the branch that **creates** one — and an install already in that state takes neither branch again, so a fix inside either would never reach the people affected. The symptom is the password-required probe firing against a server whose password the app is still holding.

**Switching servers is reachable from Now Playing** (v1.6): when `servers.count > 1`, `connectionStatus` becomes a `Menu` listing every profile — a `Menu` rather than the `confirmationDialog` the outputs/partition gutter icons use, because a full-width banner is something a menu can anchor to. `store.activeServer` resolves `activeServerID` to a profile; `serverLabel` falls back to `host:port` for an unnamed one. Selecting the **active** profile is a no-op *unless* the app is disconnected, in which case it forces a reconnect. That escape hatch was written when a failed `connect()` scheduled no retry at all and the banner was the only way back; the retry is fixed now (see "Connection lifecycle"), so it is no longer the *only* way back — but it stays, because a user looking at a red banner should not have to wait out a timer they cannot see.

### Transferring a queue between partitions

Roon's "transfer zone": the queue, current track, position and play state move to
another partition, and the source stops. **MPD has no transfer command**, and the
obvious build is the wrong one — `playlistinfo` plus one `add` per track is the
shape that starved the poll on a large artist, and a big response can outrun the
socket's 5 s read timeout. **Stored playlists are global across partitions**, so
`save` in the source and `load` in the target moves any queue in two commands.

**The ordering is the safety property.** The source is not cleared until the
target holds the queue and has started; a failure before that leaves the source
untouched, which is the state the user can least afford to lose. **This is not
`moveoutput`** and does not carry its daemon deadlock (`plans/move-active-output-hang.md`)
— no output is touched, only the partition binding and queue commands.

The scratch playlist lands in the user's own `playlist_directory`, so it is
treated like a lock file: **uniquely named per transfer** (`.mikmpd-transfer-<hex>`,
because one fixed name collides between two devices transferring at once),
removed on every exit path, **swept on each `loadPlaylists`**, and filtered from
the visible list. The sweep is **age-gated** on `Last-Modified`
(`isStaleTransferPlaylist`) — an ungated sweep deletes another device's in-flight
transfer, becoming the bug it fixes — and an undatable entry is never swept.

`storedPlaylistsAvailable` is probed **read-only** with `listplaylists`, which
fails exactly as `save` does when `playlist_directory` is unset, so availability
costs no write; `canTransferQueue` is the published mirror. When it is off the app
**names the setting and the file** rather than hiding the control.

**Consume, crossfade, MixRamp and ReplayGain belong to the partition and never
travel** — on either side. In MPD each partition has its own player, so all four
are per partition; v1.7 copied the source's `consume` onto the target, which the
user saw as the transfer "intermittently" changing settings (only when the two
partitions differed). The app also read ReplayGain only on connect, so after
following the music the button showed the *source's* mode — `switchPartition` and
the transfer now refresh it. `performTransfer` snapshots both partitions'
`PartitionSettings` before anything changes and checks them afterwards; drift is
put back and reported in `TransferResult.notes`, and the outcome is logged to
`MPDCommandLog`. `transferTargetSetupCommands` is pure so a test can pin that no
partition-owned command is ever sent. **Repeat, random and single do travel**,
read raw from the source's `status` on `Q` (so `single oneshot` survives),
because they describe how this queue is played — a shuffled playlist stays
shuffled. **Volume does not**, since it belongs to the target's outputs.
The whole Q-side sequence is `MPDStore.performTransfer(on:…)`, static and
socket-parameterised so the live test (`LiveTransferSettingsTests`, between two
throwaway output-less partitions with the source stopped — nothing plays) drives
exactly what the app runs. The
app follows to the target afterwards — **and must record it the way a manual
switch does** (`lastUsedPartitionName`, when "Remember partitions" is on).
Without that, the refresh that follows still sees the source as remembered and
`restorePartitionIfNeeded` switches straight back to it.

**Nothing touches the source until the target is audibly playing.** A transfer
into `default` with its DAC and receiver switched off aborted MPD 0.24.0
(`terminate called recursively`, uncaught `std::system_error`), while the old
resume sent `play`, `seekcur` and the source's `clear`/`stop` in the same
instant. A failed output open is survivable on its own — the restarted daemon
logged `Failed to open "E30 II"` and carried on — so the resume is now:

1. refuse a target with **no enabled outputs** before anything changes
   (`transferTargetOutputsRefusal`, from that partition's `outputs`);
2. `clearerror`, so an old `error:` cannot pass for a new one;
3. start with **one** command, `transferStartCommand` — `seek SONGPOS TIME`
   starts a stopped player at that point (verified on 0.24.0), so there is no
   separate seek while outputs are opening;
4. poll `status` until `transferStartOutcome` sees `state: play` **with elapsed
   advancing between two samples** and no `error:` (`play` on its own is not
   trusted), or 8 s pass — `default`'s USB DAC and HDMI outputs took 1.7 s to
   confirm on the real server, against 0.2 s for fifo and httpd, and a timeout
   only delays the failure message;
5. only then pause (if the source was paused) and stop the source.

If the target never plays, it is stopped and cleared and the source is left
exactly as it was. An output that is enabled but whose device is off cannot be
seen before trying; this makes trying harmless rather than impossible.

**The abort itself has not been reproduced.** Moving into `default` with its DAC
and receiver reported off — a plain `play`, three runs of the old sequence and
three of the new — survived every time, and `status` showed no `error:`, so at
least one of that partition's outputs opened. The live refusal and success paths
are verified; the "target never plays" path is covered only by unit tests.

The entry point is a **separate Move Playback button** (⇄) in Now Playing's right
gutter, opening `MovePlaybackSheet`: every other partition with its enabled
outputs and state (`PartitionSummary`, from `loadPartitionSummaries`), with
partitions that have none disabled. It first shipped as extra rows in the
partition switcher's dialog, where "switch to" and "move playback to" sat one row
apart and read as the same kind of action.

**The current song and position transfer, and the position is compensated.** The
resume reads `status` **on `Q`, immediately before the `save`** rather than using
the main-thread `elapsed`, which the 10 Hz display timer has interpolated since
the last poll. More importantly the source *keeps playing* while the queue is
saved, loaded and started, so `transferCompensatedElapsed` adds the measured
transfer duration — without it the music jumps backwards by however long the
transfer took, which is small on a LAN and not small when `save`/`load` hit slow
storage with a long queue. A paused source is never compensated (it did not
advance), and the result is clamped short of the track end, since overshooting
skips the very track the user was listening to.

### Stored playlists

`PlaylistListView`/`PlaylistDetailView` live in the Library tab (PlaylistsView.swift). Tapping a track plays it in playlist context (`clear` + `load` + `play <index>`) — and **that index is a queue position, not the row's playlist index**. Stored playlists outlive their files: `listplaylistinfo` returns an entry whose file is gone as a bare `file:` line (no tags, no duration, no `Last-Modified`), and `load` silently skips it, moving every later row up one place. Playing by playlist index therefore lands on the wrong song for every row below the first dead entry; on a real 417-entry playlist with five, that was **410 of 412** rows. `playlistQueueIndex(forPlaylistIndex:in:)` maps a row to where `load` will actually put it. `MPDSong.isMissingFromLibrary` is the detection — library source, *and* no `lastModified`, *and* zero duration, so a date that fails to parse cannot flag a real song, and streams and CD tracks (never in the database) are excluded. `PlaylistDetailView` shows such entries as `MissingPlaylistRow` (filename, "Missing file", the folder it was in), offers no queue actions for them, explains on tap with a Remove option, and still lets them be swiped away; the header counts playable tracks and missing ones separately. Reorder uses `playlistmove` with the same optimistic local reorder as the queue's `moveRow`. The shared `AddToPlaylistSheet` is reachable from Now Playing, album detail, queue rows, search rows, and playlist detail rows.

### Playback context ("Playing from <playlist>")

`playbackContext` holds the stored-playlist name the queue was built from, and is **persisted per server** (`playbackContext_<serverID>`), restored on launch and on `switchToServer`, deleted with the profile. It used to be plain in-memory state, which is why the label vanished after shuffling a playlist and leaving the app: every playlist entry point sets it, but a relaunch — including the silent one after iOS reclaims a backgrounded app — dropped it, and shuffling is precisely the "start it and come back later" action.

A *restored* label describes a queue this app did not watch being built, so it is verified once per connection (`playbackContextVerified`) via `listplaylist` (URIs only) against `playlistinfo`. `playbackContextStillValid` compares them as **sets, not sequences** — `shuffle` reorders the queue on purpose — and requires the queue to be a **subset**: a superset means tracks were added afterwards, so the queue is no longer just that playlist. All writes go through `setPlaybackContext`, which also marks the value verified, since an action taken in this app needs no checking. "Add" onto an *empty* queue sets the context; onto a non-empty one it clears it.

### Phone streaming (listen on phone)

**Two players, chosen per stream start.** `AVPlayer` handles what it can open
(mp3, AAC, wav); `OggStreamPlayer` handles Ogg, which it never could. Selection
is `StreamPlayerKind.forContentType(_:)` against the response's `Content-Type` and
is **never persisted** — the codec is MPD's configuration, so changing the
server's encoder needs no action in the app, no relaunch, and there is no codec
setting anywhere in the UI. An unclear or missing content type falls back to
`AVPlayer`, which knows more containers than we do. **The probe reads headers only**
(`URLSession.bytes(for:)`, then cancel): an httpd output never ends, and the first
version used `dataTask`, whose completion fires only when the body does — it
downloaded a whole finite test file before answering and would have sat out its
10 s timeout on every real stream start. **A lost stream is retried, then ends phone
streaming**: a server close or a transient `URLError` puts the Ogg player in
`.reconnecting(attempt:)` — 1, 2, 4, 8 s (`oggReconnectDelay`), about 15 s in all —
and only a spent budget becomes `.failed`, which `endsPhoneStream`. v1.7 ended
streaming at the first `.idle`, so any Wi-Fi blip or MPD restart silently switched
the feature off; before that, reacting to `.failed` alone left "Streaming to
phone" on screen over silence. Neither regresses: `.idle` now only follows an
explicit `stop()`, and nothing retries beyond the budget. Each player's callbacks carry a token so a late one from a
torn-down player cannot stop its successor. **Supported encoders are mp3,
Opus and FLAC**, stated under the Stream URL field and again in the failure
message; Ogg Vorbis is identified and refused, because iOS has no Vorbis decoder
at all (`vorb` is absent from `kAudioFormatProperty_DecodeFormatIDs` and "Vorbis"
appears nowhere in the SDK headers) and vendoring libvorbis for a codec Opus
supersedes is not a trade worth making.

**`OggDemuxer` exists because the container parser is undocumented, not because
it is missing.** `AudioFileStream` *does* parse Ogg on iOS 26 — verified, every
packet, even with no type hint — but `AudioFile.h` declares no Ogg type constant,
so it is unpublished behaviour that can be withdrawn. The codec side stays
Apple's: `kAudioFormatOpus` and `kAudioFormatFLAC` are in the public
`CoreAudioBaseTypes.h`. **No magic cookie is set**, deliberately — Apple's Opus
cookie is a 28-byte blob with no published layout, and a fully specified ASBD
alone decodes byte-identically, so the undocumented format is designed out rather
than depended on.

The demuxer is pure (bytes in, packets out; no Foundation networking, no
AudioToolbox), which is what lets it be tested exhaustively with no server and no
device. Three things it must keep doing, each learned rather than assumed: it
**joins mid-page**, since httpd starts sending at connect time; it **validates
every page's CRC**, because `OggS` occurs inside packet payload and scanning
alone resyncs onto garbage; and it **reports new logical bitstreams**, because a
chained stream at a track boundary otherwise presents as "plays the first track
and then goes quiet". Ogg's CRC-32 is polynomial `0x04c11db7`, init 0, **no
reflection and no final xor** — not the zlib variant; a reflected implementation
makes every page look corrupt, which presents as "no audio" rather than as a
checksum bug. Opus **pre-skip** (RFC 7845) is dropped from the front of the
decoded stream, or every stream opens with a click.

**Decoding lives in `OggPacketDecoder`**, separate from the player so real Opus
packets can be decoded in a unit test — the only place this path's audio is
actually checked, since a simulator cannot be listened to. **The first version
produced silence and reported nothing**: a new `AVAudioPCMBuffer` has
`frameLength` 0 and its buffer list advertises only `frameLength` bytes, so the
converter saw no room, wrote nothing and returned success — **set `frameLength =
frameCapacity` before the fill**, then shrink to what was produced. Three more
defects sat in the same function, and none of them is allowed back: the output
`AudioBufferList` must be `mutableAudioBufferList` itself, never a copy — the
standard format is non-interleaved, so a stereo list holds two `AudioBuffer`s and
the Swift struct has room for one; the input pointer is valid only inside the
`withUnsafeBytes` scope that **encloses** `AudioConverterFillComplexBuffer` (turning
the stored array into a pointer inside the callback dangled, and the compiler said
so in a warning); and when its packet is spent the callback returns the non-zero
`packetSpent`, not `noErr` with zero packets, which tells the converter the whole
*stream* has ended. `OggPacketDecoderTests` pins this with a synthetic stereo tone —
440 Hz left, 554 Hz right — so a silent channel, a decoder that stops after one
packet, or pre-skip applied twice each fails a test.

**The Ogg player's lifecycle (v1.7.1), each part learned from a field report.**
*Jitter buffer* (`OggBufferPolicy`): play at 2 s buffered, pause and refill to 2 s
at an underrun (≤ 0.25 s), and drop incoming audio beyond 6 s — v1.7 buffered 0.5 s
once and then stuttered through every hiccup, and nothing bounded how far behind
MPD the phone could drift. *The engine is configured per format, never per
bitstream*: MPD's Opus encoder starts a new chained bitstream at **every track
change** (verified live: six bitstreams over five skips), and v1.7 tore the engine
down for each one, cutting the song's tail and restarting from an empty buffer —
"failed to play next song". The decoder is still replaced per bitstream (pre-skip
and STREAMINFO belong to it); `LiveOggPlayerTests` pins one engine configuration
across five track changes. *`node.play()` is only ever called on a running
engine* (`playNodeLocked`) — on a stopped one it raises an Objective-C exception
Swift cannot catch — and `AVAudioEngineConfigurationChange` is observed and
rebuilt from. *Health is checked on every data arrival*: "playing" with nothing
played back for 3 s (`oggStreamStalled`) means the engine died under the player,
at no timer cost. *Buffer completions carry a generation*, so completions of
discarded audio (which `node.stop()` fires) cannot drive the frame count
negative. *Decoded packets are coalesced into ~100 ms buffers*, 10 schedules a
second instead of 50. The idle timeout is 10 s: MPD's httpd output sends encoded
silence while paused (verified), so silence on the wire means the server is gone.
**FLAC needs its STREAMINFO to decode at all.** `AudioConverterNew` refuses a
FLAC format with frames-per-packet 0 — v1.7 passed exactly that, so Ogg FLAC never
played — and a value below the block size decodes nothing; no magic cookie is
needed (all verified with the system decoder). `FLACStreamInfo` supplies the block
size, channels and the **source's** sample rate, which MPD's FLAC encoder passes
through (a CD rip is 44.1 kHz, and may change at a track boundary);
`OggFLACFixtures` holds generated 44.1 k, 48 k and chained streams, and the tests
check the tones come out at their true frequency.
**Interruptions are the store's job too** (`observeAudioInterruptions`):
`.began` suspends the player (`suspendPhoneStreamPlayer` — the stream is let go,
so a silent phone uses no network or audio power), `.ended` with `.shouldResume`
rejoins the live stream (`resumePhoneStreamPlayer`), never a stale buffer.
`phoneStreamSuspended` counts as rendering for the background check, so being
quiet on purpose never switches the feature off.

**Audio route changes are the store's job while streaming** (`observeAudioRoute`,
removed on stop). `phoneStreamRouteAction` stops the stream when a device goes
away — headphones unplugged, Bluetooth gone — because AVAudioEngine stops itself
then, and the button used to stay on "Streaming to phone" with no sound from any
speaker. A device *arriving* restarts the Ogg stream onto the new route (AVPlayer
follows by itself), and every other reason is ignored, including the category
change the app makes when streaming starts, which would otherwise loop.

`OggStreamPlayer` is `nonisolated` by necessity: URLSession delivers on its own
queue and CoreAudio calls the converter's input proc on a render thread, where
MainActor inference traps. `handleEnteringBackground` asks
`isStreamActuallyRendering`, which consults whichever player is live — without an
Ogg-side answer, the "dead stream holds the audio session open" bug returns for
Ogg users only.

`AVPlayer` plays an MPD httpd output URL on the device. The stream URL is per server profile (edited in the server form) and mirrored into the live `@AppStorage("httpStreamURL")` on switch. A toggle in Now Playing starts/stops the stream.

- **AVAudioSession**: `.playback` category enables background audio (requires `UIBackgroundModes = [audio]` in Info.plist).
- **Lock screen metadata**: `MPNowPlayingInfoCenter` displays title, artist, album, artwork, and elapsed time. Sent only when it changes (see "Dual-timer design") — the system extrapolates elapsed time via `playbackRate`. A reconnecting Ogg stream is reported as `.interrupted`, not `.playing`.
- **Lock screen controls go through the store** (`handleRemote`), not straight to the socket as in v1.7, which skipped the optimistic state and the lock-screen update and fired `try? sock.command(…)` into whatever state the socket was in. The `addTarget` closures are `@Sendable` and hop to the main actor explicitly. `remoteCommandMPD` sends explicit `pause 1`/`pause 0` (a bare `pause` does nothing on a stopped player, and a lock-screen pause must never become a resume through stale state). The command is sent by `sendEnsuringConnection`, which reconnects first when the socket is down or has been idle past `mpdConnectionNeedsRefresh`'s 45 s — MPD drops idle clients after `connection_timeout` (60 s default), and a phone iOS suspended while paused wakes for the press with a dead socket — and retries once on a fresh connection. Each remote command is logged with how long it waited on `Q`.
- **The phone follows MPD's play state** (`isPlaying` didSet → `phoneStreamFollowMPD`), from this app's buttons, the lock screen or another client via the poll. A pause *suspends* the player — silent at once, stream closed — and play rejoins the stream at the live point. v1.7 left the phone playing out its buffer after a pause (AVPlayer holds up to 30 s), which read as the lock-screen pause being ignored, and resumed with stale audio; it also received, decoded and played MPD's encoded silence for as long as MPD stayed paused. Starting phone streaming while MPD is not playing starts suspended. **Phone streaming belongs to the partition it was started in** (`phoneStreamPartition`): the stream is that partition's httpd output, and `isPlaying` describes whichever partition the app is on — so following it after a switch muted the phone (target paused) or kept it on a stream nobody was controlling, and moving the queue away and back started the phone speaker unasked (device testing, v1.7.1). Leaving that partition — a manual switch or a Move Playback — stops phone streaming, and the toggle goes off (`phoneStreamPartitionAction`; an empty partition mid-reconnect is never a reason). Reconnects therefore always return to the partition they left: `scheduleReconnect` records it, and a failed attempt hands it on to the next. `phoneStreamSuspended` counts as rendering in the background check, so a paused phone keeps the feature on and its lock-screen controls.
- **Background polling**: A `DispatchSourceTimer` on `Q` polls MPD every 2s while streaming, since `RunLoop`-based timers suspend when the app backgrounds.
- **`parseStreamURL`**: validates http/https scheme and non-empty host. Lives on `MPDStore` as a static for testability.

### Recently played

MPD has no history command, so history is client-side: `RecentlyPlayedRecorder` (Models.swift, pure) is ticked from the poll's main-thread block and commits a song after ~30 s of accumulated wall-clock play (half-duration for short tracks; per-tick delta capped at 5 s so suspended-app gaps don't count; pause freezes the clock; a file change resets, so skips never register; repeat-one logs once per continuous play). One list per server — deliberately partition-agnostic, since the poll only observes the currently tuned partition. Stored in UserDefaults under `recentlyPlayed_<serverID>`, pruned via `prunedRecentHistory` (30 days / 100 entries) on insert and load, reloaded on `switchToServer` (which also resets the recorder), and deleted with the profile. UI: `RecentlyPlayedSheet` (NowPlayingView.swift) from the clock button in the Now Playing header; shows an Albums/Tracks segmented picker — album tiles via `recentAlbumGroups` (pure derivation), track list below. Timestamps shown as "Today / Yesterday / N days ago" via `relativeDay`.

**Scope limitation:** recording only happens while the app is active. The foreground poll (RunLoop timer) drives the recorder normally. The background `DispatchSourceTimer` on `Q` also runs — but only when phone streaming is active. Songs played on the MPD device while the app is backgrounded *without* phone streaming are never captured.

### Non-library playback sources (radio, CD)

Not every playing item is a library file, and several views branch on which it is. `MPDSong.sourceKind` (`PlaybackSourceKind`: `.library` / `.radio` / `.cd`) is derived from the file URI alone — `cdda:` prefix → CD, an `http`/`https`/`icy` scheme → radio, otherwise library — and drives `fallbackArtAssetName` (`MikMPDLogo` / `RadioFallbackArt` / `CDFallbackArt`) so art-less streams still get a sensible tile. It also gates actions that don't apply: "Add Next" appears only for `.library` rows (search, playlist detail), and Now Playing's Add-to-Playlist button hides for `.cd` — CD tracks can't live in a stored playlist, though stream URLs can.

**Radio** (`RadioView`): a hardcoded `builtInStations` list (Swedish Radio P1–P4) plus user stations persisted as JSON in `@AppStorage("savedRadioStations")` (`SavedStation`: name + url, `id` is the url). Playing a station is just `store.addAndPlay(uri:)` with the stream URL; the "now playing" indicator compares `station.url == store.currentSong.file`.

**CD** (`CDView`): tracks are the `cdda:///N` URIs MPD exposes; `probeCDTracks` enumerates them, `playCD(track:)` / `addCD(track:)` play or enqueue one, and `playCD()` with no argument plays the bare `cdda:///` whole-disc URI.

### Server statistics and database update

More → Statistics reads MPD's `stats` into `MPDStats` (`loadStats`, `@Published serverStats`/`statsError`) and formats durations with `formatDuration` ("Nd Nh Nm"). The same screen triggers `update` / `rescan` via `updateDatabase(rescan:)`, which returns immediately; progress is observed through `isUpdatingDB`, set by the poll from the presence of `updating_db` in `status` — so it reflects scans started from *any* client, and the figures refresh themselves when the scan finishes. Both commands need MPD's `admin` permission and ACK otherwise, which is surfaced through `statsError` rather than silently doing nothing.

### Snapcast multiroom control

`SnapcastView` (More tab) connects to a Snapcast server's JSON-RPC 2.0 control port (default 1705, TCP, newline-delimited). The Snapcast host/port are per-server-profile (`snapcastHost`/`snapcastPort` on `MPDServerProfile`); host defaults to the MPD host when blank.

**Transport** — `SnapcastSocket` (`nonisolated @unchecked Sendable`, same pattern as MPDSocket) owns the raw Darwin POSIX TCP socket. It sets `SO_NOSIGPIPE` (see MPDSocket) and **both** `SO_SNDTIMEO` and `SO_RCVTIMEO` (5 s), like MPDSocket: with a send timeout only, the reader Thread blocked in `recv()` indefinitely and could be stopped solely from outside, by `disconnect()`'s `shutdown()`. Snapcast is push-based and usually idle, so a receive timeout is the *normal* case — `readOneLine` returns nil on it (letting `readLoop` re-check whether it is still the current connection, which is the thread's only way to end itself) and retries on `EINTR` rather than tearing down. Access invariant: `connect()` and `request()` only from `SnapcastStore`'s serial queue `Q`; `disconnect()` is thread-safe (callable from any thread). A dedicated reader Thread (started inside `connect()`) runs continuously, reading newline-delimited JSON lines and routing them:
- Lines with a matching `"id"` → fulfill the `DispatchSemaphore` in the waiting `request()` call on Q.
- Lines with a `"method"` but no `"id"` → Snapcast push notifications; dispatched via `onNotification: (@Sendable (String, Data) -> Void)?` (params serialized to `Data` for Sendable compliance).
- `disconnect()` calls `Darwin.shutdown(fd, SHUT_RDWR)` to unblock any blocking `recv()` in the reader Thread, then closes the fd and fails all pending semaphores.
- A per-request `DispatchSemaphore` (not a loop polling lines) delivers responses; the reader Thread delivers via `pendingCallbacks: [Int: (Result<Any,Error>)->Void]` protected by `NSLock`.

**State** — `SnapcastStore` (view-scoped `ObservableObject`, `@StateObject`): `@Published var groups: [SnapGroup]`, `@Published var streams: [SnapStream]`. A 2s `DispatchSourceTimer` on Q polls `Server.GetStatus` for ground-truth; notifications update state immediately between polls.

**Notification handling** — `SnapcastStore.handleNotification(method:paramsData:)` runs on main actor (via `DispatchQueue.main.async`). Handled events: `Client.OnVolumeChanged` → `applyClientVolume`; `Client.OnConnect` → `refreshStatus()` (re-poll); `Client.OnDisconnect` → `applyClientConnected`; `Client.OnLatencyChanged` → `applyClientLatency`; `Client.OnNameChanged` → `applyClientName`; `Group.OnMute` → `applyGroupMute`; `Group.OnStreamChanged` → `applyGroupStream`; `Server.OnUpdate` → decode full state from params (no extra request needed).

**Commands** — optimistic-then-RPC pattern (same as MPDStore): `Client.SetVolume`, `Client.SetLatency`, `Client.SetName`, `Group.SetMute`, `Group.SetStream`, `Server.DeleteClient`, `Group.SetClients` (used by `moveClient(clientID:fromGroupID:toGroupID:)` which calls SetClients on both source and destination groups).

**Models** — `SnapClient` (id, connected, hostName, name, volume, latency), `SnapGroup` (id, name, muted, streamID, clients), `SnapStream` (id, status). Decoded by `decodeSnapGroups`/`decodeSnapStreams` (pure `nonisolated` functions, testable). `displayName` on clients falls back to `hostName`; on groups falls back to `streamID`.

**UI** — group sections: stream picker row (shown only when `streams.count > 1`, `Picker(.menu)` calling `setGroupStream`); group mute toggle; per-client rows with connected dot, display name, latency badge ("+Xms", hidden when 0), mute button, volume slider with drag-lock. Context menu (using `Section {}` groupings for separators — `Divider()` is ignored in contextMenu on iOS): Full Volume, Mute/Unmute, Rename (alert + `setClientName`), Set Latency (alert + `setLatency`), Move to Group submenu (ForEach otherGroups → `moveClient`), Remove from Server (disconnected only → `deleteClient`). Swipe-left on disconnected clients also removes. A "Show disconnected clients" toggle at the bottom of the list (default off, state in `showDisconnected`) hides groups and clients with no connected member; groups with no visible clients are suppressed entirely. Drag-lock: `draggingClients: Set<String>` prevents the 2s poll from snapping sliders mid-drag. `decodeSnapGroups`/`decodeSnapStreams` expect the inner server object (`result["server"]`); `poll()` and `refreshStatus()` unwrap this key before decoding.

### Connection lifecycle

Disconnects on background, reconnects on foreground resume — **unless phone streaming is active**. Partition is restored automatically.

**The 3-second retry covers both ways a connection can fail, and it did not always.** It used to be scheduled *only* from `poll()`'s catch — but `startTimers()` runs on connect **success**, so after a failed `connect()` no poll timer existed, no poll could fail, and nothing ever retried: a connection that failed at `connect()` stayed down until a foreground transition. `connect()`'s catch now schedules one too, through the shared `scheduleReconnect()`.

Two failures are deliberately **not** retried, via `shouldRetryConnect(after:)` (Models.swift): `authFailed`, because retrying means a failed authentication against someone's server every three seconds forever, and `badHandshake`, because whatever answered that port is not MPD. A password-*required* server never reaches this at all — its probe returns rather than throws.

`isReconnecting` still prevents stacking, and `reconnectGeneration` is what lets an explicit `connect()` supersede a retry already in flight rather than racing it into a second connect. `cancelPendingReconnect()` is called from both `connect()` and `disconnect()`, so a retry armed three seconds ago cannot reopen a socket the app has just closed on purpose — backgrounding being the case that matters.

`MPDClientApp` calls `store.handleEnteringBackground()` rather than testing `isPhoneStreaming` inline, because that flag alone is not evidence of playback: a stream that failed or was stopped by the server left it true forever, which held the audio session open (so other apps were never told they could resume) and suppressed the disconnect indefinitely. The check is `isStreamActuallyRendering`: suspended on purpose (MPD paused, an interruption) → keep; otherwise the Ogg player's `isRendering`, or `streamPlayer?.timeControlStatus == .paused` → stop the stream; `.waitingToPlayAtSpecifiedRate` is a stream still buffering and is left alone.

**Nothing runs on termination.** There is no AppDelegate, no `applicationWillTerminate`, and no `deinit` anywhere — a force-quit is a SIGKILL, so the only defence against leaving system-level state behind is not to depend on cleanup running. Two consequences to preserve:

- `startPhoneStream` tears down **before** touching the audio session. It used to activate the session and then call `stopPhoneStream()`, which deactivated it again with `.notifyOthersOnDeactivation` — telling the very apps it was about to interrupt that they could resume — and then called `play()` on a just-deactivated session.
- `MPNowPlayingInfoCenter.playbackState` is set alongside `nowPlayingInfo`, and to `.stopped` when clearing it. The playback *rate* in the info dict is not enough: the system reads `playbackState` to decide whether this app is still the playing one, and without it a stale mikMPD card can outlive the stream in Control Center.

**More → Diagnostics → Clear Album Art Cache** deletes every cached cover *and* every `.miss` marker, then re-fetches the current song's art. It exists because a failed art lookup is remembered for 7 days, so fixing a lookup bug otherwise appears to change nothing; changing an art *key* has the same effect from the other direction, leaving old entries unreachable.

## Conventions

- MPD command arguments are escaped via `String.esc` (backslash + quote escaping) and wrapped in quotes to prevent injection.
- Password stored in Keychain via `KeychainHelper`; legacy migration from UserDefaults runs on init.
- **Never read `@Published` state from inside `Q.async`** — those properties are main-thread state. Capture what the command needs into a local *before* dispatching (`let v = repeatMode; Q.async { … }`), and hand results back through `completion: @escaping @MainActor (…)` parameters, which is how every `MPDStore` query returns.
- **No derived collections computed in `body`.** Grouping, sorting and filtering of library-sized lists go into `@State`, recomputed when an input changes (`AlbumListView`, `GenreDetailView`, `ArtistListView`). In `body` they run on every store change. `AlbumGroup.groupingKey` is stored, and album rows compare against `store.currentAlbumIdentity` (derived once per song) through the precomputed-key `isCurrentAlbum(rowKey:…)` overload, not by re-deriving both keys per row per render.
- Rows that start playback use the shared `.playableRow { … }` modifier (LibraryView.swift), which adds the tap target, a light `Haptics.tap()`, and a 350 ms accent-colour flash. Use it rather than a bare `.onTapGesture` so play feedback stays uniform across radio, CD, and library rows.
- Enumerations that a view cycles through belong in Models.swift with their order and display names attached — see `ReplayGainMode` (`allCases` order *is* the cycle order, `next` wraps, `label` is the display name). The Now Playing view previously duplicated the order as a string array and the names as a ternary chain, so adding a mode meant editing two files in step.
- **Artist tags fall back both ways.** `MPDSong.displayArtist` (artist → albumartist) is the mirror of `groupingArtist` (albumartist → artist); both go through `tagOr`, where a **present-but-blank tag counts as absent** and the returned value is deliberately **untrimmed** (it feeds `artCacheKey`, and trimming would orphan cached art for padded tags). Use `displayArtist` wherever a name is shown, navigated to, or sent to LRCLIB; `groupingArtist` for album identity, `artKey`, and cover-art lookups. Files with an AlbumArtist and no Artist are common, and used to read as "Unknown Artist" everywhere except the album page.
- **Artist comparison for external lookups is `artistCreditMatches`, not string equality.** It accepts either of two fingerprints (letters only, lowercased): diacritics folded (`Motörhead` ↔ `Motorhead`), or **non-ASCII letters dropped from the *unfolded* string** — the latter exists for mojibake, where the two sides disagree about which accented letter it is (this library holds `Blue Îyster Cult` for `Blue Öyster Cult`; folding gives i-vs-o and still misses, dropping leaves `blueystercult` both ways). Folding first would defeat it, since `î` folds to an ASCII `i` that then survives the drop. The ASCII-only path is length-guarded at 6. `normalizedForLookup` also collapses whitespace runs — a real tag here is `"Blue  Oyster Cult"` with two spaces.
- Album art keyed by `artist|album` (lowercased) with an LRU cache (400 items — the grid's working set is ~800 albums; 100 thrashed). Fetch order is **tag art → cover file → internet**: `readpicture` (picture embedded in the file's own tags), then `albumart` (cover.jpg/png beside the song), then MusicBrainz/CoverArtArchive. Tag art is probed first because on a tagged library it is the one that exists — asking `albumart` first cost a wasted ACK round trip per album. Both in-memory and disk-cached (`Caches/albumart/`).
- **Art fetching is throttled on three axes, and all three matter at grid scale.** A grid tile only knows `artist`/`album`, so `fetchArt` resolves one representative track first (`find album … artist … window 0:1`) and tries MPD-local art before the internet — without that, every tile went straight to MusicBrainz at up to ~15 round trips per album. `ArtFetchGate` (ArtFetch.swift) caps concurrent fetches at 4, since a grid otherwise opens hundreds in parallel. `MusicBrainzThrottle` serialises MusicBrainz to ~1 req/s, which their usage policy requires. Failures write a zero-byte `<key>.miss` marker next to the disk cache with a 7-day TTL, so art-less albums are not re-attempted on every scroll pass. Thumbnails use `.task(id:)` rather than `.onAppear` so scrolling away cancels pending work.
- **Bulk enqueue is server-side.** `enqueueMatching(tag:value:)` uses MPD's `findadd`; the old path fetched every song then sent one `add` per track, so "Play All" on a large artist or genre was thousands of sequential commands that starved the poll for minutes. Ordering comes from MPD's database order, which for the usual Artist/Album/NN-Track layout matches the previous client-side album/track sort. `enqueue(songs:)` remains for explicit song lists (albums, playlists, search selections).
- **Every MPD command is logged.** `MPDCommandLog` (MPDCommandLog.swift) keeps a 250-entry ring buffer of `(time, command, duration, outcome)`, written from `MPDSocket.command`/`rawLines` and read by `DiagnosticsView` (More → Diagnostics → MPD Command Log, with copy-to-clipboard). **Off by default** — the `diagnosticsEnabled` setting mirrors into `MPDCommandLog.isEnabled` (thread-safe, read on Q), so a disabled log costs nothing per command and turning it off clears the buffer. Commands slower than 2 s are highlighted. This exists because the daemon has hung hard enough to need `kill -9` with nothing on the client recording what it was doing — see `plans/mpd-hang-investigation.md`.
- Reordering goes through `mpdMoveTarget(from:to:)` (Models.swift): SwiftUI's `onMove` destination is an index into the *pre-removal* array, MPD's `move`/`playlistmove` TO argument is an index *after* removal, so dragging downward is off by one without the conversion. (`addNext(uri:)` is unrelated to that off-by-one — it just captures `playlistPos + 1` on the main thread and passes it as `addid`'s position argument.)
- **"Recently added" means added, not modified, and the query must sort server-side.** `RecentlyAddedQuery` (Models.swift) is a three-rung ladder — `find "(added-since …)" sort -Added` (MPD 0.24+), `find "(modified-since …)" sort -Last-Modified` (0.22+), then the unsorted legacy form — tried in order per connection and remembered on `MPDStore` (Q-only, reset on connect). `modified-since` compares the file's mtime, which any re-tag bumps: adding replay-gain tags to this library made it match **10,054** songs over 30 days against **619** genuinely added, i.e. the whole library. Separately, `find` returns matches in database order (directory traversal) and `window` slices *that*, so without a server-side sort the cap drops by path order and a newly added album can never reach the client — sorting client-side afterwards cannot recover a row the server never sent. MPD applies `sort` before `window` (not stated in the protocol docs; pinned by a live test), so a descending sort makes the cap drop the oldest instead. `MPDSong.added` parses the 0.24 `Added` field. **All three rungs need MPD 0.21's filter-expression syntax** (`find "(…)"`; before that only `find TAG VALUE` existed), so on 0.20 and older every rung ACKs and the view shows its empty state rather than wrong data — and re-probes on each appearance, since no rung is remembered. `firstAcceptedRecentlyAdded` (Models.swift) takes its effects as closures precisely so the fallbacks are testable: the real server is 0.24 and answers on the top rung every time, so a broken fallback would otherwise surface only on someone else's older MPD. It stops walking when the socket drops, since an ACK is not the only failure mode.
- Unbounded library queries must be bounded: `loadRecentlyAdded` windows every rung at 2000 and holds an in-flight guard. Unbounded, it walks the whole library and can outrun the socket's 5 s read timeout, which disconnects mid-response and leaves MPD generating output for a client that has gone away — and the 3 s reconnect then re-issues it.
- **Multi-disc albums**: `albumBaseAndDisc` (Models.swift) strips trailing disc markers (`[Disc 1]`, `(CD 2)`, `Disk 3`, bare `CD2`; a delimiter must precede the keyword so titles like "ABCD2" survive). **A marker sitting at the tail of a qualifier bracket re-closes it**: `"X [24-bit Remaster CD 1]"` → `"X [24-bit Remaster]"`, not `"X [24-bit Remaster"`. Only the marker is removed, never the bracket around it — a remaster is a distinct library album, and dropping the whole bracket would fold it into the plain edition. The unbalanced form was the bug: it was displayed, used as the art key, and sent to Wikipedia and MusicBrainz, where no such album exists, and `albumLookupTitle` could not strip it either because its qualifier regex requires a closing bracket. Applied in `artCacheKey` (disc variants share one cover), MusicBrainz queries, and `WikipediaService.fetchAlbum`. `MPDSong` parses the `disc` tag; `effectiveDisc` falls back to the album-suffix disc; album tracks sort via `sortedByDiscAndTrack`. Album lists collapse variants into one row via `groupAlbumVariants` ("N discs" caption); `AlbumDetailView.loadSongs` re-expands to sibling variants (one `listTag` probe) and renders "Disc N" sections when tracks span multiple discs. The stripped base title is shown only when variants actually merged.
- **Disc count comes from two independent signals, and both are needed.** Real libraries mix the conventions: "Live At Leeds" is *one* album tag with `disc` tags 1–4, "Quadrophenia [Disc 1]/[Disc 2]" puts the marker in the album name, "'98 Live Meltdown (disc 1)" uses lowercase parens. Name markers alone (`discCountFromVariants`) report a properly-tagged multi-disc album as single-disc — the better the tagging, the worse the display. So `listDiscCounts` issues `list disc [FILTER] group album` alongside each album list and maps *lowercased base name* → highest disc number, `discTagValue` parses the tag (`"1/4"` → 4, the denominator wins when present), and `albumDiscCount(variants:tagDiscs:)` takes the **max** of both signals so agreeing signals don't double-count. `AlbumGroup.tagDiscs` carries the tag value; views fill it in after the query returns. Captions gate on `discCount > 1`, never `variants.count > 1` — a mixed-tagged album ("X" + "X [Disc 1]") has 2 variants but 1 disc and must not render "1 discs". `AlbumDetailView` uses `isMultiDisc` (`songsByDisc.count > 1 && maxDiscNumber > 1`) for both its header prefix and its "Disc N" section split. Because `list disc group album` groups by name only, `AlbumListView`/`GenreDetailView` apply `tagDiscs` **only when the base name is owned by exactly one artist in the current list**, so a multi-disc "Greatest Hits" can't stamp its count onto another artist's single-disc album of the same name. `SearchView` still counts name variants only — a known, deliberate gap.
- **Album identity is punctuation-folded.** `albumGroupingKey` (Models.swift) strips disc markers then folds en/em dash and minus sign → hyphen, smart quotes → straight, ellipsis → "...", trims and lowercases. It is *only* ever a key — display always uses the raw tag. It exists because two rips of one album can differ by a single character: The Beatles' "1967-1970" (ASCII hyphen, disc 2) and "1967–1970" (en dash, disc 1) are separate directories and separate album tags, which split one 2-disc set into two single-disc rows, each with a wrong caption and half the tracks. Used by both `groupAlbumVariants` overloads, `AlbumGroup.groupingKey`, `listDiscCounts`' map keys, `AlbumDetailView.loadSongs`' sibling matching, and SearchView's album collapsing — **all of these must agree**, or a row won't find its own disc data. Folding only punctuation and case is safe because the artist remains part of every key that uses it. (`artCacheKey` is deliberately *not* folded: changing it would orphan the whole album-art disk cache for a cosmetic gain.)
- **A compilation is detected by its directory, not its tags.** Files of a various-artists album often carry **no AlbumArtist at all**, and MPD substitutes each track's Artist — so `list album group albumartist` reports "Jackie Brown" as 14 albums by 14 artists. `compilationIdentity(files:)` (Models.swift) returns the longest common directory of an album's tracks, and `collapsingCompilations` merges rows whose base name is shared by more than one artist **only** when that directory exists. Measured over the whole library, exactly 5 of 820 albums carry >1 album artist and the directory settles every one: Jackie Brown and Legends Of Metal live in one directory each (merge), while `Greatest Hits` (Dylan/RHCP) and `Live` (Fleetwood Mac/UFO) live in two (leave alone). Detection probes only those few candidates, and results are cached per session.
  - The merged row's `variants` are **uniqued by name**: they are the same album tag repeated once per track artist, not disc variants, and counting them rendered "14 discs".
  - `AlbumGroup.compilationBase` carries the directory. `compilationSongs(album:base:)` selects the tracks with MPD's `base` filter — no artist filter can, which is the whole point — and `isCurrentAlbum` matches a compilation by file prefix, since "Various Artists" matches no song's tags.
  - **Art keys on the directory but must not *look up* by it.** The key has to be unique per compilation, yet a path matches no MusicBrainz artist credit; `fetchArtIfNeeded(compilationBase:album:)` therefore keys on the directory and searches with an **empty** artist, which is the right question for a compilation anyway. Jackie Brown has neither embedded art nor a cover file, so the internet is its only source — verified working.
  - Wikipedia gets **no artist** for a compilation: "Various Artists" would be a guaranteed miss.
- **Album identity includes the artist.** Albums/Genre lists use `listAlbumsByArtist` (`list album [FILTER] group albumartist`, MPD 0.21+, flat name-only fallback on ACK) and show one `AlbumGroup` row per (albumartist, base) with an artist caption — same-named albums by different artists are separate rows. Grouped responses need `MPDSocket.rawLines` + `parseGroupedValues` (a `list … group …` response has no record-starter keys, so `parseMPDRecords` collapses it and `listValues` drops the group). `AlbumDetailView` takes `artistTag` ("albumartist" from grouped lists, "artist" from song links — different tags for compilations); sibling merging and `find` are always artist-filtered, and **merging is skipped when no artist is known**. `dedupedAlbumTracks` collapses duplicate library copies keyed `groupingArtist|disc|track|title` — the artist in the key is what makes it safe (a key without it merged same-titled tracks across artists and had to be reverted once).
- Artist/album names are clickable `NavigationLink`s across NowPlaying, Queue, Search, and Library detail views.
- No command batching — each MPD operation is a separate `send`/`receive` cycle ("No command_list, no dual sockets").
- **SDK callbacks that run off-main must be explicitly `@Sendable`.** With default MainActor isolation, closure literals passed to non-`@Sendable` SDK parameters are inferred `@MainActor` and trap at runtime (`dispatch_assert_queue`) if the framework invokes them on another queue. Known cases handled: `MPMediaItemArtwork(boundsSize:requestHandler:)` (MediaPlayer calls it on its internal queue), `DispatchSourceTimer.setEventHandler`, and `MPRemoteCommand.addTarget`. `DispatchQueue.async` is already `@Sendable` in the SDK, so `Q.async` closures are unaffected. The `PhoneStreamTests` regression test guards this class of bug.
- Stored playlists: `listplaylistinfo` returns no pos/id, so positions are assigned from the record index (`songsAssigningPositions`) to keep duplicate files uniquely identifiable. Names are validated via `validatePlaylistName` (no slashes/newlines). Only pre-0.24 command syntax is used (no `playlistadd` POSITION arg, no `save` modes). The shared `AddToPlaylistSheet` (PlaylistsView.swift) is presented via `.sheet(item:)` with an `AddToPlaylistRequest`.
- `WikipediaService` is a Swift actor with in-memory and disk caches (`Caches/artistart/` for artist images). Uses music-aware disambiguation: artist lookups try Wikipedia suffix pages `(band)`, `(musician)`, etc. before falling back to exact title with music-keyword validation. Album lookups clean the tag via `albumLookupTitle` (disc markers + bracketed edition qualifiers like "[24-bit remaster]" — lookups only, never grouping/art keys), then try naming patterns, the plain exact title (music+artist validated), and search over the top 3 hits. A hit whose *title* names the album (`titleMatchesAlbum`: exact or ≥2/3 token overlap) wins immediately; extract-only matches are fallback — a sequel's article cites the album by name in its extract ("Live at Carnegie Hall…" vs the Vienna Opera House album). Disambiguation pages and unrelated results are rejected (blank wiki shown instead).
- `LyricsService` (LyricsService.swift) is a Swift actor that fetches lyrics from LRCLIB (no API key required). `Lyrics` holds `plain: String?`, `synced: [LyricLine]?`, and `instrumental: Bool`; `LyricLine` has `secs` and `text`. `LyricsState` enum (`.loading`, `.unavailable`, `.loaded(Lyrics)`) is consumed by the Now Playing lyrics pane. Negative results are cached to avoid repeat hits. Disk cache at `Caches/lyrics/`. Modeled after `WikipediaService`.
- `MarqueeText` (NowPlayingView.swift) renders one-line text that ping-pongs (scroll–dwell–scroll back) when it overflows; used for Now Playing's title and album lines. Driven by a trigger-less `PhaseAnimator` — `.animation(value:)` + `repeatForever` gets cancelled by the 10 Hz elapsed re-renders and froze. State resets via `.id(text)`. `AlbumDetailView` keeps its (truncating) inline bar title; the in-page header carries the full name with `fixedSize(horizontal: false, vertical: true)` to guarantee wrapping.
- Now Playing's square region is a three-state pane (`Pane`: art/lyrics/queue); the four small buttons (playlist, history, queue, lyrics) sit in fixed-width columns flanking the pane, not in a header row. **The panes carry no tap gesture** — tapping the artwork to flip to lyrics was removed because accidental taps kept triggering it, so the flanking buttons are the only toggles. (Were one ever restored, it would have to live on the art/lyrics panes themselves and never on the shared container, which would swallow the queue list's row taps/swipes.) The queue pane reuses `QueueRow` (single tap plays; reorder stays in the Queue tab) and auto-centers the current track via `ScrollViewReader` on `playlistPos` changes.
- **Synced lyrics follow the song until you tell them not to.** `lyricsFollow` (view-local `@State`, reset per track) gates the autoscroll, and a Sync/Scroll capsule in the lyrics pane's corner toggles it — shown only when synced lyrics exist, since plain lyrics have no autoscroll to disable. Unconditional autoscroll made the pane unreadable anywhere but the current line: scrolling back to an earlier verse survived only until the next lyric line. Re-enabling snaps immediately rather than at the next line change. Auto-detecting a manual scroll instead does **not** work — the scroll observer also fires for the pane's own `scrollTo`, so it switches itself off. `activeLyricLine` is the single implementation of "which line is current"; its `syncOffset` must *delay* the advance, and a test pins the sign because a flipped one still looks plausible.
- **The playing track is marked in every list, by one rule and one look** (`NowPlayingRow.swift`). `isCurrentTrack` matches library listings by **URI**; `isCurrentQueueRow` matches the queue by **position**, and only the queue — a queue can hold the same file twice, while elsewhere a row's `pos` means something else entirely (in `PlaylistDetailView` it is the *playlist* index), so a position compare there lights up an arbitrary row: wrong highlighting rather than missing highlighting. Empty matches nothing, so a stopped player marks no row. `isCurrentAlbum` marks the album *containing* the playing track in album lists, grids, Recently Added/Played and Search, comparing the **disc-collapsed, artist-scoped** `albumGroupingKey` so a playing "[… CD 2]" lights the single collapsed row; it is false for an album-less current song, which is what stops a radio stream marking every untagged album. Accepted: the same file twice in one listing marks both rows.
- Album *names* in list rows wrap (no lineLimit); song rows keep `lineLimit(1)`. Now Playing's title and album lines use `MarqueeText`.
- `titleTokensMatch` (Models.swift) is the shared word-level title check for external lookups (Wikipedia article titles **and** MusicBrainz release titles): stopwords dropped, whole-word matching, ≥2/3 overlap with a two-token minimum. In `albumResultMatches`, token overlap counts only toward the title; extracts require exact containment.
- Every long-press (`.contextMenu`) action has a section-footer hint ("Long press … Swipe …", OutputsView copy style) and a swipe-action equivalent, so long press is never the sole path to an action. Playlist rename is the exception (context menu + hint only). **Search is exempt from the footer half**: its results are already four stacked sections and a hint under one of them reads as clutter in a list you are scanning, not dwelling in. The swipe actions and context menus stay — that is the part the rule is actually about — and every action there is also reachable from the destination the row navigates to.
- Launch screen: `UILaunchScreen` dict in Info.plist (`LaunchLogo` imageset + `LaunchBackground` colorset); `INFOPLIST_KEY_UILaunchScreen_Generation = NO` in both configs — a generated launch screen and the plist dict conflict. Launch images render at intrinsic point size (never scaled), hence the dedicated 180 pt 1x/2x/3x renditions; the logo PNG is opaque white, so the background is fixed white in both appearances. iOS caches launch screens aggressively — delete the app between iterations when changing it.
