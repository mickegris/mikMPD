# mikMPD v1.5 — Manual Test Checklist

Work top to bottom; the first two need a **fresh install** (delete the app first), the
rest can run on your normal install. Kill and relaunch the app before re-checking
Wikipedia results — wrong/empty lookups are cached in memory per session.

## 1. Launch screen (fresh install — iOS caches launch screens, delete app between tries)

- [ ] Cold launch: centered mikMPD logo on white, sensible size (not huge/cropped)
- [ ] Same in dark mode (background stays white by design — logo is opaque white)
- [ ] No flash of a blank screen before the logo

## 2. First-run server setup (same fresh install, before adding a server)

- [ ] Alert appears on first launch: "No MPD Server Configured … Set Up Server… / Later"
- [ ] "Set Up Server…" opens Connection; Bonjour scan starts by itself
- [ ] "Later": Now Playing shows gray "No MPD server configured — tap to set up" (not red); tapping it opens Connection
- [ ] No bogus "192.168.1.1" server in the list; no connection errors while unconfigured
- [ ] Add your real server (discovered or manual) → connects, banner turns green
- [ ] Connection screen Status row: gray dot + "No MPD server configured" before setup, green after

## 3. Upgrade path (your normal install)

- [ ] Existing servers, passwords, partitions, stream URLs all intact after updating
- [ ] Auto-connects to the last active server as before

## 4. Library chip bar

- [ ] All six chips (Albums, Artists, Genres, Playlists, Radio, CD) reachable by scrolling; none truncated
- [ ] Selected chip is visibly distinct (prominent glass) and scrolls into view when selected
- [ ] Check on the smallest screen you have (or Zoomed display mode) and with large Dynamic Type
- [ ] Each chip shows the right content

## 5. Multi-disc albums

- [ ] "Blast from the Past" appears **once** in Albums with a "2 discs" caption (also in the artist's page and search)
- [ ] "101 [Disc A]/[Disc B]" merges the same way (disc letters)
- [ ] Album page: title without the disc marker, "N discs · N tracks · time" line, Disc 1 / Disc 2 sections in order
- [ ] Play on a merged album queues *all* discs in disc order
- [ ] Both discs show the same cover; lists show one thumbnail
- [ ] Wikipedia About appears for: Blast from the Past, Clutching at Straws [24-bit remaster], 101, Crest of a Knave [2005 Remaster]
- [ ] "An Acoustic Evening at the Vienna Opera House" shows its own article — **not** Live at Carnegie Hall
- [ ] An album that merely shares a prefix with another ("Foo" vs "Foobar") did NOT merge
- [ ] A properly-tagged multi-disc album (one album tag + disc tags, if you have one) no longer interleaves tracks 1,1,2,2,…

## 6. Long titles

- [ ] Now Playing: a long album name scrolls marquee-style and is readable in full; short names stay static and centered
- [ ] Marquee resets when the song changes
- [ ] Album detail header wraps the full title (no "…")

## 7. Now Playing queue pane

- [ ] list.bullet button shows the queue in the art square; button tints when active
- [ ] Current track highlighted and centered; follows along when the song changes
- [ ] Tap a row → plays; swipe → deletes; artist/album links push detail pages
- [ ] Art tap still flips to lyrics; lyrics/queue buttons and art tap never get the pane stuck
- [ ] Empty queue shows the "Queue is Empty" placeholder

## 8. Recently played

- [ ] Clock button in the Now Playing header opens the sheet (half-height, pullable to full)
- [ ] A song appears ~30 s after it starts playing; skipped songs (< ~30 s) do NOT appear
- [ ] Entries show art, title, artist, and a relative time
- [ ] Tap replays the track; trailing swipe adds to queue; leading swipe → Add to Playlist
- [ ] Pause doesn't count toward the 30 s (pause at 10 s, wait, resume — still needs ~20 s more)
- [ ] Radio station logs once per listening session
- [ ] Switch server → history switches with it (each server keeps its own)
- [ ] Clear empties the list; history survives app restart

## 9. Long-press hints & swipe parity

- [ ] Footers present and correct: playlist list (rename hint), playlist detail, queue, search songs, servers, outputs (pre-existing)
- [ ] Playlist rename via long press works as hinted
- [ ] New leading "Playlist" swipe works on queue rows, search rows, and playlist-detail rows
- [ ] Queue footer visible after scrolling to the end; double-tap-to-play works as stated

## 10. Regression sweep (touched code paths)

- [ ] Queue tab: reorder, delete, clear, consume toggle, double-tap play all fine
- [ ] Search: songs/artists/albums sections populate; select + Add Selected works
- [ ] Playlists: create from queue, load, play at index, reorder, remove track
- [ ] Outputs/partitions: toggle output, move between partitions, switch partition
- [ ] Phone streaming: starts/stops, lock-screen controls + artwork, survives backgrounding
- [ ] Server switch: partition remembered (if enabled), no stale data flash
- [ ] Background → foreground: reconnects (unless streaming, which keeps the connection)

## 11. Album lookups for decorated tags (v1.5)

Tags in this library put the disc marker *inside* a qualifier bracket
(`Clutching at Straws [24-bit Remaster CD 1]`, `Misplaced Childhood [24-bit
Remaster, CD 1]`). Clear the art cache first — a failed lookup is remembered
for 7 days, so a fix otherwise looks like it changed nothing.

- [ ] More → Diagnostics → **Clear Album Art Cache** completes and confirms
- [ ] Both Marillion remasters appear **once** each, captioned "2 discs"
- [ ] The title reads `… [24-bit Remaster]` — balanced, no dangling `[`
- [ ] Both show cover art and an **About** section
- [ ] A remaster and a plain edition of the same album stay separate rows

## 12. Artist tags (v1.5)

- [ ] A file with an AlbumArtist and no Artist shows the name (not "Unknown
      Artist") in Now Playing, the queue, album track lists, search and playlists
- [ ] Tapping that name opens the artist page rather than an empty one
- [ ] Blue Öyster Cult albums get art and a Wikipedia summary despite the
      library holding four spellings of the name
- [ ] Compilation albums (guest track artists) still show one cover per album

## 13. Playlist search (v1.5)

- [ ] Searching a playlist's **name** lists it under Playlists
- [ ] Searching an artist/song only *inside* a playlist lists it, with an
      "N matching tracks" caption
- [ ] A query matching only a playlist does **not** show "no results"
- [ ] Swipe a result to play/add; long press for play, shuffle, add
- [ ] Typing quickly never leaves results from an earlier query on screen
- [ ] Searching stays responsive with many playlists (watch Diagnostics)

## 14. Now-playing markers (v1.5)

- [ ] Play a track, then open its album, a playlist containing it, a search that
      returns it, and its browser folder — the same row is marked in all four
- [ ] The queue marks the playing row even when the same file appears twice
- [ ] Albums list **and** grid mark exactly one album; so do Artist detail,
      Genre detail, Recently Added and Recently Played
- [ ] Playing disc 2 of a multi-disc set marks the single collapsed row
- [ ] A **radio stream** marks no album anywhere (this was the failure case)
- [ ] Stopped playback marks nothing
- [ ] CD tracks and radio stations are marked in their own lists

## 15. Lyrics Sync/Scroll (v1.5)

- [ ] On a track with synced lyrics, the capsule reads **Sync** and the pane follows
- [ ] Scrolling back stays put — it is not yanked back at the next line
- [ ] Tapping **Sync** snaps to the current line immediately
- [ ] The highlight stays visible in both modes
- [ ] No capsule on plain lyrics or instrumentals
- [ ] Changing track returns to Sync

## 16. "Playing from <playlist>" (v1.5)

- [ ] Play a playlist → label appears; **shuffle** a playlist → label appears
- [ ] Force-quit and relaunch → the label is still there
- [ ] Add a playlist to an **empty** queue → label appears
- [ ] Add a playlist to a **non-empty** queue → no label
- [ ] Replace the queue from another client, then reconnect → label disappears
- [ ] The playing playlist is marked in the Playlists list
- [ ] Switching servers switches the label with it

## 17. Audio session and shutdown (v1.5)

- [ ] Start "Listen on phone" while another app is playing → it stops cleanly
- [ ] Stop the stream → the other app is free to resume
- [ ] Lock screen shows title/artist/art and the transport controls work
- [ ] Force-quit while streaming → no lingering mikMPD card in Control Center
- [ ] Kill the MPD httpd output mid-stream, then background the app → the app
      disconnects instead of holding the audio session open
- [ ] Open the Snapcast screen, leave it, return — controls still work
