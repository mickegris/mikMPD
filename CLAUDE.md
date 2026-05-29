# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

Open `mikMPD.xcodeproj` and build the `mikMPD` scheme. No external dependencies — pure SwiftUI + Foundation + Darwin.

Deployment target: iOS 26.2+. Swift default actor isolation is set to `MainActor` in build settings.

No test targets exist.

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

### Connection lifecycle

Disconnects on background, reconnects on foreground resume. Partition is restored automatically. 3-second retry on connection loss.

## Conventions

- MPD command arguments are escaped via `String.esc` (backslash + quote escaping) and wrapped in quotes to prevent injection.
- Password stored in Keychain via `KeychainHelper`; legacy migration from UserDefaults runs on init.
- Album art keyed by `artist|album` (lowercased) with an LRU cache (100 items), fetched from MusicBrainz/CoverArtArchive.
- No command batching — each MPD operation is a separate `send`/`receive` cycle ("No command_list, no dual sockets").
- `WikipediaService` is a Swift actor with its own in-memory cache.
