# 1 — Transfer the queue between partitions

## The request

> Transfer queue between partitions. Similar to Roon's transfer functionality.

Roon's "Transfer Zone" moves what is playing — the queue, the current track, the
position within it, and whether it is playing — from one zone to another, and
stops the zone it came from. The music follows you to the kitchen. MPD
partitions are the same idea: independent players with their own queue, playback
state and outputs, on one server and one database.

## MPD has no transfer command, and the obvious build is the wrong one

Nothing in the protocol moves a queue between partitions. The obvious
construction is to read the source queue with `playlistinfo` and re-add each URI
in the target. Do not: it is one command per track, which is precisely the shape
this codebase has already been bitten by twice — "Bulk enqueue is server-side"
in CLAUDE.md exists because per-track `add` starved the poll for minutes on a
large artist, and `loadRecentlyAdded` is windowed because an unbounded response
can outrun the socket's 5 s read timeout and disconnect mid-transfer.

**Stored playlists are global, not per-partition.** That is the lever. A queue
can be saved to a playlist in one partition and loaded in another, and it is two
commands regardless of queue length:

```
                                  ← already tuned to the source partition
status                            → state, song (queue pos), elapsed
rm   "<temp>"                     → ignore ACK; a leftover from a failed run
save "<temp>"                     → the whole queue, one command
partition "<target>"
clear
load "<temp>"                     → the whole queue, one command
play <pos>                        → then seekcur <elapsed>; pause 1 if it was paused
                                  ── target is now correct; only now touch the source
partition "<source>"
clear
stop
partition "<target>"              → follow the music, see "Where the app ends up"
rm   "<temp>"
```

**The ordering is the safety property.** The source is not cleared until the
target holds the queue and has started. A failure anywhere before that leaves
the source exactly as it was, which is the state the user can least afford to
lose — it is the music they are listening to.

## Details that will bite

- **`save` needs `playlist_directory` in mpd.conf, and the app must say so.**
  Without it the command ACKs (`stored playlist support is disabled`) and the
  feature cannot work at all. A silently missing or greyed-out control is the
  wrong answer — the user has no way to guess what is wrong with their server.
  See "When the server cannot do it" below.

  Probe it **read-only**: `listplaylists` fails the same way when stored-playlist
  support is off, so availability can be established without writing anything.
  Cache per connection like `playlistSearchAvailable`, since it is server
  configuration and cannot change under a live connection.
- **Only pre-0.24 syntax.** `save NAME MODE` (create/append/replace) is 0.24+,
  and CLAUDE.md pins this codebase to the older form. Hence the `rm`-then-`save`
  pair rather than a replace mode: on older MPD, `save` onto an existing name
  ACKs.
- **Seeking requires a player that is not stopped.** After `load` the partition
  is stopped, so `seekcur` ACKs. The order is `play <pos>` → `seekcur <elapsed>`
  → `pause 1` if the source was paused. Doing it the other way round silently
  starts the track from zero.
- **Volume does not transfer.** It is a property of the partition's outputs, and
  carrying it across would blast a room at the volume of a different one.
- **The four queue modes do transfer** (`repeat`, `random`, `single`,
  `consume`) — they describe the queue, and a transferred shuffle that stops
  shuffling is not the same queue. Crossfade and replay gain stay put; they are
  output-shaped, like volume.
- **CD tracks probably will not survive.** `cdda:///N` URIs in a stored playlist
  are unlikely to reload meaningfully, and the disc is in one machine anyway.
  Radio streams do survive — an `http://` URI is just a line in an m3u.
  Detect a CD-sourced queue (`MPDSong.sourceKind == .cd`) and refuse with a
  reason rather than producing a silent, broken target queue.
- **This is not `moveoutput` and does not carry its deadlock.**
  `plans/move-active-output-hang.md` is about detaching an open, actively
  rendering output across partitions, which hung the daemon hard enough to need
  a restart. Transfer touches **no outputs at all** — it only switches which
  partition the connection is bound to, and issues queue commands. A future
  reader will assume otherwise, so the code should say so where it lives.

## The temp playlist must be genuinely ephemeral

It is written into the user's own playlist directory, so "we delete it
afterwards" is not sufficient — the interesting cases are the ones where
"afterwards" never arrives. Four rules together, none of which is enough alone:

1. **A unique name per transfer**, `.mikmpd-transfer-<8 hex>`, not one fixed
   name. Two devices transferring at the same moment would otherwise collide on
   it, and the second `save` would either ACK or silently overwrite a queue
   mid-flight. (A leading dot is legal; `/` and newlines are not, which
   `validatePlaylistName` already encodes.)
2. **`rm` on every exit path** — success, ACK, thrown error, guard failure.
   Structured as a single cleanup that cannot be skipped by an early return,
   not an `rm` repeated at each `return`.
3. **A sweep on connect**, because a force-quit or a dropped socket mid-transfer
   leaves one behind and nothing in this app runs on termination — that is a
   documented invariant, not an oversight. On connect, `listplaylists`, and `rm`
   anything matching the prefix.

   **The sweep must be age-gated**, or it becomes the bug it is fixing: another
   device's transfer, in flight right now, has a playlist matching that prefix.
   `listplaylists` returns `Last-Modified` and `MPDPlaylist.lastModified`
   already carries it, so only sweep entries older than a few minutes — far
   longer than a transfer takes, far shorter than a leftover deserves to live.
4. **Hidden from the playlist list.** Filter the prefix in `loadPlaylists` so a
   transfer in progress never flickers into the Playlists chip, and so a
   leftover awaiting sweep is not something the user is invited to tap.

A short-lived write into the playlist directory is the cost of this feature
working at all — there is no other way to move a queue across partitions in one
command. It should behave like a lock file: uniquely named, always cleaned up,
never visible, and swept if orphaned.

## When the server cannot do it

`playlist_directory` unset is a configuration a user can fix in one line, so the
app should tell them exactly that rather than hiding a control. The transfer
section of the partition dialog is replaced by a single row — "Transfer
unavailable" — which opens an alert:

> Transferring a queue needs MPD's stored-playlist support, which is off on this
> server. Set `playlist_directory` in `mpd.conf` and restart MPD.

Same text in the Outputs & Partitions footer, where partition management lives
and where someone debugging their setup will look. This is the one place the
app talks about mpd.conf, and it earns it: the alternative is a feature that
appears broken for a reason nothing on screen explains.

## Where the app ends up

Following Roon: **the app switches to the target partition.** You transferred
the music because you want to keep controlling it, and staying behind to look at
a partition you just stopped is not what "transfer" means anywhere else. This
also means `currentPartition`, the per-profile `lastPartition`, and
`partitionToRestore` all end up on the target, and `loadQueue`/`loadOutputs`
must refresh for it — `switchPartition` already does exactly this work and
should be reused rather than reimplemented inside the transfer.

## Store

One method, mirroring `moveOutputToPartition`'s shape (guard flag, everything on
`Q`, ACK text surfaced through a `@MainActor` completion):

```swift
@Published private(set) var isTransferringQueue = false

func transferQueue(toPartition target: String,
                   completion: @escaping @MainActor (String?) -> Void)
```

Guards before dispatch, in the order a user would hit them: a transfer already
running; target equals `currentPartition`; empty queue; target not in
`partitions`; `save` unavailable on this server; a CD-sourced queue.

`isTransferringQueue` is `@Published` because the UI needs to disable the action
and show progress — a transfer is several round trips and a visible pause in the
music, and an un-acknowledged tap invites a second one.

**The poll cannot race it.** `Q` is serial, so the whole sequence is atomic with
respect to polls, exactly as `moveOutputToPartition` relies on.

## What to make testable

The sequence is I/O, but the decision inside it is not. Extract the resume step,
which is where the ordering bug lives and where a live test is expensive:

```swift
/// Commands to restore playback after `load`, given what the source was doing.
/// `seekcur` ACKs on a stopped player, so `play` must come first — and when the
/// source was paused, the pause must come *after* the seek or it starts from 0.
nonisolated func resumeCommands(state: PlaybackState, pos: Int, elapsed: Double) -> [String]
```

Pure, table-testable across playing/paused/stopped × pos 0/N × elapsed 0/N, and
it follows `firstAcceptedRecentlyAdded`'s precedent of making the interesting
decision a function rather than a shape buried in a `do` block.

`transferTempPlaylistName()` (unique per call), `isStaleTransferPlaylist(name:
lastModified:now:)` — the age gate, which is pure and exactly the kind of rule
that is easy to get backwards — and the "is this queue transferable" predicate
are the other pure pieces worth naming.

## UI

**Primary: Now Playing's partition dialog.** `partitionButton` already lists
partitions in a `confirmationDialog` and is where "put this somewhere else"
belongs — it is the equivalent of Roon's zone picker, on the screen you are
already looking at. Add a "Transfer queue to …" section beneath the plain
switch list, so switching *view* and moving *music* stay visibly different
actions.

This deliberately does **not** contradict the rule that partition management
stays in the Outputs tab: that rule is about `moveoutput`, for the deadlock
reason above, and does not extend to queue commands.

**Confirmation is required**, unlike a partition switch. Transfer stops music in
one room and starts it in another, and the tap that does it sits one row away
from the tap that merely changes what you are looking at. The prompt should name
both ends: "Move playback from Kitchen to Living Room?"

**Secondary: OutputsView**, where partitions are already managed, as a row
action on each partition ("Transfer queue here").

Progress: the dialog's action shows a spinner while `isTransferringQueue`. On
failure, an alert with the ACK text — the same treatment `deletePartition`'s
"it's not empty" already gets.

## Verification

Unit: `resumeCommands` and the transferability predicate, as above.

Live (`mikMPDTests/Local/`, **Group D — mutating**, with `ServerSnapshot`
restore): needs two partitions with an output each. Not Group E — no output is
moved, so the daemon-hang risk that gates that group does not apply.

- Transfer a playing queue → target plays the same track at the same position
- Transfer a paused queue → target is paused at the same position
- Modes carry; volume does not
- Source ends empty and stopped
- The temp playlist does not exist afterwards — on success **and** after a
  forced failure partway through
- A stale `.mikmpd-transfer-*` left behind is swept on the next connect, and a
  fresh one belonging to another client is **not**
- The temp playlist never appears in the Playlists list
- Kill the connection mid-transfer → source queue is intact
- `save`-less server → the explanatory alert, and nothing is changed

Manual (`TESTING.md`): the two-room case that is the whole point — music playing
in one room, transfer, and it continues in the other from where it was.

## Live verification (MPD 0.24.0)

### The first attempt crashed the daemon

A transfer from `http` to `sova`, with both partitions playing into **httpd**
outputs, ended with MPD aborting at 14:56:11:

```
terminate called after throwing an instance of 'std::system_error'
  what():  Invalid argument
mpd.service: Main process exited, code=killed, status=6/ABRT
```

The journal places it in the same second as the transfer's last steps — the log
shows the source's song reported as `played` just before the abort — but one-
second resolution cannot say which command. Three conditions were present that
the successful retest below did not have: two partitions playing into outputs at
the same moment; httpd outputs specifically, one of which had been enabled and
streamed from minutes earlier; and `sova`'s `http mp3`, an output moved by
`moveoutput` into a partition created at runtime.

What it cost is a server fact worth knowing: **only the `default` partition's
queue survives a restart.** Every other queue was emptied and `sova`, created at
runtime, disappeared. The daemon came back through socket activation, which
starts it without a global port and therefore with zeroconf disabled.

### The retest passed at every step

No configuration was changed. `snapcast` had Snapcast flac (a fifo) enabled;
`airplay` had every output disabled, which makes it an output-less partition.
Each command was issued on its own with an uptime check after it:

| Test | Result |
|---|---|
| `snapcast` playing into the fifo → `airplay` | queue order, song index, source emptied and stopped — pass |
| `airplay` → `snapcast`, target starts playing into the fifo | target playing at the same song — pass |
| both directions at app speed, no delays | 7 ms and 3 ms; daemon survived, target playing — pass |
| scratch playlists | none left behind — pass |

So the command sequence itself does not crash 0.24.0 with fifo outputs, stepwise
or at full speed. **Still unverified:** two partitions playing into outputs at
once, httpd outputs, and outputs moved by `moveoutput`. The crash needed at least
one of those.
