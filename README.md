# mikMPD

A lightweight iOS/iPadOS client for [Music Player Daemon](https://www.musicpd.org/) built with SwiftUI. Vibe coded with Claude Code.

## Features

**Now Playing** — Album art (fetched from MusicBrainz/CoverArtArchive), synced lyrics (via LRCLIB), seek bar, transport controls (play/pause, stop, previous, next), volume slider, and mode toggles (repeat, shuffle, single, consume). Shows bitrate and audio format info. Add the current song to a playlist with one tap.

**Library** — Browse by albums, artists, genres, or playlists with search filtering. Album and artist detail views include Wikipedia summaries. Play or enqueue entire albums/artists with one tap.

**Playlists** — Full stored-playlist support: browse, rename, and delete playlists, save the queue as a playlist, tap a track to play it in playlist context, drag to reorder, swipe to remove or enqueue. "Add to Playlist" is available from Now Playing, albums, search results, and the queue.

**Recently Played** — Client-side listening history, accessible from the clock button in Now Playing. Shows an album grid (tap to open the album) and a per-track list; history is kept per server for 30 days / 100 entries. Note: recording requires the app to be running — songs played on the MPD device while the app is backgrounded (without "Listen on Phone" active) are not captured.

**Radio** — Built-in Swedish Radio streams (SR P1–P4 Göteborg) plus custom station management with persistent storage.

**CD** — Play audio CDs directly via `cdda:///` URIs with per-track control.

**File Browser** — Navigate the MPD directory tree. Single-tap enters directories, double-tap plays files. Swipe actions for add/play.

**Search** — Concurrent search across songs, artists, and albums with debounced input, batch selection, and album art thumbnails.

**Queue** — View and manage the current playlist. Double-tap to jump to a song, drag to reorder, swipe to delete, clear all, toggle consume mode.

**Outputs & Partitions** — Toggle audio outputs on/off, switch between MPD partitions, create and delete partitions, move outputs between partitions via long-press context menu. Optional partition memory across reconnects.

**Multiple Servers** — Save any number of MPD servers and switch between them with one tap. Nearby servers advertising over Bonjour/Zeroconf are discovered automatically and can be added directly. Passwords are stored in the Keychain, and the last-used partition is remembered per server.

**Listen on Phone** — Stream audio from an MPD httpd output directly to the device via AVPlayer. Configure the stream URL per server, then toggle "Listen on phone" in Now Playing. Supports background playback with lock screen metadata (song title, artist, album art) and lock screen transport controls.

**Snapcast** — Control a [Snapcast](https://github.com/badaix/snapcast) multiroom server from the More tab. Adjust per-client volume and latency, mute groups, move clients between groups, rename clients, switch stream sources, and remove disconnected clients. Real-time updates via Snapcast's JSON-RPC push notifications. Configure the Snapcast host/port per MPD server profile (defaults to the MPD host, port 1705).

## Requirements

- iOS 26.2+
- An MPD server accessible on the network

## Setup

1. Open `mikMPD.xcodeproj` in Xcode
2. Build and run on a device or simulator
3. Go to **More → Connection** and pick a discovered server or add one manually (host, port, optional password)

## License

MIT — see [LICENSE.md](LICENSE.md).
