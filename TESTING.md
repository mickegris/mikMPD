# mikMPD v1.2 — Manual Test Checklist

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
