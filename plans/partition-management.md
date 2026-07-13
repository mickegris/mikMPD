# Plan: Create and delete partitions

**Status check:** partition *switching* (`switchPartition`), listing (`loadPartitions`), and
moving outputs between partitions all exist. Creating and deleting partitions do not.

## MPD protocol

- `newpartition {NAME}` — create.
- `delpartition {NAME}` — delete. **The partition must be empty**: no connected clients and no
  outputs assigned. Deleting the current partition or `default` is not possible.

## Store (MPDStore.swift, Outputs/Partitions section)

Both follow the existing pattern (`Q.async`, escaped args, refresh on main), but unlike most
store methods these need to surface ACK errors — "partition not empty" is a state the user must
act on (move outputs out first), not something to swallow with `try?`:

```swift
func createPartition(_ name: String, completion: @escaping (String?) -> Void)
    // "newpartition \"\(name.esc)\"" → nil on success, error text on ACK
func deletePartition(_ name: String, completion: @escaping (String?) -> Void)
    // "delpartition \"\(name.esc)\""
```

On success both call `loadPartitions()`; delete also calls `rebuildOutputPartitionsByProbing()`
indirectly via `loadOutputs()`. Completion runs on main with `error.localizedDescription`
(the `MPDError.ack` text is already human-readable enough; optionally strip the `ACK [..]@..`
prefix with a small helper — testable pure logic).

Guards before sending:
- Delete: refuse `default` and `currentPartition` in the store (also hide the affordance in UI).
- Create: trim name; reject empty and duplicates (case-sensitive match against `partitions`).
  MPD itself rejects invalid names with ACK, which we surface.

If `rememberPartitions` is on and the remembered `lastUsedPartitionName` gets deleted,
clear/reset it to `default` so `restorePartitionIfNeeded` doesn't try to restore a ghost.

## UI (OutputsView.swift, existing "Partitions" section)

- Section header gains a `+` button (or a "New Partition…" row at the bottom): alert with
  TextField → `createPartition`; on error show a second alert with the message.
- Partition rows get `.swipeActions` delete (destructive) — hidden for `default` and the
  current partition. Confirmation dialog first ("Delete partition 'x'? Outputs must be moved
  out first."), then `deletePartition`; ACK errors (not empty) shown in an alert.
- The section currently only renders when `partitions` is non-empty — keep the create button
  visible regardless (a server always has at least `default`, so this is mostly theoretical).

## Notes

- Partitions were introduced in MPD 0.22; `newpartition`/`delpartition` are baseline there —
  no version concerns beyond what the app already assumes.
- "No connected clients" includes *this* app if it's currently switched to that partition —
  hence the guard against deleting `currentPartition`.
- Tests: name validation + ACK-prefix stripping (pure logic). The rest is manual against a
  real server.
