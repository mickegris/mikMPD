# mikMPD v1.7 — Manual Test Checklist

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

- [ ] All eight chips (Albums, Artists, Recent, Genres, Playlists, Radio, CD, Files) reachable by scrolling; none truncated
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
- [ ] Queue footer visible after scrolling to the end; tap-to-play works as stated

## 10. Regression sweep (touched code paths)

- [ ] Queue tab: reorder, delete, clear, consume toggle, tap-to-play all fine
- [ ] Queue tab: tapping the underlined artist/album navigates; tapping elsewhere on the row plays (with the accent flash); in Edit mode a tap does nothing
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

## 18. Queue tab and Files chip (v1.6)

The queue moved out of More into the tab bar; Browse gave up its tab and became
the Library's "Files" chip. Nothing about either screen changed internally, so
this is about navigation, not features.

- [ ] Third tab is **Queue** and opens directly on the queue
- [ ] From the tab: Edit, drag to reorder, swipe to delete, shuffle, clear,
      consume toggle, refresh, Add to Playlist — all still work
- [ ] Empty queue shows its placeholder, and the Edit button is disabled
- [ ] More no longer lists Queue and opens on Connection
- [ ] Library → **Files** browses the tree; the title shows the current
      directory name, not "Library"
- [ ] Up and Home buttons work from a deep directory
- [ ] Double-tap plays a file, single tap enters a directory, swipe adds/plays
- [ ] Navigate deep in Files, switch to another chip, come back → still there
- [ ] No doubled navigation bar anywhere in Files (the nested-stack symptom)
- [ ] Rotate, and check on iPad — tab bar and nav bar lay out differently there

## 19. Server picker in Now Playing (v1.6)

Needs **two** saved profiles; with one, the banner must look exactly as it did
in v1.5.

- [ ] One server → banner reads "Connected to host:port", is not tappable, has
      no chevron
- [ ] Two servers → banner shows the profile **name** with a chevron, and
      "host:port · Partition: X" beneath
- [ ] A profile saved with a blank name shows host:port, never an empty line
- [ ] A very long profile name truncates instead of pushing the chevron off
- [ ] Before the first poll lands there is no dangling "Partition:" with nothing
      after it
- [ ] Menu marks the active profile with ✓; "Manage Servers…" opens Connection
- [ ] Switch → queue, art, recently-played and "Playing from …" all belong to
      the new server; no stale flash from the old one
- [ ] Switch **while phone streaming** → the stream stops and other apps can play
- [ ] Switch to an **unreachable** server → banner turns red and names it
- [ ] Then tap the banner and pick that same (active, disconnected) server →
      it retries the connection
- [ ] Delete the active profile → picker follows to the next one, and disappears
      entirely when only one is left

## 20. Reconnection (v1.6)

A failed `connect()` used to schedule no retry at all, so a connection that
failed at connect time stayed down until the app was backgrounded and brought
forward again. Both directions are worth checking, and the first one is the
regression.

- [ ] Stop MPD, launch the app → banner red; **start MPD** → the app connects
      itself within a few seconds, untouched
- [ ] With the app connected, stop MPD → banner goes red; start it again →
      it recovers on its own
- [ ] Switch to a server that is switched off, then back to a working one →
      the working one connects
- [ ] Background the app while it is retrying a dead server, wait, foreground →
      one connection attempt, not a backlog of them
- [ ] Set a **wrong** password on a profile → it fails once and stays failed
      (no retry storm against the server)
- [ ] Point a profile at a port running something that is not MPD → same: one
      failure, no retry loop
- [ ] A server that legitimately requires a password still reports "This server
      requires a password" and does not retry

## 21. Ogg phone streaming (v1.7)

Needs an MPD httpd output whose `encoder` you can change, and a **real device** —
simulator and device use different media stacks, and this is exactly the kind of
thing that differs.

- [ ] **Opus** stream plays, and keeps playing for >10 minutes with no drift or
      dropout
- [ ] Playback **starts within a second or two** of tapping, not after ~10 s —
      the codec probe must read the response headers and stop, never the body
- [ ] Disable the httpd output (or restart MPD) **with the app in the
      foreground** → the button returns to "Listen on phone" rather than staying
      on "Streaming to phone" over silence
- [ ] No click at the very start of the stream (pre-skip is being honoured)
- [ ] Track changes are seamless — this is the chained-bitstream case, and the
      symptom if it is broken is "first track plays, then silence"
- [ ] **FLAC** stream plays
- [ ] **Vorbis** stream shows the message naming the codec and the supported
      list, rather than a toggle that does nothing
- [ ] **mp3** stream still works — the regression that matters most
- [ ] **Change the server's encoder between mp3 and Opus and restart the stream
      from the same URL, with no change in the app.** This is the actual
      requirement; everything else is detail
- [ ] Supported encoders are stated under the Stream URL field in the server form
- [ ] Lock screen shows metadata; transport controls still drive MPD
- [ ] Backgrounded playback survives; a stream killed at the server still stops
      cleanly and other apps can resume afterwards
- [ ] Phone call interrupts and recovers
- [ ] **Unplug headphones (or disconnect Bluetooth) while streaming** → streaming
      stops, the button returns to "Listen on phone", and nothing plays from the
      iPhone speaker
- [ ] Plug headphones in mid-stream → the Opus stream carries on through them
- [ ] Switching servers mid-stream stops the stream
- [ ] Start a stream on a URL that is not audio at all → a clear failure, no hang

## 22. Moving playback between partitions (v1.7)

Needs two partitions with an output each, and `playlist_directory` set in
mpd.conf.

- [ ] Now Playing → **Move Playback** button (⇄, under the partition button) → a
      sheet lists the other partitions with their enabled outputs and state →
      tap one, and the music continues there **from the same spot**
- [ ] **The app switches to the partition you moved to** — with "Remember
      partitions" on as well as off
- [ ] The partition button only switches partitions; it offers no moves
- [ ] A partition with no enabled outputs is greyed out and cannot be chosen
- [ ] **Move into a partition whose speakers are switched off** → an explanation
      appears, nothing is moved, the original partition keeps playing, and MPD
      stays up (check `journalctl -u mpd`)
- [ ] The source partition ends empty and stopped
- [ ] The app follows to the target partition
- [ ] Repeat/random/single/consume carry over; **volume does not**
- [ ] Move a **paused** queue → the target is paused at the same position
- [ ] Move a **stopped** queue → the queue arrives, nothing starts playing
- [ ] Move a **long** queue (hundreds of tracks) from deep in it → same song,
      same spot, no noticeable delay
- [ ] The same actions work by swiping a partition row in Outputs & Partitions
- [ ] The sheet's header names the partition you are moving from
- [ ] The Move Playback button shows a spinner while a move runs and cannot be
      tapped twice
- [ ] No `.mikmpd-transfer-*` playlist is visible in Library → Playlists at any
      point, during or after
- [ ] Force-quit mid-transfer, relaunch → any leftover scratch playlist is gone
      after the playlist list loads, and no real playlist was touched
- [ ] With `playlist_directory` **unset**: the Outputs footer explains it and
      names the setting, and the Move Playback sheet explains it instead of
      listing partitions
- [ ] A CD queue refuses with a reason
- [ ] Moving to the partition you are already on does nothing

## 23. Missing files in playlists (v1.7)

Needs a stored playlist containing a file that has since been moved or deleted
("Bra grejs" has five).

- [ ] Open the playlist: dead entries show an orange warning, the filename,
      "Missing file" and the folder they were in
- [ ] Header reads "N tracks · M missing", where N is what Play will play
- [ ] Tap a missing entry → a dialog explains it and offers Remove
- [ ] Swipe left on a missing entry removes it; no Queue / Add Next / Playlist
      actions are offered for it
- [ ] **Tap a normal track well below a missing one → that exact song plays**
      (before the fix, every track after the first missing entry played the
      wrong song)
- [ ] The footer mentions how many files are missing
- [ ] A playlist with no missing files looks exactly as before

## 24. v1.7.1 fixes

**Queue tab.** Simulator is enough.

- [ ] Tap a row (title, number or duration) → that song plays, with the accent
      flash and no double-tap delay
- [ ] Tap the underlined artist / album → navigates, does not play
- [ ] Edit → tapping rows does nothing; reorder and delete still work

**Transfer settings.** Two partitions with *different* consume, ReplayGain and
crossfade. The live test `LiveTransferSettingsTests` covers the protocol; this is
the app.

- [ ] A (consume off, RG off, crossfade 0) → B (consume on, RG track,
      crossfade 5): Now Playing shows B's values immediately — no flicker
      through A's — and the next track change crossfades
- [ ] Switch back to A manually: A's values, unchanged; the ReplayGain button
      follows the partition switch
- [ ] Move B → A: mirrored
- [ ] Diagnostics on: each move logs `transfer A→B settings: dst ok, src ok`

**Energy.** A **Release** build on a device, Xcode's Debug Navigator open.

- [ ] Albums tab while music plays: CPU near 0–2 % at rest, no 10 Hz sawtooth
- [ ] Energy Impact "Low" on the Albums tab and on Now Playing with lyrics open
- [ ] Seek bar and synced lyrics exactly as smooth as before
- [ ] The audio format line reads e.g. "44.1 kHz · 16-bit · stereo"; no bitrate

**Phone streaming, Opus and mp3.** A device, locked where it says so.
Diagnostics on, so the command log records remote commands.

- [ ] Lock, press pause → silent within ~0.5 s; the lock-screen button flips at once
- [ ] Press play → music within ~2 s, at MPD's position (compare another
      client), not where the phone stopped
- [ ] Pause from another client (`mpc pause`) → the phone goes quiet within ~2 s
- [ ] Stop MPD from another client, press the headphone button → it plays
- [ ] **Paused and locked for 5 minutes, then play on the lock screen** → it
      resumes (the app was suspended and MPD dropped the socket: this is the
      wake-and-reconnect path) and does not crash
- [ ] While paused and locked: no stream traffic (Xcode's Network gauge flat)
- [ ] Start "Listen on phone" while MPD is paused → quiet; press play → sound
- [ ] Streaming the `http` partition, switch the app to `default` → phone
      streaming stops and the toggle reads "Listen on phone"
- [ ] Streaming, Move Playback `http` → `default` → the toggle goes off; move it
      back → the phone stays silent until you turn it on again
- [ ] Wi-Fi blip while streaming (Remember partitions **off**) → the app comes
      back on the same partition and the stream is not stopped
- [ ] Twenty skips in a row → every song starts; no cut-off tails
- [ ] Three songs play through by themselves → no gap between them
- [ ] Walk to the edge of Wi-Fi → one clean "buffering" gap, then it recovers,
      not stutter
- [ ] Wi-Fi off 5 s → reconnects by itself; off 30 s → stops with a message,
      and the toggle is off
- [ ] Restart MPD mid-stream → reconnects within ~15 s
- [ ] A phone call, declined → streaming resumes; taken and ended → resumes or
      waits for lock-screen play, as iOS says
- [ ] Siri and an alarm mid-stream; AirPods in/out; AirPlay there and back → no
      crash, and it recovers
- [ ] FLAC output (`http flac`) at 44.1 kHz and at 48 kHz → correct pitch both,
      including across a track change between them (FLAC never played in 1.7.0)
- [ ] **30 minutes locked, on Wi-Fi** → no crash, no silent stop

