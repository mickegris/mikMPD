# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Open `mikMPD.xcodeproj` and build the `mikMPD` scheme. No external dependencies — pure SwiftUI + Foundation + AVFoundation + MediaPlayer + Darwin.

Deployment target: iOS 26.2+. Swift default actor isolation is set to `MainActor` in build settings.

## Tests

Unit tests use the Swift Testing framework (`mikMPDTests` target). Run via **Product → Test** (Cmd+U) in Xcode.

Tests cover pure logic that doesn't need an MPD server: model init/computed properties, `formatTime`, `String.esc`, `Double.clamped`, `parseMPDRecords` (MPD protocol record parsing), `SavedStation` Codable roundtrip, and `parseStreamURL` validation.

`parseMPDRecords` is an internal free function extracted from `MPDSocket` specifically for testability.

## Architecture

This is an MPD (Music Player Daemon) client for iOS/iPadOS.

### Layers

**MPDSocket** — Raw TCP socket using Darwin POSIX APIs. Sends text commands, reads lines until `OK` or `ACK`. Parses responses into `[[String: String]]` records by splitting on `:` and flushing on record-starter keys (`file`, `directory`, `playlist`, `outputid`, `partition`).

**MPDStore** — Single `@Observable` store that owns the socket and all published state. Views never talk to the socket directly. All socket I/O runs on a dedicated `DispatchQueue` (`.userInteractive`); all `@Published` properties update on main thread.

**Views** — SwiftUI views consume `MPDStore` via `@EnvironmentObject`. They are purely reactive — no view-local state for MPD data, only for transient UI concerns (drag state, search text).

**Models** — Lightweight value types (`MPDSong`, `MPDOutput`, `MPDBrowseItem`) initialized from parsed MPD records.

### Dual-timer design

- **Poll timer (1s)**: fetches ground truth from MPD (`status`, `currentsong`, `outputs`).
- **Display timer (0.1s)**: smoothly advances `elapsed` during playback without waiting for the next poll.

### Optimistic UI with locking

- **Seek lock (2s)**: after a seek, `elapsed` is locked from poll updates to prevent snap-back while MPD processes.
- **State lock (0.5s)**: after `togglePlay()`, `isPlaying`/`isPaused` are locked from poll to avoid flickering.
- State is captured on main thread *before* dispatching commands to the background queue to avoid races.

### Partition & output model

MPD supports multiple partitions (independent playback zones). The store tracks `outputNameToPartition` by name (not ID, since IDs can shift). Outputs can be moved between partitions. A "remember partitions" setting restores the last-used partition on reconnect.

### Phone streaming (listen on phone)

`AVPlayer` plays an MPD httpd output URL on the device. The stream URL is stored in `@AppStorage("httpStreamURL")` and configured in Connection settings. A toggle in Now Playing starts/stops the stream.

- **AVAudioSession**: `.playback` category enables background audio (requires `UIBackgroundModes = [audio]` in Info.plist).
- **Lock screen metadata**: `MPNowPlayingInfoCenter` displays title, artist, album, artwork, and elapsed time. Updated every 1s poll cycle (not the 10Hz display timer) — the system extrapolates elapsed time via `playbackRate`.
- **Lock screen controls**: `MPRemoteCommandCenter` routes play/pause/next/previous to MPD commands via the socket queue. Closures capture `Q` and `socket` (both `Sendable`) to avoid `MainActor` isolation issues.
- **Background polling**: A `DispatchSourceTimer` on `Q` polls MPD every 2s while streaming, since `RunLoop`-based timers suspend when the app backgrounds.
- **`parseStreamURL`**: validates http/https scheme and non-empty host. Lives on `MPDStore` as a static for testability.

### Connection lifecycle

Disconnects on background, reconnects on foreground resume — **unless phone streaming is active** (`isPhoneStreaming` guards the disconnect in `MPDClientApp`). Partition is restored automatically. 3-second retry on connection loss, guarded by `isReconnecting` to prevent stacking.

## Conventions

- MPD command arguments are escaped via `String.esc` (backslash + quote escaping) and wrapped in quotes to prevent injection.
- Password stored in Keychain via `KeychainHelper`; legacy migration from UserDefaults runs on init.
- Album art keyed by `artist|album` (lowercased) with an LRU cache (100 items), fetched from MusicBrainz/CoverArtArchive.
- No command batching — each MPD operation is a separate `send`/`receive` cycle ("No command_list, no dual sockets").
- `WikipediaService` is a Swift actor with its own in-memory cache.
