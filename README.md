# mikMPD

A lightweight iOS/iPadOS client for [Music Player Daemon](https://www.musicpd.org/) built with SwiftUI. Vibe coded with Claude Code.

## Features

**Now Playing** — Album art (fetched from MusicBrainz/CoverArtArchive), seek bar, transport controls (play/pause, stop, previous, next), volume slider, and mode toggles (repeat, shuffle, single, consume). Shows bitrate and audio format info.

**Library** — Browse by albums, artists, or genres with search filtering. Album and artist detail views include Wikipedia summaries. Play or enqueue entire albums/artists with one tap.

**Radio** — Built-in Swedish Radio streams (SR P1–P4 Göteborg) plus custom station management with persistent storage.

**CD** — Play audio CDs directly via `cdda:///` URIs with per-track control.

**File Browser** — Navigate the MPD directory tree. Single-tap enters directories, double-tap plays files. Swipe actions for add/play.

**Search** — Concurrent search across songs, artists, and albums with debounced input, batch selection, and album art thumbnails.

**Queue** — View and manage the current playlist. Double-tap to jump to a song, swipe to delete, clear all, toggle consume mode.

**Outputs & Partitions** — Toggle audio outputs on/off, switch between MPD partitions, move outputs between partitions via long-press context menu. Optional partition memory across reconnects.

**Listen on Phone** — Stream audio from an MPD httpd output directly to the device via AVPlayer. Configure the stream URL in Connection settings, then toggle "Listen on phone" in Now Playing. Supports background playback with lock screen metadata (song title, artist, album art) and lock screen transport controls.

## Requirements

- iOS 26.2+
- An MPD server accessible on the network

## Setup

1. Open `mikMPD.xcodeproj` in Xcode
2. Build and run on a device or simulator
3. Go to **More → Connection** to enter your MPD server host, port, and optional password

## License

MIT — see [LICENSE.md](LICENSE.md).
