# 3 — Queue transfer never changes consume, ReplayGain or crossfade

## The report

> Make sure queue transfer don't mess with consume/gain/fade. I got a feeling it
> does that intermittently. It must not change those three options.

Clarified:

> consume/gain/fade must not be replaced when transferring. If the destination has
> consume on, track gain and fade enabled it should be there after the transfer.
> Add some logic that checks before and after move.
>
> Also, source should be checked so the transfer doesn't mess with source
> consume/gain/fade.

## The rule

**Consume, ReplayGain mode and crossfade belong to the partition, not to the
queue.** A transfer moves the queue, the current track, the position and the
play state. It never changes these settings on **either** side. The target
keeps its own, and the source keeps its own. MixRamp (`mixrampdb` /
`mixrampdelay`) is MPD's other fade mechanism and is treated as part of "fade".

This is enforced twice: once by not sending anything that could change them, and
once by **checking before and after** on both partitions and repairing any drift.

## Review findings (whole transfer path)

`MPDStore.transferQueue` (≈1749) and the pure helpers in Models.swift (≈700–870).

- **T1 — The transfer overwrites the target's consume.** This is the direct
  cause. v1.7 treated the four queue modes as travelling with the queue:

  ```swift
  let modes = (rep: repeatMode, rnd: randomMode, sng: singleMode, csm: consumeMode)
  …
  _ = try? self.socket.command("consume \(modes.csm ? 1 : 0)")
  ```

  so a target with consume on ended up with the source's consume off, and the
  other way round. It only shows when the two partitions differ, which is why it
  felt intermittent.
- **T2 — The ReplayGain display goes stale after any partition change.** The
  transfer never sends `replay_gain_mode`, and MPD keeps it per partition, so the
  *real* setting survives. But the app reads it only in `loadAll()`, on connect.
  After the app follows the music to the target, or after a plain
  `switchPartition`, Now Playing's ReplayGain button still shows the **source's**
  mode. That looks exactly like the transfer changing gain.
- **T3 — The crossfade display lags.** The transfer never sends `crossfade`
  either, and the poll does pick up the target's `xfade` (absent = 0). The first
  poll after a transfer can be 3 s away, though, so the button briefly shows the
  source's value and then flips. That reads as "it changed", then "it changed
  back".
- **T4 — The `oneshot` values are lost.** `single`/`consume` are read as
  `== "1"`, so `oneshot` (0.24 for consume) collapses to off. With consume no
  longer sent, this matters only for `single`, which still travels (see the
  question below). It is fixed by carrying the raw value.
- **T5 — Nothing verifies anything.** Every mode command is `try?`, and nothing
  reads back.
- Checked and fine: the ordering and safety property (the source is untouched
  until the target plays), scratch playlist cleanup on every path, compensation
  of the elapsed time, the no-enabled-outputs refusal, the remember-partition
  bookkeeping, and that volume does not travel. `clear`, `load`, `seek`,
  `pause` and `stop` do not change consume, ReplayGain, crossfade or MixRamp in
  MPD. That is confirmed by the live test below rather than assumed.

## Changes

### 1. Stop sending `consume` to the target (T1)

Delete the `consume` line. Also delete the main-thread `modes` capture: whatever
still travels is read on Q from the same `status` snapshot as the play state
(see the open question for repeat/random/single).

### 2. `PartitionSettings` + before/after check (T5)

A pure value type in Models.swift:

```swift
/// The settings a transfer must leave alone, on both partitions.
nonisolated struct PartitionSettings: Equatable {
    var consume: String        // "0" | "1" | "oneshot" — raw
    var crossfade: Int         // `xfade` is absent when 0
    var mixrampDB: String?     // raw; nil when absent
    var mixrampDelay: String?  // raw; nil when absent or "nan" (disabled)
    var replayGainMode: String?  // from `replay_gain_status`; nil if unreadable

    init(status: [String: String], replayGainStatus: [String: String]?)

    /// Names of the settings that differ, in a fixed order, for messages.
    func drift(to after: PartitionSettings) -> [String]      // e.g. ["Consume", "Crossfade"]
    /// Commands that put a partition back to `self`, for the drifted fields only.
    func restoreCommands(from after: PartitionSettings) -> [String]
}
```

In `transferQueue`, on Q:

1. **Before:** read `status` + `replay_gain_status` in the source, *before*
   `save` (the source read already happens there, so extend it) → `srcBefore`.
   After `partition <target>`, *before* `clear`, read the same → `dstBefore`.
   The existing output-refusal detour already visits the target first, so take
   `dstBefore` there and spare the extra round trip.
2. The transfer runs as today, minus the consume line.
3. **After:** read the target (the connection is already bound there) →
   `dstAfter`. Then `partition <source>` → `srcAfter`. This slots in beside the
   existing source `clear`/`stop`, so it costs no extra switch. The failure paths
   also return to the source, so read `srcAfter` there too, and read `dstAfter`
   if the target was touched at all (`clear`/`load` ran).
4. **Repair:** for each side where `before.drift(to: after)` is non-empty, send
   `before.restoreCommands(from: after)` to that partition, then re-read once to
   confirm.
5. **Report:** the completion changes from `String?` to

   ```swift
   struct TransferResult { var failure: String?; var notes: [String] }
   ```

   `notes` holds, per side, either *"Kitchen: consume changed during the move
   and was put back"* or *"… could not be put back (MPD said: …)"*. The
   `MovePlaybackSheet` alert shows the notes after a success, and alongside the
   failure otherwise. With T1 fixed, notes should never appear. If one does,
   something outside this code (another client, an MPD quirk) changed a
   setting, and the user is told instead of it being silently fixed or silently
   lost.
6. Log a one-line summary to `MPDCommandLog` when diagnostics are on:
   `transfer A→B settings: src ok, dst ok` (or the drift). The next "I've got a
   feeling" then comes with evidence.

**A known limit, stated in the code comment:** if another client changes one of
these settings *during* the few seconds a transfer runs, the repair puts it
back. That is acceptable, since the transfer is short and the user asked for the
transfer to be the thing that never changes them.

`replayGainMode == nil` (an old MPD without `replay_gain_status`, or an ACK)
means that field is skipped in both drift and repair, never "restored" to
nothing.

### 3. Show the partition's real values straight away (T2, T3)

- The transfer's main-thread completion calls `loadReplayGainStatus()` and
  `Q.async { poll() }`, so both buttons show the **target's** values the moment
  the sheet closes. There is no window showing the source's.
- `switchPartition` and the partition-restore path also call
  `loadReplayGainStatus()`. That is one command, and it fixes the same stale
  button for manual switches.

## Open question — repeat / random / single

v1.7 copies repeat, random and single from the source to the target, on the
reasoning that they describe how the queue is played. The request names only
consume/gain/fade. Two options:

- **(a) Keep them travelling** (the default in this plan). A shuffled playlist
  stays shuffled after moving rooms. `single` is carried raw so `oneshot`
  survives (T4).
- **(b) Make them partition-owned too.** This is the same rule as consume:
  nothing about the target's playback settings changes. It is simpler to state,
  and `PartitionSettings` simply gains three fields.

## Tests

Unit (pure, Models.swift):

- `PartitionSettings(status:replayGainStatus:)`: `xfade` absent → 0; `consume:
  oneshot` kept raw; `mixrampdelay: nan` → nil; a nil `replayGainStatus` → nil
  mode.
- `drift`: equal → `[]`; one field → its name; several → all, in a stable order;
  nil ReplayGain on either side → never reported.
- `restoreCommands`: only the drifted fields; `mixrampdelay nan` when the
  original was nil; `replay_gain_mode "album"` quoted.
- A regression test that the transfer's command sequence contains no `consume`,
  `crossfade`, `mixramp…` or `replay_gain_mode` command. To make it testable,
  extract the target-side sequence into a pure `transferTargetCommands(…)`.

Live (`mikMPDTests/Local/`, Group D, `MPD_INTEGRATION_MUTATE=1`):

- Set the **source** to consume 0, crossfade 0, ReplayGain `off`, and the
  **target** to consume 1, crossfade 5, ReplayGain `track`. Transfer, then
  assert that **both** partitions still have exactly those values, and that
  `notes` is empty.
- The mirror image (source "on", target "off"), and both directions three times
  each, since the report was "intermittent".
- Snapshot and restore **both** partitions' settings and queues in `defer`.
  `ServerSnapshot` covers only the current partition and does not capture
  ReplayGain (CLAUDE.md → "Verified server behavior"), so extend it.

## Manual verification

- [ ] Partition A: consume off, crossfade 0, RG off. Partition B: consume on,
      crossfade 5, RG track. Move A→B → Now Playing immediately shows consume on,
      crossfade 5, RG track, with no flicker through A's values; the next track
      change crossfades; the finished track leaves the queue.
- [ ] Switch back to A manually → consume off, crossfade 0, RG off, unchanged.
- [ ] Move B→A → the same checks, mirrored.
- [ ] Diagnostics log shows `settings: src ok, dst ok` for each move.

## Docs

CLAUDE.md → "Transferring a queue between partitions": replace "Modes
(`repeat`/`random`/`single`/`consume`) travel with the queue because they
describe it" with the rule above, and say *why*: consume was being overwritten
on the target, and ReplayGain/crossfade are per partition. Describe the
before/after check. Add to "Verified server behavior" that `replay_gain_mode` is
per partition and absent from `status`, next to the existing `xfade` note.
