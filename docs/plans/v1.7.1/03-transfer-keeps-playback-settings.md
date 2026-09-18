# 3 — Queue transfer keeps consume, ReplayGain and crossfade

## The report

> Make sure queue transfer don't mess with consume/gain/fade. I got a feeling it
> does that intermittently. Maybe a code-review on the complete transfer logic.
> It must not change those three options.

## What "must not change" means here (decision)

After a transfer the app **follows** the music to the target partition
(`MPDStore.transferQueue`, the final `partition <target>`). So "unchanged" can
only mean *the settings in effect after the transfer are the ones that were in
effect before it*, which are the source's. The target's own previous settings
are what gets overwritten, just as its queue is. The source partition's settings
are left untouched: it is only cleared and stopped, as today.

The other reading, "never touch the target's settings", guarantees the reported
symptom whenever the two partitions differ, so it is rejected.
**Confirm before implementing.**

## Why it feels intermittent: MPD's per-partition state

In MPD, each partition has its own player, so these all live **per partition**:

| Setting | MPD command | Read from | Carried by v1.7? |
|---|---|---|---|
| repeat / random | `repeat` / `random` | `status` | yes |
| single | `single 0\|1\|oneshot` | `status` | **only as 0/1**: `oneshot` becomes 0 |
| consume | `consume 0\|1\|oneshot` (oneshot is 0.24+) | `status` | **only as 0/1** |
| crossfade | `crossfade N` | `status` → `xfade` (**absent when 0**) | **no** |
| MixRamp | `mixrampdb` / `mixrampdelay` | `status` | **no** |
| ReplayGain mode | `replay_gain_mode` | `replay_gain_status` (**not** in `status`) | **no** |

A transfer between two partitions that happen to agree changes nothing. Between
two that differ, crossfade and ReplayGain silently become the target's, and a
runtime-created partition starts with MPD's defaults (crossfade 0, ReplayGain
from mpd.conf). Which pair you transfer between decides whether you notice.
That is the intermittency.

## Review findings (whole transfer path)

`MPDStore.transferQueue` (≈1749) and the pure helpers in Models.swift (≈700–870).

- **T1 — Crossfade, MixRamp and ReplayGain mode are not carried.** This is the
  headline cause.
- **T2 — The modes are captured on main, from `@Published` state**
  (`let modes = (rep: repeatMode, …)` at ≈1769), while the play state and
  position are re-read from `status` on Q just before `save`. The modes should
  come from the same Q-side read: it is ground truth, and it is the same
  snapshot. Main-thread values lag by up to a poll (1–3 s), and a toggle made
  just before tapping Move can be lost.
- **T3 — `single`/`consume` lose `oneshot`.** The poll maps `s["single"] == "1"`
  to a Bool, so `oneshot` reads as off, and the transfer then sends `single 0`
  to the target.
- **T4 — Mode commands are `try?` and never verified.** A rejected `consume`
  (e.g. `consume oneshot` on a pre-0.24 server) goes unnoticed.
- **T5 — The ReplayGain display goes stale after any partition change.**
  `loadReplayGainStatus()` is called only from `loadAll()` (on connect). After a
  transfer, *or a plain `switchPartition`*, the Now Playing ReplayGain button
  keeps showing the old partition's mode. Even with T1 fixed, a manual switch
  would still show the wrong value. The user may have seen this as the transfer
  "changing" gain.
- **T6 — Crossfade display lag.** The poll updates `crossfadeSeconds` from
  `xfade`, which is correct, including the absent-means-0 case. After a
  transfer, though, the first poll can be up to 3 s away. The transfer
  completion should poll immediately. This is cosmetic, but it adds to the
  "flicker" impression.
- Checked and fine: the ordering and safety property (source untouched until the
  target plays), scratch playlist cleanup on every path, compensation of the
  elapsed time, the no-enabled-outputs refusal, the remember-partition
  bookkeeping, and that volume deliberately does not travel.

## Changes

### 1. `PlaybackSettings`, a pure value type in Models.swift

```swift
nonisolated struct PlaybackSettings: Equatable {
    var repeatOn: Bool
    var random: Bool
    var single: String        // "0" | "1" | "oneshot"   — raw, never collapsed
    var consume: String       // "0" | "1" | "oneshot"
    var crossfade: Int        // seconds; absent `xfade` = 0
    var mixrampDB: String?    // raw, nil when absent
    var mixrampDelay: String? // raw, nil when absent / "nan"
    var replayGainMode: String

    init(status: [String: String], replayGainStatus: [String: String])
    /// Commands that make a partition match these settings, in a fixed order.
    var applyCommands: [String]
}
```

- `init` owns every quirk in one tested place: `xfade` absent → 0, and
  `mixrampdelay` absent or `nan` → nil (MPD's "disabled").
- `applyCommands`: `repeat`, `random`, `single <raw>`, `consume <raw>`,
  `crossfade N`, `mixrampdb` (when non-nil), `mixrampdelay` (when non-nil,
  otherwise `mixrampdelay nan`, which disables it), and
  `replay_gain_mode "<mode>"`.

### 2. `transferQueue` changes

1. In the existing Q-side `status` read before `save`, also run
   `replay_gain_status` and build `PlaybackSettings` from both (fixes T2). Delete
   the main-thread `modes` capture.
2. Replace the four `repeat`/`random`/`single`/`consume` lines with
   `settings.applyCommands`, sent **after `load` and before the start command**,
   so crossfade and ReplayGain are in effect for the first sample the target
   plays.
3. After sending, read back (`status` + `replay_gain_status`) and build the
   target's `PlaybackSettings`. If it differs from the source's, the transfer
   **still succeeds**. The music has moved, and failing now would be worse. The
   completion gets a non-fatal note naming the settings that did not take, e.g.
   *"Moved. Crossfade could not be set on Kitchen (MPD said: …)."* This needs a
   small change to the completion's type: `String?` becomes a
   `TransferResult { failure: String?; warning: String? }`, and
   `MovePlaybackSheet` shows the warning. (Fixes T4.) Use the pure
   `transferSettingsMismatch(expected:actual:) -> [String]` for the comparison
   and the names.
4. The completion block on main also calls `loadReplayGainStatus()` and
   `Q.async { poll() }` so both displays are right the moment the sheet closes
   (T5 for transfer, T6).

### 3. `switchPartition` refreshes ReplayGain (T5)

Add `self.loadReplayGainStatus()` next to `loadQueue()/loadOutputs()/…` in
`switchPartition` and in the partition-restore path. One command.

### 4. Display of `oneshot` (T3, small)

Keep `singleMode: Bool` for the toggle, but add `singleOneshot` /
`consumeOneshot` so the poll no longer reads `oneshot` as off. The UI can show
it later. What matters in this release is that the transfer no longer destroys
it, and that is already handled by using raw strings in `PlaybackSettings`.
**Optional**; drop it if it grows past a few lines.

## Tests

Unit (pure, Models.swift):

- `PlaybackSettings(status:replayGainStatus:)`: `xfade` absent → 0; `single:
  oneshot` preserved raw; `consume: oneshot` preserved; `mixrampdelay: nan` →
  nil; `replay_gain_mode` read from its own record.
- `applyCommands`: exact command list and order for a representative value, and
  `mixrampdelay nan` when it is nil.
- `transferSettingsMismatch`: equal → `[]`; crossfade differs → `["Crossfade"]`;
  several differ → all named, in a stable order.

Live (`mikMPDTests/Local/`, Group D, since `MPD_INTEGRATION_MUTATE=1` is needed):

- extend the existing transfer live test. Set the **source** to consume 1,
  crossfade 3, ReplayGain `album`, and the **target** to consume 0, crossfade 0,
  ReplayGain `off`. Transfer, then assert that the target's
  `status`/`replay_gain_status` equal the source's former values, and that the
  source's settings are unchanged. Snapshot and restore **both** partitions'
  settings in `defer`. `ServerSnapshot` covers only the current partition
  (CLAUDE.md → "Verified server behavior"), so extend it or snapshot each
  partition explicitly. ReplayGain mode must be added to what it captures.
- Run it both directions, and three times, since the report was "intermittent".

## Manual verification

- [ ] Partition A: consume on, crossfade 5, ReplayGain album. Partition B: all off.
      Move A→B → Now Playing shows consume on, crossfade 5, RG album, and you
      hear crossfading at the next track change.
- [ ] Move back B→A → the same values, no flicker in the buttons.
- [ ] Switch partitions manually (no transfer) → the ReplayGain button reflects
      the partition switched to.

## Docs

CLAUDE.md → "Transferring a queue between partitions": replace "Modes
(`repeat`/`random`/`single`/`consume`) travel with the queue because they
describe it" with the full list, and explain *why*: crossfade, MixRamp and
ReplayGain are per-partition in MPD, and a transfer that skipped them looked
intermittent. Add that `replay_gain_mode` is not in `status`, alongside the
existing `xfade` note under "Verified server behavior".
